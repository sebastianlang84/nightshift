#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# bin/status.sh answers "what did nightshift find or change, how far did each item get, and what
# is left lying around" from the ledger, the merge job's state and git — not from memory.
# Asserted: a merged fix, a fix the merge job reviewed but could not merge (with its kb task), an
# open finding, a branch merged but not deleted on origin, a clean merged worktree and a stash.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=test -c user.email=test@localhost "$@"; }

R="$TMP/repo"
git init -q --bare "$TMP/repo.git"
git init -q -b main "$R"
git -C "$R" remote add origin "$TMP/repo.git"
echo one > "$R/a.txt"; g -C "$R" add a.txt; g -C "$R" commit -q -m initial
git -C "$R" push -q -u origin main
git -C "$R" remote set-head origin main

# nightshift/merged: merged into main, but still on origin.
g -C "$R" switch -q -c nightshift/merged
echo two >> "$R/a.txt"; g -C "$R" commit -q -am merged
merged_sha=$(git -C "$R" rev-parse HEAD)
git -C "$R" push -q origin nightshift/merged
g -C "$R" switch -q main
g -C "$R" merge -q --no-ff -m "merge" nightshift/merged
git -C "$R" push -q origin main
git -C "$R" branch -q -D nightshift/merged

# nightshift/open: reviewed by the merge job, conflict, kb task 9.
g -C "$R" switch -q -c nightshift/open main~1
echo three > "$R/b.txt"; g -C "$R" add b.txt; g -C "$R" commit -q -m open
open_sha=$(git -C "$R" rev-parse HEAD)
git -C "$R" push -q origin nightshift/open
g -C "$R" switch -q main
git -C "$R" branch -q -D nightshift/open

# A clean worktree whose commit main already contains, one holding only an ignored file (a removal
# would lose it, so it is not "clean"), and one stash entry.
git -C "$R" worktree add -q --detach "$TMP/wt" main
git -C "$R" worktree add -q --detach "$TMP/wt-env" main
echo '.env' > "$R/.git/info/exclude"; echo SECRET=x > "$TMP/wt-env/.env"
echo dirty >> "$R/a.txt"; g -C "$R" stash -q

today=$(date +%F)
mkdir -p "$TMP/state" "$TMP/worktrees"
{
  printf '{"night":"%s","item":"i1","repo":"%s","branch":"nightshift/merged","sha":"%s","outcome":"shipped","summary":"Fix one"}\n' "$today" "$R" "$merged_sha"
  printf '{"night":"%s","item":"i2","repo":"%s","branch":"nightshift/open","sha":"%s","outcome":"shipped","summary":"Fix two"}\n' "$today" "$R" "$open_sha"
  printf '{"night":"%s","item":"i3","repo":"%s","branch":null,"sha":null,"outcome":"finding","summary":"Finding three"}\n' "$today" "$R"
  printf '{"night":"2020-01-01","item":"i4","repo":"%s","branch":null,"sha":null,"outcome":"finding","summary":"Old finding"}\n' "$R"
  printf '{"night":"2020-01-01","item":"i5","repo":"%s","branch":null,"sha":null,"outcome":"finding","summary":"Old closed"}\n' "$R"
  printf '{"night":"2020-01-02","item":"i5","repo":"%s","branch":null,"sha":null,"outcome":"verdict","verdict":"resolved"}\n' "$R"
} > "$TMP/state/ledger.jsonl"
printf '{"%s\\tnightshift/open":{"kb":"9","result":"conflict","sha":"%s"}}\n' "$R" "$open_sha" > "$TMP/merge.json"
cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
repos:
  - path: $R
    mode: branch-fix
    test_cmd: true
EOF

out=$(RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_STATE_DIR="$TMP/state" \
  NIGHTSHIFT_MERGE_STATE="$TMP/merge.json" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/status.sh")

expect() { grep -qF -- "$1" <<<"$out" || { echo "missing: $1" >&2; echo "$out" >&2; exit 1; }; }
expect "| fix | Fix one | merged |"
expect "| fix | Fix two | reviewed: merge conflict (kb #9) |"
expect "| finding | Finding three | finding open, awaits a decision |"
expect "nightshift/merged on origin is merged but not deleted"
expect "worktree $TMP/wt [detached] is clean and merged"
expect "worktree $TMP/wt-env [detached] is merged; only ignored files remain"
# An item older than the window stays listed while it is open, and drops out once settled.
expect "| finding | Old finding | finding open, awaits a decision |"
if grep -q 'Old closed' <<<"$out"; then echo "a settled old item was listed" >&2; exit 1; fi
expect "repo: 1 stash entries"
if grep -q 'nightshift/open on origin' <<<"$out"; then
  echo "an open branch was reported as clutter" >&2; exit 1
fi

echo "test-status-report: ok"
