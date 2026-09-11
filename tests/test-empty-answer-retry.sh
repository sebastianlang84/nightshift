#!/usr/bin/env bash
set -euo pipefail

# ADR 0034: a stage whose model returned NOTHING is retried once. An empty answer is not a verdict —
# on 2026-09-11 one such turn made the night's first explore lens unparseable, and the Runner ended a
# night whose findings budget was untouched. What must NOT be retried is equally the point: an answer
# that arrived and did not parse, and an adapter refusing to run at all (status 2).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rc=$?; [ "$rc" -eq 0 ] || cat "$TMP/err" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/wd" "$TMP/item"

export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_AGENT=pi
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
source "$ROOT/bin/nightshift.sh"

calls=0

# The shape observed on 2026-09-11: the provider accepted the turn, billed it, and the stopped
# assistant message carried an empty content array — so the answer file exists and is empty.
pi_run() {
  local stage="$1" id="$3"
  calls=$((calls + 1))
  : > "$id/$stage.err"
  if [ "$calls" -eq 1 ]; then
    printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"stop"}}' \
      > "$id/.raw_$stage"
    printf '%s\n' '{"model_id":"z-ai/glm-5.3-flash","output_tokens":25,"input_tokens":8622}' \
      > "$id/.usage_$stage"
    : > "$id/$stage.out"
    return 1
  fi
  printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"{}"}],"stopReason":"stop"}}' \
    > "$id/.raw_$stage"
  printf '%s\n' '{"model_id":"z-ai/glm-5.3-flash","output_tokens":900,"input_tokens":8622}' \
    > "$id/.usage_$stage"
  printf '{"found":false}\n' > "$id/$stage.out"
  printf '{"found":false}\n' > "$id/finding.json"
  return 0
}

set +e
run_agent explore "$TMP/wd" "$TMP/item" 2> "$TMP/err"
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "retried stage still failed with exit $rc" >&2; cat "$TMP/err" >&2; exit 1; }
[ "$calls" -eq 2 ] || { echo "expected one retry, got $calls attempt(s)" >&2; exit 1; }
[ -z "$AGENT_FATAL" ] || { echo "a recovered empty answer still ended the night: $AGENT_FATAL" >&2; exit 1; }
grep -q 'empty answer' "$TMP/err" || { echo "the retry was not announced" >&2; cat "$TMP/err" >&2; exit 1; }
grep -q '"content":\[\]' "$TMP/item/.raw_explore.empty-answer-1" \
  || { echo "the empty attempt's evidence was not preserved" >&2; exit 1; }

# Both attempts are telemetry: the empty turn cost tokens and the ledger must be able to show it.
jq -se 'length==2
        and .[0].exit==1 and .[0].tokens==25
        and .[1].exit==0 and .[1].tokens==900' "$TMP/state/runs.jsonl" >/dev/null \
  || { echo "both attempts were not recorded" >&2; cat "$TMP/state/runs.jsonl" >&2; exit 1; }

# An answer that ARRIVED and did not parse is the model's verdict on the repo, not a dropped turn.
calls=0
mkdir -p "$TMP/item-2"
pi_run() {
  local stage="$1" id="$3"
  calls=$((calls + 1))
  : > "$id/$stage.err"; : > "$id/.raw_$stage"
  printf 'I could not find anything worth reporting.\n' > "$id/$stage.out"
  return 1
}
set +e
run_agent explore "$TMP/wd" "$TMP/item-2" 2>> "$TMP/err"
rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "an unparseable answer should still fail, got exit $rc" >&2; exit 1; }
[ "$calls" -eq 1 ] || { echo "an unparseable answer was retried ($calls attempts)" >&2; exit 1; }

# Status 2 is an adapter refusing to run — a configuration verdict a second identical call repeats.
calls=0
mkdir -p "$TMP/item-3"
pi_run() {
  local stage="$1" id="$3"
  calls=$((calls + 1))
  printf 'nightshift: the pi %s profile may not grant bash\n' "$stage" > "$id/$stage.err"
  : > "$id/$stage.out"
  return 2
}
set +e
run_agent explore "$TMP/wd" "$TMP/item-3" 2>> "$TMP/err"
rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "an adapter refusal should keep exit 2, got $rc" >&2; exit 1; }
[ "$calls" -eq 1 ] || { echo "an adapter refusal was retried ($calls attempts)" >&2; exit 1; }

# The documented opt-out: no extra attempt at all.
EMPTY_ANSWER_RETRIES=0
calls=0
mkdir -p "$TMP/item-4"
pi_run() {
  local stage="$1" id="$3"
  calls=$((calls + 1))
  : > "$id/$stage.err"; : > "$id/.raw_$stage"; : > "$id/$stage.out"
  return 1
}
set +e
run_agent explore "$TMP/wd" "$TMP/item-4" 2>> "$TMP/err"
rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "with retries off the empty answer should fail, got exit $rc" >&2; exit 1; }
[ "$calls" -eq 1 ] || { echo "NIGHTSHIFT_EMPTY_ANSWER_RETRIES=0 still retried ($calls attempts)" >&2; exit 1; }

echo "test-empty-answer-retry: ok"
