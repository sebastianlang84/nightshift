#!/usr/bin/env bash
# nightshift — the Brain / Runner (prototype).
#
# Outer loop: select a repo -> Explore -> Fix<->Review (capped) -> Finalize
# (push a nightshift/* branch) -> record. Enforces the nightly branch cap and the
# global open-branch backpressure. The agent invocation sits behind run_agent()
# (ADR 0001 adapter seam): NIGHTSHIFT_AGENT=mock | claude | codex.
set -euo pipefail

NIGHTSHIFT_HOME="${NIGHTSHIFT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NIGHTSHIFT_AGENT="${NIGHTSHIFT_AGENT:-mock}"
# After pushing a nightshift/* branch, optionally open a PR for it (1=on). OFF by default:
# a PR is a host-API object that needs per-host API credentials (GitHub token, Bitbucket app
# password, ...) which the SSH git transport does NOT provide — so branch-only is the credential-
# free baseline and the pushed branch is the unit of review. Opt in with NIGHTSHIFT_OPEN_PR=1
# once the host credential is in the run environment (GitHub-only today; see todo Luecke 1).
NIGHTSHIFT_OPEN_PR="${NIGHTSHIFT_OPEN_PR:-0}"
RULEBOOK="${RULEBOOK:-$NIGHTSHIFT_HOME/rulebook.yaml}"
[ -f "$RULEBOOK" ] || RULEBOOK="$NIGHTSHIFT_HOME/rulebook.example.yaml"
HOOKS_DIR="$NIGHTSHIFT_HOME/hooks"
# State/runs/digests default under NIGHTSHIFT_HOME but are env-overridable so a test
# run (e.g. an isolated claude e2e) writes nowhere near the live ledger/digest.
STATE_DIR="${NIGHTSHIFT_STATE_DIR:-$NIGHTSHIFT_HOME/state}"
NIGHT="$(date +%Y-%m-%d)"
RUNS_DIR="${NIGHTSHIFT_RUNS_DIR:-$NIGHTSHIFT_HOME/runs}/$NIGHT"
DIGEST_DIR="${NIGHTSHIFT_DIGEST_DIR:-$NIGHTSHIFT_HOME/digests}"
LEDGER="$STATE_DIR/ledger.jsonl"
RUNSLOG="$STATE_DIR/runs.jsonl"
RECON_DIR="$STATE_DIR/recon"   # per-repo recon caches (ADR 0010); derived, disposable, HEAD/TTL-invalidated
# Worktrees live OUTSIDE the control repo, so nightshift can target its own repo
# without nesting a worktree inside a working tree.
WORKTREES_DIR="${NIGHTSHIFT_WORKTREES:-${TMPDIR:-/tmp}/nightshift-worktrees}"
mkdir -p "$STATE_DIR" "$RUNS_DIR" "$DIGEST_DIR" "$WORKTREES_DIR"

log() { echo "[nightshift] $*" >&2; }

# ---------------------------------------------------------------- rulebook ----
declare -a REPO_PATHS=() REPO_MODES=() REPO_BASES=() REPO_FINDINGS=() REPO_DIMS=() DIMENSIONS=()
load_rulebook() {
  local tag a b c d e rb_run_branches="" parsed
  # Capture the parser's output AND its exit status. Reading it directly via
  # `done < <(python3 …)` hides a nonzero exit from `set -euo pipefail`, so a
  # mid-stream parse error (e.g. a bad `findings:` on repo #2) silently truncated
  # the repo set — the bad repo AND every valid repo after it were dropped and the
  # run proceeded on a partial fleet. Fail closed instead: abort the whole run.
  parsed="$(python3 "$NIGHTSHIFT_HOME/lib/parse_rulebook.py" "$RULEBOOK")" \
    || { log "rulebook parse failed ($RULEBOOK) — aborting run"; exit 1; }
  while IFS=$'\t' read -r tag a b c d e; do
    case "$tag" in
      prefix)                BRANCH_PREFIX="$a" ;;
      max_open)              MAX_OPEN="$a" ;;
      max_findings_per_item) MAX_FINDINGS="$a" ;;
      recon_enabled)         RECON_ENABLED="$a" ;;
      recon_ttl_days)        RECON_TTL_DAYS="$a" ;;
      max_branches_per_run)  rb_run_branches="$a" ;;
      max_fix_iterations)    MAX_FIX_ITER="$a" ;;
      max_files)             MAX_FILES="$a" ;;
      max_lines)             MAX_LINES="$a" ;;
      dimension)             DIMENSIONS+=("$a") ;;
      repo)                  REPO_PATHS+=("${a#path=}"); REPO_MODES+=("${b#mode=}"); REPO_BASES+=("${c#base=}"); REPO_FINDINGS+=("${d#findings=}"); REPO_DIMS+=("${e#dimensions=}") ;;
    esac
  done <<< "$parsed"
  MAX_FINDINGS="${MAX_FINDINGS:-1}"
  RECON_ENABLED="${RECON_ENABLED:-true}"; RECON_TTL_DAYS="${RECON_TTL_DAYS:-7}"
  # Fallback dimension set if the rulebook declares none, so rotation still works out of the box.
  [ "${#DIMENSIONS[@]}" -gt 0 ] || DIMENSIONS=(correctness security infra docs tests perf ui-ux deps craft)
  # Per-run safety ceiling: the rulebook wins; NIGHTSHIFT_MAX_RUN_BRANCHES stays as an
  # ops override for when it is not set there; 50 is the last-resort default.
  MAX_RUN_BRANCHES="${rb_run_branches:-${NIGHTSHIFT_MAX_RUN_BRANCHES:-50}}"
  export NIGHTSHIFT_BRANCH_PREFIX="$BRANCH_PREFIX"
}

