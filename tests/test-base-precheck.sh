#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT

# The base pre-check before the first fix (base_ready_for_fix). End to end it is covered by
# test-ship-test-gate.sh §7; this pins the two rules a single night cannot show:
# 1. On a red base the one attempt per night ROTATES across nights, so a finding that ranks first
#    cannot take it every night and starve the finding whose fix would repair the suite.
# 2. A green unchanged-base recheck after a red pre-check (a registry blip) frees the repo's
#    remaining fixes that night.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-base-precheck: $*" >&2; exit 1; }
mkdir -p "$TMP/state" "$TMP/item"

cat > "$TMP/probe.sh" <<'PROBE'
set +u
NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
set +e
repo_test_cmd() { echo "exit 1"; }
log() { :; }
# One "night" per call: BASE_PRECHECK is per process. The base is red unless BASE_GREEN=1.
base_gate_status() { [ "${BASE_GREEN:-0}" = 1 ] && return 0; return 1; }
night() { # fingerprints... -> the ones that may start a fix, space-separated. A "/" between
  # fingerprints starts a new item (a later pass), as in main; the wrap runs once, at night's end.
  local fp out=""
  for fp in "$@"; do
    [ "$fp" = / ] && continue
    if base_ready_for_fix /r/repo SHA1 "$TMP/item" "$fp"; then
      if [ "$fp" = "${NO_WORKTREE:-}" ]; then base_red_started /r/repo SHA1 "$fp" 0; continue; fi
      base_red_started /r/repo SHA1 "$fp" 1; out="$out $fp"
    fi
  done
  base_red_wrap_all
  echo "${out# }"
}
"$@"
PROBE
run() { ROOT="$ROOT" TMP="$TMP" NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
          NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
          bash "$TMP/probe.sh" "$@"; }

# --- 1. rotation ---------------------------------------------------------------------------------
[ "$(run night typo repair)" = typo ] || fail "night 1: the first finding did not get the one attempt"
[ "$(run night typo repair)" = repair ] || fail "night 2: the attempt did not rotate to the next finding"
# Night 3: everyone had a turn, so nobody runs and the record is cleared; night 4 starts over.
[ -z "$(run night typo repair)" ] || fail "night 3: a finding got a second attempt within one rotation"
[ "$(run night typo repair)" = typo ] || fail "night 4: the rotation did not start over"
# Three items in one night (later passes), one finding each: the rotation must reach the third.
rm -f "$TMP/state/base-red-attempts.tsv"
[ "$(run night a / b / c)" = a ] || fail "items: night 1 did not attempt the first finding"
[ "$(run night a / b / c)" = b ] || fail "items: night 2 did not rotate to the second item"
[ "$(run night a / b / c)" = c ] || fail "items: night 3 did not reach the third item"
# A fix whose worktree could not be created did not have its attempt: the next finding gets the
# night's attempt, and the failed one is not recorded.
rm -f "$TMP/state/base-red-attempts.tsv"
[ "$(NO_WORKTREE=typo run night typo repair)" = repair ] || fail "a failed worktree setup consumed the night's attempt"
[ "$(run night typo repair)" = typo ] || fail "a fix that never started was recorded as attempted"
# A new base sha starts over.
out="$(run eval 'base_ready_for_fix /r/repo SHA2 "$TMP/item" typo && base_red_started /r/repo SHA2 typo 1 && echo yes')" || true
[ "$out" = yes ] || fail "a new base did not get a fresh attempt"
grep -q 'SHA1' "$TMP/state/base-red-attempts.tsv" && fail "attempts on an older base were not dropped"

# --- 2. a green recheck frees the night ----------------------------------------------------------
rm -f "$TMP/state/base-red-attempts.tsv"
out="$(run eval '
  base_ready_for_fix /r/repo SHA1 "$TMP/item" a >/dev/null || exit 1
  git() { [ "$1" = -C ] && [ "$3" = rev-parse ] && { echo SHA1; return 0; }; command git "$@"; }
  BASE_GREEN=1 base_suite_red /r/repo /wt "$TMP/item" "exit 1" && exit 1
  base_ready_for_fix /r/repo SHA1 "$TMP/item" b && echo freed')" || true
[ "$out" = freed ] || fail "a green recheck of the same base did not free the remaining fixes"

echo "test-base-precheck: ok"
