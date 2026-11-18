#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# The wall rule (ADR 0023) for a routed reviewer, and its edges. Regression for 2026-10-28: the Codex
# reviewer's weekly window was spent, each Review was logged as a retryable stage failure, and the
# night went on building Fix branches no reviewer could pass. The stream is verbatim from
# runs/2026-10-28 (codex-cli 0.165.0): exit 1, empty stderr, no token counters.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rc=$?; [ "$rc" -eq 0 ] || cat "$TMP/err" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/wd"

export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_AGENT=claude NIGHTSHIFT_REVIEW_AGENT=codex
export NIGHTSHIFT_QUOTA_FALLBACK_AGENT=codex
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
source "$ROOT/bin/nightshift.sh"

CODEX_MODE=wall
codex_calls=0
codex_run() {
  local stage="$1" id="$3"
  codex_calls=$((codex_calls + 1))
  : > "$id/$stage.err"
  case "$CODEX_MODE" in
    wall)
      cat > "$id/.raw_$stage" <<'JSONL'
{"type":"thread.started","thread_id":"01a180e7-d7e9-7640-aec0-170399616b01"}
{"type":"turn.started"}
{"type":"error","message":"You’ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 2nd, 2026 7:14 AM."}
{"type":"turn.failed","error":{"message":"You’ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 2nd, 2026 7:14 AM."}}
JSONL
      printf '%s\n' '{"model_id":null,"output_tokens":null,"input_tokens":null,"cache_read_tokens":null}' \
        > "$id/.usage_$stage"
      return 1 ;;
    billed)   # a real answer that failed to parse: the model was reached
      printf '%s\n' '{"model_id":"gpt-6.1-sol","output_tokens":40,"input_tokens":900,"cache_read_tokens":0}' \
        > "$id/.usage_$stage"
      return 1 ;;
    refused)  # status 2: the adapter refused to run — a configuration verdict, not a wall
      return 2 ;;
    empty-then-slow)  # attempt 1: an empty answer at once; its retry fails slowly without counters
      if [ ! -e "$TMP/retried" ]; then
        : > "$TMP/retried"; : > "$id/$stage.out"
      else
        AGENT_WALL_SECONDS=-1   # stands in for a retry that ran longer than the bound
      fi
      return 1 ;;
  esac
}

item() { mkdir -p "$TMP/$1"; printf '%s' "$TMP/$1"; }
review() { # item -> status of one routed review
  local rc=0
  run_review_stage "$TMP/wd" "$(item "$1")" 2>> "$TMP/err" || rc=$?
  return $rc
}

# 1. One wall is not yet a verdict on the adapter.
review r1 || true
[ -z "$AGENT_FATAL" ] || { echo "one wall was already fatal: $AGENT_FATAL" >&2; exit 1; }
[ "${AGENT_WALL_STREAK[codex]}" -eq 1 ] || { echo "the wall was not counted" >&2; exit 1; }

# 2. A failure that reached the model, and a refusal, are not walls; the reached model restarts the count.
CODEX_MODE=billed;  review r2 || true
[ "${AGENT_WALL_STREAK[codex]}" -eq 0 ] || { echo "a billed failure did not restart the count" >&2; exit 1; }
CODEX_MODE=wall;    review r3 || true
CODEX_MODE=refused; review r4 || true
[ "${AGENT_WALL_STREAK[codex]}" -eq 1 ] && [ -z "$AGENT_FATAL" ] \
  || { echo "a refusal was counted as a wall" >&2; exit 1; }

# 3. The second wall in a row is fatal, names Codex, and leaves the night's adapter alone: the
#    claude -> codex fallback belongs to the night, not to a deliberately routed reviewer.
CODEX_MODE=wall;    review r5 || true
case "$AGENT_FATAL" in
  "codex could not reach its model 2 stages in a row (stage review)") ;;
  *) echo "AGENT_FATAL is not the Codex wall: '$AGENT_FATAL'" >&2; exit 1 ;;
esac
[ "$AGENT_FATAL_AGENT" = codex ] || { echo "fatal agent is '$AGENT_FATAL_AGENT', not codex" >&2; exit 1; }
[ "$NIGHTSHIFT_AGENT" = claude ] || { echo "the night's adapter changed to $NIGHTSHIFT_AGENT" >&2; exit 1; }
[ "$codex_calls" -eq 5 ] || { echo "expected 5 Codex calls, got $codex_calls" >&2; exit 1; }

# 4. The digest names the reviewer that died, not the night's adapter, and its remedy covers a spent
#    quota — the operator must not be sent only to re-authenticate.
MAX_OPEN=3
write_digest 0 0 agent_unavailable 2>> "$TMP/err"
abort_line="$(grep '^- \*\*ABORTED:' "$DIGEST_DIR/$NIGHT.md")" \
  || { echo "digest has no ABORTED line" >&2; cat "$DIGEST_DIR/$NIGHT.md" >&2; exit 1; }
case "$abort_line" in
  *'the `codex` agent could not run'*'is logged in and has quota left'*) ;;
  *) echo "ABORTED line does not name codex and the quota remedy: $abort_line" >&2; exit 1 ;;
esac
case "$abort_line" in
  *claude*) echo "ABORTED line blames claude: $abort_line" >&2; exit 1 ;;
esac

# 5. The time bound: a failure without counters that ran longer did reach something.
printf '%s\n' '{"output_tokens":null,"input_tokens":null}' > "$TMP/no-tokens.json"
agent_hit_a_wall "$TMP/no-tokens.json" "$AGENT_WALL_SECONDS" || { echo "a fast failure was not a wall" >&2; exit 1; }
if agent_hit_a_wall "$TMP/no-tokens.json" $((AGENT_WALL_SECONDS + 1)); then
  echo "a slow failure was counted as a wall" >&2; exit 1
fi

# 6. An empty-answer retry that fails without reaching the model keeps the first attempt's wall, so
#    Recon still records nothing derived from it.
AGENT_FATAL=""; AGENT_FATAL_AGENT=""; AGENT_WALL_STREAK[codex]=0; saved_bound=$AGENT_WALL_SECONDS
CODEX_MODE=empty-then-slow; review r6 || true
AGENT_WALL_SECONDS=$saved_bound
[ -e "$TMP/retried" ] || { echo "the empty answer was not retried" >&2; exit 1; }
[ "$AGENT_LAST_WALLED" = 1 ] || { echo "the failed retry cleared the first attempt's wall" >&2; exit 1; }

# 7. The streak survives sourcing from inside a function (a loader), as a global must.
out=$(NIGHTSHIFT_SOURCED=1 bash -c 'load() { source "$1"; }; load "$1"; declare -p AGENT_WALL_STREAK' _ \
  "$ROOT/bin/nightshift.sh" 2>&1) || true
case "$out" in
  "declare -A AGENT_WALL_STREAK"*) ;;
  *) echo "AGENT_WALL_STREAK is not a global associative array when sourced in a function: $out" >&2; exit 1 ;;
esac

echo "test-agent-wall-reviewer: ok"
