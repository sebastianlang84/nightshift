#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 1
  max_findings_per_item: 1
  max_branches_per_run: 1
  max_fix_iterations: 1
recon:
  enabled: true
  ttl_days: 7
agent:
  primary: codex
  advisors: codex
  codex_model: gpt-6.2-astra
  codex_effort: high
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

# Fake only the first-party CLI boundary. Runner, recon, worktree, git, and ledger paths stay real.
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="" model="" effort="" sandbox="" approval="" network=""
ephemeral=0 ignore_config=0 ignore_rules=0 strict_config=0
exclude_tmp=0 exclude_tmpdir=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -m|--model) model="$2"; shift 2 ;;
    -s|--sandbox) sandbox="$2"; shift 2 ;;
    -a|--ask-for-approval) approval="$2"; shift 2 ;;
    --ephemeral) ephemeral=1; shift ;;
    --ignore-user-config) ignore_config=1; shift ;;
    --ignore-rules) ignore_rules=1; shift ;;
    --strict-config) strict_config=1; shift ;;
    -c)
      case "$2" in
        sandbox_workspace_write.network_access=false) network=off ;;
        sandbox_workspace_write.exclude_slash_tmp=true) exclude_tmp=1 ;;
        sandbox_workspace_write.exclude_tmpdir_env_var=true) exclude_tmpdir=1 ;;
        'model_reasoning_effort="high"') effort=high ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
[[ "$model" = gpt-6.2-astra && "$effort" = high && "$approval" = never &&
   "$ephemeral" = 1 && "$ignore_config" = 1 && "$ignore_rules" = 1 && "$strict_config" = 1 ]]
[[ "$GIT_CONFIG_COUNT" = 1 && "$GIT_CONFIG_KEY_0" = core.hooksPath && "$GIT_CONFIG_VALUE_0" = "$EXPECTED_HOOKS" ]]
prompt=$(cat)
case "$prompt" in
  *"RECON stage"*)
    [ "$sandbox" = read-only ]
    printf '%s' '{"dimensions":{"correctness":{"applicable":true,"hint":"code"}},"notes":"test recon"}' > "$out" ;;
  *"EXPLORE stage"*)
    [ "$sandbox" = read-only ]
    printf '%s' '{"found":true,"coverage":{"files":["README.md"],"entrypoints":["README -> rendered documentation"],"checks":["checked typo marker"],"invariants":{"config_domain":"not-applicable: no config","semantic_sets":"not-applicable: no sets","artifact_identity":"checked: one README artifact","failure_translation":"checked: explicit result JSON","lifecycle":"not-applicable: no lifecycle"},"unresolved":[]},"findings":[{"file":"README.md","type":"typo","line_window":"L1-L3","claim":"README contains teh","verify":"search README for teh","verifiability":"static","disposition":"fix","summary":"fix typo","fingerprint":"README.md:typo:L1-L3","rank":1,"confidence":1.0}]}' > "$out" ;;
  *"FIX stage"*)
    [[ "$sandbox" = workspace-write && "$network" = off && "$exclude_tmp" = 1 && "$exclude_tmpdir" = 1 ]]
    sed -i 's/teh/the/' README.md
    printf '%s' 'Fixed the typo in README.md.' > "$out" ;;
  *"REVIEW stage"*)
    [ "$sandbox" = read-only ]
    printf '%s' '{"verdict":"ship","proof":"verified","evidence":"README now contains the","reason":"minimal typo fix"}' > "$out" ;;
  *"INDEPENDENT branch reviewer"*)
    [ "$sandbox" = read-only ]
    printf '%s' '{"recommendation":"merge","what":"Typo fix","benefit":"Spelling","reason":"README corrected"}' > "$out" ;;
  *) exit 2 ;;
esac
# Event stream shape the adapter mines for telemetry: the model ID is announced once by the
# thread/session event and deliberately DIFFERS from the --model flag ("gpt-6.2-astra"), proving
# runs.jsonl records the model the CLI reports, not the one nightshift asked for. Codex's
# `input_tokens` includes `cached_input_tokens` and it reports no cost or cache-creation count.
printf '%s\n' '{"type":"thread.started","thread_id":"t1","model":"gpt-5-codex-test"}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1300,"cached_input_tokens":1200,"output_tokens":7}}'
EOF
chmod +x "$TMP/bin/codex"

