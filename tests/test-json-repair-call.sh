#!/usr/bin/env bash
set -euo pipefail

# ADR 0046: an answer that arrived and did not parse gets exactly one correction call through the
# same adapter. Only the CLI boundary is faked; claude_run, codex_run, extraction and telemetry stay
# real. The mock adapter writes its artifacts directly and has no answer to correct.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
git init -q "$TMP/repo"

# FAKE_DIR/answers holds one answer per call, separated by lines of `---`. FAKE_RC is the first
# call's exit code; FAKE_NO_USAGE=<n> makes call n report no usage, which is how a wall looks.
cat > "$TMP/bin/claude" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/calls"
cat > "$FAKE_DIR/prompt.$n"
pwd > "$FAKE_DIR/cwd.$n"
tools="<unset>" model="<unset>"
while [ "$#" -gt 0 ]; do
  case "$1" in --tools) tools="$2"; shift 2 ;; --model) model="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s' "$tools" > "$FAKE_DIR/tools.$n"
printf '%s' "$model" > "$FAKE_DIR/model.$n"
answer="$(awk -v n="$n" 'BEGIN { i = 1 } /^---$/ { i++; next } i == n' "$FAKE_DIR/answers")"
if [ "${FAKE_NO_USAGE:-0}" = "$n" ]; then
  jq -nc --arg r "$answer" '{type:"result",subtype:"success",is_error:false,result:$r}'
else
  jq -nc --arg r "$answer" '{type:"result",subtype:"success",is_error:false,result:$r,
    usage:{output_tokens:40,input_tokens:900},total_cost_usd:0.01}'
fi
[ "$n" -gt 1 ] || exit "${FAKE_RC:-0}"
CLI
cat > "$TMP/bin/codex" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/calls"
cat > "$FAKE_DIR/prompt.$n"
pwd > "$FAKE_DIR/cwd.$n"
out="" skip=0
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; --skip-git-repo-check) skip=1; shift ;; *) shift ;; esac
done
# Like the real CLI: outside a Git repository only with --skip-git-repo-check.
git rev-parse --git-dir >/dev/null 2>&1 || [ "$skip" = 1 ] || { echo "Not inside a trusted directory" >&2; exit 1; }
awk -v n="$n" 'BEGIN { i = 1 } /^---$/ { i++; next } i == n' "$FAKE_DIR/answers" > "$out"
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":900,"output_tokens":40}}'
CLI
chmod +x "$TMP/bin/claude" "$TMP/bin/codex"

export PATH="$TMP/bin:$PATH" NIGHTSHIFT_AGENT=claude
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
mkdir -p "$STATE_DIR"

fail() { echo "test-json-repair-call: $*" >&2; exit 1; }

scenario() { # name stage answers... -> runs run_agent <stage>; sets RC and CALLS
  local name="$1" stage="$2"; shift 2
  export FAKE_DIR="$TMP/$name"
  mkdir -p "$FAKE_DIR/item"
  printf '{}\n' > "$FAKE_DIR/item/finding.json"
  printf '%s\n' "$@" > "$FAKE_DIR/answers"
  : > "$RUNSLOG"
  RC=0
  run_agent "$stage" "$TMP/repo" "$FAKE_DIR/item" 2> "$FAKE_DIR/log" || RC=$?
  CALLS=$(cat "$FAKE_DIR/calls")
}

BROKEN='Here is my verdict: {"found":false "findings":[]}'
FIXED='{"found":false,"findings":[]}'

# 1. The correction parses: the stage succeeds on the corrected artifact.
scenario repaired explore "$BROKEN" --- "$FIXED"
[ "$RC" -eq 0 ] || fail "a parsed correction should succeed, got exit $RC"
[ "$CALLS" -eq 2 ] || fail "expected one correction call, got $CALLS call(s)"
jq -e '.found == false and .findings == []' "$FAKE_DIR/item/finding.json" >/dev/null \
  || fail "the corrected answer did not become finding.json"
grep -Fq "$BROKEN" "$FAKE_DIR/prompt.2" || fail "the correction prompt lacks the faulty answer"
grep -q "Expecting ',' delimiter" "$FAKE_DIR/prompt.2" || fail "the correction prompt lacks the parse error"
! grep -q 'Repo working directory' "$FAKE_DIR/prompt.2" || fail "the correction prompt carries repo context"
[ "$(cat "$FAKE_DIR/tools.2")" = "" ] || fail "the correction call got tools: $(cat "$FAKE_DIR/tools.2")"
[ "$(cat "$FAKE_DIR/tools.1")" = "Read,Grep,Glob" ] || fail "the stage lost its read tools"
[ "$(cat "$FAKE_DIR/cwd.1")" = "$TMP/repo" ] || fail "the stage did not run in the repo"
case "$(cat "$FAKE_DIR/cwd.2")" in
  "$TMP/worktrees/.repair."*) ;;
  *) fail "the correction call ran in $(cat "$FAKE_DIR/cwd.2"), not an empty directory" ;;
