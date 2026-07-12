#!/usr/bin/env bash
set -euo pipefail

# ADR 0015 integration test: an empty Explore pass logs a {dimension, scope} ledger row, and three
# consecutive out-of-scope passes for a (repo,dim) make the digest SUGGEST a human rulebook exclusion
# (recon never excludes on its own). The mock returns out_of_scope when a NOSCOPE sentinel is present.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# clean\n\nThe demo is clean.\n' > "$TMP/repo/README.md"   # no planted defect -> nothing found
: > "$TMP/repo/NOSCOPE"                                            # sentinel -> mock returns out_of_scope
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add -A
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

# One empty out-of-scope pass writes exactly one such ledger row.
run 1
n=$(jq -s '[.[]|select(.outcome=="empty" and .scope=="out_of_scope" and .dimension=="correctness")]|length' "$TMP/state/ledger.jsonl")
[ "$n" = 1 ] || { echo "expected 1 empty/out_of_scope row after run 1, got $n" >&2; cat "$TMP/state/ledger.jsonl" >&2; exit 1; }

# The suggestion needs THREE consecutive out-of-scope passes; it must NOT fire early.
digest="$TMP/digests/$(date +%Y-%m-%d).md"
grep -q "Suggested rulebook exclusions" "$digest" && { echo "suggestion fired too early (after 1 pass)" >&2; exit 1; }

run 2
run 3
n=$(jq -s '[.[]|select(.outcome=="empty" and .scope=="out_of_scope")]|length' "$TMP/state/ledger.jsonl")
[ "$n" = 3 ] || { echo "expected 3 empty/out_of_scope rows after 3 runs, got $n" >&2; exit 1; }

grep -q "Suggested rulebook exclusions" "$digest" \
  || { echo "digest did not suggest an exclusion after 3 out-of-scope passes" >&2; cat "$digest" >&2; exit 1; }
grep -q "correctness" "$digest" || { echo "suggestion did not name the dimension" >&2; exit 1; }

echo "test-empty-scope-suggestion: ok"
