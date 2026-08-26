#!/usr/bin/env bash
set -euo pipefail

# An explicitly configured second adapter takes over after Claude reports a rejected quota event.
# The rejected attempt remains telemetry/evidence, the same stage is retried once, and later stages
# stay on the fallback instead of probing the spent Claude window again.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rc=$?; [ "$rc" -eq 0 ] || cat "$TMP/err" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/wd" "$TMP/item"

export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_AGENT=claude NIGHTSHIFT_QUOTA_FALLBACK_AGENT=codex
export NIGHTSHIFT_CODEX_MODEL=gpt-5.6-sol NIGHTSHIFT_CODEX_REASONING_EFFORT=medium
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
source "$ROOT/bin/nightshift.sh"

claude_calls=0
codex_calls=0

claude_run() {
  local stage="$1" id="$3"
  claude_calls=$((claude_calls + 1))
  : > "$id/$stage.err"
  cat > "$id/.raw_$stage" <<'JSON'
[{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1787293200,"rateLimitType":"five_hour"}}]
JSON
  return 1
}

codex_run() {
  local stage="$1" id="$3"
  codex_calls=$((codex_calls + 1))
  [ "$NIGHTSHIFT_CODEX_MODEL" = gpt-5.6-sol ]
  [ "$NIGHTSHIFT_CODEX_REASONING_EFFORT" = medium ]
  : > "$id/$stage.err"
  printf '%s\n' '{"type":"thread.started","model":"gpt-5.6-sol"}' > "$id/.raw_$stage"
  printf '%s\n' '{"model_id":"gpt-5.6-sol","output_tokens":7,"input_tokens":11,"cache_read_tokens":0}' \
    > "$id/.usage_$stage"
  return 0
}

set +e
run_agent explore "$TMP/wd" "$TMP/item" 2> "$TMP/err"
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "Codex fallback failed with exit $rc" >&2; cat "$TMP/err" >&2; exit 1; }

[ "$claude_calls" -eq 1 ] || { echo "expected one Claude attempt, got $claude_calls" >&2; exit 1; }
[ "$codex_calls" -eq 1 ] || { echo "expected one Codex retry, got $codex_calls" >&2; exit 1; }
[ "$NIGHTSHIFT_AGENT" = codex ] || { echo "night did not stay on Codex fallback" >&2; exit 1; }
[ "$RUN_AGENT_ROUTE" = 'claude -> codex' ] || { echo "agent route not recorded: $RUN_AGENT_ROUTE" >&2; exit 1; }
[ -z "$AGENT_FATAL" ] || { echo "successful fallback still marked the night fatal: $AGENT_FATAL" >&2; exit 1; }
grep -q 'switching the rest of the night to codex' "$TMP/err" \
  || { echo "fallback was not announced" >&2; cat "$TMP/err" >&2; exit 1; }
grep -q 'rate_limit_event' "$TMP/item/.raw_explore.claude-quota" \
  || { echo "rejected Claude evidence was not preserved" >&2; exit 1; }

jq -se 'length==2
        and .[0].model=="claude" and .[0].exit==1
        and .[1].model=="codex" and .[1].exit==0 and .[1].model_id=="gpt-5.6-sol"' \
  "$TMP/state/runs.jsonl" >/dev/null \
  || { echo "fallback telemetry is incomplete" >&2; cat "$TMP/state/runs.jsonl" >&2; exit 1; }

mkdir -p "$TMP/item-2"
run_agent review "$TMP/wd" "$TMP/item-2" 2>> "$TMP/err"
[ "$claude_calls" -eq 1 ] || { echo "later stage probed Claude quota again" >&2; exit 1; }
[ "$codex_calls" -eq 2 ] || { echo "later stage did not stay on Codex" >&2; exit 1; }

echo "test-agent-quota-fallback: ok"