# --------------------------------------------------------------- telemetry ----
append_run() { # stage agent start dur tokens status item cost
  jq -nc \
    --arg night "$NIGHT" --arg item "$7" --arg stage "$1" --arg model "$2" \
    --argjson start "$3" --argjson dur "$4" --arg tokens "$5" --argjson status "$6" --arg cost "$8" \
    '{night:$night,item:$item,stage:$stage,model:$model,start:$start,
      duration_s:$dur,
      tokens:($tokens|if .=="" then null else (tonumber? // null) end),
      cost_usd:($cost|if .=="" then null else (tonumber? // null) end),
      exit:$status}' >> "$RUNSLOG"
}

ledger_append() { # item repo fp branch sha outcome [summary] [pr_url] [proof] [verifiability] [dimension]
  jq -nc \
    --arg night "$NIGHT" --arg item "$1" --arg repo "$2" --arg fp "$3" \
    --arg branch "$4" --arg sha "$5" --arg outcome "$6" --arg summary "${7:-}" --arg pr "${8:-}" \
    --arg proof "${9:-}" --arg verif "${10:-}" --arg dim "${11:-}" --arg ts "$(date -Iseconds)" \
    '{night:$night,item:$item,repo:$repo,fingerprint:$fp,
      branch:($branch|if .=="" then null else . end),
      sha:($sha|if .=="" then null else . end),
      pr_url:($pr|if .=="" then null else . end),
      proof:($proof|if .=="" then null else . end),
      verifiability:($verif|if .=="" then null else . end),
      dimension:($dim|if .=="" then null else . end),
      outcome:$outcome,summary:$summary,ts:$ts}' >> "$LEDGER"
}

# Robust identity for a finding. The agent (claude mode) may omit `fingerprint`
# despite the prompt; a missing field reads back as the literal "null" via jq -r
# and would then poison dedup (every fingerprint-less finding collapses onto one
# key). Use the model's value when present, else synthesise from file:type:line_window,
# else echo "" so the caller can drop an unusable finding.
finding_fingerprint() { # finding.json -> fingerprint or ""
  jq -r '
    (.fingerprint // "") as $fp
    | if ($fp|type)=="string" and ($fp|length)>0 and $fp!="null" then $fp
      else [(.file // ""),(.type // ""),(.line_window // "")]
           | map(select(. != "" and . != null))
           | if length>0 then join(":") else "" end
      end' "$1" 2>/dev/null || true
}

already_done() { # fingerprint — ANY prior ledger entry (used by findings-only, report once)
  [ -n "$1" ] && [ "$1" != null ] || return 1   # never dedup on an unusable key
  [ -f "$LEDGER" ] || return 1
  grep -Fq "\"fingerprint\":\"$1\"" "$LEDGER"
}
already_acted() { # fingerprint — only shipped/abandoned/deferred (used by branch-fix)
  [ -n "$1" ] && [ "$1" != null ] || return 1   # never dedup on an unusable key
  [ -f "$LEDGER" ] || return 1
  # jq match, not a grep regex: fingerprints contain '.'/'/'/':' that would be
  # interpreted as regex metacharacters and could match a *different* fingerprint.
  # Slurp + any() so the verdict is order-independent (a non-matching *last* line
  # must not flip jq -e's exit status).
  jq -se --arg fp "$1" \
    'any(.[]; .fingerprint==$fp and (.outcome=="shipped" or .outcome=="abandoned" or .outcome=="deferred"))' \
    "$LEDGER" >/dev/null 2>&1
}
already_surfaced() { # fingerprint — a prior human-owned finding exists (a TODO is open)
  [ -n "$1" ] && [ "$1" != null ] || return 1   # never dedup on an unusable key
  [ -f "$LEDGER" ] || return 1
  # Only `finding` outcomes count: a surfaced divergence LATCHES until a human clears it,
  # so it neither re-surfaces nor gets silently auto-fixed on a later run — and an earlier
  # `abandoned`/`shipped` must NOT masquerade as "already surfaced" and suppress the TODO.
  jq -se --arg fp "$1" \
    'any(.[]; .fingerprint==$fp and .outcome=="finding")' \
    "$LEDGER" >/dev/null 2>&1
}

last_serviced_epoch() { # repo -> epoch of the last WORK-ITEM nightshift produced for it (0 if never)
  # Fairness signal for select_order (ADR 0008): the more recently nightshift last serviced a
  # repo, the LATER it sorts. Only work-item outcomes count (finding/shipped/abandoned) — the
  # harvest `verdict` reconcile rows are bookkeeping, not attention spent, and would otherwise
  # make a just-merged repo look freshly serviced and sink it unfairly.
  local repo="$1" iso
  [ -f "$LEDGER" ] || { echo 0; return; }
  iso=$(jq -rs --arg r "$repo" \
    '[.[]|select(.repo==$r and (.outcome=="finding" or .outcome=="shipped" or .outcome=="abandoned"))|.ts]
     | max // empty' "$LEDGER" 2>/dev/null || true)
  [ -n "$iso" ] || { echo 0; return; }
  date -d "$iso" +%s 2>/dev/null || echo 0
}

# Layer 2 settings for the agent: register the PreToolUse guard so the agent
# cannot disable the pre-push hook (--no-verify / core.hooksPath override).
write_claude_settings() {
  jq -nc --arg cmd "$HOOKS_DIR/pretooluse-guard.sh" \
    '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]}}' \
    > "$STATE_DIR/claude-settings.json"
}

# codemap (optional structural index) — an MCP tool, so it adds navigation power WITHOUT reopening
# Bash. Auto-gated per repo: only offered where the repo is already indexed. The agent works in a
# throwaway worktree (no index) and queries the STABLE real repo via repoPath; unindexed or codemap
# not installed -> the agent just uses Read/Grep/Glob. Activation is a human step: `codemap index
# --approve --repo <path>` once.
write_codemap_mcp() {
  printf '%s\n' '{"mcpServers":{"codemap":{"type":"stdio","command":"codemap-mcp","args":[],"env":{}}}}' \
    > "$STATE_DIR/codemap-mcp.json"
}

# --------------------------------------------------------------- run_agent ----
run_agent() { # stage workdir item_dir
  local stage="$1" workdir="$2" item_dir="$3" start end status=0 tokens="" cost=""
  start=$(date +%s)
  case "$NIGHTSHIFT_AGENT" in
    mock)   "mock_$stage" "$workdir" "$item_dir" || status=$? ;;
    claude) claude_run "$stage" "$workdir" "$item_dir" || status=$? ;;
    codex)  codex_run "$stage" "$workdir" "$item_dir" || status=$? ;;
    *) log "unknown NIGHTSHIFT_AGENT=$NIGHTSHIFT_AGENT (expected mock, claude, or codex)"; status=2 ;;
  esac
  if [ "$NIGHTSHIFT_AGENT" != mock ]; then
    tokens=$(cat "$item_dir/.tokens_$stage" 2>/dev/null || true)
    cost=$(cat "$item_dir/.cost_$stage" 2>/dev/null || true)
  fi
  end=$(date +%s)
  append_run "$stage" "$NIGHTSHIFT_AGENT" "$start" "$((end - start))" "$tokens" "$status" "$(basename "$item_dir")" "$cost"
  return "$status"
}

stage_prompt() { # stage workdir item_dir -> prompt on stdout
  local stage="$1" wd="$2" id="$3" prompt
  prompt="$(cat "$NIGHTSHIFT_HOME/prompts/$stage.md")

## Context
Repo working directory: $wd"
  case "$stage" in
    explore|fix) prompt="$prompt

## Change-size guidance (soft — not a hard cap)
Prefer a change under ${MAX_FILES:-15} files and ${MAX_LINES:-400} lines. Larger is acceptable only
if it is genuinely ONE coherent, reviewable improvement — never bundle unrelated changes." ;;
  esac
  if [ "$stage" = explore ]; then
    prompt="$prompt

## Findings budget
Emit UP TO ${NIGHTSHIFT_FINDINGS_N:-1} finding(s) this pass — the top of your ranked shortlist, each a
DISTINCT root cause (the repeated-inconsistency rule still collapses twins into ONE finding). Rank them
so the most valuable is first; the runner ships in that order and truncates at the cap. Fewer is fine —
never pad. If nothing clears the value bar, return found:false with an empty findings array."
  fi
  if [ "$stage" = explore ] && [ -n "${NIGHTSHIFT_DIMENSION:-}" ] && \
     [ -f "$NIGHTSHIFT_HOME/prompts/dimensions/$NIGHTSHIFT_DIMENSION.md" ]; then
    prompt="$prompt

## Tonight's lens: ${NIGHTSHIFT_DIMENSION}
Aim your scan through the lens below. Rank findings WITHIN it — but a screaming, out-of-lens
correctness bug you happen to see may still take a slot; the lens focuses attention, it does not
blind you to a live bug.

$(cat "$NIGHTSHIFT_HOME/prompts/dimensions/$NIGHTSHIFT_DIMENSION.md")"
  fi
  if [ "$stage" = explore ] && [ -n "${NIGHTSHIFT_RECON_NOTES:-}" ]; then
    prompt="$prompt

## Repo orientation (from tonight's recon)
${NIGHTSHIFT_RECON_NOTES}"
  fi
  if [ "$stage" = recon ] && [ -f "$id/signals.json" ]; then
    prompt="$prompt

### recon_signals (deterministic filesystem probe — refine these into per-dimension applicability)
$(cat "$id/signals.json")"
  fi
  case "$stage" in
    fix|review) prompt="$prompt

### finding.json
$(cat "$id/finding.json")" ;;
  esac
  if [ "$stage" = review ]; then
    prompt="$prompt

### git diff (working tree)
$(git -C "$wd" diff)"
  fi
  printf '%s' "$prompt"
}