# No NIGHTSHIFT_CODEX_REASONING_EFFORT: the stub demands effort=high, so the whole night proves the
# rulebook's `agent.codex_effort` reaches every stage.
env -u NIGHTSHIFT_CODEX_REASONING_EFFORT -u NIGHTSHIFT_AGENT -u NIGHTSHIFT_CODEX_MODEL -u NIGHTSHIFT_REVIEW_MODEL -u NIGHTSHIFT_ADVISORS \
PATH="$TMP/bin:/usr/bin:/bin" \
RULEBOOK="$TMP/rulebook.yaml" \
CODEX_HOME="$TMP/fake-operator" EXPECTED_HOOKS="$ROOT/hooks" \
NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/log" 2>&1 || { cat "$TMP/log" >&2; exit 1; }
grep -q 'agent=codex ' "$TMP/log"
grep -q 'codex model: gpt-6.2-astra (from rulebook agent.codex_model)' "$TMP/log"
grep -q 'codex effort: high' "$TMP/log"

branch=$(git --git-dir="$TMP/remote.git" for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*')
[ -n "$branch" ]
git --git-dir="$TMP/remote.git" show "$branch:README.md" | grep -q 'This is the demo.'
# Telemetry: `model` stays the ADAPTER name, `model_id` the model the CLI reported, plus the token
# counters. Fields codex does not report degrade to null, they must not be invented. Asserted on
# EVERY line, so one stage losing its usage sidecar fails the test.
jq -se '([.[].stage] | unique) == ["advise","explore","fix","recon","review"] and all(.model=="codex" and .model_id=="gpt-5-codex-test" and .tokens==7 and .input_tokens==1300
            and .cache_read_tokens==1200 and .cache_creation_tokens==null
            and .context_window==null and .cost_usd==null and .model_cost_usd==null
            and .exit==0)' "$TMP/state/runs.jsonl" >/dev/null
jq -e 'select(.outcome=="shipped" and .branch!=null)' "$TMP/state/ledger.jsonl" >/dev/null

# Effort precedence, unit level: env if SET (empty = pass none) > `agent.codex_effort` > CLI default.
# A stub that records its argv NUL-separated; the argv file is deleted before each call so a failed
# call cannot leave the previous one's argv behind.
mkdir -p "$TMP/ubin" "$TMP/ustate" "$TMP/uwd" "$TMP/uitem" "$TMP/ucodex"
cat > "$TMP/ubin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "$NIGHTSHIFT_TEST_ARGV"
out="" model="" prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; --model) model="$a" ;; esac
  prev="$a"
done
if [ -n "${WALLED_MODEL:-}" ] && [ "$model" = "$WALLED_MODEL" ]; then
  : > "$out"
  printf '%s\n' '{"type":"turn.failed","error":{"message":"quota exhausted"}}'
  exit 1
