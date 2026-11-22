#!/usr/bin/env bash
set -euo pipefail

# ADR 0044: an unattended night that finds the Claude week (nearly) spent pauses and says so in one
# line instead of switching models. NIGHTSHIFT_QUOTA_CMD is asked once before the night: exit 75 =
# pause, with the first line of its stdout as the reason; any other exit, a check that cannot run,
# crashes or times out means go. NIGHTSHIFT_NOTIFY_CMD gets the pause as `$1`.
#
# Asserted against the real launcher with a fake runner that only records that it started:
#   1. pause: the runner does not start, the launcher exits 0, the digest says PAUSED and why, the
#      log says so, the notify command is called once — and the paused night is not an ABORTED one
#      for aborted_streak;
#   2. go: the runner starts and nobody is notified;
#   3. a check that cannot run, or times out, means go;
#   4. a failing notify command does not turn the pause into a failure.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-quota-pause: $*" >&2; exit 1; }

mkdir -p "$TMP/launcher/bin"
printf '#!/usr/bin/env bash\ntouch "$TEST_TMP/ran"\n' > "$TMP/launcher/bin/nightshift.sh"
chmod +x "$TMP/launcher/bin/nightshift.sh"
night="$(date +%F)"

launch() { # case [VAR=value …] -> rc of the launcher; state under $TMP/<case>
  local c="$1" rc=0; shift
  mkdir -p "$TMP/$c"
  env -u NIGHTSHIFT_QUOTA_CMD -u NIGHTSHIFT_NOTIFY_CMD -u NIGHTSHIFT_QUOTA_TIMEOUT \
    TEST_TMP="$TMP/$c" NIGHTSHIFT_HOME="$TMP/launcher" NIGHTSHIFT_AGENT=mock \
    NIGHTSHIFT_LOCK="$TMP/$c/lock" NIGHTSHIFT_LOG_DIR="$TMP/$c/logs" \
    NIGHTSHIFT_DIGEST_DIR="$TMP/$c/digests" NOTIFIED="$TMP/$c/notified" \
    "$@" bash "$ROOT/bin/nightshift-cron.sh" > "$TMP/$c/out" 2>&1 || rc=$?
  return $rc
}
notify='printf "%s\n" "$1" >> "$NOTIFIED"'

# 1. pause
rc=0; launch pause NIGHTSHIFT_QUOTA_CMD='echo "Claude week 97% spent"; echo second line; exit 75' \
  NIGHTSHIFT_NOTIFY_CMD="$notify" || rc=$?
d="$TMP/pause"
[ "$rc" -eq 0 ] || { cat "$d/out" >&2; fail "a pause exited $rc, not 0"; }
[ ! -e "$d/ran" ] || fail "the runner started despite the pause"
grep -q '^- \*\*PAUSED:.*Claude week 97% spent' "$d/digests/$night.md" \
  || fail "the digest does not say the night paused and why: $(cat "$d/digests/$night.md" 2>/dev/null)"
grep -q 'second line' "$d/digests/$night.md" && fail "more than the first line of the check reached the digest"
grep -q 'ABORTED' "$d/digests/$night.md" && fail "a pause was recorded as ABORTED"
grep -q 'nightshift paused' "$d/logs/$night.log" || fail "the log does not record the pause"
[ "$(grep -c . "$d/notified")" -eq 1 ] || fail "expected one notify line, got: $(cat "$d/notified")"
grep -qx "nightshift $night paused: Claude week 97% spent" "$d/notified" \
  || fail "the notify line is wrong: $(cat "$d/notified")"
