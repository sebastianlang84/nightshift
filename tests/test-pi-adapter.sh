#!/usr/bin/env bash
# The pi adapter (ADR 0031) serving the Review stage while the night runs on another adapter:
# the flags it passes, the stage isolation it sets up, the telemetry it mines from pi's event
# stream, and its refusal to serve the Fix stage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/pi-real"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

# The operator's real pi dir: credentials and catalogs to carry over, plus the global AGENTS.md that
# must NOT be carried over (ADR 0019).
printf '{}\n'                       > "$TMP/pi-real/auth.json"
printf '{}\n'                       > "$TMP/pi-real/models.json"
printf '{}\n'                       > "$TMP/pi-real/models-store.json"
printf 'operator private rules\n'   > "$TMP/pi-real/AGENTS.md"
# On a gateway host the AUTH ITSELF is a pi extension, so stage isolation cannot simply switch
# extension discovery off — it has to load this one back by path (ADR 0031).
printf '// auth extension\n'        > "$TMP/pi-real/auth-ext.ts"

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
agent:
  review_agent: pi
  pi_model: z-ai/glm-5.3-flash
  pi_provider: pidso-proxy
  pi_extensions: $TMP/pi-real/auth-ext.ts,$TMP/pi-real/missing-ext.ts
limits:
  max_open_branches: 1
  max_findings_per_item: 1
  max_branches_per_run: 1
  max_fix_iterations: 1
recon:
  enabled: true
  ttl_days: 7
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: branch-fix
    test_cmd: true
    base: main
    findings: 1
    dimensions: correctness
EOF

# Fake only the first-party CLI boundary. The stub asserts the adapter's contract and then emits the
# event shape a real pi 0.84.2 emits (verified 2026-08-30): JSONL, the answer as the text content of
# the last assistant message_end whose stopReason is "stop", usage PER MESSAGE rather than cumulative.
cat > "$TMP/bin/pi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
model="" provider="" tools="" prompt="" exts="" print=0 mode="" nosession=0 noext=0 noskills=0 notpl=0 noappr=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    --provider) provider="$2"; shift 2 ;;
    --tools|-t) tools="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    -p|--print) print=1; shift ;;
    --no-session) nosession=1; shift ;;
    --no-extensions|-ne) noext=1; shift ;;
    --no-skills|-ns) noskills=1; shift ;;
    --no-prompt-templates|-np) notpl=1; shift ;;
    --no-approve|-na) noappr=1; shift ;;
    -e|--extension) exts="${exts:+$exts,}$2"; shift 2 ;;
    --) shift; prompt="$1"; shift ;;
    *) shift ;;
  esac
done
# The contract the adapter promises: the declared model/provider, headless JSON, every discovery
# source off, and a READ-ONLY tool set with no bash/edit/write in it.
#
# One assertion per line, each with its own `|| exit`. A single `&&` chain would check only its LAST
# link: bash's `set -e` does not fire when a command left of `&&` fails, so the chain would abort,
# fall through, and the stub would still emit a perfectly successful stream — the test passing
# against an adapter that dropped --no-extensions, the model, or the provider.
fail() { echo "pi stub: $1" >&2; exit 3; }
[ "$model"     = z-ai/glm-5.3-flash ] || fail "model=$model"
[ "$provider"  = pidso-proxy ]        || fail "provider=$provider"
[ "$print"     = 1 ]                  || fail "no -p"
[ "$mode"      = json ]               || fail "mode=$mode"
[ "$nosession" = 1 ]                  || fail "no --no-session"
[ "$noext"     = 1 ]                  || fail "no --no-extensions"
[ "$noskills"  = 1 ]                  || fail "no --no-skills"
[ "$notpl"     = 1 ]                  || fail "no --no-prompt-templates"
[ "$noappr"    = 1 ]                  || fail "no --no-approve"
[ "$tools"     = "read,grep,find,ls" ] || fail "tools=$tools"
case ",$tools," in *,bash,*|*,edit,*|*,write,*) fail "write/exec tool granted: $tools" ;; esac
# Extension discovery is off, yet the declared auth extension must still arrive by path — without it
# a gateway host answers 403, which reads like a revoked credential and is not. A declared path that
# does NOT exist must be dropped rather than passed on, so pi is not handed a broken argument.
case ",$exts," in *auth-ext.ts*) ;; *) fail "auth extension not loaded: $exts" ;; esac
case ",$exts," in *missing-ext.ts*) fail "a nonexistent extension was passed to pi" ;; esac
# Stage isolation: a Runner-owned agent dir holding the credentials and catalogs but NOT the
# operator's AGENTS.md. Asserted here because this is the only place that can see the env pi got.
# One per line, for the same reason as above.
[ -n "${PI_CODING_AGENT_DIR:-}" ]                 || fail "no PI_CODING_AGENT_DIR"
[ -e "$PI_CODING_AGENT_DIR/auth.json" ]           || fail "stage home carries no credentials"
[ -e "$PI_CODING_AGENT_DIR/models-store.json" ]   || fail "stage home carries no model catalog"
[ ! -e "$PI_CODING_AGENT_DIR/AGENTS.md" ]         || fail "operator AGENTS.md leaked into the stage"
case "$prompt" in
  *"REVIEW stage"*) answer='{"verdict":"ship","proof":"verified","evidence":"README now contains the","reason":"minimal typo fix"}' ;;
  *) exit 2 ;;
