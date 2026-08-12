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
# Freshness snapshot for open findings (lib/probe_findings.py): derived, disposable, rewritten by
# harvest and by the verify phase. Read by the dashboard's Nightshift tab through the same mount.
PROBE_SNAPSHOT="$STATE_DIR/findings-probe.json"
# Derived, disposable index of the last service epoch per (repo,dimension). One aggregating jq
# pass over the append-only ledger, memoized on the ledger's mtime, so last_dim_epoch's nested
# repo×dimension callers stop re-slurping the whole ledger on every cell (see last_dim_epoch).
LEDGER_EPOCH_INDEX="$STATE_DIR/.ledger-epoch.idx"
RUNSLOG="$STATE_DIR/runs.jsonl"
RECON_DIR="$STATE_DIR/recon"   # per-repo recon caches (ADR 0010); derived, disposable, HEAD/TTL-invalidated
SCAN_DIR="$STATE_DIR/dim-scans"  # per (repo,dim) explore markers so rotation advances even on an empty Explore
# A recon that produces nothing is negative-cached with THIS backoff (short vs the good-cache ttl_days),
# so a transient failure retries soon but repeated failures don't re-run the expensive recon every pass.
RECON_FAIL_BACKOFF_S="${NIGHTSHIFT_RECON_FAIL_BACKOFF_S:-21600}"  # 6h
# Worktrees live OUTSIDE the control repo, so nightshift can target its own repo
# without nesting a worktree inside a working tree.
WORKTREES_DIR="${NIGHTSHIFT_WORKTREES:-${TMPDIR:-/tmp}/nightshift-worktrees}"
mkdir -p "$STATE_DIR" "$RUNS_DIR" "$DIGEST_DIR" "$WORKTREES_DIR" "$SCAN_DIR"

log() { echo "[nightshift] $*" >&2; }

