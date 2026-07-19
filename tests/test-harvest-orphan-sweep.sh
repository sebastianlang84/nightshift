#!/usr/bin/env bash
set -euo pipefail

# harvest orphan sweep (ADR 0016): a <prefix>* branch on origin with no ledger row is reported
# (it can never receive a verdict yet holds an open-branch cap slot). A branch the ledger knows
# (has a shipped row) is NOT reported as orphan.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state"
LEDGER="$TMP/state/ledger.jsonl"
GC="git -c user.name=test -c user.email=test@localhost"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf 'x\n' > "$TMP/repo/f.txt"
$GC -C "$TMP/repo" add -A && $GC -C "$TMP/repo" commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

mkbranch() { # name
  git -C "$TMP/repo" checkout -q -b "$1" main
  printf '%s\n' "$1" >> "$TMP/repo/f.txt"
  $GC -C "$TMP/repo" commit -q -am "$1"
  git -C "$TMP/repo" push -q -u origin "$1"
  git -C "$TMP/repo" rev-parse HEAD
}
KNOWN_SHA="$(mkbranch nightshift/known)"
mkbranch nightshift/orphan >/dev/null

# only the 'known' branch gets a shipped ledger row
jq -nc --arg repo "$TMP/repo" --arg sha "$KNOWN_SHA" \
  '{night:"2026-07-13",item:"i1",repo:$repo,fingerprint:($repo+":x:L1"),
    branch:"nightshift/known",sha:$sha,outcome:"shipped",pr_url:null,schema_version:2}' >> "$LEDGER"

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

STATE_DIR="$TMP/state" LEDGER="$LEDGER" RULEBOOK="$TMP/rulebook.yaml" \
  bash "$ROOT/bin/harvest.sh" > "$TMP/out" 2>&1 || { echo "harvest failed" >&2; cat "$TMP/out" >&2; exit 1; }

grep -q "orphan nightshift/\* branches on origin" "$TMP/out" \
  || { echo "no orphan section printed" >&2; cat "$TMP/out" >&2; exit 1; }
# the orphan section (from its header to end) must list the orphan and not the known branch
sect="$(sed -n '/orphan nightshift.* branches on origin/,$p' "$TMP/out")"
grep -q "nightshift/orphan" <<<"$sect" || { echo "orphan branch not reported" >&2; cat "$TMP/out" >&2; exit 1; }
grep -q "nightshift/known"  <<<"$sect" && { echo "known branch wrongly reported as orphan" >&2; cat "$TMP/out" >&2; exit 1; }

# --- ADR 0018: the orphan is ADOPTED — a synthetic shipped row now exists for it ---------------
grep -q "(adopted -> shipped)" "$TMP/out" || { echo "orphan not marked adopted" >&2; cat "$TMP/out" >&2; exit 1; }
adopted="$(jq -sc '[.[]|select(.branch=="nightshift/orphan" and .outcome=="shipped" and .adopted==true)]|length' "$LEDGER")"
[ "$adopted" = 1 ] || { echo "expected exactly 1 adopted shipped row for the orphan, got $adopted" >&2; exit 1; }

# idempotent: a second harvest must NOT adopt again (the branch is now in the known set)
STATE_DIR="$TMP/state" LEDGER="$LEDGER" RULEBOOK="$TMP/rulebook.yaml" \
  bash "$ROOT/bin/harvest.sh" > "$TMP/out2" 2>&1 || { echo "2nd harvest failed" >&2; cat "$TMP/out2" >&2; exit 1; }
again="$(jq -sc '[.[]|select(.branch=="nightshift/orphan" and .adopted==true)]|length' "$LEDGER")"
[ "$again" = 1 ] || { echo "adoption not idempotent: $again adopted rows after 2nd run" >&2; exit 1; }
sect2="$(sed -n '/orphan nightshift.* branches on origin/,$p' "$TMP/out2")"
grep -q "nightshift/orphan" <<<"$sect2" && { echo "orphan re-reported after adoption (should be known)" >&2; cat "$TMP/out2" >&2; exit 1; }

# --dry-run reports but writes nothing
mkbranch nightshift/orphan2 >/dev/null
STATE_DIR="$TMP/state" LEDGER="$LEDGER" RULEBOOK="$TMP/rulebook.yaml" \
  bash "$ROOT/bin/harvest.sh" --dry-run > "$TMP/out3" 2>&1 || { echo "dry-run harvest failed" >&2; cat "$TMP/out3" >&2; exit 1; }
grep -q "would adopt" "$TMP/out3" || { echo "dry-run did not report would-adopt" >&2; cat "$TMP/out3" >&2; exit 1; }
w="$(jq -sc '[.[]|select(.branch=="nightshift/orphan2")]|length' "$LEDGER")"
[ "$w" = 0 ] || { echo "dry-run wrote a ledger row for orphan2 ($w) — must be read-only" >&2; exit 1; }

echo "test-harvest-orphan-sweep: ok"
