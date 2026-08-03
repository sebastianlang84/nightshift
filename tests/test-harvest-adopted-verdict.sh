#!/usr/bin/env bash
set -euo pipefail

# An ADOPTED orphan (ADR 0018) must reconcile to a correct verdict on the next harvest.
# adopt_orphan writes `fingerprint: null` by design — the branch name is the only surviving
# provenance. The reconcile loop reads its rows as delimited text, so that legitimately empty
# field must not shift the ones after it: a separator that bash treats as IFS whitespace (tab)
# collapses runs of delimiters, which moved `branch` into `fp` and `sha` into `branch`. reconcile
# then probed a branch literally named "<sha>" with an empty sha, found no such ref on origin, and
# recorded `dropped` — for a branch that was in fact merged. That silently inverts the merge-rate
# the dimension picker steers on, so assert the field positions, not just the verdict.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state"
LEDGER="$TMP/state/ledger.jsonl"
# reconcile step 1 only reports `merged` when nightshift authored the tip (see NIGHTSHIFT_COMMIT_EMAIL);
# a foreign author on a contained sha is deliberately `dropped`. Commit as nightshift.
NS="git -c user.name=nightshift -c user.email=nightshift@localhost"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf 'x\n' > "$TMP/repo/f.txt"
$NS -C "$TMP/repo" add -A && $NS -C "$TMP/repo" commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

# A branch that was shipped, MERGED into main, and whose ref still sits on origin — but whose
# shipped row was lost (isolated-state run / crash between push and ledger_append).
git -C "$TMP/repo" checkout -q -b nightshift/adopted main
printf 'fix\n' >> "$TMP/repo/f.txt"
$NS -C "$TMP/repo" commit -q -am "nightshift: a real fix"
SHA="$(git -C "$TMP/repo" rev-parse HEAD)"
git -C "$TMP/repo" push -q -u origin nightshift/adopted
git -C "$TMP/repo" checkout -q main
$NS -C "$TMP/repo" merge -q --no-ff nightshift/adopted -m "merge: adopted"
git -C "$TMP/repo" push -q origin main

# The ledger exists but knows nothing about that branch (a finding row has no branch, so the
# reconcile loop skips it — it is here only so harvest does not exit early on a missing ledger).
jq -nc --arg repo "$TMP/repo" \
  '{night:"2026-07-13",item:"i0",repo:$repo,fingerprint:($repo+":x:L1"),
    branch:null,sha:null,outcome:"finding",summary:"unrelated",pr_url:null,schema_version:2}' > "$LEDGER"

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

run() { STATE_DIR="$TMP/state" LEDGER="$LEDGER" RULEBOOK="$TMP/rulebook.yaml" bash "$ROOT/bin/harvest.sh"; }

run > "$TMP/out1" 2>&1 || { echo "harvest 1 failed" >&2; cat "$TMP/out1" >&2; exit 1; }
grep -q "(adopted -> shipped)" "$TMP/out1" \
  || { echo "orphan was not adopted" >&2; cat "$TMP/out1" >&2; exit 1; }

run > "$TMP/out2" 2>&1 || { echo "harvest 2 failed" >&2; cat "$TMP/out2" >&2; exit 1; }

v="$(jq -sc --arg b nightshift/adopted \
  '[.[]|select(.outcome=="verdict" and .branch==$b)]|last // {}' "$LEDGER")"
[ "$(jq -r '.verdict // ""' <<<"$v")" = merged ] || {
  echo "adopted+merged branch got verdict '$(jq -r '.verdict // "<none>"' <<<"$v")', expected merged" >&2
  echo "row: $v" >&2; cat "$TMP/out2" >&2; exit 1; }

# Field positions, the actual failure mode: a shift put the branch name in fingerprint and the
# sha in branch, so a row can carry the right verdict only by carrying the right fields.
[ "$(jq -r '.sha // ""' <<<"$v")" = "$SHA" ] \
  || { echo "verdict row lost the sha (fields shifted?): $v" >&2; exit 1; }
[ "$(jq -r '.fingerprint // "null"' <<<"$v")" = null ] \
  || { echo "adopted row has no fingerprint; verdict must keep it null, got: $v" >&2; exit 1; }

echo "test-harvest-adopted-verdict: ok"
