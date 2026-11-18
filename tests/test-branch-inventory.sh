#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "$ROOT/.test-branch-inventory.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=test -c user.email=test@localhost "$@"; }

git init -q --bare -b main "$TMP/origin.git"
git init -q -b main "$TMP/source"
echo root > "$TMP/source/root"
g -C "$TMP/source" add root
g -C "$TMP/source" commit -qm root
root=$(git -C "$TMP/source" rev-parse HEAD)
echo main > "$TMP/source/main.txt"
g -C "$TMP/source" add main.txt
g -C "$TMP/source" commit -qm 'fix: main.txt'
g -C "$TMP/source" branch nightshift/archive/open
g -C "$TMP/source" switch -qc develop "$root"
g -C "$TMP/source" commit -qm 'integrated change' --allow-empty
g -C "$TMP/source" branch nightshift/merged
g -C "$TMP/source" commit -qm 'develop advances' --allow-empty
g -C "$TMP/source" push -q "$TMP/origin.git" --all

repo="$TMP/runner"
git clone -q --depth=1 --single-branch -b main "file://$TMP/origin.git" "$repo"
git -C "$repo" tag origin/nightshift/archive/open HEAD
git -C "$repo" config --add remote.origin.fetch '^refs/heads/nightshift/archive/*'
git -C "$repo" config --add remote.origin.fetch '^refs/heads/develop'

export RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_STATE_DIR="$TMP/state" \
       NIGHTSHIFT_RUNS_DIR="$TMP/runs" NIGHTSHIFT_DIGEST_DIR="$TMP/digests" \
       NIGHTSHIFT_WORKTREES="$TMP/worktrees" NIGHTSHIFT_MERGE_STATE="$TMP/merge.json"
mkdir -p "$NIGHTSHIFT_STATE_DIR"
cat > "$RULEBOOK" <<YAML
repos:
  - path: $repo
    base: develop
    mode: branch-fix
    test_cmd: true
YAML
for branch in archive/open merged; do
  sha=$(git -C "$TMP/source" rev-parse "refs/heads/nightshift/$branch")
  jq -nc --arg night "$(date +%F)" --arg repo "$repo" --arg branch "nightshift/$branch" \
    --arg sha "$sha" '{night:$night, repo:$repo, item:$branch, branch:$branch,
                        sha:$sha, summary:$branch, outcome:"shipped"}'
done > "$NIGHTSHIFT_STATE_DIR/ledger.jsonl"

cap_count() (
  NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
  load_rulebook
  refresh_open_branch_refs || return
  open_branch_count
)
review() { "$ROOT/bin/review-branch.sh" "$repo" "$@"; }
status() { "$ROOT/bin/status.sh" "$@"; }
expect() { grep -Fq -- "$1" <<<"$2" || { printf 'missing %s\n%s\n' "$1" "$2" >&2; exit 1; }; }
refuse() {
  if "$@"; then
    printf 'unexpected success: %s\n' "$*" >&2
    exit 1
  fi
}
reject() { refuse grep -Fq -- "$1" <<<"$2"; }

[ "$(git -C "$repo" rev-parse --is-shallow-repository)" = true ]
out=$(status --no-fetch)
expect '| fix | nightshift/merged | unknown' "$out"
[ "$(cap_count)" = 1 ]
[ "$(git -C "$repo" rev-parse --is-shallow-repository)" = false ]
git -C "$repo" update-ref -d refs/remotes/origin/nightshift/archive/open
out=$(status --no-fetch)
expect '| fix | nightshift/archive/open | unknown: branch missing from local refs |' "$out"
out=$(review)
expect 'nightshift/archive/open' "$out"
reject 'nightshift/merged' "$out"
out=$(review origin/nightshift/archive/open)
expect 'base: origin/develop' "$out"
expect 'open a PR: nightshift/archive/open -> develop' "$out"
reject 'ALREADY MERGED' "$out"
out=$(review nightshift/merged)
expect 'ALREADY MERGED' "$out"
out=$(status)
expect '| fix | nightshift/archive/open | open, not yet reviewed |' "$out"
expect '| fix | nightshift/merged | merged |' "$out"
expect 'nightshift/merged on origin is merged but not deleted' "$out"

# A default-branch rename on origin can leave the clone's cached origin/HEAD stale.
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/develop
cp "$RULEBOOK" "$TMP/configured.yaml"
sed -i '/base: develop/d' "$RULEBOOK"
[ "$(cap_count)" = 1 ]
out=$(review nightshift/archive/open)
expect 'base: origin/develop' "$out"
reject 'ALREADY MERGED' "$out"
out=$(status)
expect '| fix | nightshift/archive/open | open, not yet reviewed |' "$out"
out=$(status --no-fetch)
expect '| fix | nightshift/archive/open | unknown' "$out"