# Stage isolation has a location precondition: the claude CLI also collects CLAUDE.md files along the
# cwd->/ directory chain, and for a cwd under $HOME that chain includes ~/.claude/CLAUDE.md — which
# --setting-sources cannot drop (verified 2026-08-02, claude 2.1.205). Worktrees default under
# ${TMPDIR:-/tmp}, outside $HOME, where the isolation holds. Overriding NIGHTSHIFT_WORKTREES into
# $HOME silently reopens the leak, so say so instead of failing the run (see docs/design/hook-spec.md).
if [ "$NIGHTSHIFT_AGENT" = claude ] && [ -n "${HOME:-}" ]; then
  case "$(cd "$WORKTREES_DIR" && pwd -P)/" in
    "$(cd "$HOME" && pwd -P)"/*)
      log "WARNING: worktrees live under \$HOME ($WORKTREES_DIR) — stages will inherit ~/.claude/CLAUDE.md" ;;
  esac
fi

# ---------------------------------------------------------------- rulebook ----
declare -a REPO_PATHS=() REPO_MODES=() REPO_BASES=() REPO_FINDINGS=() REPO_DIMS=() REPO_TEST_CMDS=() DIMENSIONS=()
# Rulebook-declared model per adapter (ADR 0020); empty = the rulebook declares none. Kept separate
# from the NIGHTSHIFT_*_MODEL env vars so the precedence env > rulebook > CLI default stays legible.
RB_CLAUDE_MODEL="" RB_CODEX_MODEL="" RB_MAX_VERIFY=""
# Announce which model the night will REQUEST, and where that choice came from (ADR 0020). Not which
# model serves it: with no --model the CLI picks for itself, and even a given id may be an alias that
# resolves elsewhere — that answer only exists afterwards, in `runs.jsonl` (`model_id`). Announcing
# the selection is still the point: stage isolation (ADR 0019) means a machine-wide pin in the CLI's
# own config no longer reaches a stage, so a host that believes it pinned one must learn otherwise at
# the start of the night rather than the morning after.
log_model_selection() { # adapter env_var_name rulebook_value
  local adapter="$1" name="$2" rb="$3"
  if [ -n "${!name+set}" ]; then
    log "$adapter model: ${!name:-<none — no --model passed>} (from \$$name)"
  elif [ -n "$rb" ]; then
    log "$adapter model: $rb (from rulebook agent.${adapter}_model)"
  else
    log "$adapter model: not declared — the CLI's own default applies (runs.jsonl model_id records what served)"
  fi
}

load_rulebook() {
  local tag a b c d e f rb_run_branches="" parsed
  # Capture the parser's output AND its exit status. Reading it directly via
  # `done < <(python3 …)` hides a nonzero exit from `set -euo pipefail`, so a
  # mid-stream parse error (e.g. a bad `findings:` on repo #2) silently truncated
  # the repo set — the bad repo AND every valid repo after it were dropped and the
  # run proceeded on a partial fleet. Fail closed instead: abort the whole run.
  parsed="$(python3 "$NIGHTSHIFT_HOME/lib/parse_rulebook.py" "$RULEBOOK")" \
    || { log "rulebook parse failed ($RULEBOOK) — aborting run"; exit 1; }
  while IFS=$'\t' read -r tag a b c d e f; do
    case "$tag" in
      prefix)                BRANCH_PREFIX="$a" ;;
      max_open)              MAX_OPEN="$a" ;;
      max_findings_per_item) MAX_FINDINGS="$a" ;;
      max_verifies_per_run)  RB_MAX_VERIFY="$a" ;;
      recon_enabled)         RECON_ENABLED="$a" ;;
      recon_ttl_days)        RECON_TTL_DAYS="$a" ;;
      max_branches_per_run)  rb_run_branches="$a" ;;
      max_fix_iterations)    MAX_FIX_ITER="$a" ;;
      max_run_minutes)       RB_MAX_RUN_MINUTES="$a" ;;
      test_timeout_seconds)  TEST_TIMEOUT="$a" ;;
      max_files)             MAX_FILES="$a" ;;
      max_lines)             MAX_LINES="$a" ;;
      claude_model)          RB_CLAUDE_MODEL="$a" ;;
      codex_model)           RB_CODEX_MODEL="$a" ;;
      dimension)             DIMENSIONS+=("$a") ;;
      repo)                  REPO_PATHS+=("${a#path=}"); REPO_MODES+=("${b#mode=}"); REPO_BASES+=("${c#base=}"); REPO_FINDINGS+=("${d#findings=}"); REPO_DIMS+=("${e#dimensions=}"); REPO_TEST_CMDS+=("${f#test_cmd=}") ;;
    esac
  done <<< "$parsed"
  MAX_FINDINGS="${MAX_FINDINGS:-1}"
  RECON_ENABLED="${RECON_ENABLED:-true}"; RECON_TTL_DAYS="${RECON_TTL_DAYS:-7}"
  # Ship gate ceiling (ADR 0022). Env override for a one-off, else the rulebook (which the
  # parser already defaulted and validated), else 600s.
  TEST_TIMEOUT="${NIGHTSHIFT_TEST_TIMEOUT:-${TEST_TIMEOUT:-600}}"
  # How many open findings the verify phase may re-check per night. Bounds what closure can cost:
  # every candidate is one read-only stage call. 0 disables the phase (the deterministic probe
  # still runs — it is free). Env override for a one-off, else the rulebook, else 5.
  MAX_VERIFY="${NIGHTSHIFT_MAX_VERIFIES:-${RB_MAX_VERIFY:-5}}"
  # Fallback dimension set if the rulebook declares none, so rotation still works out of the box.
  [ "${#DIMENSIONS[@]}" -gt 0 ] || DIMENSIONS=(correctness security infra docs tests perf ui-ux deps craft)
  # Per-run safety ceiling: the rulebook wins; NIGHTSHIFT_MAX_RUN_BRANCHES stays as an
  # ops override for when it is not set there; 50 is the last-resort default.
  MAX_RUN_BRANCHES="${rb_run_branches:-${NIGHTSHIFT_MAX_RUN_BRANCHES:-50}}"
  export NIGHTSHIFT_BRANCH_PREFIX="$BRANCH_PREFIX"
}

# --------------------------------------------------------------- telemetry ----
# `model` is the ADAPTER name (claude|codex|mock) and stays that way — harvest/digest code may read
# it. The model that ACTUALLY served the stage is the separate `model_id` field ("claude-opus-5",
# "claude-opus-4-8[1m]", "gpt-5-codex", …), self-reported by the CLI; null whenever the CLI reports
# none (mock, older CLI shapes). `tokens` remains OUTPUT tokens for backwards compatibility; the
# input/cache counters are per-stage CUMULATIVE over every request the stage made, so they bound
# (never equal) the peak context of a single request. `context_window` answers the 200k-vs-[1m]
# question outright — it is the window the served model actually ran with, reported by the CLI, not
# inferred from those sums. `cost_usd` is the whole stage invocation; `model_cost_usd` is the slice
# attributed to `model_id`, which differs only when a stage touched more than one model.
# See docs/design/documentation-system.md.
append_run() { # stage agent start dur status item usage_json
  local usage="${7:-}"
  [ -n "$usage" ] || usage='{}'
  jq -nc \
    --arg night "$NIGHT" --arg item "$6" --arg stage "$1" --arg model "$2" \
    --argjson start "$3" --argjson dur "$4" --argjson status "$5" \
    --argjson usage "$usage" \
    'def s: if . == null or . == "" then null else tostring end;
     def n: if . == null or . == "" then null else (tonumber? // null) end;
     {night:$night,item:$item,stage:$stage,model:$model,
      model_id:($usage.model_id|s),
      start:$start,
      duration_s:$dur,
      tokens:($usage.output_tokens|n),
      input_tokens:($usage.input_tokens|n),
      cache_read_tokens:($usage.cache_read_tokens|n),
      cache_creation_tokens:($usage.cache_creation_tokens|n),
      context_window:($usage.context_window|n),
      cost_usd:($usage.cost_usd|n),
      model_cost_usd:($usage.model_cost_usd|n),
      exit:$status}' >> "$RUNSLOG"
}

ledger_append() { # item repo fp branch sha outcome [summary] [pr_url] [proof] [verifiability] [dimension] [type] [code_sig] [scope]
  jq -nc \
    --arg night "$NIGHT" --arg item "$1" --arg repo "$2" --arg fp "$3" \
    --arg branch "$4" --arg sha "$5" --arg outcome "$6" --arg summary "${7:-}" --arg pr "${8:-}" \
    --arg proof "${9:-}" --arg verif "${10:-}" --arg dim "${11:-}" --arg type "${12:-}" --arg csig "${13:-}" --arg scope "${14:-}" --arg ts "$(date -Iseconds)" \
    '{night:$night,item:$item,repo:$repo,fingerprint:$fp,
      branch:($branch|if .=="" then null else . end),
      sha:($sha|if .=="" then null else . end),
      pr_url:($pr|if .=="" then null else . end),
      proof:($proof|if .=="" then null else . end),
      verifiability:($verif|if .=="" then null else . end),
      dimension:($dim|if .=="" then null else . end),
      type:($type|if .=="" then null else . end),
      code_sig:($csig|if .=="" then null else . end),
      scope:($scope|if .=="" then null else . end),
      outcome:$outcome,summary:$summary,ts:$ts}' >> "$LEDGER"
}

# Runner-canonical finding identity (ADR 0014). Computed by the Runner from NORMALIZED structured
# fields — NOT trusted from the model's free-form `fingerprint`, which is prose-unstable. Layered:
#   sorted files : normalized type : semantic anchor (symbol, else a normalized code snippet)
# Prose summary and line numbers are DELIBERATELY excluded, so the identity survives rewording and
# line movement; files are sorted so multi-file order is irrelevant. Falls back to the model's
# fingerprint only when no structured anchor exists at all, else "" so the caller drops the finding.
finding_fingerprint() { # finding.json -> canonical identity or ""
  jq -r '
    ((.files // [ .file ]) | map(select(. != null and . != "")) | unique) as $files
    | ((.type // "") | ascii_downcase | gsub("\\s+";"-")) as $type
    | ((.symbol // "") | gsub("\\s+";"")) as $sym
    | ((.snippet // "") | ascii_downcase | gsub("\\s+";" ") | gsub("^ +| +$";"")) as $snip
    | ($files | join(",")) as $fkey
    | if ($fkey|length)==0 and ($sym|length)==0 then
        (.fingerprint // "") | if (type=="string" and length>0 and . != "null") then . else "" end
      else
        ([$fkey, $type] | map(select(length>0)) | join(":"))
        + (if ($sym|length)>0 then ":" + $sym
           elif ($snip|length)>0 then ":#" + $snip
           else "" end)
      end' "$1" 2>/dev/null || true
}

# Content signature of a finding's target (ADR 0014, invalidation). A short hash of the target files'
# blob shas at HEAD: when the code under a finding changes, the signature changes, and a previously
# suppressed identity (resolved/abandoned/dropped) becomes eligible again — a `wontfix` alone stays
# permanent. Empty when there is no locatable target.
code_sig() { # repo finding.json -> 12-char signature or ""
  local repo="$1" fj="$2" files sig
  files=$(jq -r '(.files // [ .file ]) | map(select(. != null and . != "")) | unique | .[]' "$fj" 2>/dev/null || true)
  [ -n "$files" ] || { echo ""; return; }
  sig=$(while IFS= read -r f; do
          [ -n "$f" ] || continue
          git -C "$repo" rev-parse "HEAD:$f" 2>/dev/null || echo "absent:$f"
        done <<< "$files" | sha1sum | cut -c1-12)
  echo "$sig"
}

# Lifecycle-aware suppression (ADR 0014). A repo-scoped fingerprint is suppressed if it is permanently ignored
# (a human `wontfix` verdict) OR it has a prior row in the given outcome set whose stored content
# signature still MATCHES the current code (code_sig equal, or absent on older rows). If the code
# under the finding has changed since (code_sig differs), it is NOT suppressed — the identity is
# eligible again. jq match (not a grep regex): fingerprints contain '.'/'/'/':' metacharacters; a
# slurped any() keeps the verdict order-independent.
_fp_suppressed() { # repo fingerprint code_sig outcomes_json
  [ -n "$2" ] && [ "$2" != null ] || return 1   # never dedup on an unusable key
  [ -f "$LEDGER" ] || return 1
  jq -se --arg repo "$1" --arg fp "$2" --arg csig "$3" --argjson outs "$4" '
    . as $all
    | ([$all[] | select(.fingerprint==$fp and .repo!=null) | .repo] | unique) as $owners
    | [$all[] | select(.fingerprint==$fp and
        (.repo==$repo or (.repo==null and $owners==[$repo])))] as $rows
    | ($rows | any(.outcome=="verdict" and .verdict=="wontfix")) as $permanent
    | ($rows | any(
        ((.outcome as $o | $outs | index($o)) != null)
        and (((.code_sig // "") == "") or ((.code_sig // "") == $csig)))) as $known
    | $permanent or $known' "$LEDGER" >/dev/null 2>&1
}
_suppressed_for() { # outcomes_json repo fingerprint code_sig; legacy: outcomes_json fingerprint code_sig
  local outs="$1" repo fp csig
  shift
  if [ "$#" -eq 3 ]; then
    repo="$1"; fp="$2"; csig="$3"
  else
    fp="${1:-}"; csig="${2:-}"
    # Keep the sourced helper's old two-argument form safe: infer a repo only when the ledger
    # identifies exactly one owner. A colliding fingerprint is deliberately not suppressed.
    repo=$(jq -rs --arg fp "$fp" \
      '[.[] | select(.fingerprint==$fp and .repo!=null) | .repo] | unique
       | if length==1 then .[0] else empty end' "$LEDGER" 2>/dev/null || true)
    [ -n "$repo" ] || return 1
  fi
  _fp_suppressed "$repo" "$fp" "$csig" "$outs"
}
already_done()     { _suppressed_for '["finding","shipped","abandoned"]' "$@"; }  # findings-only: report once
already_acted()    { _suppressed_for '["shipped","abandoned"]' "$@"; }             # branch-fix: acted before
already_surfaced() { _suppressed_for '["finding"]' "$@"; }                         # a human-owned TODO is open

known_work() { # repo -> compact "fingerprint — summary" list of STILL-OPEN items for the explore prompt
  local repo="$1"
  [ -f "$LEDGER" ] || return 0
  # Latest verdict per fingerprint, then keep findings/open-branches whose verdict is NOT a terminal
  # clear (merged/resolved/wontfix/dropped). Cap the list so the prompt stays bounded.
  jq -rs --arg r "$repo" '
    . as $rows
    | ([ $rows[] | select(.outcome=="verdict" and .fingerprint!=null)
         | . as $verdict
         | ([ $rows[] | select(.fingerprint==$verdict.fingerprint and .repo!=null) | .repo] | unique) as $owners
         | select(.repo==$r or (.repo==null and $owners==[$r])) ] | group_by(.fingerprint)
      | map(sort_by(.ts)|last) | map({key:.fingerprint, value:.verdict}) | from_entries) as $v
    | [$rows[] | select(.repo==$r and (.outcome=="finding" or .outcome=="shipped") and .fingerprint!=null)]
    | group_by(.fingerprint) | map(sort_by(.ts)|last)
    | map(select((($v[.fingerprint] // "") | (. == "merged" or . == "resolved" or . == "wontfix" or . == "dropped")) | not))
    | .[0:40] | map("- " + .fingerprint + " — " + (.summary // "")) | join("\n")' \
    "$LEDGER" 2>/dev/null || true
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

# Layer 2 settings for the agent: register the PreToolUse guard. The matcher MUST
# cover Bash (anti-bypass of the pre-push hook) AND the file-writing tools
# (Write/Edit/MultiEdit/NotebookEdit) — otherwise the guard never fires for a Write
# and the worktree confinement (R8) is dead. The matcher is a regex over tool names.
write_claude_settings() {
  jq -nc --arg cmd "$HOOKS_DIR/pretooluse-guard.sh" \
    '{hooks:{PreToolUse:[{matcher:"Bash|Write|Edit|MultiEdit|NotebookEdit",
                          hooks:[{type:"command",command:$cmd}]}]}}' \
    > "$STATE_DIR/claude-settings.json"
}

# codemap (optional structural index) — an MCP tool, so it adds navigation power WITHOUT reopening
# Bash. Auto-gated per repo: offered only where the Runner's own `codemap index --approve` succeeded
# for that repo this pass (NIGHTSHIFT_CODEMAP_REPO, set in the night loop) — nightshift indexes every
# repo itself, so activation is never a human step; the rulebook is the consent surface. The agent
# works in a throwaway worktree (no index) and queries the STABLE real repo via repoPath; codemap not
# installed, indexing failed or NIGHTSHIFT_CODEMAP=0 -> the agent just uses Read/Grep/Glob.
write_codemap_mcp() {
  printf '%s\n' '{"mcpServers":{"codemap":{"type":"stdio","command":"codemap-mcp","args":[],"env":{}}}}' \
    > "$STATE_DIR/codemap-mcp.json"
}

# The Runner-owned CODEX_HOME a codex stage runs under (ADR 0019) — echoes the path, empty on
# failure. It deliberately contains NOTHING but a symlink to the operator's credentials: no
# AGENTS.md (the leak this closes), no config.toml, no skills, no memories, no session history.
# NIGHTSHIFT_CODEX_STAGE_HOME overrides the location; set it EMPTY to run under the operator's real
# home instead (escape hatch — reopens the leak). Cheap enough to re-assert per stage, and doing so
# self-heals a stale symlink after `codex login`.
codex_stage_home() {
  local real stage
  real="${CODEX_HOME:-$HOME/.codex}"
  stage="${NIGHTSHIFT_CODEX_STAGE_HOME-$STATE_DIR/codex-home}"
  [ -n "$stage" ] || { printf '%s' "$real"; return 0; }
  mkdir -p "$stage" || { log "codex stage home $stage not creatable"; return 1; }
  # Same path = the operator's own home; never relink credentials onto themselves.
  [ "$(cd "$stage" && pwd -P)" != "$(cd "$real" 2>/dev/null && pwd -P || echo "$real")" ] || {
    printf '%s' "$stage"; return 0; }
  if [ -e "$real/auth.json" ]; then
    ln -sfn "$real/auth.json" "$stage/auth.json"
  else
    # No credential file to carry over (e.g. API-key-in-env auth). Isolating still beats leaking:
    # codex fails loudly on a real auth problem, whereas falling back to the real home would fail
    # SILENTLY — as a leak nobody sees until it is in a commit body.
    log "codex: no auth.json under $real — stage home carries no credentials"
  fi
  printf '%s' "$stage"
}

# --------------------------------------------------------------- run_agent ----
# A stage that fails because the agent CLI has no usable credentials is NOT a quiet night: every
# later stage fails the same way, in a second or two, and the night still exits rc=0 having written
# a negative recon cache and an `empty` ledger row per repo — i.e. an infrastructure outage forges
# the record of a clean fleet. Observed 2026-08-05: all 8 stages died with `authentication_failed`
# ("Not logged in · Please run /login"), the log said "nothing worth doing" four times, and the four
# resulting `empty` rows are fiction. So classify the failure once and let main() abort the night.
AGENT_FATAL=""         # non-empty = the agent itself is unusable; set by run_agent, read by main()
AGENT_FATAL_AGENT=""   # WHICH adapter died — the advisor may legitimately run on a different one
# Credential-failure signatures, matched against the stage's captured stderr AND raw stdout (the
# claude CLI reports the failure as a JSON result object on stdout, codex on stderr). Deliberately
# broad: a false positive costs one aborted night, a false negative costs a forged clean fleet.
AGENT_AUTH_RE='not logged in|/login|authentication_failed|invalid api key|unauthorized|oauth token|credentials? (not found|expired|invalid)|codex login'
agent_credentials_failed() { # file… -> 0 if any readable file carries a credential-failure signature
  local f
  for f in "$@"; do
    [ -s "$f" ] || continue
    grep -qiE "$AGENT_AUTH_RE" "$f" 2>/dev/null && return 0
  done
  return 1
}

run_agent() { # stage workdir item_dir
  local stage="$1" workdir="$2" item_dir="$3" start end status=0 usage='{}'
  start=$(date +%s)
  case "$NIGHTSHIFT_AGENT" in
    mock)   "mock_$stage" "$workdir" "$item_dir" || status=$? ;;
    claude) claude_run "$stage" "$workdir" "$item_dir" || status=$? ;;
    codex)  codex_run "$stage" "$workdir" "$item_dir" || status=$? ;;
    *) log "unknown NIGHTSHIFT_AGENT=$NIGHTSHIFT_AGENT (expected mock, claude, or codex)"; status=2 ;;
  esac
  # A non-zero stage is reported as a FAILURE, not absorbed into "found nothing". The exit code has
  # always been recorded in runs.jsonl, but nothing ever read it back out — so a stage that could not
  # run at all was indistinguishable, in the night log and in the digest, from one that ran and had
  # nothing to say. Both adapters leave the CLI's own diagnosis in $stage.err (stderr) and
  # .raw_$stage (unparsed stdout); the last non-blank stderr line goes straight into the log so the
  # morning does not start with an archaeology session.
  if [ "$status" -ne 0 ]; then
    local errf="$item_dir/$stage.err" rawf="$item_dir/.raw_$stage" detail=""
    if [ -s "$errf" ]; then
      detail="$(tr -d '\r' < "$errf" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-200 || true)"
      [ -z "$detail" ] || detail=" · $detail"
    fi
    log "  stage $stage FAILED (exit $status)${detail}"
    [ -s "$errf" ] && log "  stage $stage: stderr in $errf"
    if [ -z "$AGENT_FATAL" ] && agent_credentials_failed "$errf" "$rawf"; then
      AGENT_FATAL="$NIGHTSHIFT_AGENT has no usable credentials (stage $stage)"
      AGENT_FATAL_AGENT="$NIGHTSHIFT_AGENT"
      log "FATAL: $AGENT_FATAL — aborting the night rather than recording a clean fleet."
      log "FATAL: re-authenticate the $NIGHTSHIFT_AGENT CLI, then run bin/nightshift.sh again."
    fi
  fi
  # Each real adapter drops ONE compact JSON object per stage (model_id + token/cost counters).
  # Missing, empty or unparsable -> {}, and every derived telemetry field degrades to null; the mock
  # agent never writes one. Telemetry must never be able to fail a stage.
  if [ "$NIGHTSHIFT_AGENT" != mock ] && [ -s "$item_dir/.usage_$stage" ]; then
    usage=$(jq -c 'if type=="object" then . else {} end' "$item_dir/.usage_$stage" 2>/dev/null || true)
    [ -n "$usage" ] || usage='{}'
  fi
  end=$(date +%s)
  append_run "$stage" "$NIGHTSHIFT_AGENT" "$start" "$((end - start))" "$status" "$(basename "$item_dir")" "$usage"
  return "$status"
}

# ----------------------------------------------------------- commit subject ----
# A host repo's `commit-msg` gate reads the Conventional Commits type as a CHECKED CLAIM about user
# visibility — git-workflow's changelog-check.sh demands a CHANGELOG entry for `feat|fix|perf`,
# exempts `refactor|test|chore|docs|ci|build|style|revert`, and treats an UNPARSEABLE subject as
# user-visible so a malformed message never becomes a bypass. The fixed `nightshift: ` subject was
# exactly that unparseable case: every change touching a code-classified file was read as
# user-visible and blocked for a missing CHANGELOG entry — and the Fix stage could not satisfy the
# gate by choosing a better subject, because it does not write the subject. (Observed 2026-08-07:
# pi-ext-auth lost two comment-only `doc` findings that way, and two `bug` fixes on 08-05.)
#
# An unrecognised finding type deliberately yields NOTHING here, which restores the old subject and
# with it the gate's fail-closed default: nightshift must never under-claim its way past a gate.
commit_type() { # finding_type -> conventional commits type, or empty when unknown
  case "$1" in
    bug|typo)                        printf 'fix' ;;
    doc)                             printf 'docs' ;;
    convention)                      printf 'chore' ;;
    cleanup|smell|naming|complexity)  printf 'refactor' ;;
  esac
}

# The `nightshift` scope keeps authorship visible in `git log --oneline`, which the old fixed prefix
# carried and the committer identity alone does not show. A scope is optional in the grammar every
# such gate parses, so carrying it costs the type nothing.
commit_subject() { # finding_type summary -> subject line
  local ct; ct="$(commit_type "$1")"
  if [ -n "$ct" ]; then printf '%s(nightshift): %s' "$ct" "$2"; else printf 'nightshift: %s' "$2"; fi
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
  if [ "$stage" = fix ]; then
    # Name the gates the repo will apply to the runner's commit. The Fix stage cannot commit and so
    # never sees a hook fire; an unmet convention surfaces only as `commit-failed` AFTER the model
    # is gone, discarding the whole change (that is how partflow's CHANGELOG gate silently ate a
    # deps cleanup, and pi-authenticator's two test fixes before it). Detected, not guessed: only
    # what is actually present is listed, and nothing is listed when the repo gates nothing.
    local gates="" hooks changelog f
    for f in CHANGELOG.md CHANGELOG CHANGES.md; do
      [ -f "$wd/$f" ] && { changelog="$f"; break; }
    done
    [ -n "${changelog:-}" ] && gates="$gates
- \`$changelog\` is present — a user-visible change is expected to carry an entry. Match the file's
  own format and add to its newest/unreleased section; do not invent a release."
    hooks="$(git -C "$wd" config core.hooksPath 2>/dev/null || true)"
    # `core.hooksPath` is very often RELATIVE (`.githooks` is the common spelling, and this repo
    # uses it). git resolves that against the working tree; testing it as-is would resolve it
    # against the RUNNER's cwd instead, so the hook silently went undetected and the Fix stage was
    # never told about a gate that then rejected its commit — the exact `commit-failed` this block
    # exists to prevent.
    case "$hooks" in "" ) ;; /* ) ;; * ) hooks="$wd/$hooks" ;; esac
    [ -n "$hooks" ] || hooks="$(git -C "$wd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)/hooks"
    # BOTH message hooks, not just `pre-commit`: a repo that moved its CHANGELOG check to
    # `commit-msg` (which alone can see the commit type) was reported as ungated, and the Fix stage
    # was never told about the gate that then rejected its commit. pi-ext-auth is precisely that
    # repo — its `pre-commit` is a SKILL.md lint and its `commit-msg` is the CHANGELOG gate.
    for f in pre-commit commit-msg; do
      [ -f "$hooks/$f" ] && gates="$gates
- A \`$f\` hook is installed (\`$hooks/$f\`) and runs on the runner's commit. Read it
  if you are unsure what it demands of the files you touched."
    done
    if [ -n "$gates" ]; then
      # Name the subject VERBATIM. A hook that reads the commit type decides against this exact
      # line, and the Fix stage has no other way to know it — left to guess, it reasoned about a
      # subject it would never get and concluded a gate would pass that then blocked it.
      local subj
      subj="$(commit_subject "$(jq -r '.type // "change"' "$id/finding.json" 2>/dev/null || true)" \
                             "$(jq -r '.summary // ""'   "$id/finding.json" 2>/dev/null || true)")"
      prompt="$prompt

## Gates this repo applies to the commit
The runner commits your working tree exactly as you leave it, with the repo's own hooks active. A
rejected commit discards the ENTIRE fix — there is no second attempt. You do NOT write the commit
message and cannot change it; the runner's subject line will be exactly:

    $subj

Judge any hook that reads the subject against THAT line, not against one you would have written.
Satisfy these as part of the change:$gates"
    fi
    # A tests.log here means the PREVIOUS iteration of this same loop passed review and then broke
    # the repo's suite (ADR 0022). run_test_gate deletes the file the moment the suite is green, so
    # its presence is always about the attempt that is still in the working tree.
    if [ -f "$id/tests.log" ]; then
      prompt="$prompt

## Your previous attempt broke this repo's test suite
The reviewer accepted your fix and the repo's own suite then failed against it. The working tree
still holds that attempt — this is YOUR regression to repair, not a new finding. Read the output
below, fix the cause, and keep the original finding fixed: reverting your change to make the suite
pass is not a solution. If the failing test is itself wrong, say so in the worknote and correct it
deliberately rather than deleting or skipping it. Last 100 lines:

\`\`\`
$(tail -n 100 "$id/tests.log")
\`\`\`"
    fi
  fi
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
  if [ "$stage" = explore ] && [ -n "${NIGHTSHIFT_KNOWN_WORK:-}" ]; then
    prompt="$prompt

## Known work — already surfaced or handled (do NOT re-report; keep searching for NEW issues)
nightshift has already recorded the items below and will suppress a duplicate. Spend your findings
budget on DISTINCT, new issues. Re-raise one only if it is genuinely unresolved AND worse than
anything new you can find.

${NIGHTSHIFT_KNOWN_WORK}"
  fi
  if [ "$stage" = recon ] && [ -f "$id/signals.json" ]; then
    prompt="$prompt

### recon_signals (deterministic filesystem probe — refine these into a per-dimension yield)
$(cat "$id/signals.json")"
  fi
  case "$stage" in
    fix|review|verify) prompt="$prompt

### finding.json
$(cat "$id/finding.json")" ;;
  esac
  if [ "$stage" = review ]; then
    # Stage first, then show the STAGED diff so review sees exactly what finalize commits
    # (`git add -A` in finalize). A plain `git diff` reports tracked modifications only and
    # omits new untracked files, letting a fix-created file ship unreviewed (R9 / fix N3).
    git -C "$wd" add -A
    prompt="$prompt

### git diff (staged — exactly what finalize will commit)
$(git -C "$wd" diff --staged)"
  fi
  if [ "$stage" = advise ]; then
    prompt="$prompt

### finding.json (what this branch claims to address)
$(cat "$id/finding.json" 2>/dev/null || echo '{}')

### git diff (three-dot: base...branch — independent of base drift)
$(git -C "$wd" diff "${NIGHTSHIFT_ADVISE_BASE:-HEAD}...HEAD" 2>/dev/null || true)"
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
  # An intent-ambiguous divergence (ADR 0006): the reviewer can prove it but cannot know which side is
  # authoritative, so it must SURFACE as a human-owned finding, never auto-fix. Deterministic trigger.
  if [ -f "$wd/NOTES.md" ] && grep -q 'AMBIGUOUS' "$wd/NOTES.md"; then
    arr=$(printf '%s' "$arr" | jq -c '. + [{file:"NOTES.md",type:"divergence",line_window:"L1-L5",
      disposition:"surface",verifiability:"static",summary:"ambiguous divergence in NOTES.md — needs a human",
      fingerprint:"NOTES.md:divergence:L1-L5",rank:1,confidence:0.8}]')
  fi
  # An UNRECOGNISED disposition must fail closed (surface, not auto-fix). Deterministic trigger.
  if [ -f "$wd/WEIRD.md" ] && grep -q 'FROB' "$wd/WEIRD.md"; then
    arr=$(printf '%s' "$arr" | jq -c '. + [{file:"WEIRD.md",type:"other",line_window:"L1-L3",
      disposition:"frobnicate",verifiability:"static",summary:"unknown disposition must fail closed",
      fingerprint:"WEIRD.md:other:L1-L3",rank:1,confidence:0.8}]')
  fi
  # ADR 0015 scope: when nothing is found, declare whether the lens even applies here. Deterministic
  # trigger — a `NOSCOPE` sentinel file makes the mock return out_of_scope (the "no surface" verdict).
  local scope=in_scope_no_findings
  [ -f "$wd/NOSCOPE" ] && scope=out_of_scope
  jq -nc --argjson f "$arr" --arg scope "$scope" \
    '{found:($f|length>0),findings:$f} + (if ($f|length>0) then {} else {scope:$scope} end)' > "$id/finding.json"
  # A stage that FAILS is not the same as a stage that found nothing, and a stage can fail after
  # having written a usable verdict — the claude CLI's `--max-turns` ceiling is the live case for both.
  # The sentinel is the exit code itself (env, not a file in the worktree) so a test can reach either
  # half of the Runner's response: with findings on disk it must keep them, without it must record no
  # verdict at all. finding.json is written first on purpose, exactly as the failing case leaves it.
  return "${NIGHTSHIFT_MOCK_EXPLORE_RC:-0}"
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
  # Deterministic `abandon`, so the reviewer's give-up verdict is reachable in mock mode like every
  # other path. The trigger is a sentinel PATH, not content in the worktree: a test must be able to
  # arm it MID-loop (from a failing test_cmd, say) without planting a file in the tree that is about
  # to be committed.
  if [ -n "${NIGHTSHIFT_MOCK_ABANDON_IF:-}" ] && [ -e "${NIGHTSHIFT_MOCK_ABANDON_IF:-}" ]; then
    jq -nc '{verdict:"abandon",reason:"mock: abandon sentinel present."}' > "$id/review.md"
    return 0
  fi
  jq -nc '{verdict:"ship",reason:"Typo fix; single file, reversible, no behaviour change — clears the smallness bar."}' > "$id/review.md"
}
mock_advise() { # workdir item_dir — deterministic second-opinion from the branch's finding type
  local _wd="$1" id="$2" type
  type=$(jq -r '.type // ""' "$id/finding.json" 2>/dev/null || echo "")
  if [ "$type" = typo ]; then
    jq -nc '{recommendation:"merge",reason:"Typo fix; trivial, reversible, no behaviour change."}' > "$id/advice.json"
  else
    jq -nc '{recommendation:"do-not-merge",reason:"Non-trivial change; a human should judge intent."}' > "$id/advice.json"
  fi
}
mock_verify() { # workdir item_dir — resolved iff the planted defect is gone from the target file
  local wd="$1" id="$2" file marker
  file=$(jq -r '.file // ((.files // [])[0] // "")' "$id/finding.json" 2>/dev/null || echo "")
  case "$file" in
    README.md) marker="teh " ;;
    app.py)    marker="retrun" ;;
    *)         marker="" ;;
  esac
  if [ -n "$marker" ] && [ -f "$wd/$file" ] && ! grep -qF "$marker" "$wd/$file"; then
    jq -nc --arg f "$file" '{resolved:true,confidence:"high",
      evidence:("planted defect no longer present in " + $f)}' > "$id/verify.json"
  else
    jq -nc --arg f "$file" '{resolved:false,confidence:"high",
      evidence:("defect still present in " + $f)}' > "$id/verify.json"
  fi
}
mock_recon() { # workdir item_dir — deterministic yield straight from recon_signals.json (ADR 0015)
  local _wd="$1" id="$2" sig
  sig=$(cat "$id/signals.json" 2>/dev/null || echo '{}')
  # Recon reprioritizes, never excludes (ADR 0015): every dimension gets a yield label, never
  # dropped. high = strong signal the lens pays off here; low = little signal, still rotated in.
  printf '%s' "$sig" | jq -c '. as $s | {
    dimensions: {
      correctness:{yield:"normal", hint:"any code path"},
      security:   {yield:"normal", hint:"trust boundaries"},
      infra:      {yield:(if (($s.has_compose//false) or ($s.has_dockerfile//false) or ($s.has_ci//false) or ($s.has_iac//false)) then "high" else "low" end), hint:"compose/docker/ci present"},
      docs:       {yield:"normal", hint:"docs vs code"},
      tests:      {yield:(if ($s.has_tests//false) then "normal" else "low" end), hint:"test dir present"},
      perf:       {yield:"low", hint:"hot path only if data volume"},
      "ui-ux":    {yield:(if ($s.has_frontend//false) then "high" else "low" end), hint:"frontend present"},
      deps:       {yield:(if ((($s.lockfiles//[])|length)>0) then "normal" else "low" end), hint:"lockfiles present"},
      craft:      {yield:"normal", hint:"floor lens"}
    }, notes:"mock recon (deterministic yield mapping from filesystem signals)"}' > "$id/recon.json"
}

# ---- claude adapter (first-party CLI headless, ADR 0003) ----
# The agent only reads/edits files; the Runner owns all git (branch/commit/push).
# Sandbox default uses --dangerously-skip-permissions (throwaway repo; git-level
# confinement via hooks/pre-push holds regardless of Claude's permission mode).
claude_run() { # stage workdir item_dir
  local stage="$1" wd="$2" id="$3" prompt out model
  # --max-turns is the C6 runaway cap (docs/design/risk-analysis.md), not a budget: the spend cap and
  # the wall-clock bound are what limit cost. It was 25, which Explore reached and died on for 5 of 26
  # items on 2026-08-12 — each after spending its full ~$2 of tokens and returning nothing. A ceiling
  # that is hit routinely is the wrong ceiling: 60 still hard-stops a loop, but leaves a navigating
  # stage room to finish. Every abort is now visible in the digest rather than read as "found nothing".
  local flags="${NIGHTSHIFT_CLAUDE_FLAGS:---dangerously-skip-permissions --max-turns 60}"
  # Which model this stage runs on. Precedence: the env var if SET (an explicitly empty value is the
  # escape hatch — pass no --model), else the rulebook's `agent.claude_model` (ADR 0020), else
  # nothing and the CLI resolves its own default. The rulebook layer matters because stage isolation
  # (ADR 0019) drops the CLI's `user` settings scope, so a pin in ~/.claude/settings.json cannot
  # reach a stage; the host declares the model in its own governance file instead. nightshift still
  # commits no model of its own — rulebook.yaml is host-owned and untracked.
  local -a model_arg=()
  model="${NIGHTSHIFT_CLAUDE_MODEL-${RB_CLAUDE_MODEL:-}}"
  [ -z "$model" ] || model_arg=(--model "$model")
  # Stage isolation from the OPERATOR's personal Claude Code config (docs/design/hook-spec.md).
  # `--setting-sources` selects which settings SCOPES the CLI loads; dropping `user` drops both
  # ~/.claude/settings.json AND ~/.claude/CLAUDE.md, while `project,local` keeps the TARGET repo's
  # own CLAUDE.md — the context a stage actually wants. Without this the operator's private
  # instructions (chat language, personal conventions, tripwires) end up verbatim in worknotes and
  # therefore in pushed commit bodies. Empty = pass no flag (escape hatch for a CLI too old to know
  # the option; the leak returns). Measured: ~3.8k tokens of personal rules dropped per stage call.
  local -a sources_arg=()
  local sources="${NIGHTSHIFT_CLAUDE_SETTING_SOURCES-project,local}"
  [ -z "$sources" ] || sources_arg=(--setting-sources "$sources")
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
  # NIGHTSHIFT_WORKTREE tells the PreToolUse guard which root to confine Write/Edit to
  # (the Fix stage has Write/Edit but no Bash; absolute paths would otherwise escape — R8).
  # CLAUDE_CODE_DISABLE_AUTO_MEMORY: the auto-memory store is keyed by cwd under ~/.claude/projects/
  # and is NOT covered by --setting-sources. A stage worktree is throwaway, so there is nothing to
  # read — but the memory writer is a write path OUTSIDE the worktree that the PreToolUse guard
  # never sees (R8). Off for stages: nightshift's memory is its ledger, not a per-cwd store.
  # stdout and stderr both go to FILES, and the exit code is inspected afterwards, rather than the
  # older `out="$(… 2>/dev/null)" || return 1`. That form discarded the CLI's diagnosis twice over:
  # stderr went to /dev/null, and a non-zero exit dropped the captured stdout on the floor with it —
  # so a stage that never started left an empty item dir and no trace of why (see AGENT_FATAL above).
  # Keeping both lets run_agent report the reason and recognise a credential failure.
  local rawf="$id/.raw_$stage" errf="$id/$stage.err" rc=0
  (cd "$wd" && \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR" \
    NIGHTSHIFT_WORKTREE="$wd" CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
    claude -p "$prompt" --output-format json --settings "$STATE_DIR/claude-settings.json" --tools "$tools" "${model_arg[@]}" "${sources_arg[@]}" $cm_flags $flags </dev/null) >"$rawf" 2>"$errf" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  out="$(cat "$rawf")"
  # `claude -p --output-format json` is NOT a stable shape. Sometimes it is a single
  # result object ({result,usage,total_cost_usd}); sometimes a JSON ARRAY of events with
  # the result object as one element (observed with claude 2.1.197, e.g. when a
  # rate_limit_event is present). A parser that assumes one shape silently yields an empty
  # result on the other — every explore then reports found:false and claude mode does
  # nothing. So normalise both: pick the result object whether top-level is it or an array.
  local pick='if type=="array" then (map(select(.type=="result"))|last) else . end'
  printf '%s' "$out" | jq -r "$pick"' | (.result // "")'                > "$id/$stage.out"
  # Telemetry sidecar for run_agent. `modelUsage` is keyed by the REAL model ID
  # ("claude-opus-5", "claude-opus-4-8[1m]", …) and is the only place the served model appears — the
  # adapter name alone cannot answer "which model ran, and did it need the [1m] context variant". A
  # stage may touch more than one model (e.g. a small model for side work), so attribute it to the
  # one that consumed the most tokens; fall back to a top-level `.model` for older result shapes.
  # `model_id`, `context_window` and `model_cost_usd` all come from that ONE attributed entry, so
  # they never describe different models. `contextWindow` is the window the model actually ran with
  # (200000 vs 1000000) — it settles the [1m] question outright, instead of bounding it from the
  # cumulative token sums. Note the casing asymmetry the CLI emits: `usage.*` is snake_case,
  # `modelUsage.<id>.*` is camelCase.
  # Every field is optional: absent -> null, and a jq failure here must never fail the stage.
  printf '%s' "$out" | jq -c "$pick"' |
    (((.modelUsage // {}) | to_entries
      | map(select((.value | type) == "object"))
      | max_by((.value.inputTokens // 0) + (.value.outputTokens // 0)
               + (.value.cacheReadInputTokens // 0) + (.value.cacheCreationInputTokens // 0))) // null) as $top |
    {
      model_id: (($top.key) // .model // null),
      output_tokens:         (.usage.output_tokens // null),
      input_tokens:          (.usage.input_tokens // null),
      cache_read_tokens:     (.usage.cache_read_input_tokens // null),
      cache_creation_tokens: (.usage.cache_creation_input_tokens // null),
      context_window:        ($top.value.contextWindow // null),
      cost_usd:              (.total_cost_usd // null),
      model_cost_usd:        ($top.value.costUSD // null)
    }' > "$id/.usage_$stage" 2>/dev/null || true
  case "$stage" in
    explore) python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/finding.json" ;;
    fix)     cp "$id/$stage.out" "$id/worknote.md" ;;
    review)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/review.md" ;;
    recon)   python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/recon.json" ;;
    advise)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/advice.json" ;;
    verify)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/verify.json" ;;
  esac
  return 0
}

# ---- codex adapter (first-party CLI headless, ADR 0003) ----
# Recon/Explore/Review run read-only. Fix can write and execute commands only inside the disposable
# worktree, with network disabled. The Runner still owns branch/commit/push.
#
# Fix-stage confinement — the two adapters differ, deliberately, and NOT symmetrically:
#   claude: capability-restricted to Read,Grep,Glob,Write,Edit — NO Bash, so it cannot run any
#           command (git or otherwise). Its PreToolUse guard confines Write/Edit paths to the
#           Runner-injected worktree root, including absolute paths.
#   codex:  OS-level `--sandbox workspace-write` — CAN exec commands (incl. git) but only inside the
#           worktree, and network is off. Out-of-tree writes are blocked by the sandbox.
# Neither can push (the Runner owns push; the pre-push hook + PreToolUse guard hold regardless), so
# neither is exploitable to reach main — but their fix-stage boundaries are enforced by different
# mechanisms (tool capability vs OS sandbox) with different residual gaps. See risk-analysis.md.
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
  # Same precedence as the claude half: env if SET (empty = pass no --model), else the rulebook's
  # `agent.codex_model` (ADR 0020), else the CLI default.
  model="${NIGHTSHIFT_CODEX_MODEL-${RB_CODEX_MODEL:-}}"
  [ -z "$model" ] || args+=(--model "$model")
  effort="${NIGHTSHIFT_CODEX_REASONING_EFFORT:-}"
  [ -z "$effort" ] || args+=(-c "model_reasoning_effort=\"$effort\"")
  # Stage isolation, codex half (ADR 0019). `--ignore-user-config` covers $CODEX_HOME/config.toml and
  # `--ignore-rules` the execpolicy files, but NEITHER covers $CODEX_HOME/AGENTS.md — the operator's
  # global instructions leak into the stage verbatim (verified 2026-08-02, codex-cli 0.145.0). The
  # only lever that separates the scopes is the home itself: a Runner-owned CODEX_HOME with no
  # AGENTS.md in it drops the global file while the TARGET repo's own AGENTS.md still loads. The
  # config-level knob is the wrong way round — `project_doc_max_bytes=0` kills the repo's AGENTS.md
  # and leaves the global one standing. Auth is the one thing the isolated home must keep: codex
  # resolves credentials under CODEX_HOME, so auth.json is symlinked in (verified: a real API call
  # succeeds through it). No auth.json -> still isolate, and let codex report the auth failure
  # itself rather than silently reopening the leak.
  local cx_home
  cx_home="$(codex_stage_home)"
  [ -n "$cx_home" ] || return 1

  if [ -n "${NIGHTSHIFT_CODEMAP_REPO:-}" ] && { [ "$stage" = explore ] || [ "$stage" = review ]; }; then
    args+=(-c 'mcp_servers.codemap.command="codemap-mcp"')
    prompt="$prompt

## Structural index (codemap)
A codemap index of this repo is available. Prefer codemap_search / codemap_context to locate relevant
code instead of reading files blindly. Your cwd is a throwaway worktree with NO index — ALWAYS pass
repoPath=$NIGHTSHIFT_CODEMAP_REPO to these tools."
  fi

  # Same capture contract as the claude half: stderr to $stage.err, unparsed stdout to .raw_$stage
  # (here the event stream, which is also what codex uses to report an auth failure), so run_agent
  # can name the reason a stage died and spot a credential failure. Codex's stderr previously landed
  # unlabelled in the night log; per stage and per item dir it is attributable.
  events="$id/.raw_$stage"
  if ! (cd "$wd" && printf '%s' "$prompt" | \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR" \
    CODEX_HOME="$cx_home" \
    codex "${args[@]}" - > "$events" 2>"$id/$stage.err"); then
    return 1
  fi
  # Telemetry sidecar for run_agent — same object contract as the claude adapter. Codex's event
  # stream is no more stable than claude's JSON: a payload sits either at the top level of an event
  # or wrapped in `.msg`, so consider both for every event. Usage rides on `turn.completed` (with
  # `token_count`/`total_token_usage` as the older shape) and is cumulative, hence `last`. The model
  # ID is announced once by a session/thread event. Codex's `input_tokens` INCLUDES
  # `cached_input_tokens`, unlike claude's, and codex reports neither cost nor the context window it
  # ran with — those degrade to null rather than being inferred. See documentation-system.md.
  jq -sc '
    def evs: [.[] | select(type == "object") | ., (.msg | select(type == "object"))];
    def usage: [ evs[]
                 | (select(.type == "turn.completed") | .usage)
                 , (select(.type == "token_count")   | .info.total_token_usage)
                 | select(type == "object") ] | last // {};
    def modelid: [ evs[]
                   | (try (.model, .session.model, .thread.model, .turn.model) catch empty)
                   | select(type == "string" and . != "") ] | last // null;
    usage as $u |
    { model_id: modelid,
      output_tokens:         ($u.output_tokens // null),
      input_tokens:          ($u.input_tokens // null),
      cache_read_tokens:     ($u.cached_input_tokens // $u.cache_read_input_tokens // null),
      cache_creation_tokens: null,
      context_window:        null,
      cost_usd:              null,
      model_cost_usd:        null }' \
    "$events" > "$id/.usage_$stage" 2>/dev/null || true
  case "$stage" in
    explore) python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/finding.json" ;;
    fix)     cp "$id/$stage.out" "$id/worknote.md" ;;
    review)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/review.md" ;;
    recon)   python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/recon.json" ;;
    advise)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/advice.json" ;;
    verify)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/verify.json" ;;
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

repo_test_cmd() { # repo -> the repo's ship-gate command, or "" for an ungated repo (ADR 0022)
  # Deliberately has NO global fallback: a test command is repo-specific by nature, and inheriting
  # some fleet-wide default would run the wrong suite. Absent means ungated, which is a real and
  # legitimate state (a repo may genuinely have no runner) — finalize logs it so it stays visible.
  local repo="$1" i
  for i in "${!REPO_PATHS[@]}"; do
    if [ "${REPO_PATHS[$i]}" = "$repo" ]; then
      echo "${REPO_TEST_CMDS[$i]:-}"; return
    fi
  done
  echo ""
}

repo_dimensions() { # repo -> candidate dimensions, space-separated, in priority order (ADR 0010)
  # Per-repo `dimensions:` (comma-separated) overrides the global set. This IS the candidate set and
  # nothing downstream shrinks it: the human rulebook is the only exclusion authority (ADR 0015);
  # recon only reweights the lenses within it (see dim_weight/select_dimension).
  local repo="$1" i
  for i in "${!REPO_PATHS[@]}"; do
    if [ "${REPO_PATHS[$i]}" = "$repo" ]; then
      [ -n "${REPO_DIMS[$i]:-}" ] && { echo "${REPO_DIMS[$i]//,/ }"; return; }
      break
    fi
  done
  echo "${DIMENSIONS[*]}"
}

dim_scan_marker() { # repo dim -> marker file path (basename + path hash keeps same-named repos distinct)
  printf '%s/%s-%s__%s' "$SCAN_DIR" "$(basename "$1")" "$(printf '%s' "$1" | sha1sum | cut -c1-8)" "$2"
}
refresh_ledger_epoch_index() { # rebuild LEDGER_EPOCH_INDEX (repo\tdim\tepoch) iff the ledger changed
  # last_dim_epoch runs once per (repo,dimension) cell inside nested loops — select_dimension's
  # dimension loop and write_digest's repo×dimension coverage matrix — so a per-call `jq -rs` slurp
  # re-parses the whole append-only, never-pruned ledger O(R*D) times a night. Instead derive the
  # per-key max service ts in ONE jq pass and cache it, invalidated on the ledger's mtime (the file
  # is command-substitution-safe state, since callers run last_dim_epoch in a subshell). The per-key
  # max is exactly what the old per-call query returned, so the staleness ranking is unchanged.
  if [ ! -f "$LEDGER" ]; then rm -f "$LEDGER_EPOCH_INDEX" 2>/dev/null || true; return 0; fi
  # Fresh index (exists and the ledger is not newer) → reuse; nested cells cost a lookup, not a scan.
  { [ -f "$LEDGER_EPOCH_INDEX" ] && [ ! "$LEDGER" -nt "$LEDGER_EPOCH_INDEX" ]; } && return 0
  local raw tmp repo dim iso
  # On a jq failure keep any existing index and retry next call — never cache an empty index over a
  # good one (matches the old per-call `|| true`, which fell back to epoch 0 only for that one call).
  raw=$(jq -rs '
    [.[]|select(.repo!=null and .dimension!=null
                and (.outcome=="finding" or .outcome=="shipped" or .outcome=="abandoned"))]
    | group_by([.repo,.dimension]) | map(max_by(.ts) | [.repo,.dimension,.ts])
    | .[] | @tsv' "$LEDGER" 2>/dev/null) || return 0
  tmp="$(mktemp "$STATE_DIR/.ledger-epoch.idx.XXXXXX")"
  {
    while IFS=$'\t' read -r repo dim iso; do
      [ -n "$iso" ] || continue
      printf '%s\t%s\t%s\n' "$repo" "$dim" "$(date -d "$iso" +%s 2>/dev/null || echo 0)"
    done <<< "$raw"
  } > "$tmp"
  mv -f "$tmp" "$LEDGER_EPOCH_INDEX"
}
last_dim_epoch() { # repo dim -> epoch this (repo,dim) was last SERVICED — a work-item row OR an Explore scan
  # A lens can Explore and find nothing; counting only work-item outcomes left its epoch at 0
  # forever — permanently maximal staleness, so select_dimension re-picked it every run and
  # starved the others.
  # The Explore scan marker (touched every pass, outcome or not) is what makes rotation advance.
  local repo="$1" dim="$2" lepoch=0 mepoch=0 marker
  refresh_ledger_epoch_index
  if [ -f "$LEDGER_EPOCH_INDEX" ]; then
    lepoch=$(awk -F'\t' -v r="$repo" -v d="$dim" '$1==r && $2==d {print $3; exit}' "$LEDGER_EPOCH_INDEX")
    [ -n "$lepoch" ] || lepoch=0
  fi
  marker="$(dim_scan_marker "$repo" "$dim")"
  [ -f "$marker" ] && mepoch=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
  [ "$mepoch" -gt "$lepoch" ] && echo "$mepoch" || echo "$lepoch"
}

recon_cache_path() { # repo -> cache path; basename for readability + a path hash so two repos
  # with the SAME basename (e.g. /a/api and /b/api) never share (and cross-contaminate) a cache.
  printf '%s/%s-%s.json' "$RECON_DIR" "$(basename "$1")" "$(printf '%s' "$1" | sha1sum | cut -c1-8)"
}
# --- ADR 0015: recon reprioritizes via yield weights, never excludes ----------
# Recon can no longer drop a dimension; it only weights it. The finite low-weight floor is the real
# anti-starvation guarantee (a `low` lens recurs ~DIM_W_HIGH/DIM_W_LOW = 10x less often than a `high`
# one, never never); the cadence-relative ceiling is a legibility backstop. Fable's 2.0/1.0/0.2
# weights are scaled ×5 to integers so the whole selection score stays integer arithmetic in bash.
DIM_W_HIGH=10 DIM_W_NORMAL=5 DIM_W_LOW=1

dim_weight() { # repo dim -> integer yield weight; no cache / unknown / pre-0015 => normal (never drops)
  local repo="$1" dim="$2" cache y
  cache="$(recon_cache_path "$repo")"
  [ -f "$cache" ] || { echo "$DIM_W_NORMAL"; return; }
  y=$(jq -r --arg d "$dim" '.dimensions[$d].yield // "normal"' "$cache" 2>/dev/null || echo normal)
  case "$y" in high) echo "$DIM_W_HIGH" ;; low) echo "$DIM_W_LOW" ;; *) echo "$DIM_W_NORMAL" ;; esac
}

recon_generated_epoch() { # repo -> epoch the recon cache was generated (0 if none)
  local cache iso; cache="$(recon_cache_path "$1")"
  [ -f "$cache" ] || { echo 0; return; }
  iso=$(jq -r '.ts // ""' "$cache" 2>/dev/null || echo "")
  { [ -n "$iso" ] && date -d "$iso" +%s 2>/dev/null; } || echo 0
}

evidence_override() { # repo dim -> 0 if a SHIPPED finding for (repo,dim) postdates recon's last look.
  # A shipped finding (passed review) newer than recon's judgment proves a `low` verdict stale, so the
  # weight floors at normal. Anchored to recon's generation time, it self-clears once recon re-runs
  # with that finding in history. Only `shipped` counts — a later-dropped false positive must not pin
  # the weight up. Derived from the durable ledger; NOTHING is written to the disposable recon cache.
  local repo="$1" dim="$2" gen ts e
  [ -f "$LEDGER" ] || return 1
  gen=$(recon_generated_epoch "$repo")
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    e=$(date -d "$ts" +%s 2>/dev/null || echo 0)
    [ "$e" -gt "$gen" ] && return 0
  done < <(jq -r --arg r "$repo" --arg d "$dim" \
            'select(.repo==$r and .dimension==$d and .outcome=="shipped") | .ts' "$LEDGER" 2>/dev/null || true)
  return 1
}

median_gap() { # repo D -> median inter-service interval (secs) across the repo's service rows; 60d bootstrap
  # "Overdue" is judged RELATIVE to how often this repo actually gets attention, not absolute calendar
  # age — else a slow-cadence repo would trip an absolute ceiling on every lens every run, neutralizing
  # the weights. Until the repo has >= D recorded services, bootstrap with an absolute 60d.
  local repo="$1" D="$2" boot=$((60*86400)) ts e n; local -a eps=()
  [ -f "$LEDGER" ] || { echo "$boot"; return; }
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    e=$(date -d "$ts" +%s 2>/dev/null || echo 0); [ "$e" -gt 0 ] && eps+=("$e")
  # `-s` (slurp) rather than the streaming form: a retracted row is identified by an entry that
  # appears LATER in the append-only ledger, so the whole file has to be in hand before any row can
  # be judged. A retracted `empty` never counted as a service — it is the record of a night that
  # claimed to have reviewed something without doing so (ADR 0023), and letting it shorten the
  # measured cadence would make every lens look more overdue than it is.
  done < <(jq -rs --arg r "$repo" \
            '[.[]|select(.outcome=="retracted")|.item] as $void
             | .[]|select(.repo==$r and ([.item]|inside($void)|not)
                          and (.outcome=="finding" or .outcome=="shipped" or .outcome=="abandoned" or .outcome=="empty"))
             | .ts' \
            "$LEDGER" 2>/dev/null || true)
  n=${#eps[@]}
  [ "$n" -lt "$D" ] && { echo "$boot"; return; }
  printf '%s\n' "${eps[@]}" | sort -n | awk 'NR>1{print $1-p} {p=$1}' | sort -n \
    | awk -v boot="$boot" '{a[NR]=$1} END{ if(NR==0){print boot;exit}
        m=(NR%2)?a[(NR+1)/2]:int((a[int(NR/2)]+a[int(NR/2)+1])/2); if(m<=0)m=boot; print m }'
}

dim_ceiling() { # repo D -> overdue threshold in secs = 2.5 * D * median_gap  (~2.5 realized rotations)
  local repo="$1" D="$2" gap; gap=$(median_gap "$repo" "$D"); echo $(( 5 * D * gap / 2 ))
}

select_dimension() { # repo -> highest weighted-staleness dimension (ADR 0015)
  # score = (now - last_epoch) * eff_weight. eff_weight = recon yield weight, floored to normal by
  # ledger evidence, boosted to high when overdue past the cadence-relative ceiling. Strict `>` scan in
  # rulebook order means the earliest-listed dimension wins a tie (cold-start / all-overdue => flat
  # rulebook-order rotation, which is the correct behavior for a starved repo). No dimension is ever
  # skipped — recon reprioritizes, it never excludes; only the human rulebook narrows the candidate set.
  local repo="$1" now dim w ep age score best_dim="" best_score=-1 ceil
  local -a dd; read -ra dd <<< "$(repo_dimensions "$repo")"
  local D=${#dd[@]}; [ "$D" -gt 0 ] || { echo ""; return; }
  now=$(date +%s); ceil=$(dim_ceiling "$repo" "$D")
  for dim in "${dd[@]}"; do
    w=$(dim_weight "$repo" "$dim")
    { evidence_override "$repo" "$dim" && [ "$w" -lt "$DIM_W_NORMAL" ]; } && w=$DIM_W_NORMAL
    ep=$(last_dim_epoch "$repo" "$dim"); age=$(( now - ep )); [ "$age" -lt 0 ] && age=0
    [ "$age" -gt "$ceil" ] && w=$DIM_W_HIGH
    score=$(( age * w ))
    if [ "$score" -gt "$best_score" ]; then best_score=$score; best_dim="$dim"; fi
  done
  echo "$best_dim"
}

ensure_recon() { # repo -> refresh the recon cache if missing / HEAD changed / older than ttl_days (ADR 0010)
  [ "${RECON_ENABLED:-true}" != false ] || return 0
  local repo="$1" cache head chead cts cepoch now ttl win cfailed id wt base tmp
  cache="$(recon_cache_path "$repo")"; mkdir -p "$RECON_DIR"
  head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")
  if [ -f "$cache" ]; then
    chead=$(jq -r '.head // ""' "$cache" 2>/dev/null || echo "")
    cts=$(jq -r '.ts // ""' "$cache" 2>/dev/null || echo "")
    cfailed=$(jq -r '.recon_failed // false' "$cache" 2>/dev/null || echo false)
    cepoch=0; [ -n "$cts" ] && cepoch=$(date -d "$cts" +%s 2>/dev/null || echo 0)
    now=$(date +%s); ttl=$(( ${RECON_TTL_DAYS:-7} * 86400 ))
    # A negative (failed) cache uses the short backoff, a good cache the full ttl.
    win="$ttl"; [ "$cfailed" = true ] && win="$RECON_FAIL_BACKOFF_S"
    if [ "$chead" = "$head" ] && [ "$cepoch" -gt 0 ] && [ "$(( now - cepoch ))" -lt "$win" ]; then
      return 0   # cache is fresh — recon costs zero this run
    fi
  fi
  id="$RUNS_DIR/recon-$(date +%s%N)"; mkdir -p "$id"
  "$NIGHTSHIFT_HOME/lib/recon_signals.sh" "$repo" > "$id/signals.json" 2>/dev/null || echo '{}' > "$id/signals.json"
  # Recon is read-only, but the "never the live checkout" invariant is absolute: if the
  # isolated worktree can't be created, SKIP recon rather than pointing a stage at the
  # operator's working tree. Recon degrades gracefully — no cache written this run means
  # dim_weight() returns the normal weight for every dimension, so nothing is starved.
  base="$(base_ref "$repo")"; wt="$WORKTREES_DIR/$(basename "$id")"
  if setup_worktree "$repo" "$wt" "$base"; then
    run_agent recon "$wt" "$id" || true; remove_worktree "$repo" "$wt"
  else
    log "  $(basename "$repo"): recon worktree failed — skipping recon (never the live checkout)"
    return 0
  fi
  # An agent that cannot authenticate produces no recon result — but that is a statement about the
  # CLI, not about the repo, and caching it would be wrong twice: the negative cache asserts "recon
  # found nothing here" and its backoff then suppresses the retry for 6h, so the operator's fix does
  # not take effect on the next run either. Leave the cache untouched and let main() end the night.
  if [ -n "$AGENT_FATAL" ]; then
    log "  $(basename "$repo"): recon skipped — agent unavailable (cache left untouched)"
    return 0
  fi
  # Write atomically (temp + rename): a failed/partial jq must never truncate a good prior cache.
  tmp="$cache.tmp.$$"
  if [ -s "$id/recon.json" ]; then
    if jq -c --arg h "$head" --arg r "$repo" --arg ts "$(date -Iseconds)" \
         '. + {repo:$r, head:$h, ts:$ts}' "$id/recon.json" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$cache"
    else
      rm -f "$tmp"; log "  $(basename "$repo"): recon cache write failed — keeping prior cache"
    fi
  else
    # Negative cache: recon produced nothing. Empty dimensions ⇒ dim_weight() falls back to the normal
    # weight for every lens (safe degrade); recon_failed + the short backoff stop it re-running every pass.
    if jq -nc --arg h "$head" --arg r "$repo" --arg ts "$(date -Iseconds)" \
         '{repo:$r, head:$h, ts:$ts, recon_failed:true, dimensions:{}, notes:""}' > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$cache"; log "  $(basename "$repo"): recon produced no result — negative-cached (backoff ${RECON_FAIL_BACKOFF_S}s)"
    else
      rm -f "$tmp"
    fi
  fi
}

refresh_open_branch_refs() { # reconcile remote-tracking refs once per pass, not once per cap check
  local i path
  for i in "${!REPO_PATHS[@]}"; do
    path="${REPO_PATHS[$i]}"
    [ -d "$path/.git" ] || continue
    # --prune: without it, a branch deleted on origin lingers as a stale remote-tracking ref and
    # `--no-merged` keeps counting it, inflating backpressure and blocking runs on phantom slots.
    git -C "$path" fetch --prune -q origin 2>/dev/null || true
  done
}

SETTLED_BRANCHES=""   # newline-separated "<repo>\t<branch>" the ledger has already settled

refresh_settled_branches() { # cache the branches whose latest ledger verdict is terminal
  # The cap asks "how many decisions am I still waiting on", but `--no-merged` can only answer
  # "is the sha an ancestor of base" — the same naive test ADR 0016 already replaced inside
  # harvest, and it is wrong in both directions once the ref outlives the decision:
  #   * a CLOSED PR whose branch was never deleted is a REJECTION, not a pending decision, yet
  #     it holds a slot forever (observed 2026-08-13: market-digest's correctness-bug branch,
  #     rejected 2026-08-09 in favour of a hand-written fix, blocked the whole fleet for four
  #     nights — 4/4, "0 shipped, 0 considered", three nights in a row);
  #   * a squash- or rebase-merged branch never becomes an ancestor of base (ADR 0016 §1/§2),
  #     so a surviving ref counts as open although the change demonstrably landed.
  # harvest already resolves both via its authoritative ladder and records the verdict. Read that
  # instead of re-deriving a weaker answer: the ledger is the record (ADR 0021).
  SETTLED_BRANCHES=""
  [ -f "$LEDGER" ] || return 0
  # Terminal set mirrors known_work()'s: merged/resolved/wontfix/dropped all mean "decided".
  SETTLED_BRANCHES=$(jq -rs '
    [ .[] | select(.outcome=="verdict" and .branch!=null and .repo!=null) ]
    | group_by([.repo, .branch]) | map(sort_by(.ts) | last)
    | map(select(.verdict=="merged" or .verdict=="resolved"
                 or .verdict=="wontfix" or .verdict=="dropped"))
    | map(.repo + "\t" + .branch) | join("\n")' "$LEDGER" 2>/dev/null) || SETTLED_BRANCHES=""
}

branch_is_settled() { # repo branch -> 0 when the ledger's latest verdict for it is terminal
  [ -n "$SETTLED_BRANCHES" ] || return 1
  printf '%s\n' "$SETTLED_BRANCHES" | grep -qxF "$1	$2"
}

open_branch_count() { # count nightshift/* still awaiting the operator's decision (§3e)
  local total=0 i path base b
  for i in "${!REPO_PATHS[@]}"; do
    path="${REPO_PATHS[$i]}"
    [ -d "$path/.git" ] || continue
    base="$(resolve_base "$path" "${REPO_BASES[$i]:-}")"
    while read -r b; do
      b="${b#origin/}"
      case "$b" in "${BRANCH_PREFIX}"*) ;; *) continue ;; esac
      branch_is_settled "$path" "$b" && continue
      total=$((total + 1))
    done < <(git -C "$path" branch -r --no-merged "$base" --format='%(refname:short)' 2>/dev/null)
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

# --------------------------------------------------------------- ship gate ----
# The Review stage proves the FINDING is fixed; it does not prove nothing ELSE broke. Regressions
# therefore shipped unnoticed unless the host repo happened to have CI — and only one of four did.
# (Observed 2026-08-04: market-digest PR #10 dropped a dependency that looked unreferenced in src/
# but was imported by tests across a service boundary; three tests broke, the PR shipped.)
#
# So the repo's own suite runs against the worktree, INSIDE the fix<->review loop rather than after
# it: a failure is a revision request, not a death sentence. The Fix stage caused the breakage and
# is still in the loop with budget left, so it gets the failing output back and repairs its own
# damage (see stage_prompt). Only an item that leaves the loop still broken is refused.
run_test_gate() { # repo worktree item_dir -> 0 pass/ungated, 1 fail; writes item_dir/tests.log on failure
  local repo="$1" wt="$2" id="$3" tcmd trc=0
  tcmd=$(repo_test_cmd "$repo")
  if [ -z "$tcmd" ]; then
    log "  $(basename "$repo"): no test_cmd in the rulebook — shipping UNGATED"
    return 0
  fi
  # Runs in the WORKTREE, not the repo — the worktree is what carries the fix and what is about to
  # be committed. `timeout` bounds a hanging suite so it cannot eat the night.
  # `|| trc=$?` and not `if ! …`: inside an `if !` body `$?` is the negation's 0, not the suite's.
  # NIGHTSHIFT_TEST_PATH is the developer toolchain (node/npm/pnpm) the repo's own suite needs but
  # that a systemd user service does not get — bin/nightshift-cron.sh explains why it is prepended
  # HERE and nowhere else: the Runner's own unqualified jq/git/python3 calls must keep resolving to
  # the system dirs (R10/N4), while this subprocess already runs the repo's package scripts anyway.
  ( cd "$wt" && export PATH="${NIGHTSHIFT_TEST_PATH:+$NIGHTSHIFT_TEST_PATH:}$PATH" \
    && timeout "$TEST_TIMEOUT" bash -c "$tcmd" ) >"$id/tests.log" 2>&1 || trc=$?
  if [ "$trc" -ne 0 ]; then
    [ "$trc" -eq 124 ] && log "  $(basename "$repo"): test gate TIMED OUT after ${TEST_TIMEOUT}s"
    log "  $(basename "$repo"): test gate failed (rc=$trc) — see $id/tests.log"
    return 1
  fi
  # Removed on success on purpose: the file's PRESENCE is what tells stage_prompt that the previous
  # attempt broke the suite. A stale log from an earlier iteration would keep asking the Fix stage
  # to repair damage it has already repaired.
  rm -f "$id/tests.log"
  log "  $(basename "$repo"): test gate passed"
  return 0
}

# ---------------------------------------------------------------- finalize ----
finalize() { # repo worktree item_dir [seq] [base] -> echoes branch name
  local repo="$1" wt="$2" id="$3" seq="${4:-0}" basearg="${5:-}" fp type dim csig slug branch sha summary verif
  fp=$(jq -r '.fingerprint' "$id/finding.json")
  type=$(jq -r '.type // "change"' "$id/finding.json")   # default so the branch slug never reads "null"
  dim=$(jq -r '.dimension // ""' "$id/finding.json")     # the review lens (ADR 0010), leads the slug
  csig=$(jq -r '.code_sig // ""' "$id/finding.json")     # content signature for invalidation (ADR 0014)
  summary=$(jq -r '.summary // ""' "$id/finding.json")
  verif=$(jq -r '.verifiability // ""' "$id/finding.json" 2>/dev/null || true)
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
  # The TARGET repo's own hooks run for this commit — deliberately: nightshift must not manufacture
  # commits the host repo would reject. So the commit can fail (a blocking pre-commit hook, or an
  # empty index because the Fix stage changed nothing), and NOTHING below may treat that as shipped.
  # Without this check `rev-parse HEAD` just returned the BASE sha, the untouched branch was pushed,
  # and the ledger recorded `shipped` — a fix that does not exist, holding an open-branch slot.
  # (Observed 2026-08-02: partflow's CHANGELOG pre-commit hook rejected a deps cleanup; the empty
  # branch shipped anyway. `set -e` cannot catch it — finalize runs inside an `if` condition.)
  if ! git -C "$wt" -c user.name=nightshift -c user.email=nightshift@localhost \
       commit -q -m "$(commit_subject "$type" "$(jq -r '.summary' "$id/finding.json")")

$(cat "$id/worknote.md")"; then
    log "  $(basename "$repo"): commit rejected (repo hook, or nothing to commit) — not shipped: $branch"
    ledger_append "$(basename "$id")" "$repo" "$fp" "" "" "commit-failed" "$summary" "" "" "$verif" "$dim" "$type" "$csig"
    git -C "$wt" checkout -q --detach >/dev/null 2>&1 || true
    git -C "$repo" branch -q -D "$branch" >/dev/null 2>&1 \
      || log "  $(basename "$repo"): cleanup warning — local branch remains: $branch"
    return 1
  fi
  sha=$(git -C "$wt" rev-parse HEAD)
  # Layer 1 hook active for THIS push only (-c), never persisted to the repo config.
  if ! git -c core.hooksPath="$HOOKS_DIR" -C "$wt" push -q -u origin "$branch"; then
    log "  $(basename "$repo"): push failed — not shipped: $branch"
    ledger_append "$(basename "$id")" "$repo" "$fp" "$branch" "$sha" "push-failed" "$summary" "" "" "$verif" "$dim" "$type" "$csig"
    git -C "$wt" checkout -q --detach >/dev/null 2>&1 || true
    git -C "$repo" branch -q -D "$branch" >/dev/null 2>&1 \
      || log "  $(basename "$repo"): cleanup warning — local branch remains: $branch"
    return 1
  fi
  local pr_url proof
  pr_url=$(open_pr "$repo" "$wt" "$branch" "$id" "$basearg")
  proof=$(jq -r '.proof // ""' "$id/review.md" 2>/dev/null || true)
  verif=$(jq -r '.verifiability // ""' "$id/finding.json" 2>/dev/null || true)
  ledger_append "$(basename "$id")" "$repo" "$fp" "$branch" "$sha" "shipped" "$(jq -r '.summary // ""' "$id/finding.json")" "$pr_url" "$proof" "$verif" "$dim" "$type" "$csig"
  echo "$branch"
}

# ------------------------------------------------- independent branch review ----
# ----------------------------------------------------------- finding closure ----
# A finding is a human-owned TODO with no branch and no sha, so harvest's reconcile loop — which
# tests a branch sha against base — can never reach it. Left alone it stays open in the ledger, the
# digest and the dashboard forever, and known_work keeps re-injecting it into Explore. This phase
# closes the loop, cheapest layer first:
#   1. the deterministic freshness probe (lib/probe_findings.py) recomputes every open finding's
#      content signature (ADR 0014). An UNCHANGED signature proves the target code was never
#      touched, so the finding cannot have been fixed — no model is spent on it.
#   2. only findings whose code DID change reach the read-only verify stage, which reads today's
#      code and judges whether that specific defect is gone.
# Fail closed at every step: only resolved:true AND confidence:high writes a verdict, and it is
# stamped source "auto-verify" — a machine claim, distinct from a human's `manual` ground truth
# (ADR 0007). Anything else leaves the item open and records the negative in the probe snapshot, so
# the same unchanged code is never paid for twice.
append_finding_verdict() { # item repo fingerprint verdict [reason]
  jq -nc --arg night "$NIGHT" --arg item "$1" --arg repo "$2" --arg fp "$3" \
    --arg verdict "$4" --arg reason "${5:-}" --arg ts "$(date -Iseconds)" \
    '{night:$night,item:$item,repo:$repo,fingerprint:$fp,branch:null,sha:null,
      outcome:"verdict",verdict:$verdict,
      reason:($reason|if .=="" then null else . end),
      source:"auto-verify",ts:$ts,schema_version:2}' >> "$LEDGER"
}

repo_cfg_base() { # repo -> the rulebook's `base:` for it ("" = auto-detect)
  local repo="$1" i
  for i in "${!REPO_PATHS[@]}"; do
    [ "${REPO_PATHS[$i]}" = "$repo" ] && { echo "${REPO_BASES[$i]:-}"; return; }
  done
  echo ""
}

run_probe() { # refresh the freshness snapshot; never fatal — it is derived, disposable state
  python3 "$NIGHTSHIFT_HOME/lib/probe_findings.py" \
    --ledger "$LEDGER" --out "$PROBE_SNAPSHOT" >/dev/null 2>&1 \
    || log "findings probe failed (non-fatal)"
}

verify_findings() {
  [ "${MAX_VERIFY:-0}" -gt 0 ] || return 0
  [ -f "$LEDGER" ] || return 0
  run_probe
  local n=0 cand row item repo fp sig summary dim ts base wt id resolved conf ev
  # Oldest candidate first, and only those never verified against TODAY's signature — the probe
  # drops a stale verify block itself, so an item re-enters this queue exactly when its code moves.
  cand=$(jq -r '[.items[]? | select(.state=="code_changed" and (has("verify")|not))]
                | sort_by(.ts) | .[] | @base64' "$PROBE_SNAPSHOT" 2>/dev/null || true)
  [ -n "$cand" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if [ "$n" -ge "$MAX_VERIFY" ]; then
      log "verify: cap reached ($MAX_VERIFY) — the rest keep until the next night"; break
    fi
    if over_budget; then log "verify: time budget exhausted — stop"; break; fi
    row=$(base64 -d <<<"$row")
    item=$(jq -r '.item' <<<"$row");        repo=$(jq -r '.repo' <<<"$row")
    fp=$(jq -r '.fingerprint' <<<"$row");   sig=$(jq -r '.code_sig_now' <<<"$row")
    summary=$(jq -r '.summary' <<<"$row");  dim=$(jq -r '.dimension' <<<"$row")
    ts=$(jq -r '.ts' <<<"$row")
    [ -d "$repo/.git" ] || continue
    base="$(resolve_base "$repo" "$(repo_cfg_base "$repo")")"
    wt="$WORKTREES_DIR/verify-$(date +%s%N)"
    setup_worktree "$repo" "$wt" "$base" || { log "verify: no worktree for $(basename "$repo") — skip"; continue; }
    id="$RUNS_DIR/verify-$(date +%s%N)"; mkdir -p "$id"
    # The stage sees the finding as recorded — NOT the original code. Judging the present state is
    # the whole point; handing it a reconstruction would invite pattern-matching on the old defect.
    jq -nc --arg s "$summary" --arg fp "$fp" --arg d "$dim" --arg ts "$ts" \
      --argjson files "$(jq -c '[(.fingerprint|split(":")[0]|split(","))[]|select(length>0)]' <<<"$row")" \
      '{summary:$s,fingerprint:$fp,dimension:$d,recorded:$ts,files:$files}' > "$id/finding.json"
    run_agent verify "$wt" "$id" || true
    remove_worktree "$repo" "$wt"
    n=$((n + 1))
    resolved=$(jq -r '.resolved // false' "$id/verify.json" 2>/dev/null || echo false)
    conf=$(jq -r '.confidence // "low"' "$id/verify.json" 2>/dev/null || echo low)
    ev=$(jq -r '.evidence // ""' "$id/verify.json" 2>/dev/null || echo "")
    if [ "$resolved" = true ] && [ "$conf" = high ]; then
      append_finding_verdict "$item" "$repo" "$fp" resolved "auto-verify: ${ev:-no evidence given}"
      python3 "$NIGHTSHIFT_HOME/lib/probe_findings.py" record-verify --out "$PROBE_SNAPSHOT" \
        --item "$item" --sig "$sig" --result resolved --reason "$ev" >/dev/null 2>&1 || true
      log "  verify: $(basename "$repo") — RESOLVED ($fp)"
    else
      python3 "$NIGHTSHIFT_HOME/lib/probe_findings.py" record-verify --out "$PROBE_SNAPSHOT" \
        --item "$item" --sig "$sig" --result open --reason "${ev:-no evidence given}" >/dev/null 2>&1 || true
      log "  verify: $(basename "$repo") — still open ($fp)"
    fi
  done <<< "$cand"
  # Resolved items must leave the snapshot now, not on the next harvest — the dashboard reads it.
  [ "$n" -gt 0 ] && run_probe
  return 0
}

# Opt-in (NIGHTSHIFT_BRANCH_REVIEW=1): a FRESH read-only agent gives a second opinion — merge /
# do-not-merge — on every open nightshift/* branch, written into the morning digest. It NEVER merges
# or pushes (read-only tool profile + git-confinement hold). Prefer a different model/vendor with
# NIGHTSHIFT_ADVISOR_AGENT (e.g. codex when the night ran on claude); the advisor's model is its own
# adapter env (NIGHTSHIFT_CODEX_MODEL / NIGHTSHIFT_CLAUDE_MODEL). Emits a markdown section on stdout
# ("" if disabled or no open branches).
advise_branches() {
  [ "${NIGHTSHIFT_BRANCH_REVIEW:-0}" = 1 ] || return 0
  # Dynamic-scope override: run_agent reads the global NIGHTSHIFT_AGENT; a local here rebinds it for
  # every advise call without disturbing the night's own adapter.
  local NIGHTSHIFT_AGENT="${NIGHTSHIFT_ADVISOR_AGENT:-$NIGHTSHIFT_AGENT}"
  # If the advisor runs on the adapter that just failed to authenticate, every call would die the
  # same way and stamp "?" over every open branch in the digest. A DIFFERENT vendor is unaffected by
  # the outage, and its second opinion on already-pushed branches is still worth having — so gate on
  # which adapter died, not merely on the fact that one did.
  if [ -n "$AGENT_FATAL" ] && [ "$NIGHTSHIFT_AGENT" = "$AGENT_FATAL_AGENT" ]; then
    log "branch review: skipped — $AGENT_FATAL"
    return 0
  fi
  local i path base branches ref name id wt rec reason out=""
  for i in "${!REPO_PATHS[@]}"; do
    path="${REPO_PATHS[$i]}"; [ -d "$path/.git" ] || continue
    git -C "$path" fetch --prune -q origin 2>/dev/null || true   # --prune: drop stale refs so review skips phantom branches
    base="$(resolve_base "$path" "${REPO_BASES[$i]:-}")"
    branches=$(git -C "$path" branch -r --no-merged "$base" 2>/dev/null | tr -d ' ' | grep "^origin/${BRANCH_PREFIX}" || true)
    [ -n "$branches" ] || continue
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      name="${ref#origin/}"
      id="$RUNS_DIR/advise-$(date +%s%N)"; mkdir -p "$id"
      # Best-effort finding context from the ledger's shipped row for this branch.
      jq -sc --arg b "$name" '([.[]|select(.outcome=="shipped" and .branch==$b)]|last) // {}
        | {summary:(.summary//""),fingerprint:(.fingerprint//""),type:(.type//""),dimension:(.dimension//"")}' \
        "$LEDGER" 2>/dev/null > "$id/finding.json" || echo '{}' > "$id/finding.json"
      wt="$WORKTREES_DIR/$(basename "$id")"
      if ! setup_worktree "$path" "$wt" "$ref"; then rm -rf "$id"; continue; fi
      local NIGHTSHIFT_ADVISE_BASE="$base"   # seen by stage_prompt via dynamic scope
      run_agent advise "$wt" "$id" || true
      remove_worktree "$path" "$wt"
      rec=$(jq -r '.recommendation // "?"' "$id/advice.json" 2>/dev/null || echo "?")
      reason=$(jq -r '.reason // ""'        "$id/advice.json" 2>/dev/null || echo "")
      out="$out- \`$name\` ($(basename "$path")): **$rec** — $reason"$'\n'
    done <<< "$branches"
  done
  [ -n "$out" ] || return 0
  printf '\n## Independent branch review (advisor: %s)\n_Read-only second opinion; never merges or pushes._\n\n%s' \
    "$NIGHTSHIFT_AGENT" "$out"
}

# ------------------------------------------------------------------- digest ----
write_digest() { # made open status [advice]
  local made="$1" open="$2" status="$3" advice="${4:-}" f="$DIGEST_DIR/$NIGHT.md" runs dur
  {
    echo "# nightshift digest — $NIGHT"
    echo
    local fcount=0
    [ -f "$LEDGER" ] && fcount=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n and .outcome=="finding")]|length' "$LEDGER" 2>/dev/null || echo 0)
    echo "- agent: \`$NIGHTSHIFT_AGENT\` · shipped this run: ${made} · surfaced (findings): ${fcount} · open (awaiting your verdict): ${open}/${MAX_OPEN} (cap)"
    [ "$status" = budget ] && echo "- **Stopped: time budget exhausted** (\`${MAX_RUN_SECONDS:-?}s\`) — the night ended on the spend cap, not for lack of work."
    # An aborted night must announce itself in the ONE artifact the operator actually reads in the
    # morning. Without this the digest of a credential outage is indistinguishable from a clean
    # fleet: same "shipped: 0", same empty tables, no reason given.
    [ "$status" = agent_unavailable ] && echo "- **ABORTED: the \`$NIGHTSHIFT_AGENT\` agent could not run** — ${AGENT_FATAL:-no usable credentials}. Nothing below reflects the state of the code: re-authenticate the CLI and run the night again. No recon caches or \`empty\` rows were written."
    if [ -f "$RUNSLOG" ]; then
      runs=$(grep -c "\"night\":\"$NIGHT\"" "$RUNSLOG" || true)
      dur=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n)|.duration_s]|add // 0' "$RUNSLOG")
      echo "- runs tonight: ${runs} stage-invocations, ${dur}s total"
      # Stages that never finished, counted from the exit codes runs.jsonl has always recorded but
      # nothing ever read back. They cost real tokens and produce no verdict, so the morning must see
      # them next to the shipped count instead of having to notice their absence.
      local nfail
      nfail=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n and .exit!=0)]|length' "$RUNSLOG" 2>/dev/null || echo 0)
      [ "${nfail:-0}" -gt 0 ] && echo "- **${nfail} stage-invocation(s) did not complete** — those lenses recorded no verdict and did not advance; grep the night log for \`FAILED\`."
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
    # ADR 0015: rulebook-exclusion suggestions. 3 consecutive out-of-scope passes for a (repo,dim) —
    # a full review through the lens that keeps concluding it has no surface here — is strong evidence
    # recon's low verdict is right. Recon can't exclude (it only reprioritizes); the human owns the
    # rulebook, so surface a suggestion rather than acting. Driven by Explore's own conclusion, not by
    # recon repeating itself (which would be a circular doom loop).
    [ -f "$LEDGER" ] && jq -rs '
      [.[]|select(.outcome=="retracted")|.item] as $void
      | [.[] | select(.dimension!=null and ([.item]|inside($void)|not)
                      and (.outcome=="empty" or .outcome=="finding" or .outcome=="shipped" or .outcome=="abandoned"))]
      | group_by([.repo,.dimension])
      | map(sort_by(.ts) | .[-3:])
      | map(select(length==3 and all(.[]; .outcome=="empty" and .scope=="out_of_scope")))
      | if length==0 then empty else
          "\n## Suggested rulebook exclusions (ADR 0015)\n"
          + (map("- `\(.[0].repo)` × `\(.[0].dimension)` — 3 consecutive out-of-scope passes; consider dropping this lens for this repo in rulebook.yaml `dimensions:`") | join("\n"))
        end' "$LEDGER" 2>/dev/null || true
    # ADR 0015: rulebook/recon contradictions. A lens the human narrowed OUT of a repo's configured
    # set that recon still sees signal for — a hand-exclusion never re-evaluates on its own, so flag it.
    if [ "${#REPO_PATHS[@]}" -gt 0 ]; then
      local contra="" rp cfg d y cache
      for rp in "${REPO_PATHS[@]}"; do
        cache="$(recon_cache_path "$rp")"; [ -f "$cache" ] || continue
        cfg=" $(repo_dimensions "$rp") "
        for d in "${DIMENSIONS[@]}"; do
          case "$cfg" in *" $d "*) continue ;; esac
          y=$(jq -r --arg d "$d" '.dimensions[$d].yield // "low"' "$cache" 2>/dev/null || echo low)
          case "$y" in high|normal) contra+="- \`$(basename "$rp")\` excludes \`$d\`, but recon rates it $y-yield here"$'\n' ;; esac
        done
      done
      [ -n "$contra" ] && printf '\n## Rulebook/recon contradictions (ADR 0015)\n%s' "$contra"
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
    # The same merge-rate signal sliced by verifiability, proof, and finding type — the tuning
    # feedback for which KINDS of change humans actually merge. Empty slices are omitted.
    [ -f "$LEDGER" ] && jq -rs '
      def rate($key; $name):
        ([.[]|select(.outcome=="verdict" and .branch!=null)] | group_by(.branch) | map(sort_by(.ts)|last)
          | map(select(.verdict=="merged" or .verdict=="dropped")) | INDEX(.branch)) as $v
        | [.[]|select(.outcome=="shipped" and .branch!=null)]
        | group_by(.[$key] // "—")
        | map({g:(.[0][$key] // "—"), br:(map(.branch)|unique)})
        | map({g:.g, n:(.br|length),
               m:(.br|map(select($v[.].verdict=="merged"))|length),
               d:(.br|map(select($v[.].verdict=="dropped"))|length)})
        | if length==0 then empty else
            "\n## Merge-rate by \($name) (all-time)\n"
            + (map("- \(.g): shipped \(.n) · merged \(.m) · dropped \(.d)"
                   + (if (.m+.d)>0 then " · rate \((100*.m/(.m+.d))|floor)%" else "" end)) | join("\n"))
          end ;
      [ rate("verifiability";"verifiability"), rate("proof";"proof"), rate("type";"finding type") ] | .[]
      ' "$LEDGER" 2>/dev/null || true
    echo
    # Backpressure ADDS a banner; it never REPLACES the body. Hitting the open-branch cap is the
    # normal end of a productive night (default cap 2, and the cap is only reached BY shipping), so
    # this is exactly when the human most needs the sections below: the banner says "go harvest
    # branches", and `## Shipped` is what names them. Suppressing the body here also broke ADR
    # 0004's digest contract (report shipped AND considered-but-abandoned) and contradicted this
    # same file's own `shipped this run: N` header line.
    if [ "$status" = "backpressure" ]; then
      echo "**FULL STOP — open-branch cap reached.** Harvest (merge/delete) some \`${BRANCH_PREFIX}\` branches to resume."
      echo
    fi
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
      'select(.night==$n and (.outcome=="abandoned" or .outcome=="push-failed" or .outcome=="commit-failed" or .outcome=="tests-failed")) | "- " + .repo + " — " + .outcome + ": " + (.summary // .fingerprint)' \
      "$LEDGER" 2>/dev/null || true
    echo
    # Carry-forward (ADR 0014): every surfaced finding, across ALL nights, that a human has not yet
    # cleared (merged/resolved/wontfix/dropped) — so an unresolved TODO stays visible until acted on.
    echo "## Open findings (all nights — awaiting a human)"
    [ -f "$LEDGER" ] && jq -rs '
      ([.[]|select(.outcome=="verdict" and .fingerprint!=null)] | group_by([.repo, .fingerprint])
        | map(sort_by(.ts)|last)
        | map({key:([.repo, .fingerprint] | tojson), value:.verdict}) | from_entries) as $v
      | [.[]|select(.outcome=="finding" and .fingerprint!=null)]
      | group_by([.repo, .fingerprint]) | map(sort_by(.ts)|last)
      | map(select((($v[([.repo, .fingerprint] | tojson)] // "") | (. == "merged" or . == "resolved" or . == "wontfix" or . == "dropped")) | not))
      | map("- " + .repo + " — " + (.summary // .fingerprint) + "  (" + .fingerprint + ", since " + .night + ")")
      | join("\n")' "$LEDGER" 2>/dev/null || true
    [ -n "$advice" ] && printf '%s\n' "$advice"
  } > "$f"
  log "digest -> $f"
}

# --------------------------------------------------------------- spend budget ----
# Wall-clock is the one budget signal that works identically for both first-party CLIs without a
# metered API (ADR 0013). Enforced for the whole night: checked before each pass and before each
# fix, so a read-only stage in flight finishes but no NEW mutation starts once the budget is spent.
over_budget() { # 0 (true) iff a time budget is set and the run has reached it
  [ -n "${MAX_RUN_SECONDS:-}" ] || return 1
  [ "$(( $(date +%s) - ${RUN_START:-0} ))" -ge "$MAX_RUN_SECONDS" ]
}

# -------------------------------------------------- state/remote coherence ----
# ADR 0017. A run whose ledger is not the canonical one harvest reads ($NIGHTSHIFT_HOME/state)
# while pushing to a NETWORK remote silently drops its `shipped` rows: the branch lands on the real
# forge, but the row lands in the isolated ledger harvest never reads, so the branch resurfaces
# later only as an orphan (ADR 0016) — its verdict recoverable only by harvest's adoption sweep
# (ADR 0018). A legitimate isolated e2e run pushes to a LOCAL bare remote (a filesystem path, not a
# host) and never trips this. This is the run-start half of the defense; adoption is the backstop.
is_network_remote() { # url -> 0 iff it targets a remote host (git's own "colon before first slash" rule)
  case "$1" in
    file://*) return 1 ;;   # explicitly local
    *://*)    return 0 ;;   # https:// ssh:// git:// — scheme with host
  esac
  # scp-like: a ':' before the first '/' means host:path (SSH), including ssh-config aliases with
  # no user@ (e.g. `github.com-me:org/repo`). A ':' only AFTER a slash is part of a local path.
  case "$1" in
    */*) case "${1%%/*}" in *:*) return 0 ;; *) return 1 ;; esac ;;
    *:*) return 0 ;;        # no slash at all but has ':' → host:repo
    *)   return 1 ;;        # bare filesystem path (e.g. the sandbox bare remote)
  esac
}
guard_state_remote_incoherence() { # hard-stop (override NIGHTSHIFT_ALLOW_SPLIT_STATE=1); ADR 0017
  [ -n "${NIGHTSHIFT_STATE_DIR:-}" ] || return 0        # ledger not redirected — nothing to check
  local canon_r state_r
  canon_r="$(realpath -m "$NIGHTSHIFT_HOME/state" 2>/dev/null || echo "$NIGHTSHIFT_HOME/state")"
  state_r="$(realpath -m "$STATE_DIR"             2>/dev/null || echo "$STATE_DIR")"
  [ "$state_r" = "$canon_r" ] && return 0               # IS the canonical ledger harvest reads — coherent
  local i path url hits=""
  for i in "${!REPO_PATHS[@]}"; do
    path="${REPO_PATHS[$i]}"
    url="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
    [ -n "$url" ] && is_network_remote "$url" && hits+=" $(basename "$path")"
  done
  [ -n "$hits" ] || return 0                            # no network remote among targets — no exposure
  local msg="ledger ($state_r) is not the canonical one harvest reads ($canon_r) while origin is a network remote for:${hits}. Shipped rows would land in this isolated ledger — pushed branches would surface later only as orphans (adopt via harvest)."
  if [ "${NIGHTSHIFT_ALLOW_SPLIT_STATE:-}" = 1 ]; then
    log "WARNING (NIGHTSHIFT_ALLOW_SPLIT_STATE=1): $msg"
    return 0
  fi
  log "ABORT: $msg Re-run with NIGHTSHIFT_ALLOW_SPLIT_STATE=1 to proceed anyway, or use the canonical state dir / a local sandbox remote."
  exit 1
}

