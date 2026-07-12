#!/usr/bin/env bash
set -euo pipefail

# L1 regression: two findings shipped from ONE explore pass must get DISTINCT, globally
# unique work-item IDs in the ledger (and telemetry). They used to both record as "f0"/"f1"
# — a bare per-finding basename — colliding across items and runs and breaking the
# harvest `verdict <item>` selector and any runs->ledger join.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
# Two planted defects → the mock Explore emits two findings.
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
printf '# retrun from here\n' > "$TMP/repo/app.py"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md app.py
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
  max_findings_per_item: 2
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: branch-fix
    findings: 2
EOF

RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/stdout" 2>"$TMP/stderr"

LEDGER="$TMP/state/ledger.jsonl"
shipped=$(jq -s '[.[]|select(.outcome=="shipped")]|length' "$LEDGER")
[ "$shipped" -eq 2 ] || { echo "expected 2 shipped, got $shipped" >&2; exit 1; }

# Both item IDs present, distinct, and non-null.
distinct=$(jq -rs '[.[]|select(.outcome=="shipped")|.item]|unique|length' "$LEDGER")
[ "$distinct" -eq 2 ] || { echo "shipped rows share a work-item ID (got $distinct distinct)" >&2; jq -c 'select(.outcome=="shipped")|{item,branch}' "$LEDGER" >&2; exit 1; }

# The runs telemetry item field must join back to a ledger item (no bare "f0"/"f1").
jq -e 'select(.item=="f0" or .item=="f1")' "$TMP/state/runs.jsonl" >/dev/null 2>&1 \
  && { echo "telemetry still records colliding bare item IDs" >&2; exit 1; }

echo "test-multi-finding-item-ids: ok"