fi
[ -z "$out" ] || printf '%s' '{}' > "$out"
cat >/dev/null
printf '%s\n' '{"type":"turn.completed","usage":{"output_tokens":1}}'
EOF
chmod +x "$TMP/ubin/codex"
(
  fail() { echo "FAIL: $*" >&2; exit 1; }
  export PATH="$TMP/ubin:$PATH" CODEX_HOME="$TMP/ucodex" NIGHTSHIFT_TEST_ARGV="$TMP/argv"
  export NIGHTSHIFT_STATE_DIR="$TMP/ustate" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
         NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
         RULEBOOK="$TMP/rulebook.yaml"
  unset NIGHTSHIFT_AGENT NIGHTSHIFT_CODEX_REASONING_EFFORT NIGHTSHIFT_CODEX_MODEL NIGHTSHIFT_REVIEW_MODEL
  # shellcheck disable=SC1090
  NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
  load_rulebook
  [ "$RB_CODEX_EFFORT" = high ] || fail "rulebook codex_effort not loaded: '$RB_CODEX_EFFORT'"
  stage_prompt() { printf 'stub stage %s' "$1"; }
  RB_REVIEW_MODEL=codex-review
  for stage in recon explore fix review advise verify; do
    codex_run "$stage" "$TMP/uwd" "$TMP/uitem"
    mapfile -d '' -t argv < "$TMP/argv"
    model="" sandbox=""
    for i in "${!argv[@]}"; do
      case "${argv[i]}" in
        --model) model="${argv[i+1]}" ;;
        --sandbox) sandbox="${argv[i+1]}" ;;
      esac
    done
    case "$stage" in
      review|advise) expected=codex-review ;;
      *) expected=gpt-6.2-astra ;;
    esac
    [ "$model" = "$expected" ] || fail "$stage requested $model"
    expected=read-only; [ "$stage" != fix ] || expected=workspace-write
    [ "$sandbox" = "$expected" ] || fail "$stage requested $sandbox"
  done
  [ "$(advisor_model codex 1)" = codex-review ] || fail "Codex advice cache missed review_model"
  RB_CLAUDE_MODEL=claude-advisor
  [ "$(advisor_model claude 1)" = claude-advisor ] || fail "Codex review_model reached a Claude advisor"
  export WALLED_MODEL=codex-review
  EMPTY_ANSWER_RETRIES=0
  run_agent review "$TMP/uwd" "$TMP/uitem" 2>/dev/null && fail "walled review succeeded"
  [ -z "$AGENT_FATAL" ] || fail "one review failure ended the night"
  run_agent fix "$TMP/uwd" "$TMP/uitem"
  run_agent review "$TMP/uwd" "$TMP/uitem" 2>/dev/null && fail "second walled review succeeded"
  [[ "$AGENT_FATAL_AGENT" = codex && "$AGENT_FATAL" = *"model codex-review"* ]] || fail "lost the review model's wall"
  unset WALLED_MODEL
  printf '%s\n' '{"type":"item.completed","item":{"text":"codex login"}}' > "$TMP/event"
  agent_credentials_failed /dev/null "$TMP/event" && fail "repository text was mistaken for a login failure"
  printf '%s\n' '{"type":"turn.failed","error":{"message":"run codex login"}}' >> "$TMP/event"
  agent_credentials_failed /dev/null "$TMP/event" || fail "Codex login failure was missed"

  efforts() { # label -> prints every model_reasoning_effort override codex received
    rm -f "$TMP/argv"
    codex_run recon "$TMP/uwd" "$TMP/uitem" >/dev/null 2>&1 || fail "codex_run failed ($1)"
    [ -f "$TMP/argv" ] || fail "codex_run never reached the stub ($1)"
    mapfile -d '' -t ARGV < "$TMP/argv"
    local i
    for i in "${!ARGV[@]}"; do
      [ "${ARGV[$i]}" = -c ] || continue
      case "${ARGV[$((i + 1))]:-}" in model_reasoning_effort=*) printf '%s\n' "${ARGV[$((i + 1))]}" ;; esac
    done
  }
  [ "$(efforts rulebook)" = 'model_reasoning_effort="high"' ] \
    || fail "rulebook effort must pass -c model_reasoning_effort=\"high\": $(efforts rulebook)"
  export NIGHTSHIFT_CODEX_REASONING_EFFORT=low
  [ "$(efforts env-wins)" = 'model_reasoning_effort="low"' ] \
    || fail "env effort must beat the rulebook: $(efforts env-wins)"
  export NIGHTSHIFT_CODEX_REASONING_EFFORT=
  [ -z "$(efforts escape-hatch)" ] || fail "empty env effort must pass none: $(efforts escape-hatch)"
  unset NIGHTSHIFT_CODEX_REASONING_EFFORT
  RB_CODEX_EFFORT=""
  [ -z "$(efforts neither)" ] || fail "no declared effort must pass none: $(efforts neither)"
)
echo "test-codex-adapter: ok"