# ---- mock adapter (deterministic; the tested path) ----
mock_explore() { # workdir item_dir — emits the v2 container {found, findings:[…]} with up to N planted defects
  local wd="$1" id="$2" arr='[]'
  if [ -f "$wd/README.md" ] && grep -q 'teh ' "$wd/README.md"; then
    arr=$(printf '%s' "$arr" | jq -c '. + [{file:"README.md",type:"typo",line_window:"L1-L40",
      disposition:"fix",verifiability:"static",summary:"typo \"teh\" -> \"the\" in README",
      fingerprint:"README.md:typo:L1-L40",rank:1,confidence:0.9}]')
  fi
  if [ -f "$wd/app.py" ] && grep -q 'retrun' "$wd/app.py"; then
    arr=$(printf '%s' "$arr" | jq -c '. + [{file:"app.py",type:"typo",line_window:"L1-L10",
      disposition:"fix",verifiability:"static",summary:"typo \"retrun\" -> \"return\" in app.py comment",
      fingerprint:"app.py:typo:L1-L10",rank:2,confidence:0.9}]')
  fi
  jq -nc --argjson f "$arr" '{found:($f|length>0),findings:$f}' > "$id/finding.json"
}
mock_fix() { # workdir item_dir — applies the fix for THIS finding (dispatched on .file)
  local wd="$1" id="$2" file
  file=$(jq -r '.file' "$id/finding.json" 2>/dev/null || echo "")
  case "$file" in
    README.md) sed -i 's/teh /the /g' "$wd/README.md"
      printf '# Worknote\n\nFixed typo "teh" -> "the" in README.md. Single file, reversible.\n' > "$id/worknote.md" ;;
    app.py)    sed -i 's/retrun/return/g' "$wd/app.py"
      printf '# Worknote\n\nFixed typo "retrun" -> "return" in app.py comment. Single file, reversible.\n' > "$id/worknote.md" ;;
    *)         printf '# Worknote\n\nNo mock fix registered for %s.\n' "$file" > "$id/worknote.md" ;;
  esac
}
mock_review() { # workdir item_dir
  local _wd="$1" id="$2"
  jq -nc '{verdict:"ship",reason:"Typo fix; single file, reversible, no behaviour change — clears the smallness bar."}' > "$id/review.md"
}
mock_recon() { # workdir item_dir — deterministic applicability straight from recon_signals.json
  local _wd="$1" id="$2" sig
  sig=$(cat "$id/signals.json" 2>/dev/null || echo '{}')
  printf '%s' "$sig" | jq -c '. as $s | {
    dimensions: {
      correctness:{applicable:true, hint:"any code path"},
      security:   {applicable:true, hint:"trust boundaries"},
      infra:      {applicable:(($s.has_compose//false) or ($s.has_dockerfile//false) or ($s.has_ci//false) or ($s.has_iac//false)), hint:"compose/docker/ci present"},
      docs:       {applicable:true, hint:"docs vs code"},
      tests:      {applicable:($s.has_tests//false), hint:"test dir present"},
      perf:       {applicable:((($s.languages//[])|length)>0), hint:"code present"},
      "ui-ux":    {applicable:($s.has_frontend//false), hint:"frontend present"},
      deps:       {applicable:((($s.lockfiles//[])|length)>0), hint:"lockfiles present"},
      craft:      {applicable:true, hint:"floor lens"}
    }, notes:"mock recon (deterministic mapping from filesystem signals)"}' > "$id/recon.json"
}

# ---- claude adapter (first-party CLI headless, ADR 0003) ----
# The agent only reads/edits files; the Runner owns all git (branch/commit/push).
# Sandbox default uses --dangerously-skip-permissions (throwaway repo; git-level
# confinement via hooks/pre-push holds regardless of Claude's permission mode).
claude_run() { # stage workdir item_dir
  local stage="$1" wd="$2" id="$3" prompt out
  local flags="${NIGHTSHIFT_CLAUDE_FLAGS:---dangerously-skip-permissions --max-turns 25}"
  # Per-stage CAPABILITY profile: enforce each stage's rules by which tools EXIST, not by
  # asking the prompt nicely (same philosophy as the git-confinement hook). explore/review
  # are read-only by nature -> only Read/Grep/Glob, no Write/Edit/Bash. fix edits the working
  # tree -> Write/Edit, but still NO Bash, which capability-enforces fix.md's "do NOT run git,
  # no destructive commands". Verified: with these sets claude cannot write outside its granted
  # tools even under --dangerously-skip-permissions (adversarial test, 2026-07-09).
  local tools
  case "$stage" in
    fix) tools="${NIGHTSHIFT_FIX_TOOLS:-Read,Grep,Glob,Write,Edit}" ;;
    *)   tools="${NIGHTSHIFT_READONLY_TOOLS:-Read,Grep,Glob}" ;;
  esac
  prompt="$(stage_prompt "$stage" "$wd" "$id")"
  # codemap structural index — only when the Runner flagged THIS repo as indexed, and only for the
  # navigation stages (explore/review). It is an MCP tool, so it needs no Bash. The worktree has no
  # index, so the agent must query the stable real repo via repoPath (injected below).
  local cm_flags=""
  if [ -n "${NIGHTSHIFT_CODEMAP_REPO:-}" ] && { [ "$stage" = explore ] || [ "$stage" = review ]; }; then
    tools="$tools,mcp__codemap__codemap_search,mcp__codemap__codemap_context"
    cm_flags="--mcp-config $STATE_DIR/codemap-mcp.json"
    prompt="$prompt

## Structural index (codemap)
A codemap index of this repo is available. Prefer codemap_search / codemap_context to locate relevant
code instead of reading files blindly. Your cwd is a throwaway worktree with NO index — ALWAYS pass
repoPath=$NIGHTSHIFT_CODEMAP_REPO to these tools."
  fi
  # Layer 1 for the agent: inject core.hooksPath via env so EVERY git the agent runs is
  # confined by hooks/pre-push — no writes to any repo config. Layer 2: the PreToolUse guard
  # (blocks disabling Layer 1) via --settings. NIGHTSHIFT_BRANCH_PREFIX is already exported.
  # shellcheck disable=SC2086
  out="$(cd "$wd" && \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR" \
    claude -p "$prompt" --output-format json --settings "$STATE_DIR/claude-settings.json" --tools "$tools" $cm_flags $flags </dev/null 2>/dev/null)" || return 1
  # `claude -p --output-format json` is NOT a stable shape. Sometimes it is a single
  # result object ({result,usage,total_cost_usd}); sometimes a JSON ARRAY of events with
  # the result object as one element (observed with claude 2.1.197, e.g. when a
  # rate_limit_event is present). A parser that assumes one shape silently yields an empty
  # result on the other — every explore then reports found:false and claude mode does
  # nothing. So normalise both: pick the result object whether top-level is it or an array.
  local pick='if type=="array" then (map(select(.type=="result"))|last) else . end'
  printf '%s' "$out" | jq -r "$pick"' | (.result // "")'                > "$id/$stage.out"
  printf '%s' "$out" | jq -r "$pick"' | (.usage.output_tokens // empty)' > "$id/.tokens_$stage" 2>/dev/null || true
  printf '%s' "$out" | jq -r "$pick"' | (.total_cost_usd // empty)'      > "$id/.cost_$stage"   2>/dev/null || true
  case "$stage" in
    explore) python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/finding.json" ;;
    fix)     cp "$id/$stage.out" "$id/worknote.md" ;;
    review)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/review.md" ;;
    recon)   python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/recon.json" ;;
  esac
  return 0
}

# ---- codex adapter (first-party CLI headless, ADR 0003) ----
# Recon/Explore/Review run read-only. Fix can write and execute commands only inside the disposable
# worktree, with network disabled. The Runner still owns branch/commit/push.
codex_run() { # stage workdir item_dir
  local stage="$1" wd="$2" id="$3" prompt sandbox events model effort
  local -a args=(--ask-for-approval never exec --ephemeral --ignore-user-config --ignore-rules
    --strict-config --json -o "$id/$stage.out")
  prompt="$(stage_prompt "$stage" "$wd" "$id")"
  case "$stage" in
    fix) sandbox=workspace-write ;;
    *)   sandbox=read-only ;;
  esac
  args+=(--sandbox "$sandbox")
  [ "$stage" != fix ] || args+=(-c 'sandbox_workspace_write.network_access=false')
  model="${NIGHTSHIFT_CODEX_MODEL:-}"
  [ -z "$model" ] || args+=(--model "$model")
  effort="${NIGHTSHIFT_CODEX_REASONING_EFFORT:-}"
  [ -z "$effort" ] || args+=(-c "model_reasoning_effort=\"$effort\"")

  if [ -n "${NIGHTSHIFT_CODEMAP_REPO:-}" ] && { [ "$stage" = explore ] || [ "$stage" = review ]; }; then
    args+=(-c 'mcp_servers.codemap.command="codemap-mcp"')
    prompt="$prompt

## Structural index (codemap)
A codemap index of this repo is available. Prefer codemap_search / codemap_context to locate relevant
code instead of reading files blindly. Your cwd is a throwaway worktree with NO index — ALWAYS pass
repoPath=$NIGHTSHIFT_CODEMAP_REPO to these tools."
  fi

  events="$id/.codex_events_$stage"
  if ! (cd "$wd" && printf '%s' "$prompt" | \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR" \
    codex "${args[@]}" - > "$events"); then
    return 1
  fi
  jq -sr '[.[] | select(.type=="turn.completed") | .usage.output_tokens // empty] | last // empty' \
    "$events" > "$id/.tokens_$stage" 2>/dev/null || true
  case "$stage" in
    explore) python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/finding.json" ;;
    fix)     cp "$id/$stage.out" "$id/worknote.md" ;;
    review)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/review.md" ;;
    recon)   python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/recon.json" ;;
  esac
}

# --------------------------------------------------------------- selection ----
select_order() { # emit "path<TAB>mode<TAB>base", least-recently-serviced repo first (ADR 0008)
  # Fairness over recency: the repo nightshift has NOT touched in the longest sorts first, so
  # coverage rotates instead of fixating on the most-active repo (which is nightshift itself —
  # it commits nightly, so a commit-recency sort put it first every night and starved the tail
  # repos at the open-branch cap). Human commit-recency stays as the tiebreaker: among equally-
  # (or never-) serviced repos, prefer the one with the hottest code. Cold start = no ledger =
  # every repo ties at serviced 0, so night one still orders by commit-recency exactly as before.
  local i path mode base ct st
  for i in "${!REPO_PATHS[@]}"; do
    path="${REPO_PATHS[$i]}"; mode="${REPO_MODES[$i]}"; base="${REPO_BASES[$i]:-}"
    case "$mode" in branch-fix|findings-only) ;; *) continue ;; esac
    [ -d "$path/.git" ] || { log "skip $path (not a git repo)"; continue; }
    ct=$(git -C "$path" log -1 --format=%ct 2>/dev/null || echo 0)   # human commit recency
    st=$(last_serviced_epoch "$path")                                # nightshift last touched
    printf '%s\t%s\t%s\t%s\t%s\n' "$st" "$ct" "$path" "$mode" "$base"
  done | sort -t"$(printf '\t')" -k1,1n -k2,2nr | cut -f3-
}

