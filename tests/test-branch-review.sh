#!/usr/bin/env bash
set -euo pipefail

# Independent branch review (opt-in): a fresh read-only advisor gives a merge/do-not-merge
# recommendation on each open nightshift/* branch, into the digest. Off by default. Never pushes.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
recon:
  enabled: false
dimensions:
  - docs
repos:
  - path: $TMP/repo
    mode: branch-fix
EOF

run() { # tag  [extra env assignments...]
  local tag="$1"; shift
  env "$@" \
  RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out.$tag" 2>"$TMP/err.$tag"
}
branch_count() { git --git-dir="$TMP/remote.git" for-each-ref 'refs/heads/nightshift/*' | wc -l; }

# Run 1: ships a typo branch. Branch review OFF by default → no review section.
run 1
[ "$(branch_count)" -eq 1 ] || { echo "expected 1 shipped branch after run 1" >&2; exit 1; }
digest="$(ls -t "$TMP/digests"/*.md | head -1)"
! grep -q "Independent branch review" "$digest" || { echo "branch review ran while disabled" >&2; exit 1; }

# Run 2: enable branch review with a mock advisor. It advises the open branch, into the digest.
run 2 NIGHTSHIFT_BRANCH_REVIEW=1 NIGHTSHIFT_ADVISOR_AGENT=mock
after="$(branch_count)"
[ "$after" -eq 1 ] || { echo "branch review created/pushed a branch (count $after)" >&2; exit 1; }
digest="$(ls -t "$TMP/digests"/*.md | head -1)"
grep -q "Independent branch review (advisor: mock)" "$digest" || { echo "digest missing branch-review section" >&2; cat "$digest" >&2; exit 1; }
# A typo fix → mock advisor recommends merge.
grep -qE '`nightshift/.*`.*\*\*merge\*\*' "$digest" || { echo "advisor recommendation missing/wrong" >&2; grep -A3 'Independent branch' "$digest" >&2; exit 1; }
# No advise worktrees left behind.
[ -z "$(find "$TMP/worktrees" -mindepth 1 -maxdepth 1 2>/dev/null)" ] || { echo "advise worktree left behind" >&2; exit 1; }

echo "test-branch-review: ok"
