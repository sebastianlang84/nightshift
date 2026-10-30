#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# A Codex reviewer whose weekly window is spent must abort the night (ADR 0023), like a Claude
# rejection does (test-agent-quota-abort.sh). Regression for 2026-10-28: the routed Review stage
# failed on Codex's usage limit three times, each was logged as a retryable stage failure, and the
# night went on building Fix branches that no reviewer could pass. The stream below is verbatim
# from runs/2026-10-28 (codex-cli 0.165.0); Codex says it in a failed turn, not a rate-limit event.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rc=$?; [ "$rc" -eq 0 ] || cat "$TMP/err" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/wd" "$TMP/item"

export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_AGENT=claude NIGHTSHIFT_REVIEW_AGENT=codex
export NIGHTSHIFT_QUOTA_FALLBACK_AGENT=codex
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
source "$ROOT/bin/nightshift.sh"

codex_calls=0
codex_run() {
  local stage="$1" id="$3"
  codex_calls=$((codex_calls + 1))
  : > "$id/$stage.err"
  cat > "$id/.raw_$stage" <<'JSONL'
{"type":"thread.started","thread_id":"01a180e7-d7e9-7640-aec0-170399616b01"}
{"type":"turn.started"}
{"type":"error","message":"You’ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 2nd, 2026 7:14 AM."}
{"type":"turn.failed","error":{"message":"You’ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 2nd, 2026 7:14 AM."}}
JSONL
  return 1
}

# 1. The routed reviewer's rejection is fatal for the night, names Codex and the reset time, and
#    is not retried (an empty-answer retry would only hit the same wall).
set +e
run_review_stage "$TMP/wd" "$TMP/item" 2> "$TMP/err"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "a quota-rejected review reported success" >&2; exit 1; }
[ "$codex_calls" -eq 1 ] || { echo "expected one Codex call, got $codex_calls" >&2; exit 1; }
case "$AGENT_FATAL" in
  "codex is out of quota until 2026-11-02 07:14"*) ;;
  *) echo "AGENT_FATAL not set to a Codex quota abort: '$AGENT_FATAL'" >&2; exit 1 ;;
esac
[ "$AGENT_FATAL_AGENT" = codex ] || { echo "fatal agent is '$AGENT_FATAL_AGENT', not codex" >&2; exit 1; }
# The reviewer keeps its own quota verdict: the night's claude -> codex fallback is not used.
[ "$NIGHTSHIFT_AGENT" = claude ] || { echo "the night's adapter changed to $NIGHTSHIFT_AGENT" >&2; exit 1; }
grep -q 'FATAL: codex is out of quota' "$TMP/err" || { echo "log does not name the quota abort" >&2; exit 1; }

# The digest names the reviewer that died, not the night's adapter, and gives the reset time as the
# remedy — the operator must not be sent to re-authenticate a healthy Claude CLI.
MAX_OPEN=3
write_digest 0 0 agent_unavailable 2>> "$TMP/err"
abort_line="$(grep '^- \*\*ABORTED:' "$DIGEST_DIR/$NIGHT.md")" \
  || { echo "digest has no ABORTED line" >&2; cat "$DIGEST_DIR/$NIGHT.md" >&2; exit 1; }
case "$abort_line" in
  *'the `codex` agent could not run'*'run the night again after 2026-11-02 07:14'*) ;;
  *) echo "ABORTED line does not name codex and its reset: $abort_line" >&2; exit 1 ;;
esac
case "$abort_line" in
  *claude*|*re-authenticate*) echo "ABORTED line blames claude or prescribes a login: $abort_line" >&2; exit 1 ;;
esac

# 2. Only the CLI's failed turn counts. A failed turn for another reason, or the words in the
#    model's own output, leave the night running.
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"this repo handles a usage limit"}}' \
  '{"type":"turn.failed","error":{"message":"stream disconnected before completion"}}' > "$TMP/other.jsonl"
if codex_quota_rejected "$TMP/other.jsonl" >/dev/null; then
  echo "a non-quota failed turn was read as a usage limit" >&2; exit 1
fi

# 3. The `error` event alone counts too: a stream cut off before `turn.failed` is still a rejection.
printf '%s\n' '{"type":"error","message":"You’ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 2nd, 2026 7:14 AM."}' \
  > "$TMP/error-only.jsonl"
when=$(codex_quota_rejected "$TMP/error-only.jsonl") || { echo "an error-only usage-limit stream was missed" >&2; exit 1; }
case "$when" in "2026-11-02 07:14"*) ;; *) echo "error-only reset reported as '$when'" >&2; exit 1 ;; esac

# 4. A usage-limit message without a parseable time is still a rejection, reported as such.
printf '%s\n' '{"type":"turn.failed","error":{"message":"You have hit your usage limit. Try again later."}}' \
  > "$TMP/later.jsonl"
when=$(codex_quota_rejected "$TMP/later.jsonl") || { echo "a usage limit without a time was missed" >&2; exit 1; }
[ "$when" = "an unknown time" ] || { echo "unparseable reset reported as '$when'" >&2; exit 1; }

echo "test-codex-quota-abort: ok"
