#!/usr/bin/env bash
set -euo pipefail

# The `surface` route: an intent-ambiguous divergence (ADR 0006) ships as a human-owned
# finding — NOT an auto-fix. Verify the ledger row, no push, worktree removal, digest
# rendering, the latch on re-run, and that an UNKNOWN disposition fails closed (surfaces).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# project\n' > "$TMP/repo/README.md"
printf 'AMBIGUOUS: two configs disagree; a human must choose.\n' > "$TMP/repo/NOTES.md"
printf 'FROB: nonsense disposition to test fail-closed.\n' > "$TMP/repo/WEIRD.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
  max_findings_per_item: 5
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: branch-fix
    findings: 5
EOF

run() {
  RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out.$1" 2>"$TMP/err.$1"
}

LEDGER="$TMP/state/ledger.jsonl"

run 1
# Both the surface finding and the unknown-disposition finding land as `finding` rows.
finds=$(jq -s '[.[]|select(.outcome=="finding")]|length' "$LEDGER")
[ "$finds" -eq 2 ] || { echo "expected 2 surfaced findings, got $finds" >&2; jq -c '{outcome,fingerprint}' "$LEDGER" >&2; exit 1; }
# Never auto-fixed: no shipped row, no branch on origin.
[ "$(jq -s '[.[]|select(.outcome=="shipped")]|length' "$LEDGER")" -eq 0 ] || { echo "surface route shipped a branch" >&2; exit 1; }
[ "$(git --git-dir="$TMP/remote.git" for-each-ref 'refs/heads/nightshift/*' | wc -l)" -eq 0 ] || { echo "branch pushed for a surfaced finding" >&2; exit 1; }
# Worktrees cleaned up.
[ -z "$(find "$TMP/worktrees" -mindepth 1 -maxdepth 1 2>/dev/null)" ] || { echo "worktree left behind" >&2; exit 1; }
# Unknown disposition failed closed (logged) and surfaced rather than auto-fixed.
grep -q "unrecognized disposition 'frobnicate'" "$TMP/err.1" || { echo "unknown disposition not failed-closed" >&2; cat "$TMP/err.1" >&2; exit 1; }
# Digest renders the surfaced findings.
grep -q "ambiguous divergence in NOTES.md" "$TMP/digests"/*.md || { echo "surfaced finding missing from digest" >&2; exit 1; }

# Re-run: a surfaced finding LATCHES — human-owned, neither re-surfaced nor auto-fixed.
run 2
grep -q "previously surfaced — human-owned" "$TMP/err.2" || { echo "surface latch did not hold on re-run" >&2; cat "$TMP/err.2" >&2; exit 1; }
[ "$(jq -s '[.[]|select(.outcome=="finding")]|length' "$LEDGER")" -eq 2 ] || { echo "re-run duplicated a surfaced finding" >&2; exit 1; }
[ "$(jq -s '[.[]|select(.outcome=="shipped")]|length' "$LEDGER")" -eq 0 ] || { echo "re-run auto-fixed a latched finding" >&2; exit 1; }

echo "test-surface-route: ok"
