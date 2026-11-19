#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# The wall rule (ADR 0023) for the review model (ADR 0044), and its edges. A spent window belongs to
# one model, and Fix and Review alternate on the same adapter: counted per adapter, a Fix on a
# working model between two walled reviews restarted the count, and the night went on building Fix
# branches no reviewer could pass — the regression of 2026-10-28, when the reviewer's weekly window
# was spent and every Review was logged as a retryable stage failure. So the streak is counted per
# adapter and model.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rc=$?; [ "$rc" -eq 0 ] || cat "$TMP/err" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/wd"

export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_AGENT=claude
unset NIGHTSHIFT_CLAUDE_MODEL NIGHTSHIFT_REVIEW_MODEL
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
source "$ROOT/bin/nightshift.sh"
RB_CLAUDE_MODEL=work-model RB_REVIEW_MODEL=review-model
WORK=claude:work-model REVIEW=claude:review-model

# The adapter boundary is replaced by a function: the review model is in one of the modes below, the
# work model always answers. Shapes from runs/2026-10-31: a 429 result with zero usage.
REVIEW_MODE=wall
calls=0
claude_run() {
  local stage="$1" id="$3"
  calls=$((calls + 1))
  : > "$id/$stage.err"
  if [ "$(stage_model "$stage")" != review-model ]; then
    printf '%s\n' '{"model_id":"work-model","output_tokens":40,"input_tokens":900}' > "$id/.usage_$stage"
    return 0
  fi
  case "$REVIEW_MODE" in
    wall)
      printf '%s\n' '{"type":"result","is_error":true,"api_error_status":429,"result":"You have hit your weekly limit","usage":{"input_tokens":0,"output_tokens":0}}' \
        > "$id/.raw_$stage"
      printf '%s\n' '{"model_id":null,"output_tokens":0,"input_tokens":0,"cache_read_tokens":0}' > "$id/.usage_$stage"
      return 1 ;;
    billed)   # a real answer that failed to parse: the model was reached
      printf '%s\n' '{"model_id":"review-model","output_tokens":40,"input_tokens":900,"cache_read_tokens":0}' \
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

n=0
item() { n=$((n + 1)); mkdir -p "$TMP/i$n"; printf '%s' "$TMP/i$n"; }
stage() { # stage -> status of one stage
  local rc=0
  run_agent "$1" "$TMP/wd" "$(item)" 2>> "$TMP/err" || rc=$?
  return $rc
}

# 1. One wall is not yet a verdict on the model.
stage review || true
[ -z "$AGENT_FATAL" ] || { echo "one wall was already fatal: $AGENT_FATAL" >&2; exit 1; }
[ "${AGENT_WALL_STREAK[$REVIEW]}" -eq 1 ] || { echo "the wall was not counted" >&2; exit 1; }

# 2. A Fix on the working model between two walled reviews does not restart the review model's count.
stage fix
[ "${AGENT_WALL_STREAK[$REVIEW]}" -eq 1 ] || { echo "a Fix on another model restarted the review model's count" >&2; exit 1; }
[ "${AGENT_WALL_STREAK[$WORK]}" -eq 0 ] || { echo "the working model was counted" >&2; exit 1; }

# 3. A failure that reached the model, and a refusal, are not walls; the reached model restarts the count.
REVIEW_MODE=billed;  stage review || true
[ "${AGENT_WALL_STREAK[$REVIEW]}" -eq 0 ] || { echo "a billed failure did not restart the count" >&2; exit 1; }
REVIEW_MODE=wall;    stage review || true
REVIEW_MODE=refused; stage review || true
[ "${AGENT_WALL_STREAK[$REVIEW]}" -eq 1 ] && [ -z "$AGENT_FATAL" ] \
  || { echo "a refusal was counted as a wall" >&2; exit 1; }

# 4. The second wall in a row on the review model is fatal and names the model, with a Fix between.
stage fix
REVIEW_MODE=wall;    stage review || true
case "$AGENT_FATAL" in
  "claude could not reach its model 2 stages in a row (stage review, model review-model)") ;;
  *) echo "AGENT_FATAL is not the review model's wall: '$AGENT_FATAL'" >&2; exit 1 ;;
esac
[ "$AGENT_FATAL_AGENT" = claude ] || { echo "fatal agent is '$AGENT_FATAL_AGENT', not claude" >&2; exit 1; }
[ "$NIGHTSHIFT_AGENT" = claude ] || { echo "the night's adapter changed to $NIGHTSHIFT_AGENT" >&2; exit 1; }
[ "$calls" -eq 7 ] || { echo "expected 7 adapter calls, got $calls" >&2; exit 1; }
grep -q 'did not reach its model review-model (2 in a row)' "$TMP/err" \
  || { echo "the log does not name the walled model" >&2; exit 1; }

# 5. The digest names the adapter, and its remedy covers a spent quota — the operator must not be
#    sent only to re-authenticate.
MAX_OPEN=3
write_digest 0 0 agent_unavailable 2>> "$TMP/err"
abort_line="$(grep '^- \*\*ABORTED:' "$DIGEST_DIR/$NIGHT.md")" \
  || { echo "digest has no ABORTED line" >&2; cat "$DIGEST_DIR/$NIGHT.md" >&2; exit 1; }
case "$abort_line" in
  *'the `claude` agent could not run'*'model review-model'*'is logged in and has quota left'*) ;;
  *) echo "ABORTED line does not name the model and the quota remedy: $abort_line" >&2; exit 1 ;;
esac

# 6. The time bound: a failure without counters that ran longer did reach something.
printf '%s\n' '{"output_tokens":null,"input_tokens":null}' > "$TMP/no-tokens.json"
agent_hit_a_wall "$TMP/no-tokens.json" "$AGENT_WALL_SECONDS" || { echo "a fast failure was not a wall" >&2; exit 1; }
if agent_hit_a_wall "$TMP/no-tokens.json" $((AGENT_WALL_SECONDS + 1)); then
  echo "a slow failure was counted as a wall" >&2; exit 1
fi

# 7. An empty-answer retry that fails without reaching the model keeps the first attempt's wall, so
#    Recon still records nothing derived from it.
AGENT_FATAL=""; AGENT_FATAL_AGENT=""; AGENT_WALL_STREAK[$REVIEW]=0; saved_bound=$AGENT_WALL_SECONDS
REVIEW_MODE=empty-then-slow; stage review || true
AGENT_WALL_SECONDS=$saved_bound
[ -e "$TMP/retried" ] || { echo "the empty answer was not retried" >&2; exit 1; }
[ "$AGENT_LAST_WALLED" = 1 ] || { echo "the failed retry cleared the first attempt's wall" >&2; exit 1; }

# 8. The streak survives sourcing from inside a function (a loader), as a global must.
out=$(NIGHTSHIFT_SOURCED=1 bash -c 'load() { source "$1"; }; load "$1"; declare -p AGENT_WALL_STREAK' _ \
  "$ROOT/bin/nightshift.sh" 2>&1) || true
case "$out" in
  "declare -A AGENT_WALL_STREAK"*) ;;
  *) echo "AGENT_WALL_STREAK is not a global associative array when sourced in a function: $out" >&2; exit 1 ;;
esac

echo "test-agent-wall-reviewer: ok"