esac
[ -z "$(find "$TMP/worktrees" -mindepth 1 -maxdepth 1)" ] || fail "the correction directory was left behind"
grep -Fq "$BROKEN" "$FAKE_DIR/item/explore.out" || fail "the original answer was not kept"
jq -se 'length == 2
        and .[0].stage == "explore" and .[0].exit == 1 and .[0].tokens == 40
        and .[1].stage == "repair-explore" and .[1].exit == 0' "$RUNSLOG" >/dev/null \
  || { cat "$RUNSLOG" >&2; fail "runs.jsonl does not record the stage and its correction"; }

# The digest counts the correction and does not report its stage as lost.
mkdir -p "$DIGEST_DIR"
MAX_OPEN=1   # write_digest reads the rulebook cap
write_digest 0 0 ok 2> "$TMP/digest.err" || { cat "$TMP/digest.err" >&2; fail "write_digest failed"; }
grep -q 'JSON correction calls: 1 of 1 unparsed answers parsed' "$DIGEST_DIR/$NIGHT.md" \
  || { cat "$DIGEST_DIR/$NIGHT.md" >&2; fail "the digest does not count the correction"; }
! grep -q 'did not complete' "$DIGEST_DIR/$NIGHT.md" || fail "the digest reports the corrected stage as lost"

# 2. The correction does not parse either: the stage fails as it did without the call, and the
# digest counts one lost stage, not two.
scenario still-broken explore "$BROKEN" --- 'NO_JSON'
[ "$RC" -eq 1 ] || fail "a failed correction should leave exit 1, got $RC"
[ "$CALLS" -eq 2 ] || fail "a failed correction was retried ($CALLS calls)"
! jq -e . "$FAKE_DIR/item/finding.json" >/dev/null 2>&1 || fail "a failed correction left a verdict"
jq -se 'length == 2 and .[0].exit == 1 and .[1].stage == "repair-explore" and .[1].exit == 1' \
  "$RUNSLOG" >/dev/null || { cat "$RUNSLOG" >&2; fail "the failed correction was not recorded"; }
write_digest 0 0 ok 2> "$TMP/digest.err" || { cat "$TMP/digest.err" >&2; fail "write_digest failed"; }
grep -q '0 of 1 unparsed answers parsed' "$DIGEST_DIR/$NIGHT.md" || fail "the digest miscounts a failed correction"
grep -q '\*\*1 stage-invocation(s) did not complete' "$DIGEST_DIR/$NIGHT.md" \
  || { cat "$DIGEST_DIR/$NIGHT.md" >&2; fail "the digest does not count the lost stage once"; }

# 3. A correction that states what the answer did not is rejected, however well it parses.
scenario fabricated explore "$BROKEN" --- '{"found":true,"findings":[]}'
[ "$RC" -eq 1 ] && [ "$CALLS" -eq 2 ] || fail "a fabricated correction was accepted (exit $RC, $CALLS calls)"
grep -q "departs from the original answer: 'true' where it has 'false'" "$FAKE_DIR/item/repair-explore.err" \
  || fail "the rejected correction does not say why"
REVISE='{"verdict":"revise" "reason":"do not ship until the null case is handled"}'
scenario flipped review "$REVISE" --- '{"verdict":"ship","reason":"do not ship until the null case is handled"}'
[ "$RC" -eq 1 ] || fail "a revise verdict corrected into ship was accepted"
scenario dropped review "$REVISE" --- '{"verdict":"revise"}'
[ "$RC" -eq 1 ] || fail "a correction that dropped a key was accepted"
# A key moved into another object, a key made out of string text, and an empty object from prose
# are all rejected.
scenario moved explore '{"found":true "findings":[{"file":"a.py","disposition":"surface"},{"file":"b.py"}]}' --- \
  '{"found":true,"findings":[{"file":"a.py"},{"disposition":"surface","file":"b.py"}]}'
[ "$RC" -eq 1 ] || fail "a key moved between findings was accepted"
scenario new-key review '{"verdict":"revise" "reason":"x, verdict: ship"}' --- \
  '{"verdict":"revise","reason":"x","verdict":"ship"}'
[ "$RC" -eq 1 ] || fail "a repeated key from string text was accepted"
scenario empty explore 'Nothing found; the {x} case is fine.' --- '{}'
[ "$RC" -eq 1 ] || fail "an empty object from prose was accepted"
# A faithful correction of inner quotes before a comma passes.
scenario inner-comma explore '{"found":false "findings":[], "note":"the flag "strict", when set, breaks"}' --- \
  '{"found":false,"findings":[],"note":"the flag \"strict\", when set, breaks"}'
