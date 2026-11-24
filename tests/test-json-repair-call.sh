#!/usr/bin/env bash
set -euo pipefail

# ADR 0046: an answer that arrived and did not parse gets exactly one correction call through the
# same adapter. Only the CLI boundary is faked; claude_run, extraction and telemetry stay real.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
git init -q "$TMP/repo"

# FAKE_ANSWERS holds one answer per call, separated by lines of `---`; FAKE_RC the stage exit code.
cat > "$TMP/bin/claude" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/calls"
cat > "$FAKE_DIR/prompt.$n"
tools="<unset>"
while [ "$#" -gt 0 ]; do
  case "$1" in --tools) tools="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s' "$tools" > "$FAKE_DIR/tools.$n"
answer="$(awk -v n="$n" 'BEGIN { i = 1 } /^---$/ { i++; next } i == n' "$FAKE_DIR/answers")"
jq -nc --arg r "$answer" '{type:"result",subtype:"success",is_error:false,result:$r,
  usage:{output_tokens:40,input_tokens:900},total_cost_usd:0.01}'
[ "$n" -gt 1 ] || exit "${FAKE_RC:-0}"
CLI
chmod +x "$TMP/bin/claude"

export PATH="$TMP/bin:$PATH" NIGHTSHIFT_AGENT=claude
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
mkdir -p "$STATE_DIR"

fail() { echo "test-json-repair-call: $*" >&2; exit 1; }

scenario() { # name answers... -> runs run_agent explore; sets RC
  local name="$1"; shift
  export FAKE_DIR="$TMP/$name"
  mkdir -p "$FAKE_DIR/item"
  printf '%s\n' "$@" > "$FAKE_DIR/answers"
  : > "$RUNSLOG"
  RC=0
  run_agent explore "$TMP/repo" "$FAKE_DIR/item" 2> "$FAKE_DIR/log" || RC=$?
  CALLS=$(cat "$FAKE_DIR/calls")
}

BROKEN='Here is my verdict: {"found":false "findings":[]}'

# 1. The correction parses: the stage succeeds on the corrected artifact.
scenario repaired "$BROKEN" --- '{"found":false,"findings":[]}'
[ "$RC" -eq 0 ] || fail "a parsed correction should succeed, got exit $RC"
[ "$CALLS" -eq 2 ] || fail "expected one correction call, got $CALLS call(s)"
jq -e '.found == false and .findings == []' "$FAKE_DIR/item/finding.json" >/dev/null \
  || fail "the corrected answer did not become finding.json"
grep -Fq "$BROKEN" "$FAKE_DIR/prompt.2" || fail "the correction prompt lacks the faulty answer"
grep -q "Expecting ',' delimiter" "$FAKE_DIR/prompt.2" || fail "the correction prompt lacks the parse error"
! grep -q 'Repo working directory' "$FAKE_DIR/prompt.2" || fail "the correction prompt carries repo context"
[ "$(cat "$FAKE_DIR/tools.2")" = "" ] || fail "the correction call got tools: $(cat "$FAKE_DIR/tools.2")"
[ "$(cat "$FAKE_DIR/tools.1")" = "Read,Grep,Glob" ] || fail "the stage lost its read tools"
grep -Fq "$BROKEN" "$FAKE_DIR/item/explore.out" || fail "the original answer was not kept"
jq -se 'length == 2
        and .[0].stage == "explore" and .[0].exit == 1 and .[0].tokens == 40
        and .[1].stage == "repair-explore" and .[1].exit == 0' "$RUNSLOG" >/dev/null \
  || { cat "$RUNSLOG" >&2; fail "runs.jsonl does not record the stage and its correction"; }

# The digest counts the correction and does not report its stage as lost.
mkdir -p "$DIGEST_DIR"
MAX_OPEN=1   # write_digest reads the rulebook cap
write_digest 0 0 ok 2> "$TMP/digest.err" || { cat "$TMP/digest.err" >&2; fail "write_digest failed"; }
grep -q 'JSON correction calls: 1 of 1 unparsed answers became valid JSON' "$DIGEST_DIR/$NIGHT.md" \
  || { cat "$DIGEST_DIR/$NIGHT.md" >&2; fail "the digest does not count the correction"; }
! grep -q 'did not complete' "$DIGEST_DIR/$NIGHT.md" || fail "the digest reports the corrected stage as lost"

# 2. The correction does not parse either: the stage fails as it did without the call.
scenario still-broken "$BROKEN" --- 'NO_JSON'
[ "$RC" -eq 1 ] || fail "a failed correction should leave exit 1, got $RC"
[ "$CALLS" -eq 2 ] || fail "a failed correction was retried ($CALLS calls)"
! jq -e . "$FAKE_DIR/item/finding.json" >/dev/null 2>&1 || fail "a failed correction left a verdict"
jq -se 'length == 2 and .[0].exit == 1 and .[1].stage == "repair-explore" and .[1].exit == 1' \
  "$RUNSLOG" >/dev/null || { cat "$RUNSLOG" >&2; fail "the failed correction was not recorded"; }
[ "$AGENT_LAST_WALLED" -eq 0 ] || fail "a failed correction marked the stage as walled"

# 3. Valid JSON on the first try makes no extra call.
scenario valid '{"found":false,"findings":[]}'
[ "$RC" -eq 0 ] || fail "a valid answer failed with exit $RC"
[ "$CALLS" -eq 1 ] || fail "a valid answer made $CALLS calls"
jq -se 'length == 1 and .[0].stage == "explore" and .[0].exit == 0' "$RUNSLOG" >/dev/null \
  || fail "a valid answer recorded extra rows"

# 4. An answer above the size limit is not sent.
JSON_REPAIR_MAX_BYTES=10   # NIGHTSHIFT_JSON_REPAIR_MAX_BYTES, read when the Runner is sourced
scenario oversized "$BROKEN" --- '{"found":false,"findings":[]}'
[ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] || fail "an oversized answer was sent (exit $RC, $CALLS calls)"
grep -q 'above the correction limit' "$FAKE_DIR/log" || fail "the refusal was not logged"
JSON_REPAIR_MAX_BYTES=65536

# 5. A CLI that did not complete (turn limit) gets no correction, nor does prose without an object.
FAKE_RC=1 scenario cli-failed "$BROKEN" --- '{"found":false,"findings":[]}'
[ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] || fail "an incomplete CLI run was corrected (exit $RC, $CALLS calls)"
scenario prose 'I found nothing worth reporting.' --- '{"found":false,"findings":[]}'
[ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] || fail "prose without an object was sent (exit $RC, $CALLS calls)"

echo 'test-json-repair-call: ok'