# The narrow clone still fetches main ordinarily. Its deletion must not block the live inventory.
g -C "$TMP/source" push -q "$TMP/origin.git" --delete main
[ "$(cap_count)" = 1 ]
out=$(review nightshift/archive/open)
expect 'base: origin/develop' "$out"
g -C "$TMP/source" push -q "$TMP/origin.git" main

# Tracking refs cannot represent a branch and its descendant at the same time.
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main/stable
g -C "$TMP/source" push -q "$TMP/origin.git" --delete main
g -C "$TMP/source" push -q "$TMP/origin.git" develop:refs/heads/main/stable
[ "$(cap_count)" = 1 ]
out=$(review nightshift/archive/open)
expect 'base: origin/main/stable' "$out"
refuse git -C "$repo" show-ref --verify --quiet refs/remotes/origin/main
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
g -C "$TMP/source" push -q "$TMP/origin.git" --delete main/stable
g -C "$TMP/source" push -q "$TMP/origin.git" main
[ "$(cap_count)" = 1 ]
refuse git -C "$repo" show-ref --verify --quiet refs/remotes/origin/main/stable
cp "$RULEBOOK" "$TMP/missing-child.yaml"
printf '    base: main/stable\n' >> "$TMP/missing-child.yaml"
RULEBOOK="$TMP/missing-child.yaml" refuse cap_count
git -C "$repo" show-ref --verify --quiet refs/remotes/origin/main

# A detached origin HEAD does not identify a branch for merge or delete decisions.
git -C "$TMP/origin.git" update-ref --no-deref HEAD "$(git -C "$TMP/source" rev-parse develop)"
refuse cap_count
if out=$(review nightshift/archive/open); then
  echo 'review guessed a base for a detached origin HEAD' >&2
  exit 1
fi
expect 'VERDICT: UNKNOWN' "$out"
reject 'next:' "$out"
mv "$TMP/configured.yaml" "$RULEBOOK"
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main

# The negative local refspec must not prevent pruning an archive branch.
g -C "$TMP/source" push -q "$TMP/origin.git" --delete nightshift/archive/open
[ "$(cap_count)" = 0 ]
refuse git -C "$repo" show-ref --verify --quiet refs/remotes/origin/nightshift/archive/open
out=$(status)
expect '| fix | nightshift/archive/open | branch gone, not merged |' "$out"

# A stale tracking ref must never substitute for a deleted configured base.
g -C "$TMP/source" push -q "$TMP/origin.git" --delete develop
refuse cap_count
if out=$(review nightshift/merged); then
  echo 'review accepted a missing configured base' >&2
  exit 1
fi
expect 'VERDICT: UNKNOWN' "$out"
reject 'ALREADY MERGED' "$out"
reject 'next:' "$out"
out=$(status)
expect '| fix | nightshift/merged | unknown' "$out"
reject 'nightshift/merged on origin is merged' "$out"

# The real runner must stop at the cap and preserve the ledger when harvest cannot refresh.
cp "$NIGHTSHIFT_STATE_DIR/ledger.jsonl" "$TMP/before"
rc=0
NIGHTSHIFT_AGENT=mock NIGHTSHIFT_OPEN_PR=0 "$ROOT/bin/nightshift.sh" >"$TMP/run.out" 2>&1 || rc=$?
[ "$rc" -eq 4 ] || { tail -20 "$TMP/run.out" >&2; exit 1; }
expect 'night ABORTED: open branch inventory unavailable' "$(tail -8 "$TMP/run.out")"
cmp "$TMP/before" "$NIGHTSHIFT_STATE_DIR/ledger.jsonl"

# A shallow origin can advertise a newer ref whose shallow boundary the full clone lacks.
# The previous tracking tip was contained in develop but the new one is not.
g -C "$TMP/source" push -q "$TMP/origin.git" develop
g -C "$TMP/source" switch -q nightshift/merged
g -C "$TMP/source" commit -qm newer --allow-empty
g -C "$TMP/source" push -q "$TMP/origin.git" nightshift/merged
git clone -q --bare --depth=1 --no-single-branch "file://$TMP/origin.git" "$TMP/shallow.git"
git -C "$repo" remote set-url origin "file://$TMP/shallow.git"
if out=$(review nightshift/merged); then
  echo 'review accepted incomplete history from a shallow origin' >&2
  exit 1
fi
expect 'VERDICT: UNKNOWN' "$out"
reject 'ALREADY MERGED' "$out"

echo 'test-branch-inventory: ok'