# A paused night is neither a lost night nor a serviced one for aborted_streak.
streak() { # night-after -> aborted_streak's output over $d/digests
  ( export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_STATE_DIR="$TMP/s" NIGHTSHIFT_RUNS_DIR="$TMP/r" \
      NIGHTSHIFT_WORKTREES="$TMP/w" NIGHTSHIFT_DIGEST_DIR="$d/digests"
    # shellcheck disable=SC1090
    source "$ROOT/bin/nightshift.sh"; NIGHT="$1"; aborted_streak )
}
[ "$(streak 9999-12-31)" = "0 - - -" ] || fail "a lone pause changed aborted_streak: $(streak 9999-12-31)"
printf '# nightshift digest — 0001-01-01\n\n- **ABORTED: test**\n' > "$d/digests/0001-01-01.md"
[ "$(streak 9999-12-31)" = "1 0001-01-01 0001-01-01 -" ] \
  || fail "a pause after an aborted night was read as a completed one: $(streak 9999-12-31)"

# The quota hook sees the effective adapter even when only the rulebook selects it.
ln -s "$ROOT/lib" "$TMP/launcher/lib"
cat > "$TMP/codex.yaml" <<EOF
agent:
  primary: codex
repos:
  - path: $TMP/unused
    mode: findings-only
EOF
launch codex RULEBOOK="$TMP/codex.yaml" NIGHTSHIFT_AGENT= \
  NIGHTSHIFT_QUOTA_CMD='echo "$NIGHTSHIFT_AGENT window spent"; exit 75'
grep -q 'PAUSED:.*codex window spent' "$TMP/codex/digests/$night.md" || fail "wrong quota window"
[ ! -e "$TMP/codex/ran" ] || fail "a Codex quota pause started a night"

# 2. go
launch go NIGHTSHIFT_QUOTA_CMD='echo "Claude week 40% spent"' NIGHTSHIFT_NOTIFY_CMD="$notify" \
  || { cat "$TMP/go/out" >&2; fail "a go night failed"; }
[ -e "$TMP/go/ran" ] || fail "the runner did not start on a go"
[ ! -e "$TMP/go/notified" ] || fail "a go night notified the operator"
grep -q 'quota check: go' "$TMP/go/logs/$night.log" || fail "the go is not logged"

# 3. a check that cannot run, times out or crashes means go
launch broken NIGHTSHIFT_QUOTA_CMD="$TMP/no-such-check" NIGHTSHIFT_NOTIFY_CMD="$notify" \
  || { cat "$TMP/broken/out" >&2; fail "a broken check failed the launcher"; }
[ -e "$TMP/broken/ran" ] || fail "a check that cannot run stopped the night"
grep -q 'quota check failed (rc=127)' "$TMP/broken/logs/$night.log" || fail "the broken check is not logged"
[ ! -e "$TMP/broken/notified" ] || fail "a broken check notified the operator"
launch slow NIGHTSHIFT_QUOTA_CMD='sleep 30; exit 75' NIGHTSHIFT_QUOTA_TIMEOUT=1 \
  || { cat "$TMP/slow/out" >&2; fail "a slow check failed the launcher"; }
[ -e "$TMP/slow/ran" ] || fail "a check that timed out stopped the night"
grep -q 'quota check failed (rc=124)' "$TMP/slow/logs/$night.log" || fail "the timeout is not logged"

launch crash NIGHTSHIFT_QUOTA_CMD='echo boom >&2; exit 1' NIGHTSHIFT_NOTIFY_CMD="$notify" \
  || { cat "$TMP/crash/out" >&2; fail "a crashing check failed the launcher"; }
[ -e "$TMP/crash/ran" ] || fail "a check that crashed stopped the night"
grep -q 'quota check failed (rc=1)' "$TMP/crash/logs/$night.log" || fail "the crashed check is not logged"

# 4. a failing notify command is logged, and the pause still exits 0
rc=0; launch badnotify NIGHTSHIFT_QUOTA_CMD='exit 75' NIGHTSHIFT_NOTIFY_CMD='exit 3' || rc=$?
[ "$rc" -eq 0 ] || fail "a failing notify command made the pause exit $rc"
[ ! -e "$TMP/badnotify/ran" ] || fail "the runner started despite the pause"
grep -q 'notify command failed (rc=3)' "$TMP/badnotify/logs/$night.log" || fail "the failing notify is not logged"
grep -q 'the quota check gave no reason' "$TMP/badnotify/digests/$night.md" || fail "a silent check left no reason"

echo "test-quota-pause: ok"
