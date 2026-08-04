#!/usr/bin/env bash
set -euo pipefail

# ADR 0022 — the Review stage proves the FINDING is fixed; it never proves nothing ELSE broke.
# Until the gate existed, a regression only surfaced if the host repo happened to have CI, and one
# of four did. (Observed 2026-08-04: market-digest PR #10 removed a dependency that looked unused
# in src/ but was imported by tests across a service boundary — three tests broke and it shipped.)
# The gate runs the repo's declared `test_cmd` in the WORKTREE, INSIDE the fix<->review loop:
#   fails  -> the failing output goes back to the Fix stage, which repairs its own regression
#   fails every iteration -> ledger `tests-failed`, no branch anywhere, the finding stays unlatched
#   passes -> ships exactly as before
#   absent -> ships UNGATED, and the run says so out loud
# Throwing the fix away on the first red suite was the wrong reaction: the Fix stage caused the
# breakage, is still in the loop with budget left, and is the thing best placed to repair it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Builds a throwaway fleet-of-one and runs one night with the given `test_cmd` line.
# $1 = case name, $2 = the `test_cmd:` line to splice into the rulebook ("" = omit the key).
run_night() {
  local case="$1" cmdline="${2:-}" d="$TMP/$1"
  mkdir -p "$d/state" "$d/runs" "$d/digests" "$d/worktrees"
  git init -q --bare "$d/remote.git"
  git init -q -b main "$d/repo"
  git -C "$d/repo" remote add origin "$d/remote.git"
  # `teh` is what the mock Explore stage finds and the mock Fix stage repairs.
  printf '# Demo\n\nThis is teh demo.\n' > "$d/repo/README.md"
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost add -A
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
  git -C "$d/repo" push -q -u origin main

  {
    echo "branch_prefix: nightshift/"
    echo "limits:"
    echo "  max_open_branches: 5"
    echo "recon:"
    echo "  enabled: false"
    echo "dimensions:"
    echo "  - docs"
    echo "repos:"
    echo "  - path: $d/repo"
    echo "    mode: branch-fix"
    echo "    base: main"
    [ -n "$cmdline" ] && echo "    test_cmd: $cmdline"
  } > "$d/rulebook.yaml"

  RULEBOOK="$d/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$d/state" NIGHTSHIFT_RUNS_DIR="$d/runs" \
  NIGHTSHIFT_DIGEST_DIR="$d/digests" NIGHTSHIFT_WORKTREES="$d/worktrees" \
    "$ROOT/bin/nightshift.sh" >"$d/out" 2>"$d/err"
}

fail() { echo "test-ship-test-gate: $*" >&2; exit 1; }

# --- 1. a suite that stays red through every attempt blocks the ship ----------
run_night fails 'exit 1'
d="$TMP/fails"; LEDGER="$d/state/ledger.jsonl"

grep -q "test gate failed" "$d/err" "$d/out" || { cat "$d/err" >&2; fail "the failed gate was not reported"; }
# It must have RETRIED, not given up on the first red suite.
grep -q "gate overrules ship" "$d/err" "$d/out" || { cat "$d/err" >&2; fail "the gate did not send the fix back for another attempt"; }
[ "$(grep -c "test gate failed" "$d/err")" -ge 2 ] \
  || { cat "$d/err" >&2; fail "the gate ran only once — the fix<->review loop did not retry"; }

if [ -f "$LEDGER" ] && jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1; then
  jq -c . "$LEDGER" >&2; fail "a branch shipped although the test gate failed"
fi

row="$(jq -sc '[.[]|select(.outcome=="tests-failed")][0] // empty' "$LEDGER" 2>/dev/null || true)"
[ -n "$row" ] || { jq -c . "$LEDGER" >&2; fail "no tests-failed row in the ledger"; }
# No branch/sha: nothing was created, so the row must not imply a pushed artifact.
jq -e '.branch==null and .sha==null' <<<"$row" >/dev/null \
  || fail "tests-failed row names a branch/sha that never existed: $row"

# The gate must not cost a branch — it runs BEFORE the branch is created.
if git -C "$d/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*' | grep -q .; then
  fail "a nightshift/* branch reached the remote despite the failed gate"
fi
if git -C "$d/repo" branch --list 'nightshift/*' | grep -q .; then
  fail "a local nightshift/* branch was left behind after the failed gate"
fi

# The suite's output is kept for diagnosis, next to the finding it belongs to.
find "$d/runs" -name tests.log | grep -q . || fail "no tests.log written for the failed gate"

