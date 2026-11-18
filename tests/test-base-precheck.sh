#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT

# The base pre-check before Explore (base_precheck). End to end it is covered by
# test-ship-test-gate.sh §3b and §7; this pins what a single night there does not show:
# 1. One suite run per repo and base in a night, whatever the number of passes.
# 2. A skipped repo stays skipped for the run, even when its base moves to a green commit.
# 3. A failed report is retried next night instead of being recorded as sent.

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
base_gate_status() { echo run >> "$TMP/runs.count"; [ "${BASE_GREEN:-0}" = 1 ] && return 0; return 1; }
"$@"
PROBE
run() { ROOT="$ROOT" TMP="$TMP" NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
          NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
          bash "$TMP/probe.sh" "$@"; }

# --- 1. cached per night -------------------------------------------------------------------------
out="$(run eval 'base_precheck /r/repo SHA1 "$TMP/item"; base_precheck /r/repo SHA1 "$TMP/item" || echo "$BASE_PRECHECK_WHY"')"
[[ "$out" == *"red on the unchanged base SHA1"* ]] || fail "a red base was not refused: $out"
[ "$(wc -l < "$TMP/runs.count")" -eq 1 ] || fail "the base suite ran more than once for one base"

# --- 2. a skipped repo stays skipped when its base moves --------------------------------------
# An automatic merge can move the base to a green commit between passes; the digest already says the
# repo was skipped tonight, so a later pass must not admit it.
out="$(run eval '
  base_precheck /r/repo SHA1 "$TMP/item" && exit 1
  BASE_GREEN=1 base_precheck /r/repo SHA9 "$TMP/item" || echo still-skipped')" || true
[ "$out" = still-skipped ] || fail "a later pass admitted a skipped repo on a moved base"

# --- 3. a failed report is not recorded ----------------------------------------------------------
NIGHTSHIFT_BLOCKED_BASE_CMD='exit 3' run eval 'base_precheck /r/repo SHA1 "$TMP/item"' || true
[ ! -s "$TMP/state/blocked-bases.tsv" ] || fail "a failed report was recorded as sent"
NIGHTSHIFT_BLOCKED_BASE_CMD='true' run eval 'base_precheck /r/repo SHA1 "$TMP/item"' || true
grep -qxF "/r/repo"$'\t'"SHA1" "$TMP/state/blocked-bases.tsv" || fail "a sent report was not recorded"

echo "test-base-precheck: ok"