# --------------------------------------------------------------------- main ----
main() {
  load_rulebook
  guard_state_remote_incoherence
  write_claude_settings
  write_codemap_mcp
  # Resolve the night's wall-clock budget: env (seconds, also the test hook) wins, else the rulebook's
  # max_run_minutes, else none. Empty ⇒ no time cap (unchanged behavior).
  RUN_START=$(date +%s)
  MAX_RUN_SECONDS="${NIGHTSHIFT_MAX_RUN_SECONDS:-}"
  if [ -z "$MAX_RUN_SECONDS" ] && [ -n "${RB_MAX_RUN_MINUTES:-}" ]; then
    MAX_RUN_SECONDS=$(( RB_MAX_RUN_MINUTES * 60 ))
  fi
  # Harvest first: reconcile prior shipped branches against git reality (merged/
  # dropped) so the morning digest scoreboard is current. Non-fatal — a harvest
  # hiccup must never block the night's work.
  if [ -x "$NIGHTSHIFT_HOME/bin/harvest.sh" ]; then
    # Pass THIS run's state/ledger/rulebook through explicitly: they are resolved here (LEDGER and
    # RULEBOOK independently of STATE_DIR) and never exported, so without this bridge an isolated
    # run (e.g. an e2e test) would silently reconcile a different ledger than the one it writes.
    # harvest.sh reads NIGHTSHIFT_STATE_DIR on its own too; the explicit STATE_DIR below still wins.
    STATE_DIR="$STATE_DIR" LEDGER="$LEDGER" RULEBOOK="$RULEBOOK" \
      "$NIGHTSHIFT_HOME/bin/harvest.sh" >/dev/null 2>&1 || log "harvest: skipped (non-fatal)"
  fi
  # Then close the loop harvest cannot reach: open findings (no branch, no sha). Runs before the
  # night's work so a finding cleared here also drops out of tonight's known_work injection.
  verify_findings
  log "agent=$NIGHTSHIFT_AGENT prefix=$BRANCH_PREFIX · cap: max $MAX_OPEN undecided ${BRANCH_PREFIX} branches · run ceiling $MAX_RUN_BRANCHES · fix iters $MAX_FIX_ITER"
  case "$NIGHTSHIFT_AGENT" in
    claude) log_model_selection claude NIGHTSHIFT_CLAUDE_MODEL "$RB_CLAUDE_MODEL" ;;
    codex)  log_model_selection codex  NIGHTSHIFT_CODEX_MODEL  "$RB_CODEX_MODEL"  ;;
  esac

  local made=0 considered=0 findings=0 repo mode cfgbase id fp fnj iter verdict wt base b summary open="" pass=0 progress ship_progress stop_reason=ok disp rfind farr n_find k fd dim explore_rc n_partial
  # verify_findings above is the night's first agent call of all. If the credentials are already
  # dead there, every later stage is too — skip straight to the digest so the abort is on record.
  if [ -n "$AGENT_FATAL" ]; then stop_reason=agent_unavailable; fi
  # No per-night production cap. The ONLY cap is the count of nightshift/* branches still AWAITING
  # a verdict — not merely unmerged: a branch the ledger records as merged/dropped/resolved/wontfix
  # is decided and frees its slot even if its ref survives on origin (see refresh_settled_branches).
  # Work continues while fewer than max_open_branches are undecided; merging/closing frees slots and
  # work resumes; when merging stops it fills to the cap and stops. "All night" continuous operation
  # is bounded by this cap, by running out of new work, and by the subscription 5h window.
  while true; do
    [ "$made" -ge "$MAX_RUN_BRANCHES" ] && { log "safety ceiling ($MAX_RUN_BRANCHES) reached — stop"; break; }
    if over_budget; then log "time budget (${MAX_RUN_SECONDS}s) exhausted — stop"; stop_reason=budget; break; fi
    # The single gate every pass goes through — it catches a credential failure raised by
    # verify_findings before the loop as well as one raised by any stage inside a previous pass.
    if [ -n "$AGENT_FATAL" ]; then stop_reason=agent_unavailable; break; fi
    # Reconcile once at the pass boundary. All inner cap checks reuse this total; successful pushes
    # increment it below, eliminating a fleet-wide network fetch for every repo and finding.
    refresh_open_branch_refs
    refresh_settled_branches
    open=$(open_branch_count)
    if [ "$open" -ge "$MAX_OPEN" ]; then
      log "open-branch cap reached ($open/$MAX_OPEN) — stop; merge/close some to free slots"
      stop_reason=backpressure; break
    fi
    pass=$((pass + 1))
    # `progress` = anything happened this pass (incl. surfaced findings); `ship_progress` = a branch
    # was shipped. Only shipping keeps the multi-pass loop alive: shipped work is bounded by the
    # branch caps, whereas a nondeterministic Findings-only repo could surface new findings forever.
    progress=0; ship_progress=0
  while IFS=$'\t' read -r repo mode cfgbase; do
    [ -n "$repo" ] || continue
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
    # Recon (cached): survey the repo and label each dimension's expected yield. Then pick the review
    # lens for this repo/pass: the highest weighted staleness across the rulebook's candidate set
    # (ADR 0010 + 0015) — recon steers the order, it never drops a lens. The lens and the recon
    # orientation notes are injected into explore; the lens is stamped onto every finding.
    ensure_recon "$repo"
    # Recon is the night's first agent call per repo, so it is usually where a credential failure
    # surfaces. Stop here rather than spending an Explore that will die the same way.
    if [ -n "$AGENT_FATAL" ]; then
      remove_worktree "$repo" "$wt"
      stop_reason=agent_unavailable; break
    fi
    dim=$(select_dimension "$repo")
    export NIGHTSHIFT_DIMENSION="$dim"
    NIGHTSHIFT_RECON_NOTES="$(jq -r '.notes // ""' "$(recon_cache_path "$repo")" 2>/dev/null || true)"
    export NIGHTSHIFT_RECON_NOTES
    # Known work (ADR 0014): the repo's still-open findings/branches, injected so Explore does not
    # spend its findings budget re-reporting an item the Runner would only suppress.
    NIGHTSHIFT_KNOWN_WORK="$(known_work "$repo")"; export NIGHTSHIFT_KNOWN_WORK
    log "  $(basename "$repo") [$mode]: lens=${dim:-none} · budget=$rfind"
    explore_rc=0
    run_agent explore "$wt" "$id" || explore_rc=$?
    # Bail out BEFORE anything derived from this stage is recorded. A dead agent must not advance the
    # dimension rotation, must not count as `considered`, and above all must not append the `empty`
    # ledger row below — that row is the fleet's memory of "this lens was clean on this night".
    if [ -n "$AGENT_FATAL" ]; then
      remove_worktree "$repo" "$wt"
      stop_reason=agent_unavailable; break
    fi
    # An Explore that could not run to COMPLETION is not evidence about this repo either, and the
    # same three artifacts are at stake: the `empty` ledger row (which ADR 0023 lets the fleet trust
    # as "this lens was clean here"), the scan marker that rotates the lens onward, and the
    # `considered` count. A credential failure is only the loudest way to lose a stage; the turn
    # ceiling is the quiet one. Observed 2026-08-12: five of 26 items ended in the claude CLI's
    # `error_max_turns` after ~$2 of tokens each, and every one was logged as "nothing worth doing"
    # and stamped as serviced — so the coverage matrix reported those lenses as freshly reviewed.
    #
    # Findings that DID land are kept: a stage can hit the ceiling after writing a usable verdict,
    # and throwing that away would be a second, self-inflicted loss.
    if [ "$explore_rc" -ne 0 ]; then
      n_partial=$(jq -c 'if (.findings|type)=="array" then (.findings|length)
                         elif (.found==true) then 1 else 0 end' "$id/finding.json" 2>/dev/null || echo 0)
      case "$n_partial" in ''|*[!0-9]*) n_partial=0 ;; esac
      if [ "$n_partial" -eq 0 ]; then
        remove_worktree "$repo" "$wt"
        log "  $(basename "$repo") [$mode]: explore did not complete (exit $explore_rc) — no verdict recorded for lens=${dim:-none}, rotation not advanced"
        continue
      fi
      log "  $(basename "$repo"): explore exited $explore_rc but left $n_partial finding(s) — continuing with those"
    fi
    considered=$((considered + 1))
    # Mark this (repo,dim) as serviced NOW — regardless of what Explore found — so the rotation
    # advances to the next lens next run even when this pass surfaced nothing (ADR 0010).
    [ -n "$dim" ] && touch "$(dim_scan_marker "$repo" "$dim")" 2>/dev/null || true
    # Explore emits the v2 container {found, findings:[…]} or (back-compat) a single finding object
    # {found:true,file,…}. Normalise to a findings array, cap it at the repo's N, then remove the
    # explore worktree — explore is read-only; every fix gets its OWN fresh worktree so diffs never
    # compound and each finding lands as one independently-reviewable, independently-rejectable branch.
    farr=$(jq -c 'if (.findings|type)=="array" then .findings elif (.found==true) then [.] else [] end' "$id/finding.json" 2>/dev/null || echo '[]')
    remove_worktree "$repo" "$wt"
    n_find=$(printf '%s' "$farr" | jq 'length' 2>/dev/null || echo 0)
    [ "$n_find" -gt "$rfind" ] && n_find="$rfind"
    if [ "$n_find" -le 0 ]; then
      # ADR 0015: an empty pass logs a {dimension, scope} ledger row (the scan marker already advanced
      # rotation above). scope = the model's first-class "nothing here" verdict: `out_of_scope` (this
      # lens has no surface in this repo — the confabulation-guard's honest return) vs the conservative
      # default `in_scope_no_findings` (lens applies, just clean this pass). Only out_of_scope, repeated,
      # feeds the digest's rulebook-exclusion suggestion, so we never up-rate an unstated verdict.
      scope=$(jq -r '.scope // "in_scope_no_findings"' "$id/finding.json" 2>/dev/null || echo in_scope_no_findings)
      case "$scope" in out_of_scope|in_scope_no_findings) ;; *) scope=in_scope_no_findings ;; esac
      [ -n "$dim" ] && ledger_append "$(basename "$id")" "$repo" "" "" "" "empty" "" "" "" "" "$dim" "" "" "$scope"
      log "  $(basename "$repo") [$mode]: nothing worth doing (scope=$scope)"; continue
    fi

    for (( k=0; k<n_find; k++ )); do
      if [ "$open" -ge "$MAX_OPEN" ]; then
        log "  open-branch cap reached ($open/$MAX_OPEN) — stop"; stop_reason=backpressure; break
      fi
      # Per-finding dir as a SIBLING of the item dir ("item-<nanos>-f<k>"), not a child ("f<k>").
      # The ledger/telemetry `item` field is basename "$fd"; a bare "f0"/"f1" collided across items
      # and runs, making harvest `verdict <item>` and runs->ledger joins ambiguous. The sibling name
      # is globally unique, so every downstream join keys cleanly.
      fd="$id-f$k"; mkdir -p "$fd"
      printf '%s' "$farr" | jq -c ".[$k]" > "$fd/finding.json"
      fp=$(finding_fingerprint "$fd/finding.json")
      if [ -z "$fp" ]; then
        log "  $(basename "$repo") [$mode]: finding without a usable fingerprint — skip"; continue
      fi
      # Content signature of the finding's target (ADR 0014): lets a suppressed identity become
      # eligible again once the underlying code changes. Persist the resolved fingerprint, the
      # selected dimension, AND the code signature so finalize/ledger/dedup all read one identity.
      csig=$(code_sig "$repo" "$fd/finding.json")
      fnj=$(jq --arg fp "$fp" --arg d "$dim" --arg cs "$csig" \
              '.fingerprint=$fp | .dimension=$d | .code_sig=$cs' "$fd/finding.json") \
        && printf '%s' "$fnj" > "$fd/finding.json"
      summary=$(jq -r '.summary // ""' "$fd/finding.json")

      if [ "$mode" = findings-only ]; then
        if already_done "$repo" "$fp" "$csig"; then
          log "  $(basename "$repo") [findings-only]: already reported ($fp) — skip"; continue
        fi
        ledger_append "$(basename "$fd")" "$repo" "$fp" "" "" "finding" "$summary" "" "" "" "$dim" "" "$csig"
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
      if already_surfaced "$repo" "$fp" "$csig"; then
        log "  $(basename "$repo"): previously surfaced — human-owned, not touching ($fp)"; continue
      fi
      if [ "$disp" = surface ]; then
        ledger_append "$(basename "$fd")" "$repo" "$fp" "" "" "finding" "$summary" "" "" "" "$dim" "" "$csig"
        findings=$((findings + 1)); progress=1
        log "  $(basename "$repo") [branch-fix]: surfaced, not auto-fixed: $summary"
        continue
      fi
      if already_acted "$repo" "$fp" "$csig"; then
        log "  $(basename "$repo"): already handled ($fp) — skip"; continue
      fi
      # Spend budget: stop BEFORE starting a new fix (the only mutation). Findings already surfaced
      # this pass stay recorded; we simply do not open another branch once the budget is spent.
      if over_budget; then log "  time budget exhausted — stop before fix"; stop_reason=budget; break; fi

      # One finding = one branch = one fresh worktree from base (diffs stay independent).
      wt="$WORKTREES_DIR/$(basename "$id")-f$k"
      if ! setup_worktree "$repo" "$wt" "$base"; then
        log "  $(basename "$repo"): could not create worktree for finding — skip"; continue
      fi
      iter=0; verdict="revise"; gate=""
      while [ "$iter" -lt "$MAX_FIX_ITER" ]; do
        iter=$((iter + 1))
        # Cleared per ITERATION, not per finding: only the attempt the loop ends on may classify the
        # item below. A `fail` carried over from an earlier iteration would outrank a later `abandon`
        # — which breaks out before the gate is ever consulted — and label it `tests-failed`. That is
        # a different outcome on purpose (ADR 0022 §3), and unlike `abandoned` it does not latch the
        # finding, so the reviewer's refusal would come back for a fresh attempt every night.
        gate=""
        run_agent fix "$wt" "$fd" || true
        run_agent review "$wt" "$fd" || true
        verdict=$(jq -r '.verdict' "$fd/review.md" 2>/dev/null || echo abandon)
        [ "$verdict" = abandon ] && break
        if [ "$verdict" = ship ]; then
          # The reviewer is satisfied that the FINDING is fixed. The gate asks the other question —
          # is the repo still whole? — and it OVERRULES a ship (ADR 0022). A failure is not the end
          # of the item: the Fix stage broke it, is still in the loop, and gets the failing output
          # back on the next turn. Only running out of iterations refuses the item.
          if run_test_gate "$repo" "$wt" "$fd"; then gate=pass; break; fi
          gate=fail; verdict=revise
          log "  $(basename "$repo"): gate overrules ship — fix attempt $iter/$MAX_FIX_ITER broke the suite"
        fi
      done
      b=""
      if [ "$verdict" = ship ]; then
        if b=$(finalize "$repo" "$wt" "$fd" "$made" "$base"); then
          made=$((made + 1)); open=$((open + 1)); progress=1; ship_progress=1
          log "  $(basename "$repo"): shipped -> $b"
        fi
      elif [ "$gate" = fail ]; then
        # Distinct from `abandoned`: the reviewer WANTED to ship and the suite said no, every time.
        # Recorded as a fact about this attempt, not a verdict on the defect — the finding stays
        # unlatched so a later night may try again.
        ledger_append "$(basename "$fd")" "$repo" "$fp" "" "" "tests-failed" "$summary" "" "" "" "$dim" "" "$csig"
        log "  $(basename "$repo"): test gate refused every ship attempt in $MAX_FIX_ITER iterations — not shipped ($fp)"
      else
        ledger_append "$(basename "$fd")" "$repo" "$fp" "" "" "abandoned" "$summary" "" "" "" "$dim" "" "$csig"
        log "  $(basename "$repo"): abandoned ($fp)"
      fi
      remove_worktree "$repo" "$wt"
      [ -n "$b" ] && git -C "$repo" branch -q -D "$b" >/dev/null 2>&1 || true
    done
    case "$stop_reason" in backpressure|budget|agent_unavailable) break ;; esac
  done < <(select_order)
    case "$stop_reason" in budget|agent_unavailable) break ;; esac
    # Gate on SHIPPABLE progress. Findings surface once (they dedup/latch), so a pass that only
    # surfaced findings must not spin the loop — else a nondeterministic Findings-only fleet never
    # halts. Always emit an explicit stop reason.
    if [ "$ship_progress" -eq 0 ]; then
      if [ "$progress" -ne 0 ]; then
        log "pass $pass: only surfaced findings, no shippable work — stop (findings don't keep the loop alive)"
      else
        log "pass $pass: no new work — stop"
      fi
      break
    fi
  done

  # A zero-length run (for example an already-exhausted time budget) has not reached a pass boundary.
  if [ -z "$open" ]; then refresh_open_branch_refs; refresh_settled_branches; open=$(open_branch_count); fi
  local advice; advice="$(advise_branches)"
  write_digest "$made" "$open" "$stop_reason" "$advice"
  # An aborted night exits NON-ZERO. `nightshift-cron.sh` records the rc in the day's log and the
  # systemd unit surfaces it as a failed service — the two places an operator finds out something
  # broke without reading a digest. The old unconditional rc=0 meant a credential outage looked, to
  # every layer above, exactly like a night that simply found nothing.
  if [ -n "$AGENT_FATAL" ]; then
    log "night ABORTED: $AGENT_FATAL — $considered repos considered, nothing recorded."
    return 3
  fi
  log "night done: $made shipped this run, $considered considered, $open now open (cap $MAX_OPEN)."
}

# Sourced (NIGHTSHIFT_SOURCED=1) by unit tests to exercise pure functions without running the night.
[ -n "${NIGHTSHIFT_SOURCED:-}" ] || main "$@"