esac
printf '%s\n' '{"type":"session","version":3}'
# A thinking-only message and a tool call come first: neither is the answer, and a parser that takes
# the last assistant message without checking for text content would return one of them.
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"pondering"}],"model":"z-ai/glm-5.3-flash","usage":{"input":100,"output":5,"cacheRead":10,"cacheWrite":1,"cost":{"total":0.001}},"stopReason":"toolUse"}}'
printf '%s\n' '{"type":"message_end","message":{"role":"toolResult","toolName":"read","content":[{"type":"text","text":"README"}]}}'
printf '%s\n' "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$answer" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}],\"model\":\"z-ai/glm-5.3-flash-served\",\"usage\":{\"input\":200,\"output\":7,\"cacheRead\":20,\"cacheWrite\":2,\"cost\":{\"total\":0.002}},\"stopReason\":\"stop\"}}"
printf '%s\n' '{"type":"agent_settled"}'
EOF
chmod +x "$TMP/bin/pi"

# A real night: mock serves every stage, pi serves Review only.
PATH="$TMP/bin:/usr/bin:/bin" \
RULEBOOK="$TMP/rulebook.yaml" \
NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_PI_STAGE_HOME="$TMP/state/pi-home" PI_CODING_AGENT_DIR="$TMP/pi-real" \
NIGHTSHIFT_PI_UPDATE=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" > "$TMP/night.log" 2>&1

branch=$(git --git-dir="$TMP/remote.git" for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*')
[ -n "$branch" ] || { echo "no branch shipped" >&2; sed -n '1,40p' "$TMP/night.log" >&2; exit 1; }
git --git-dir="$TMP/remote.git" show "$branch:README.md" | grep -q 'This is the demo.'

# Review ran on pi while everything else ran on mock — the split is what ADR 0031 buys.
jq -se 'any(.[]; .stage=="review" and .model=="pi")
        and all(.[]; select(.stage!="review") | .model=="mock")' \
  "$TMP/state/runs.jsonl" >/dev/null || { echo "review did not route to pi" >&2; exit 1; }

# Telemetry: model_id is what pi REPORTED (not the flag), counters are summed across the stage's
# messages, and the field pi does not report stays null instead of being invented.
jq -se '[.[] | select(.stage=="review")] | length==1 and (.[0]
        | .model_id=="z-ai/glm-5.3-flash-served" and .tokens==12 and .input_tokens==300
          and .cache_read_tokens==30 and .cache_creation_tokens==3
          and .context_window==null and .exit==0)' "$TMP/state/runs.jsonl" >/dev/null \
  || { echo "pi telemetry wrong" >&2; jq -c 'select(.stage=="review")' "$TMP/state/runs.jsonl" >&2; exit 1; }

grep -q 'review stage: pi' "$TMP/night.log" || { echo "route not announced" >&2; exit 1; }