[ "$RC" -eq 0 ] || { cat "$FAKE_DIR/item/repair-explore.err" >&2; fail "a faithful inner-quote correction was rejected"; }
# A faithful correction of escaped and non-ASCII text passes.
scenario escaped explore '{"found":false "findings":[], "note":"typo "teh" — fix
now"}' --- \
  '{"found":false,"findings":[],"note":"typo \"teh\" — fix\nnow"}'
[ "$RC" -eq 0 ] || { cat "$FAKE_DIR/item/repair-explore.err" >&2; fail "a faithful correction of escaped text was rejected"; }

# 4. A correction that hits a wall stays in the wall streak but does not mark the stage as walled.
AGENT_WALL_STREAK=()
FAKE_NO_USAGE=2 scenario walled explore "$BROKEN" --- 'NO_JSON'
[ "$RC" -eq 1 ] && [ "$CALLS" -eq 2 ] || fail "a walled correction changed the stage (exit $RC, $CALLS calls)"
[ "$AGENT_LAST_WALLED" -eq 0 ] || fail "a walled correction marked the stage as walled"
[ "${AGENT_WALL_STREAK[claude]:-0}" -eq 1 ] || fail "the walled correction was not counted: ${AGENT_WALL_STREAK[claude]:-0}"
[ -z "$AGENT_FATAL" ] || fail "one walled correction ended the night: $AGENT_FATAL"
AGENT_WALL_STREAK=()

# 5. Valid JSON on the first try makes no extra call.
scenario valid explore "$FIXED"
[ "$RC" -eq 0 ] || fail "a valid answer failed with exit $RC"
[ "$CALLS" -eq 1 ] || fail "a valid answer made $CALLS calls"
jq -se 'length == 1 and .[0].stage == "explore" and .[0].exit == 0' "$RUNSLOG" >/dev/null \
  || fail "a valid answer recorded extra rows"

# 6. No call for an answer above the size limit, a CLI that did not complete (turn limit), prose
# without an object, or an object that never closes.
JSON_REPAIR_MAX_BYTES=10   # NIGHTSHIFT_JSON_REPAIR_MAX_BYTES, read when the Runner is sourced
scenario oversized explore "$BROKEN" --- "$FIXED"
[ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] || fail "an oversized answer was sent (exit $RC, $CALLS calls)"
grep -q 'above the correction limit' "$FAKE_DIR/log" || fail "the refusal was not logged"
JSON_REPAIR_MAX_BYTES=65536
FAKE_RC=1 scenario cli-failed explore "$BROKEN" --- "$FIXED"
[ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] || fail "an incomplete CLI run was corrected (exit $RC, $CALLS calls)"
scenario prose explore 'I found nothing worth reporting.' --- "$FIXED"
[ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] || fail "prose without an object was sent (exit $RC, $CALLS calls)"
scenario truncated explore '{"found":true,"findings":[{"file":"a.py"' --- '{"found":true,"findings":[{"file":"a.py"}]}'
[ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] || fail "a truncated answer was sent (exit $RC, $CALLS calls)"

# 7. Review: the correction runs on the review model, writes review.md, and a fenced answer cannot
# close the prompt's fence.
NIGHTSHIFT_REVIEW_MODEL=review-model
scenario review review '```json' '{"verdict":"ship" "reason":"ok"}' '```' --- '{"verdict":"ship","reason":"ok"}'
unset NIGHTSHIFT_REVIEW_MODEL
[ "$RC" -eq 0 ] && [ "$CALLS" -eq 2 ] || fail "a review correction failed (exit $RC, $CALLS calls)"
jq -e '.verdict == "ship"' "$FAKE_DIR/item/review.md" >/dev/null || fail "the correction did not become review.md"
[ "$(cat "$FAKE_DIR/model.2")" = review-model ] || fail "the review correction ran on $(cat "$FAKE_DIR/model.2")"
grep -qx '````' "$FAKE_DIR/prompt.2" || fail "the prompt fence is not longer than the answer's"

# 8. Codex takes the same path.
NIGHTSHIFT_AGENT=codex
scenario codex verify '{"resolved":false "confidence":"high","evidence":"still there"}' --- \
  '{"resolved":false,"confidence":"high","evidence":"still there"}'
NIGHTSHIFT_AGENT=claude
[ "$RC" -eq 0 ] && [ "$CALLS" -eq 2 ] || fail "a codex correction failed (exit $RC, $CALLS calls)"
jq -e '.resolved == false' "$FAKE_DIR/item/verify.json" >/dev/null || fail "the codex correction did not become verify.json"
jq -se '.[1].stage == "repair-verify" and .[1].model == "codex"' "$RUNSLOG" >/dev/null \
  || fail "the codex correction was not recorded"

echo 'test-json-repair-call: ok'
