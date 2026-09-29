#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# ADR 0027 — the reviewed tree is what ships, including past a hook that PASSES.
# finalize commits with the target repo's own hooks active (ADR 0022). A pre-commit hook that
# exits 0 but stages a file of its own (a formatter, a generated manifest) changes the commit
# after review and the test gate are done. Pushing it would ship a tree nobody reviewed. So the
# commit's tree is compared with the recorded reviewed tree, and a mismatch is refused as
# `commit-failed`: no remote branch, no local branch, no `shipped` row.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-finalize-hook-modified-tree: $*" >&2; exit 1; }

night() { # dir hook-name hook-body — one mock night against a repo carrying that one hook
  local d="$1" hook="$2" body="$3"
  mkdir -p "$d/state" "$d/runs" "$d/digests" "$d/worktrees"
  git init -q --bare "$d/remote.git"
  git init -q -b main "$d/repo"
  git -C "$d/repo" remote add origin "$d/remote.git"
  printf '# Demo\n\nThis is teh demo.\n' > "$d/repo/README.md"
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost add -A
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
  git -C "$d/repo" push -q -u origin main
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$d/repo/.git/hooks/$hook"
  chmod +x "$d/repo/.git/hooks/$hook"
  cat > "$d/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
recon:
  enabled: false
dimensions:
  - docs
repos:
  - path: $d/repo
    mode: branch-fix
    test_cmd: true
    base: main
EOF
  RULEBOOK="$d/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$d/state" NIGHTSHIFT_RUNS_DIR="$d/runs" \
  NIGHTSHIFT_DIGEST_DIR="$d/digests" NIGHTSHIFT_WORKTREES="$d/worktrees" \
    "$ROOT/bin/nightshift.sh" >"$d/out" 2>"$d/err"
}
outcomes() { jq -sc '[.[]|select(.outcome!=null and .outcome!="verdict")|.outcome]' "$1/state/ledger.jsonl"; }
remote_branches() { git -C "$1/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*'; }

# (1) The hook passes and stages an extra file: refused, recorded, cleaned up.
d="$TMP/stages"
night "$d" pre-commit 'echo formatted > HOOK_EXTRA && git add HOOK_EXTRA'
[ "$(outcomes "$d")" = '["commit-failed"]' ] \
  || { cat "$d/err" >&2; fail "(1) expected one commit-failed row, got $(outcomes "$d")"; }
jq -se '[.[]|select(.outcome=="commit-failed")][0]|.branch==null and .sha==null' "$d/state/ledger.jsonl" >/dev/null \
  || fail "(1) the commit-failed row names a branch/sha that was never pushed"
[ -z "$(remote_branches "$d")" ] || fail "(1) a commit the hook changed reached the remote"
git -C "$d/repo" branch --list 'nightshift/*' | grep -q . && fail "(1) local nightshift/* branch left behind"
grep -q "hooks changed the commit — it is not the reviewed tree" "$d/err" \
  || { cat "$d/err" >&2; fail "(1) refusal not logged"; }
grep -q "hook changed: A	HOOK_EXTRA" "$d/err" || fail "(1) the log does not name the path the hook added"
# No retry: the hook passed, so there is no refusal the Fix stage could answer.
[ "$(jq -s '[.[]|select(.stage=="fix")]|length' "$d/state/runs.jsonl")" = 1 ] \
  || fail "(1) a hook-modified commit bought a Fix retry"

# (2) A post-commit hook leaves HEAD on the reviewed commit but points the BRANCH at another one.
#     finalize pushes the branch, so checking HEAD alone would let that commit out.
d="$TMP/moves-branch"
night "$d" post-commit '
b=$(git symbolic-ref -q HEAD) || exit 0
orig=$(git rev-parse HEAD)
git checkout -q --detach
echo planted > HOOK_EXTRA && git add HOOK_EXTRA
git -c user.name=h -c user.email=h@localhost commit -q --no-verify -m planted
git update-ref "$b" "$(git rev-parse HEAD)"
git checkout -q --detach "$orig"'
[ "$(outcomes "$d")" = '["commit-failed"]' ] \
  || { cat "$d/err" >&2; fail "(2) a branch the hook moved was not refused: $(outcomes "$d")"; }
# Refused for THIS reason: the hook's planted file is what the log names, not some other failure.
grep -q "hook changed: A	HOOK_EXTRA" "$d/err" \
  || { cat "$d/err" >&2; fail "(2) refused, but not because the hook moved the branch"; }
[ -z "$(remote_branches "$d")" ] || fail "(2) the commit the hook planted reached the remote"
git -C "$d/repo" branch --list 'nightshift/*' | grep -q . && fail "(2) local nightshift/* branch left behind"

# (3) Control: a hook that passes WITHOUT touching the commit still ships — the check must not
#     accuse an honest commit — and the remote branch carries exactly the reviewed tree.
d="$TMP/clean"
night "$d" pre-commit 'exit 0'
[ "$(outcomes "$d")" = '["shipped"]' ] \
  || { cat "$d/err" >&2; fail "(3) an untouched commit did not ship: $(outcomes "$d")"; }
rb="$(remote_branches "$d")"
[ -n "$rb" ] || fail "(3) shipped row but no remote branch"
rt="$(find "$d/runs" -name reviewed-tree | head -1)"
[ -n "$rt" ] || fail "(3) no reviewed-tree record found"
[ "$(git -C "$d/remote.git" rev-parse "$rb^{tree}")" = "$(cat "$rt")" ] \
  || fail "(3) the pushed tree is not the reviewed tree"

echo "test-finalize-hook-modified-tree: ok"
