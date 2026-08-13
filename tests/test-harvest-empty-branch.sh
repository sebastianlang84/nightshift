#!/usr/bin/env bash
set -euo pipefail

# A branch that never received a nightshift commit still points at the base commit it was cut from.
# That sha is trivially an ancestor of base, so the ancestor test called it `merged` — a merge that
# never happened, counted into the merge-rate, and the ONE verdict that outranks a human's, so it
# silently reversed a `dropped` an operator had recorded. reconcile must read a foreign sha as
# "nothing was delivered" instead. A real nightshift commit that DID land must still read `merged`.
# (Observed 2026-08-02 on partflow: a pre-commit hook rejected the commit, the empty branch shipped.)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LEDGER="$TMP/ledger.jsonl"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
c() { git -C "$TMP/repo" -c user.name="$1" -c user.email="$2" "${@:3}"; }

printf 'base\n' > "$TMP/repo/f.txt"
c human human@example.com add -A
c human human@example.com commit -q -m "base commit"
base_sha="$(git -C "$TMP/repo" rev-parse HEAD)"
git -C "$TMP/repo" push -q -u origin main

# (a) The empty branch: finalize's commit was rejected, so the branch stayed on the base commit.
git -C "$TMP/repo" branch "nightshift/empty" "$base_sha"
git -C "$TMP/repo" push -q origin "nightshift/empty"

# (b) A genuine nightshift branch whose commit really did land on main.
git -C "$TMP/repo" checkout -q -b "nightshift/real"
printf 'fixed\n' > "$TMP/repo/f.txt"
c nightshift nightshift@localhost add -A
c nightshift nightshift@localhost commit -q -m "nightshift: a real change"
real_sha="$(git -C "$TMP/repo" rev-parse HEAD)"
git -C "$TMP/repo" push -q origin "nightshift/real"
git -C "$TMP/repo" checkout -q main
c human human@example.com merge -q --no-ff --no-edit "nightshift/real"
git -C "$TMP/repo" push -q origin main

# main advances afterwards, exactly as a busy repo's does
printf 'later\n' >> "$TMP/repo/f.txt"
c human human@example.com add -A
c human human@example.com commit -q -m "later work"
git -C "$TMP/repo" push -q origin main

ship() { # branch sha
  jq -nc --arg b "$1" --arg s "$2" --arg r "$TMP/repo" \
    '{night:"2026-08-02",item:("i-"+$b),repo:$r,fingerprint:($b+":x"),branch:$b,sha:$s,
      outcome:"shipped",pr_url:null,schema_version:2}' >> "$LEDGER"
}
ship "nightshift/empty" "$base_sha"
ship "nightshift/real"  "$real_sha"

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
repos:
  - path: $TMP/repo
    mode: branch-fix
    test_cmd: true
    base: main
EOF

run() { STATE_DIR="$TMP" LEDGER="$LEDGER" RULEBOOK="$TMP/rulebook.yaml" bash "$ROOT/bin/harvest.sh" "$@"; }

# 1. An operator's `dropped` on the empty branch must SURVIVE reconciliation.
run verdict "nightshift/empty" dropped "empty branch" >/dev/null
run >"$TMP/out" 2>&1 || { echo "harvest failed" >&2; cat "$TMP/out" >&2; exit 1; }

verdict_of() { # branch -> last recorded verdict
  jq -rs --arg b "$1" '[.[]|select(.outcome=="verdict" and .branch==$b)]|last|.verdict // "—"' "$LEDGER"
}

got="$(verdict_of nightshift/empty)"
[ "$got" = dropped ] || {
  echo "empty branch reconciled to '$got', expected 'dropped'" >&2; cat "$TMP/out" >&2; exit 1; }

# 2. The genuine merged branch must still be recognised — the guard must not blind the ladder.
got="$(verdict_of nightshift/real)"
[ "$got" = merged ] || {
  echo "real merged branch reconciled to '$got', expected 'merged'" >&2; cat "$TMP/out" >&2; exit 1; }

# 3. …and it holds across a second run (no oscillation between the two verdicts).
run >/dev/null 2>&1
[ "$(verdict_of nightshift/empty)" = dropped ] \
  || { echo "empty branch flipped on the second harvest" >&2; exit 1; }
[ "$(verdict_of nightshift/real)" = merged ] \
  || { echo "real branch flipped on the second harvest" >&2; exit 1; }

echo "test-harvest-empty-branch: ok"
