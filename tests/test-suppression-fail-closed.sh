#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT

# Suppression fails closed: only the ledger module's explicit `false` lets a finding through.
# A ledger that becomes unreadable after the start guard (a torn last row) must not re-open
# decided work for the rest of the night.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export NIGHTSHIFT_HOME="$ROOT" NIGHTSHIFT_AGENT=mock
export NIGHTSHIFT_STATE_DIR="$TMP/state"
export NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests"
export NIGHTSHIFT_WORKTREES="$TMP/wt"
export NIGHTSHIFT_SOURCED=1
# shellcheck disable=SC1090
source "$ROOT/bin/nightshift.sh"

mkdir -p "$(dirname "$LEDGER")"
printf '%s\n' '{"outcome":"finding","repo":"/r","fingerprint":"f1","code_sig":"s"}' > "$LEDGER"

already_done /r f1 s || { echo "FAIL: recorded finding not suppressed"; exit 1; }
if already_done /r f2 s; then echo "FAIL: unknown finding suppressed on a readable ledger"; exit 1; fi

printf '{"outcome":"fin' >> "$LEDGER"   # torn row, as after a short write
already_done /r f2 s 2>/dev/null || { echo "FAIL: unreadable ledger lets a finding through"; exit 1; }
already_acted /r f2 s 2>/dev/null || { echo "FAIL: unreadable ledger lets a fix through"; exit 1; }
already_surfaced /r f2 s 2>/dev/null || { echo "FAIL: unreadable ledger re-surfaces"; exit 1; }
[ -z "$(known_work /r 2>/dev/null)" ] || { echo "FAIL: known_work printed from an unreadable ledger"; exit 1; }

echo "PASS: suppression fails closed on an unreadable ledger"
