#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT

# Three failure paths that used to be silent or misreported:
# 1. One bad ledger line made every slurping reader fail open (decided work re-surfaced, re-fixed and
#    re-pushed). The night must refuse such a ledger before it spends anything.
# 2. A Claude control-file refusal returned status 1, which run_agent counts as "did not reach its
#    model"; two of them aborted the whole night. It is a configuration refusal: status 2.
# 3. A runner exit before write_digest (rulebook parse error, split-state guard, invalid ledger) left
#    no digest, so the morning saw the last good night. The launcher records it with the ABORTED
#    marker aborted_streak counts.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$TMP/probe.sh" <<'PROBE'
set +u
NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
set +e
"$@"
PROBE
run() { ROOT="$ROOT" NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
          NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
          bash "$TMP/probe.sh" "$@" 2>/dev/null; }
mkdir -p "$TMP/state"

# --- 1. ledger guard ---------------------------------------------------------------------------
run guard_ledger_valid || fail "a missing ledger was refused"
printf '%s\n' '{"outcome":"finding","repo":"r","fingerprint":"a"}' > "$TMP/state/ledger.jsonl"
run guard_ledger_valid || fail "a valid ledger was refused"
printf '%s' '{"outcome":"shipped","repo":"r","fing' >> "$TMP/state/ledger.jsonl"
if run guard_ledger_valid; then fail "a ledger with a truncated last line was accepted"; fi

# --- 2. control-file refusal is a configuration refusal, not a wall ------------------------------
G() { git -c user.name=t -c user.email=t@localhost "$@"; }
git init -q -b main "$TMP/repo"
printf '{"mcpServers":{"x":{"command":"sh"}}}\n' > "$TMP/repo/.mcp.json"
G -C "$TMP/repo" add -A
G -C "$TMP/repo" commit -q -m init
mkdir -p "$TMP/item"
rc=0; run claude_run explore "$TMP/repo" "$TMP/item" || rc=$?
[ "$rc" -eq 2 ] || fail "a refused Claude control file returned $rc, not 2"

# --- 3. the launcher records a runner exit that wrote no digest ----------------------------------
H="$TMP/home"; mkdir -p "$H/bin"
printf '#!/bin/sh\necho "rulebook parse failed — aborting run"\nexit 1\n' > "$H/bin/nightshift.sh"
chmod +x "$H/bin/nightshift.sh"
cp "$ROOT/bin/nightshift-cron.sh" "$H/bin/"
launch() { NIGHTSHIFT_HOME="$H" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_LOG_DIR="$TMP/logs" \
             NIGHTSHIFT_LOCK="$TMP/lock" NIGHTSHIFT_DIGEST_DIR="$TMP/digests" \
             bash "$H/bin/nightshift-cron.sh" >/dev/null 2>&1; }
rc=0; launch || rc=$?
[ "$rc" -eq 1 ] || fail "the launcher did not propagate the runner's status (got $rc)"
d="$TMP/digests/$(date +%Y-%m-%d).md"
[ -f "$d" ] || fail "no digest was written for a night the runner aborted before its digest"
grep -q '^- \*\*ABORTED:' "$d" || fail "the stub digest lacks the ABORTED marker aborted_streak counts"
grep -q 'rulebook parse failed' "$d" || fail "the stub digest does not carry the log tail"

# A digest the runner itself wrote during the run is left alone.
printf '#!/bin/sh\nmkdir -p "$NIGHTSHIFT_DIGEST_DIR"\necho "# own digest" > "$NIGHTSHIFT_DIGEST_DIR/$(date +%%Y-%%m-%%d).md"\nexit 3\n' \
  > "$H/bin/nightshift.sh"
rm -f "$d"
rc=0; launch || rc=$?
[ "$(cat "$d")" = "# own digest" ] || fail "the launcher rewrote a digest the runner wrote itself"

echo "test-abort-reporting: ok"