digest=""; for f in "$d/digests"/*.md; do digest="$f"; done
[ -f "$digest" ] || fail "no digest written"
grep -qF "tests-failed" "$digest" || { cat "$digest" >&2; fail "the digest hides the failed gate"; }

# --- 2. a passing suite ships, and the gate ran against the FIX ---------------
# `grep 'the demo'` only succeeds in the worktree AFTER the mock fix repairs `teh`. Running the
# gate in the repo (or before the fix) would fail it — so this pins the working directory too.
run_night passes 'grep -q "This is the demo" README.md'
d="$TMP/passes"; LEDGER="$d/state/ledger.jsonl"

grep -q "test gate passed" "$d/err" "$d/out" || { cat "$d/err" >&2; fail "a passing gate was not reported"; }
jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1 \
  || { jq -c . "$LEDGER" >&2; fail "nothing shipped although the test gate passed"; }
git -C "$d/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*' | grep -q . \
  || fail "no nightshift/* branch on the remote although the gate passed"


# --- 2b. red once, green on the retry: the item ships instead of dying --------
# The marker lives OUTSIDE the worktree so the gate's own bookkeeping never lands in the commit.
run_night retries "test -f $TMP/retries-seen || { touch $TMP/retries-seen; exit 1; }"
d="$TMP/retries"; LEDGER="$d/state/ledger.jsonl"

grep -q "gate overrules ship" "$d/err" "$d/out" || { cat "$d/err" >&2; fail "the first red suite was not reported as a retry"; }
grep -q "test gate passed"    "$d/err" "$d/out" || { cat "$d/err" >&2; fail "the retry never went green"; }
jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1 \
  || { jq -c . "$LEDGER" >&2; fail "a fix that went green on the retry must ship, not be thrown away"; }
if [ -f "$LEDGER" ] && jq -e 'select(.outcome=="tests-failed")' "$LEDGER" >/dev/null 2>&1; then
  fail "a recovered item must not also be recorded as tests-failed"
fi
# The log is deleted the moment the suite is green — its presence is the Fix stage's signal, so a
# stale one would ask the next attempt to repair damage that is already repaired.
find "$d/runs" -name tests.log | grep -q . && fail "tests.log survived a passing gate"

# --- 2c. the failing output actually reaches the Fix stage --------------------
# The mock adapter never reads a prompt, so this pins the wiring where it lives: stage_prompt.
pid="$TMP/promptitem"; mkdir -p "$pid"
echo '{"file":"README.md","summary":"s","fingerprint":"f"}' > "$pid/finding.json"
prompt_with() { # tests.log content ("" = no log) -> the fix prompt on stdout
  rm -f "$pid/tests.log"
  [ -n "$1" ] && printf '%s' "$1" > "$pid/tests.log"
  ( set +u; NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
    stage_prompt fix "$TMP" "$pid" )
}
if prompt_with "" | grep -q "previous attempt broke"; then
  fail "the regression block appears in the fix prompt without a tests.log"
fi
withlog="$(prompt_with 'FAILED tests/test_thing.py::test_it
E   AssertionError')"
grep -q "previous attempt broke" <<<"$withlog" || fail "the Fix stage is never told its change broke the suite"
grep -q "test_thing.py::test_it" <<<"$withlog" || fail "the Fix stage does not receive the failing output"
rm -f "$pid/tests.log"

# --- 3. no test_cmd: ships as before, but the run says it is ungated ----------
run_night ungated ''
d="$TMP/ungated"; LEDGER="$d/state/ledger.jsonl"

grep -q "shipping UNGATED" "$d/err" "$d/out" \
  || { cat "$d/err" >&2; fail "an ungated repo shipped without saying so"; }
jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1 \
  || { jq -c . "$LEDGER" >&2; fail "an ungated repo must still ship (backward compatibility)"; }

# --- 4. a hanging suite is bounded, not waited on -----------------------------
( export NIGHTSHIFT_TEST_TIMEOUT=1; run_night hangs 'sleep 30' )
d="$TMP/hangs"; LEDGER="$d/state/ledger.jsonl"

grep -q "test gate TIMED OUT" "$d/err" "$d/out" \
  || { cat "$d/err" >&2; fail "a hanging suite was not reported as a timeout"; }
jq -e 'select(.outcome=="tests-failed")' "$LEDGER" >/dev/null 2>&1 \
  || { jq -c . "$LEDGER" >&2; fail "a timed-out gate must be recorded as tests-failed"; }
if [ -f "$LEDGER" ] && jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1; then
  fail "a branch shipped although the test gate timed out"
fi

echo "test-ship-test-gate: ok"