repo_findings() { # repo -> per-repo `findings:` override from the rulebook, else global MAX_FINDINGS
  local repo="$1" i
  for i in "${!REPO_PATHS[@]}"; do
    if [ "${REPO_PATHS[$i]}" = "$repo" ]; then
      echo "${REPO_FINDINGS[$i]:-$MAX_FINDINGS}"; return
    fi
  done
  echo "$MAX_FINDINGS"
}

repo_dimensions() { # repo -> applicable dimensions, space-separated, in priority order (ADR 0010)
  # Per-repo `dimensions:` (comma-separated) overrides the global set. Recon further narrows this
  # (Phase 3) via recon_applicable(); here it is the configured candidate set.
  local repo="$1" i
  for i in "${!REPO_PATHS[@]}"; do
    if [ "${REPO_PATHS[$i]}" = "$repo" ]; then
      [ -n "${REPO_DIMS[$i]:-}" ] && { echo "${REPO_DIMS[$i]//,/ }"; return; }
      break
    fi
  done
  echo "${DIMENSIONS[*]}"
}

last_dim_epoch() { # repo dim -> epoch of the last WORK-ITEM ledger row for this (repo,dim), 0 if never
  local repo="$1" dim="$2" iso
  [ -f "$LEDGER" ] || { echo 0; return; }
  iso=$(jq -rs --arg r "$repo" --arg d "$dim" \
    '[.[]|select(.repo==$r and .dimension==$d and (.outcome=="finding" or .outcome=="shipped" or .outcome=="abandoned"))|.ts]
     | max // empty' "$LEDGER" 2>/dev/null || true)
  [ -n "$iso" ] || { echo 0; return; }
  date -d "$iso" +%s 2>/dev/null || echo 0
}

recon_applicable() { # repo dim -> 0 if applicable (or unknown/no-recon), 1 only if recon says NOT applicable
  local repo="$1" dim="$2" cache val
  cache="$RECON_DIR/$(basename "$repo").json"
  [ -f "$cache" ] || return 0   # no recon cache → never starve; treat as applicable
  val=$(jq -r --arg d "$dim" '.dimensions[$d].applicable // true' "$cache" 2>/dev/null || echo true)
  [ "$val" = false ] && return 1 || return 0
}

select_dimension() { # repo -> the least-recently-serviced APPLICABLE dimension (rulebook order breaks ties)
  # Reproduces the operator's "security yesterday on A → docs today on A, security on B" rotation:
  # argmin of last_dim_epoch over the recon-applicable set; strict `<` scan in priority order means
  # the earliest-listed dimension wins a tie (so at cold start every repo gets the first-listed lens).
  local repo="$1" dim best_dim="" best_ep="" ep
  for dim in $(repo_dimensions "$repo"); do
    recon_applicable "$repo" "$dim" || continue
    ep=$(last_dim_epoch "$repo" "$dim")
    if [ -z "$best_ep" ] || [ "$ep" -lt "$best_ep" ]; then best_ep="$ep"; best_dim="$dim"; fi
  done
  # If recon excluded everything (shouldn't happen — correctness/docs/craft are always applicable),
  # fall back to the first configured dimension so a repo is never fully starved.
  if [ -z "$best_dim" ]; then local -a dd; read -ra dd <<< "$(repo_dimensions "$repo")"; best_dim="${dd[0]:-}"; fi
  echo "$best_dim"
}

ensure_recon() { # repo -> refresh the recon cache if missing / HEAD changed / older than ttl_days (ADR 0010)
  [ "${RECON_ENABLED:-true}" != false ] || return 0
  local repo="$1" cache head chead cts cepoch now ttl id wt base
  cache="$RECON_DIR/$(basename "$repo").json"; mkdir -p "$RECON_DIR"
  head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")
  if [ -f "$cache" ]; then
    chead=$(jq -r '.head // ""' "$cache" 2>/dev/null || echo "")
    cts=$(jq -r '.ts // ""' "$cache" 2>/dev/null || echo "")
    cepoch=0; [ -n "$cts" ] && cepoch=$(date -d "$cts" +%s 2>/dev/null || echo 0)
    now=$(date +%s); ttl=$(( ${RECON_TTL_DAYS:-7} * 86400 ))
    if [ "$chead" = "$head" ] && [ "$cepoch" -gt 0 ] && [ "$(( now - cepoch ))" -lt "$ttl" ]; then
      return 0   # cache is fresh — recon costs zero this run
    fi
  fi
  id="$RUNS_DIR/recon-$(date +%s%N)"; mkdir -p "$id"
  "$NIGHTSHIFT_HOME/lib/recon_signals.sh" "$repo" > "$id/signals.json" 2>/dev/null || echo '{}' > "$id/signals.json"
  # Recon is read-only; run it in a throwaway worktree (isolation), falling back to the repo path.
  base="$(base_ref "$repo")"; wt="$WORKTREES_DIR/$(basename "$id")"
  if setup_worktree "$repo" "$wt" "$base"; then
    run_agent recon "$wt" "$id" || true; remove_worktree "$repo" "$wt"
  else
    run_agent recon "$repo" "$id" || true
  fi
  if [ -s "$id/recon.json" ]; then
    jq -c --arg h "$head" --arg r "$repo" --arg ts "$(date -Iseconds)" \
      '. + {repo:$r, head:$h, ts:$ts}' "$id/recon.json" > "$cache" 2>/dev/null \
      || log "  $(basename "$repo"): recon cache write failed — continuing without recon"
  fi
}

open_branch_count() { # unmerged nightshift/* across all repos (reconciles against reality, §3e)
  local total=0 i path n
  for i in "${!REPO_PATHS[@]}"; do
    path="${REPO_PATHS[$i]}"
    [ -d "$path/.git" ] || continue
    git -C "$path" fetch -q origin 2>/dev/null || true
    if git -C "$path" show-ref -q --verify refs/remotes/origin/main 2>/dev/null; then
      n=$(git -C "$path" branch -r --no-merged origin/main 2>/dev/null | grep -c "origin/${BRANCH_PREFIX}" || true)
    else
      n=$(git -C "$path" ls-remote --heads origin "${BRANCH_PREFIX}*" 2>/dev/null | wc -l | tr -d ' ')
    fi
    total=$((total + n))
  done
  echo "$total"
}

# ---------------------------------------------------------------- worktree ----
# Every work item runs in a throwaway, isolated git worktree — never the repo's
# live checkout. So nightshift never touches your branch/state, and any misstep
# (incl. non-git shell, §2b) is confined to a dir we delete afterwards.
base_ref() { # repo -> best base ref to branch from
  local repo="$1" r
  for r in ORIGIN_HEAD origin/main origin/master main master; do
    if [ "$r" = ORIGIN_HEAD ]; then
      r=$(git -C "$repo" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/##') || true
      [ -z "$r" ] && continue
    fi
    git -C "$repo" rev-parse -q --verify "$r" >/dev/null 2>&1 && { echo "$r"; return 0; }
  done
  echo HEAD
}
resolve_base() { # repo cfgbase -> ref to branch from (rulebook `base:` wins, else auto-detect)
  local repo="$1" cfg="$2"
  if [ -n "$cfg" ]; then
    if git -C "$repo" rev-parse -q --verify "origin/$cfg" >/dev/null 2>&1; then echo "origin/$cfg"; return 0; fi
    if git -C "$repo" rev-parse -q --verify "$cfg"        >/dev/null 2>&1; then echo "$cfg";        return 0; fi
    log "  $(basename "$repo"): configured base '$cfg' not found — auto-detecting"
  fi
  base_ref "$repo"
}
setup_worktree() { git -C "$1" worktree add -q --detach "$2" "$3"; }   # repo wt base
remove_worktree() {                                                    # repo wt
  git -C "$1" worktree remove --force "$2" 2>/dev/null || true
  git -C "$1" worktree prune 2>/dev/null || true
}

# --------------------------------------------------------------------- pr ----
# Open a normal (non-draft) PR for a freshly pushed nightshift/* branch. A PR is a
# GitHub-API object, NOT a push to main — the pre-push hook is untouched and the
# merge stays the human's click. Best-effort: PR off, no GitHub remote (e.g. a
# local bare remote / sandbox), missing gh, or a gh failure all just skip the PR;
# the branch is already pushed either way. Echoes the PR url ("" if none). All
# progress/errors go to stderr so stdout stays clean for the caller.
open_pr() { # repo wt branch item_dir base -> echoes PR url ("" if none)
  local repo="$1" wt="$2" branch="$3" id="$4" base="${5:-}" url
  [ "$NIGHTSHIFT_OPEN_PR" = 1 ] || return 0
  case "$(git -C "$repo" remote get-url origin 2>/dev/null || true)" in
    *github.com*) ;;
    *) log "  no GitHub remote — branch pushed, PR skipped"; return 0 ;;
  esac
  command -v gh >/dev/null 2>&1 || { log "  gh not found — branch pushed, no PR"; return 0; }
  # The PR base MUST be the ref the branch was actually cut from (rulebook `base:`,
  # e.g. develop) — NOT an auto-detected origin/main. Re-deriving with base_ref here
  # ignored the configured base and opened every PR against main, so a develop-based
  # one-line fix showed develop's whole divergence as its diff. Fall back to auto-
  # detect only if the caller passed nothing.
  [ -n "$base" ] || base="$(base_ref "$repo")"
  base="${base#origin/}"; [ "$base" = HEAD ] && base=main
  # A runtime/behavioral finding the reviewer could not statically prove ships flagged, so the
  # morning human knows this one needs tests before merge and the verified ones do not.
  local mark=""
  [ "$(jq -r '.proof // ""' "$id/review.md" 2>/dev/null)" = unproven ] && mark="[unverified] "
  # The verification chain travels WITH the PR so the morning merge is a 30-second audit,
  # not a re-derivation — and so a rubber-stamp review is visible rather than hidden.
  local claim verify verif proof evidence
  claim=$(jq -r '.claim // ""'         "$id/finding.json" 2>/dev/null || true)
  verify=$(jq -r '.verify // ""'       "$id/finding.json" 2>/dev/null || true)
  verif=$(jq -r '.verifiability // ""' "$id/finding.json" 2>/dev/null || true)
  proof=$(jq -r '.proof // ""'         "$id/review.md"    2>/dev/null || true)
  evidence=$(jq -r '.evidence // ""'   "$id/review.md"    2>/dev/null || true)
  { echo "${mark}$(jq -r '.summary // "improvement"' "$id/finding.json")"
    echo; echo '---'
    echo '_Opened by nightshift — review at leisure; the merge is yours._'; echo
    cat "$id/worknote.md" 2>/dev/null || true
    if [ -n "$claim$evidence" ]; then
      echo; echo '### Verification'
      [ -n "$claim" ]    && { echo; echo "**Claim:** $claim"; }
      { [ -n "$verif" ] || [ -n "$proof" ]; } && echo "**Class:** \`${verif:-?}\` · **Proof:** \`${proof:-?}\`"
      [ -n "$verify" ]   && { echo; echo "**How to verify:** $verify"; }
      [ -n "$evidence" ] && { echo; echo "**What the reviewer found:** $evidence"; }
    fi
  } > "$id/pr-body.md"
  url="$( (cd "$wt" && gh pr create --base "$base" --head "$branch" \
            --title "${mark}nightshift: $(jq -r '.summary // "improvement"' "$id/finding.json")" \
            --body-file "$id/pr-body.md" 2>/dev/null) )" \
    || { log "  gh pr create failed — branch pushed, no PR"; return 0; }
  log "  PR opened: $url"
  printf '%s' "$url"
}

