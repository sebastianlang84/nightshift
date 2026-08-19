#!/usr/bin/env bash
set -euo pipefail

# Iterations reuse one item directory. A failed stage must not leave the caller reading the previous
# iteration's valid-looking artifact — especially a stale review.md with verdict:ship.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/repo" "$TMP/item"

export NIGHTSHIFT_AGENT=mock NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"

printf '%s\n' '{"verdict":"ship","reason":"stale prior iteration"}' > "$TMP/item/review.md"
printf '%s\n' '{"model_id":"stale"}' > "$TMP/item/.usage_review"
mock_review() { return 7; }

rc=0
run_agent review "$TMP/repo" "$TMP/item" || rc=$?
[ "$rc" -eq 7 ] || { echo "test-stage-artifact-isolation: wrong failure rc $rc" >&2; exit 1; }
[ ! -e "$TMP/item/review.md" ] || {
  echo "test-stage-artifact-isolation: stale ship verdict survived a failed review" >&2; exit 1;
}
[ ! -e "$TMP/item/.usage_review" ] || {
  echo "test-stage-artifact-isolation: stale telemetry survived a failed review" >&2; exit 1;
}

echo "test-stage-artifact-isolation: ok"
