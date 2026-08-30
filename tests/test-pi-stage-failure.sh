#!/usr/bin/env bash
# pi's failure semantics (ADR 0031 / ADR 0023): the CLI exits 0 even when the provider rejected the
# request, so the adapter must read the stream's own verdict — and it must read ONLY that, never the
# repo prose the same stream carries.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/item"
# A real worktree: the Review prompt stages it and shows the staged diff, so a non-repo would make
# the stage noisy for a reason that has nothing to do with what this test asserts.
git init -q -b main "$TMP/repo"
printf 'demo\n' > "$TMP/repo/README.md"

# --- 1. A provider rejection arrives as rc=0 plus stopReason "error" (verified against a real 403,
#        2026-08-30). Absorbed as success it would forge "the reviewer found nothing".
cat > "$TMP/bin/pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[],"model":"z-ai/glm-5.3-flash","usage":{"input":0,"output":0},"stopReason":"error","errorMessage":"403: token is bound to a different device"}}'
exit 0
EOF
chmod +x "$TMP/bin/pi"

export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_AGENT=pi
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
export NIGHTSHIFT_PI_STAGE_HOME="$TMP/state/pi-home"
PATH="$TMP/bin:$PATH"
# shellcheck disable=SC1090
source "$ROOT/bin/nightshift.sh"

printf '{}' > "$TMP/item/finding.json"
rc=0; pi_run review "$TMP/repo" "$TMP/item" || rc=$?
[ "$rc" -ne 0 ] || { echo "a rejected request was reported as a successful stage" >&2; exit 1; }
grep -q '403' "$TMP/item/review.err" || { echo "the provider's reason was not recorded" >&2; exit 1; }

# --- 1b. pi retries a turn on its own (`willRetry` in its stream), so an error event followed by a
#         completed answer is a hiccup, not a failed stage. Failing it anyway would turn a transient
#         provider rejection into a lost review on the gate that decides shipping.
cat > "$TMP/bin/pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"502 upstream hiccup"}}'
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"{\"verdict\":\"ship\",\"proof\":\"verified\",\"evidence\":\"e\",\"reason\":\"r\"}"}],"model":"m","usage":{"input":1,"output":1},"stopReason":"stop"}}'
exit 0
EOF
chmod +x "$TMP/bin/pi"
rm -f "$TMP/item/review.err"
rc=0; pi_run review "$TMP/repo" "$TMP/item" || rc=$?
[ "$rc" -eq 0 ] || { echo "a retried turn with a usable answer was failed (rc=$rc)" >&2; exit 1; }
review_artifact_usable "$TMP/item" || { echo "the recovered verdict was lost" >&2; exit 1; }
# The hiccup is still recorded — a stage that needed a retry is worth seeing in the morning.
grep -q '502' "$TMP/item/review.err" || { echo "the retried error was not recorded" >&2; exit 1; }

# --- 1c. The read-only tool profile IS pi's whole confinement (it has no hook and no sandbox), so
#         the override may narrow it, never widen it past read-only.
rm -f "$TMP/item/review.err"
rc=0; NIGHTSHIFT_PI_READONLY_TOOLS="read,grep,bash" pi_run review "$TMP/repo" "$TMP/item" || rc=$?
[ "$rc" = 2 ] || { echo "a stage granted bash was not refused (rc=$rc)" >&2; exit 1; }
rc=0; NIGHTSHIFT_PI_READONLY_TOOLS="read,write" pi_run review "$TMP/repo" "$TMP/item" || rc=$?
[ "$rc" = 2 ] || { echo "a stage granted write was not refused (rc=$rc)" >&2; exit 1; }
# Narrowing stays allowed.
rc=0; NIGHTSHIFT_PI_READONLY_TOOLS="read" pi_run review "$TMP/repo" "$TMP/item" || rc=$?
[ "$rc" = 0 ] || { echo "a narrowed read-only profile was refused (rc=$rc)" >&2; exit 1; }

# --- 1d. An explicitly EMPTY NIGHTSHIFT_REVIEW_AGENT means "no routing tonight", the same as an
#         omitted key — not an unknown adapter that aborts the night before it starts.
[ "$(NIGHTSHIFT_REVIEW_AGENT="" NIGHTSHIFT_AGENT=claude RB_REVIEW_AGENT=pi review_stage_agent)" = claude ] \
  || { echo "an empty review-agent override did not fall back to the night's adapter" >&2; exit 1; }
[ "$(NIGHTSHIFT_REVIEW_AGENT=codex NIGHTSHIFT_AGENT=claude RB_REVIEW_AGENT=pi review_stage_agent)" = codex ] \
  || { echo "the env override lost to the rulebook" >&2; exit 1; }

# --- 2. The diagnosis filter. pi's stream carries the prompt and every tool result verbatim, i.e.
#        the REPO's words — the exact shape that aborted a healthy night on 2026-08-24 when
#        credential prose in a reviewed file was read as the account being logged out.
cat > "$TMP/raw-repo-prose.jsonl" <<'EOF'
{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"Review this: the docs say run codex login when you are not logged in."}]}}
{"type":"message_end","message":{"role":"toolResult","toolName":"read","content":[{"type":"text","text":"if unauthorized: print 'invalid api key'"}]}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"{\"verdict\":\"ship\"}"}],"stopReason":"stop"}}
EOF
out="$(agent_diagnosis "$TMP/raw-repo-prose.jsonl")"
printf '%s' "$out" | grep -qiE "$AGENT_AUTH_RE" \
  && { echo "repo prose in pi's stream was offered as the CLI's own diagnosis" >&2; exit 1; }
agent_credentials_failed /dev/null "$TMP/raw-repo-prose.jsonl" \
  && { echo "a healthy pi stage was classified as a credential failure" >&2; exit 1; }

# A REAL credential failure still has to be recognised — the filter must narrow the input, not
# blind the check.
cat > "$TMP/raw-auth.jsonl" <<'EOF'
{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"Review this repo."}]}}
{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"401 unauthorized"}}
EOF
agent_credentials_failed /dev/null "$TMP/raw-auth.jsonl" \
  || { echo "a real credential failure went unrecognised" >&2; exit 1; }

echo "test-pi-stage-failure: ok"
