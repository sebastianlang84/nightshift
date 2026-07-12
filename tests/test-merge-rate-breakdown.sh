#!/usr/bin/env bash
set -euo pipefail

# Harvest visibility: shipped ledger rows carry the finding `type`, and the digest renders
# merge-rate broken down by verifiability / proof / finding type once verdicts exist.

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

LEDGER="$TMP/state/ledger.jsonl"
run() {
  RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out.$1" 2>"$TMP/err.$1"
}

run 1
# Shipped row now carries the finding type.
jq -e 'select(.outcome=="shipped") | .type=="typo"' "$LEDGER" >/dev/null \
  || { echo "shipped ledger row missing type=typo" >&2; jq -c 'select(.outcome=="shipped")' "$LEDGER" >&2; exit 1; }

branch="$(jq -r 'select(.outcome=="shipped")|.branch' "$LEDGER" | head -1)"
[ -n "$branch" ] || { echo "no shipped branch" >&2; exit 1; }
# Record a human merge verdict, then re-run to regenerate the digest with merge-rate data.
STATE_DIR="$TMP/state" LEDGER="$LEDGER" RULEBOOK="$TMP/rulebook.yaml" \
  bash "$ROOT/bin/harvest.sh" verdict "$branch" merged >/dev/null

run 2
digest="$(ls -t "$TMP/digests"/*.md | head -1)"
grep -q "Merge-rate by finding type" "$digest" || { echo "digest missing finding-type breakdown" >&2; cat "$digest" >&2; exit 1; }
grep -q "Merge-rate by verifiability" "$digest" || { echo "digest missing verifiability breakdown" >&2; exit 1; }
grep -qE "typo: shipped 1 . merged 1" "$digest" || { echo "type breakdown wrong" >&2; grep -A3 'finding type' "$digest" >&2; exit 1; }

echo "test-merge-rate-breakdown: ok"