# The Fix refusal: pi has no write-confinement mechanism, so it must refuse rather than write
# unconfined. Exercised directly — the night above never routes fix to pi.
(
  export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_AGENT=pi NIGHTSHIFT_STATE_DIR="$TMP/state2"
  export NIGHTSHIFT_RUNS_DIR="$TMP/runs2" NIGHTSHIFT_DIGEST_DIR="$TMP/digests2"
  export NIGHTSHIFT_WORKTREES="$TMP/worktrees2"
  # shellcheck disable=SC1090
  source "$ROOT/bin/nightshift.sh"
  mkdir -p "$TMP/item"
  rc=0; pi_run fix "$TMP/repo" "$TMP/item" || rc=$?
  [ "$rc" = 2 ] || { echo "pi_run fix returned $rc, expected 2" >&2; exit 1; }
  grep -q 'read-only' "$TMP/item/fix.err" || { echo "no refusal reason recorded" >&2; exit 1; }
)

# --- The daily catalog refresh. pi resolves a model against a cached catalog, so a stale one
# refuses a model the provider already serves; the refresh runs once per DAY, not once per run, and
# a failure must never take the night down with it.
(
  export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_AGENT=mock NIGHTSHIFT_REVIEW_AGENT=pi
  export NIGHTSHIFT_STATE_DIR="$TMP/state3" NIGHTSHIFT_RUNS_DIR="$TMP/runs3"
  export NIGHTSHIFT_DIGEST_DIR="$TMP/digests3" NIGHTSHIFT_WORKTREES="$TMP/worktrees3"
  mkdir -p "$TMP/bin2"
  cat > "$TMP/bin2/pi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/pi-update.log"
EOF
  chmod +x "$TMP/bin2/pi"
  PATH="$TMP/bin2:$PATH"
  # shellcheck disable=SC1090
  source "$ROOT/bin/nightshift.sh"
  pi_daily_update
  pi_daily_update   # same day: must be a no-op, not a second round of network work
  [ "$(grep -c . "$TMP/pi-update.log")" = 2 ] || {
    echo "expected exactly one update pass, got: $(cat "$TMP/pi-update.log")" >&2; exit 1; }
  grep -qx 'update --all'    "$TMP/pi-update.log" || { echo "no --all pass" >&2; exit 1; }
  grep -qx 'update --models' "$TMP/pi-update.log" || { echo "no --models pass" >&2; exit 1; }
  [ "$(cat "$TMP/state3/.pi-update-day")" = "$(date +%F)" ] || { echo "stamp wrong" >&2; exit 1; }

  # NIGHTSHIFT_PI_PATH must reach the pi subprocess: pi is an npm-global under nvm whose
  # `env node` shebang otherwise picks the system node, which is too old to run it at all.
  rm -f "$TMP/state3/.pi-update-day" "$TMP/pi-update.log"
  mkdir -p "$TMP/nvmbin"
  cat > "$TMP/nvmbin/pi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "nvm:\$*" >> "$TMP/pi-update.log"
EOF
  chmod +x "$TMP/nvmbin/pi"
  NIGHTSHIFT_PI_PATH="$TMP/nvmbin" pi_daily_update
  grep -q '^nvm:update --all' "$TMP/pi-update.log" \
    || { echo "NIGHTSHIFT_PI_PATH did not reach the pi subprocess: $(cat "$TMP/pi-update.log")" >&2; exit 1; }

  # A night that never touches pi must not run it at all.
  rm -f "$TMP/state3/.pi-update-day"
  NIGHTSHIFT_REVIEW_AGENT="" NIGHTSHIFT_AGENT=mock pi_daily_update
  [ ! -e "$TMP/state3/.pi-update-day" ] || { echo "updated pi for a night that never uses it" >&2; exit 1; }

  # A failing refresh leaves the stamp unwritten (so tomorrow retries) and still returns success.
  cat > "$TMP/bin2/pi" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$TMP/bin2/pi"
  rc=0; pi_daily_update || rc=$?
  [ "$rc" = 0 ] || { echo "a failed refresh was fatal to the night (exit $rc)" >&2; exit 1; }
  [ ! -e "$TMP/state3/.pi-update-day" ] || { echo "a failed refresh stamped the day as done" >&2; exit 1; }
)

echo "test-pi-adapter: ok"
