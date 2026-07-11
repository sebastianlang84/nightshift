#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 1
  max_findings_per_item: 1
  max_branches_per_run: 1
  max_fix_iterations: 1
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: branch-fix
    base: main
EOF

# Keep the fetched base ref but make the next push fail.
git -C "$TMP/repo" remote set-url origin "$TMP/missing/remote.git"

RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/stdout" 2>"$TMP/stderr"

! jq -e 'select(.outcome=="shipped")' "$TMP/state/ledger.jsonl" >/dev/null
jq -e 'select(.outcome=="push-failed" and .branch!=null and .sha!=null)' \
  "$TMP/state/ledger.jsonl" >/dev/null
grep -q 'push failed' "$TMP/stderr"
grep -q 'push-failed' "$TMP/digests/$(date +%F).md"
! git -C "$TMP/repo" for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*' | grep -q .

echo "test-push-failure: ok"