# ---------------------------------------------------------------- finalize ----
finalize() { # repo worktree item_dir [seq] [base] -> echoes branch name
  local repo="$1" wt="$2" id="$3" seq="${4:-0}" basearg="${5:-}" fp type dim slug branch sha summary verif
  fp=$(jq -r '.fingerprint' "$id/finding.json")
  type=$(jq -r '.type // "change"' "$id/finding.json")   # default so the branch slug never reads "null"
  dim=$(jq -r '.dimension // ""' "$id/finding.json")     # the review lens (ADR 0010), leads the slug
  if [ -n "$dim" ]; then
    slug="$(printf '%s-%s-%s' "$dim" "$type" "$(basename "$repo")" | tr '[:upper:] /' '[:lower:]--' | cut -c1-48)"
  else
    slug="$(printf '%s-%s' "$type" "$(basename "$repo")" | tr '[:upper:] /' '[:lower:]--' | cut -c1-40)"
  fi
  # `seq` (a per-run monotonic counter) disambiguates several findings that finalize within the
  # same clock second in one repo/pass — without it their timestamped branch names would collide.
  branch="${BRANCH_PREFIX}${slug}-$(date +%Y%m%d-%H%M%S)-${seq}"
  git -C "$wt" checkout -q -b "$branch"
  git -C "$wt" add -A
  git -C "$wt" -c user.name=nightshift -c user.email=nightshift@localhost \
      commit -q -m "nightshift: $(jq -r '.summary' "$id/finding.json")

$(cat "$id/worknote.md")"
  sha=$(git -C "$wt" rev-parse HEAD)
  summary=$(jq -r '.summary // ""' "$id/finding.json")
  verif=$(jq -r '.verifiability // ""' "$id/finding.json" 2>/dev/null || true)
  # Layer 1 hook active for THIS push only (-c), never persisted to the repo config.
  if ! git -c core.hooksPath="$HOOKS_DIR" -C "$wt" push -q -u origin "$branch"; then
    log "  $(basename "$repo"): push failed — not shipped: $branch"
    ledger_append "$(basename "$id")" "$repo" "$fp" "$branch" "$sha" "push-failed" "$summary" "" "" "$verif" "$dim"
    git -C "$wt" checkout -q --detach >/dev/null 2>&1 || true
    git -C "$repo" branch -q -D "$branch" >/dev/null 2>&1 \
      || log "  $(basename "$repo"): cleanup warning — local branch remains: $branch"
    return 1
  fi
  local pr_url proof
  pr_url=$(open_pr "$repo" "$wt" "$branch" "$id" "$basearg")
  proof=$(jq -r '.proof // ""' "$id/review.md" 2>/dev/null || true)
  verif=$(jq -r '.verifiability // ""' "$id/finding.json" 2>/dev/null || true)
  ledger_append "$(basename "$id")" "$repo" "$fp" "$branch" "$sha" "shipped" "$(jq -r '.summary // ""' "$id/finding.json")" "$pr_url" "$proof" "$verif" "$dim"
  echo "$branch"
}

