#!/usr/bin/env bash
set -euo pipefail

# The open-branch cap counts DECISIONS STILL PENDING, not merely unmerged refs.
#
# `git branch -r --no-merged <base>` answers "is the sha an ancestor of base" — the same naive
# test ADR 0016 already replaced inside harvest's reconcile ladder, and it is wrong in both
# directions once a ref outlives the decision it belongs to:
#   * a rejected branch (PR closed, ref never deleted) is a verdict, not a pending decision, yet
#     it held a slot forever — on 2026-08-13 one such branch had the fleet at 4/4 for three
#     nights running, each night logging "0 shipped, 0 considered";
#   * a squash/rebase merge never makes the sha an ancestor of base (ADR 0016 §1/§2), so a
#     surviving ref counted as open although the change demonstrably landed.
# The ledger already holds harvest's authoritative verdict for both. The cap must read it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

# Four branches on origin, every one of them genuinely unmerged into main, so `--no-merged`
# alone would report 4. Only their ledger verdicts tell them apart.
for b in pending rejected squashed reopened; do
  git -C "$TMP/repo" checkout -q -b "nightshift/$b" main
  printf 'change for %s\n' "$b" > "$TMP/repo/$b.txt"
  git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add -A
  git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m "fix($b)"
  git -C "$TMP/repo" push -q origin "nightshift/$b"
done
git -C "$TMP/repo" checkout -q main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 4
recon:
  enabled: false
dimensions:
  - docs
repos:
  - path: $TMP/repo
    mode: branch-fix
    base: main
EOF

# `pending` deliberately has NO verdict row — the one branch actually awaiting a decision.
# `reopened` was dropped and then reopened: the LATEST verdict wins, so it counts again.
verdict() { # branch verdict ts
  jq -nc --arg r "$TMP/repo" --arg b "nightshift/$1" --arg v "$2" --arg ts "$3" \
    '{night:"2026-08-13", item:"item-x", repo:$r, fingerprint:"f", branch:$b,
      sha:"deadbeef", outcome:"verdict", verdict:$v, ts:$ts, schema_version:2}' \
    >> "$TMP/state/ledger.jsonl"
}
verdict rejected dropped 2026-08-10T04:00:00+02:00
verdict squashed merged  2026-08-10T04:00:00+02:00
verdict reopened dropped 2026-08-10T04:00:00+02:00
verdict reopened open     2026-08-12T04:00:00+02:00

export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
       NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
       RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_SOURCED=1
# shellcheck disable=SC1090
source "$ROOT/bin/nightshift.sh"
load_rulebook

# Sanity: without the verdicts the naive count really is 4 — otherwise this test proves nothing.
SETTLED_BRANCHES=""
naive=$(open_branch_count)
[ "$naive" = 4 ] || { echo "expected 4 unmerged refs before verdicts are read, got '$naive'" >&2; exit 1; }

refresh_settled_branches
open=$(open_branch_count)
[ "$open" = 2 ] \
  || { echo "cap counted '$open' branches, expected 2 (pending + reopened)" >&2
       echo "settled: $SETTLED_BRANCHES" >&2; exit 1; }

branch_is_settled "$TMP/repo" nightshift/rejected \
  || { echo "a rejected branch must not hold a slot" >&2; exit 1; }
branch_is_settled "$TMP/repo" nightshift/squashed \
  || { echo "a squash-merged branch must not hold a slot" >&2; exit 1; }
! branch_is_settled "$TMP/repo" nightshift/pending \
  || { echo "a branch with no verdict is still awaiting one" >&2; exit 1; }
! branch_is_settled "$TMP/repo" nightshift/reopened \
  || { echo "the latest verdict must win — reopened is pending again" >&2; exit 1; }

# A verdict for the same branch NAME in another repo must not free this repo's slot.
! branch_is_settled "$TMP/other" nightshift/rejected \
  || { echo "verdicts leaked across repos" >&2; exit 1; }

# No ledger at all (first ever night) degrades to the naive count rather than failing.
mv "$TMP/state/ledger.jsonl" "$TMP/ledger.bak"
refresh_settled_branches
[ -z "$SETTLED_BRANCHES" ] || { echo "expected no settled branches without a ledger" >&2; exit 1; }
[ "$(open_branch_count)" = 4 ] || { echo "ledgerless run must fall back to counting refs" >&2; exit 1; }

echo "test-open-branch-cap-verdicts: ok"
