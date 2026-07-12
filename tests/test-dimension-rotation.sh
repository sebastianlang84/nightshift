#!/usr/bin/env bash
set -euo pipefail

# L3 regression: dimension rotation must advance even when Explore finds NOTHING.
# Before the fix, last_dim_epoch counted only work-item ledger rows, so an empty-
# Explore lens stayed at epoch 0 and the argmin re-selected it every run — starving
# the other applicable dimensions forever. The Explore scan marker fixes that.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
# A CLEAN readme — no planted "teh"/"retrun" — so the mock Explore finds nothing.
printf '# Demo\n\nThe demo is clean.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 3
recon:
  enabled: false
dimensions:
  - correctness
  - docs
repos:
  - path: $TMP/repo
    mode: branch-fix
EOF

run() {
  RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out.$1" 2>"$TMP/err.$1"
}

# Run 1: cold start → first-listed lens (correctness), finds nothing.
run 1
grep -q "lens=correctness" "$TMP/err.1" || { echo "run 1 did not pick correctness" >&2; cat "$TMP/err.1" >&2; exit 1; }
[ -n "$(find "$TMP/state/dim-scans" -name 'repo-*__correctness' 2>/dev/null)" ] \
  || { echo "no scan marker written for the empty explore" >&2; exit 1; }

# Run 2: correctness now carries a fresh scan epoch → rotation must move to docs.
run 2
grep -q "lens=docs" "$TMP/err.2" || { echo "rotation did not advance after empty explore" >&2; cat "$TMP/err.2" >&2; exit 1; }

echo "test-dimension-rotation: ok"