# ------------------------------------------------------------------- digest ----
write_digest() { # made open status
  local made="$1" open="$2" status="$3" f="$DIGEST_DIR/$NIGHT.md" runs dur
  {
    echo "# nightshift digest — $NIGHT"
    echo
    local fcount=0
    [ -f "$LEDGER" ] && fcount=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n and .outcome=="finding")]|length' "$LEDGER" 2>/dev/null || echo 0)
    echo "- agent: \`$NIGHTSHIFT_AGENT\` · shipped this run: ${made} · surfaced (findings): ${fcount} · open (unmerged): ${open}/${MAX_OPEN} (cap)"
    if [ -f "$RUNSLOG" ]; then
      runs=$(grep -c "\"night\":\"$NIGHT\"" "$RUNSLOG" || true)
      dur=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n)|.duration_s]|add // 0' "$RUNSLOG")
      echo "- runs tonight: ${runs} stage-invocations, ${dur}s total"
    fi
    # Harvest scoreboard (all-time, from bin/harvest verdict events): the human
    # feedback loop made visible. A branch with no terminal verdict counts as open.
    [ -f "$LEDGER" ] && jq -rs '
      ([.[]|select(.outcome=="verdict" and .branch!=null)]
        | group_by(.branch) | map(sort_by(.ts)|last) | map(select(.verdict=="merged" or .verdict=="dropped"))
        | INDEX(.branch)) as $v
      | [.[]|select(.outcome=="shipped" and .branch!=null)|.branch] | unique as $ship
      | ($ship|map(select($v[.].verdict=="merged"))|length) as $m
      | ($ship|map(select($v[.].verdict=="dropped"))|length) as $d
      | ($ship|length) as $n
      | ($n-$m-$d) as $open
      | if $n==0 then empty else
          "- harvest (all-time): shipped \($n) · merged \($m) · dropped \($d) · open \($open)"
          + (if ($m+$d)>0 then " · merge-rate \((100*$m/($m+$d))|floor)%" else "" end)
        end' "$LEDGER" 2>/dev/null || true
    # Coverage matrix (ADR 0010): days since nightshift last serviced each (repo × dimension).
    # Makes the rotation observable — a large number or — flags a long-overdue lens.
    if [ "${#DIMENSIONS[@]}" -gt 0 ] && [ "${#REPO_PATHS[@]}" -gt 0 ]; then
      local nowe rp d e; nowe=$(date +%s)
      echo; echo "## Coverage — days since last serviced (— = never)"; echo
      { printf '| repo |'; for d in "${DIMENSIONS[@]}"; do printf ' %s |' "$d"; done; printf '\n'
        printf '|---|'; for d in "${DIMENSIONS[@]}"; do printf '%s' '---|'; done; printf '\n'
        for rp in "${REPO_PATHS[@]}"; do
          printf '| %s |' "$(basename "$rp")"
          for d in "${DIMENSIONS[@]}"; do
            e=$(last_dim_epoch "$rp" "$d")
            if [ "$e" -gt 0 ]; then printf ' %s |' "$(( (nowe - e) / 86400 ))"; else printf ' — |'; fi
          done
          printf '\n'
        done
      }
    fi
    # Per-dimension merge-rate (ADR 0010 Phase 4): the tuning signal — which lenses produce findings
    # humans actually merge. Join the latest verdict per branch back to the shipped row's dimension.
    [ -f "$LEDGER" ] && jq -rs '
      ([.[]|select(.outcome=="verdict" and .branch!=null)] | group_by(.branch) | map(sort_by(.ts)|last)
        | map(select(.verdict=="merged" or .verdict=="dropped")) | INDEX(.branch)) as $v
      | [.[]|select(.outcome=="shipped" and .branch!=null)]
      | group_by(.dimension // "—")
      | map({dim:(.[0].dimension // "—"), br:(map(.branch)|unique)})
      | map({dim:.dim, n:(.br|length),
             m:(.br|map(select($v[.].verdict=="merged"))|length),
             d:(.br|map(select($v[.].verdict=="dropped"))|length)})
      | if length==0 then empty else
          "\n## Merge-rate by dimension (all-time)\n"
          + (map("- \(.dim): shipped \(.n) · merged \(.m) · dropped \(.d)"
                 + (if (.m+.d)>0 then " · rate \((100*.m/(.m+.d))|floor)%" else "" end)) | join("\n"))
        end' "$LEDGER" 2>/dev/null || true
    echo
    if [ "$status" = "backpressure" ]; then
      echo "**FULL STOP — open-branch cap reached.** Harvest (merge/delete) some \`${BRANCH_PREFIX}\` branches to resume."
    else
      echo "## Shipped"
      [ -f "$LEDGER" ] && jq -r --arg n "$NIGHT" \
        'select(.night==$n and .outcome=="shipped") | "- " + (if .proof=="unproven" then "**[unverified]** " else "" end) + .repo + " → `" + (.branch // "") + "` — " + (.summary // .fingerprint) + (if .pr_url then "  ([open PR](" + .pr_url + "))" else "" end)' \
        "$LEDGER" 2>/dev/null || true
      echo
      echo "## Findings (surfaced — reported, not touched)"
      [ -f "$LEDGER" ] && jq -r --arg n "$NIGHT" \
        'select(.night==$n and .outcome=="finding") | "- " + .repo + " — " + (.summary // .fingerprint) + "  (" + .fingerprint + ")"' \
        "$LEDGER" 2>/dev/null || true
      echo
      echo "## Considered but not shipped"
      [ -f "$LEDGER" ] && jq -r --arg n "$NIGHT" \
        'select(.night==$n and (.outcome=="abandoned" or .outcome=="deferred" or .outcome=="push-failed")) | "- " + .repo + " — " + .outcome + ": " + (.summary // .fingerprint)' \
        "$LEDGER" 2>/dev/null || true
    fi
  } > "$f"
  log "digest -> $f"
}

# --------------------------------------------------------------------- main ----
main() {
  load_rulebook
  write_claude_settings
  write_codemap_mcp
  # Harvest first: reconcile prior shipped branches against git reality (merged/
  # dropped) so the morning digest scoreboard is current. Non-fatal — a harvest
  # hiccup must never block the night's work.
  if [ -x "$NIGHTSHIFT_HOME/bin/harvest.sh" ]; then
    # Pass THIS run's state/ledger/rulebook through: harvest honours STATE_DIR/LEDGER/RULEBOOK, but
    # nightshift.sh names them NIGHTSHIFT_STATE_DIR/… — without this bridge an isolated run (e.g. an
    # e2e test with NIGHTSHIFT_STATE_DIR set) would silently reconcile the LIVE ledger instead.
    STATE_DIR="$STATE_DIR" LEDGER="$LEDGER" RULEBOOK="$RULEBOOK" \
      "$NIGHTSHIFT_HOME/bin/harvest.sh" >/dev/null 2>&1 || log "harvest: skipped (non-fatal)"
  fi
  log "agent=$NIGHTSHIFT_AGENT prefix=$BRANCH_PREFIX · cap: max $MAX_OPEN unmerged ${BRANCH_PREFIX} branches · run ceiling $MAX_RUN_BRANCHES · fix iters $MAX_FIX_ITER"

  local made=0 considered=0 findings=0 repo mode cfgbase id fp fnj iter verdict wt base b summary open pass=0 progress stop_reason=ok disp rfind farr n_find k fd dim
  # No per-night production cap. The ONLY cap is the count of OPEN (unmerged) nightshift/* branches:
  # work continues while fewer than max_open_branches are unmerged; merging/closing frees slots and
  # work resumes; when merging stops it fills to the cap and stops. "All night" continuous operation
  # is bounded by this cap, by running out of new work, and by the subscription 5h window.
  while true; do
    [ "$made" -ge "$MAX_RUN_BRANCHES" ] && { log "safety ceiling ($MAX_RUN_BRANCHES) reached — stop"; break; }
    open=$(open_branch_count)
    if [ "$open" -ge "$MAX_OPEN" ]; then
      log "open-branch cap reached ($open/$MAX_OPEN) — stop; merge/close some to free slots"
      stop_reason=backpressure; break
    fi
    pass=$((pass + 1))
    progress=0
  while IFS=$'\t' read -r repo mode cfgbase; do
    [ -n "$repo" ] || continue
    open=$(open_branch_count)
    [ "$open" -ge "$MAX_OPEN" ] && { log "open-branch cap reached ($open/$MAX_OPEN) — stop"; stop_reason=backpressure; break; }

    id="$RUNS_DIR/item-$(date +%s%N)"; mkdir -p "$id"
    echo "$repo" > "$id/repo"
    wt="$WORKTREES_DIR/$(basename "$id")"
    base="$(resolve_base "$repo" "$cfgbase")"
    if ! setup_worktree "$repo" "$wt" "$base"; then
      log "  $(basename "$repo"): could not create worktree — skip"; continue
    fi
    # codemap: nightshift keeps the structural index current ITSELF — never a manual step. Indexing is
    # local + incremental (seconds), so just do it every run before explore; the index is always
    # current. --approve makes first-time automatic: the rulebook is already the human's consent
    # surface (you listed these repos). Absent binary or a failure -> plain Read/Grep/Glob.
    # Kill switch: NIGHTSHIFT_CODEMAP=0.
    export NIGHTSHIFT_CODEMAP_REPO=""
    if [ "${NIGHTSHIFT_CODEMAP:-1}" = 1 ] && command -v codemap >/dev/null 2>&1; then
      if codemap index --approve --repo "$repo" >/dev/null 2>&1; then
        export NIGHTSHIFT_CODEMAP_REPO="$repo"
      else
        log "  $(basename "$repo"): codemap index failed — continuing without it"
      fi
    fi

    rfind=$(repo_findings "$repo")
    export NIGHTSHIFT_FINDINGS_N="$rfind"
    # Recon (cached): survey the repo and narrow which dimensions apply. Then pick the review lens
    # for this repo/pass: its least-recently-serviced APPLICABLE dimension (ADR 0010). The lens and
    # the recon orientation notes are injected into explore; the lens is stamped onto every finding.
    ensure_recon "$repo"
    dim=$(select_dimension "$repo")
    export NIGHTSHIFT_DIMENSION="$dim"
    NIGHTSHIFT_RECON_NOTES="$(jq -r '.notes // ""' "$RECON_DIR/$(basename "$repo").json" 2>/dev/null || true)"
    export NIGHTSHIFT_RECON_NOTES
    log "  $(basename "$repo") [$mode]: lens=${dim:-none} · budget=$rfind"
    run_agent explore "$wt" "$id" || true
    considered=$((considered + 1))
    # Explore emits the v2 container {found, findings:[…]} or (back-compat) a single finding object
    # {found:true,file,…}. Normalise to a findings array, cap it at the repo's N, then remove the
    # explore worktree — explore is read-only; every fix gets its OWN fresh worktree so diffs never
    # compound and each finding lands as one independently-reviewable, independently-rejectable branch.
    farr=$(jq -c 'if (.findings|type)=="array" then .findings elif (.found==true) then [.] else [] end' "$id/finding.json" 2>/dev/null || echo '[]')
    remove_worktree "$repo" "$wt"
    n_find=$(printf '%s' "$farr" | jq 'length' 2>/dev/null || echo 0)
    [ "$n_find" -gt "$rfind" ] && n_find="$rfind"
    if [ "$n_find" -le 0 ]; then
      log "  $(basename "$repo") [$mode]: nothing worth doing"; continue
    fi

    for (( k=0; k<n_find; k++ )); do
      open=$(open_branch_count)
      if [ "$open" -ge "$MAX_OPEN" ]; then
        log "  open-branch cap reached ($open/$MAX_OPEN) — stop"; stop_reason=backpressure; break
      fi
      fd="$id/f$k"; mkdir -p "$fd"
      printf '%s' "$farr" | jq -c ".[$k]" > "$fd/finding.json"
      fp=$(finding_fingerprint "$fd/finding.json")
      if [ -z "$fp" ]; then
        log "  $(basename "$repo") [$mode]: finding without a usable fingerprint — skip"; continue
      fi
      # Persist the resolved fingerprint AND the selected dimension so finalize/ledger read the
      # same identity and the coverage rotation (ADR 0010) has its signal.
      fnj=$(jq --arg fp "$fp" --arg d "$dim" '.fingerprint=$fp | .dimension=$d' "$fd/finding.json") && printf '%s' "$fnj" > "$fd/finding.json"
      summary=$(jq -r '.summary // ""' "$fd/finding.json")

      if [ "$mode" = findings-only ]; then
        if already_done "$fp"; then
          log "  $(basename "$repo") [findings-only]: already reported ($fp) — skip"; continue
        fi
        ledger_append "$(basename "$fd")" "$repo" "$fp" "" "" "finding" "$summary" "" "" "" "$dim"
        findings=$((findings + 1)); progress=1
        log "  $(basename "$repo") [findings-only]: $summary"
        continue
      fi

      # branch-fix
      # Intent-ambiguous divergence (ADR 0006): the reviewer can PROVE it but cannot know which side
      # is authoritative. It ships as a human-owned finding (TODO), never an auto-fix. Fail closed:
      # an unrecognized disposition surfaces (asks a human) rather than auto-fixing.
      disp=$(jq -r '.disposition // "fix"' "$fd/finding.json" 2>/dev/null || echo fix)
      case "$disp" in
        fix|surface) ;;
        *) log "  $(basename "$repo"): unrecognized disposition '$disp' — surfacing instead of auto-fixing"; disp=surface ;;
      esac
      # A surfaced divergence LATCHES: once a human owns it as a TODO, a later run must neither
      # re-surface it nor quietly auto-fix it.
      if already_surfaced "$fp"; then
        log "  $(basename "$repo"): previously surfaced — human-owned, not touching ($fp)"; continue
      fi
      if [ "$disp" = surface ]; then
        ledger_append "$(basename "$fd")" "$repo" "$fp" "" "" "finding" "$summary" "" "" "" "$dim"
        findings=$((findings + 1)); progress=1
        log "  $(basename "$repo") [branch-fix]: surfaced, not auto-fixed: $summary"
        continue
      fi
      if already_acted "$fp"; then
        log "  $(basename "$repo"): already handled ($fp) — skip"; continue
      fi

      # One finding = one branch = one fresh worktree from base (diffs stay independent).
      wt="$WORKTREES_DIR/$(basename "$id")-f$k"
      if ! setup_worktree "$repo" "$wt" "$base"; then
        log "  $(basename "$repo"): could not create worktree for finding — skip"; continue
      fi
      iter=0; verdict="revise"
      while [ "$iter" -lt "$MAX_FIX_ITER" ]; do
        iter=$((iter + 1))
        run_agent fix "$wt" "$fd" || true
        run_agent review "$wt" "$fd" || true
        verdict=$(jq -r '.verdict' "$fd/review.md" 2>/dev/null || echo abandon)
        [ "$verdict" = ship ] && break
        [ "$verdict" = abandon ] && break
      done
      b=""
      if [ "$verdict" = ship ]; then
        if b=$(finalize "$repo" "$wt" "$fd" "$made" "$base"); then
          made=$((made + 1)); progress=1
          log "  $(basename "$repo"): shipped -> $b"
        fi
      else
        ledger_append "$(basename "$fd")" "$repo" "$fp" "" "" "abandoned" "$summary" "" "" "" "$dim"
        log "  $(basename "$repo"): abandoned ($fp)"
      fi
      remove_worktree "$repo" "$wt"
      [ -n "$b" ] && git -C "$repo" branch -q -D "$b" >/dev/null 2>&1 || true
    done
    [ "$stop_reason" = backpressure ] && break
  done < <(select_order)
    [ "$progress" -eq 0 ] && { log "pass $pass: no new shippable work — stop"; break; }
  done

  open=$(open_branch_count)
  write_digest "$made" "$open" "$stop_reason"
  log "night done: $made shipped this run, $considered considered, $open now open (cap $MAX_OPEN)."
}

main "$@"
