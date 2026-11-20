#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# harvest tells a Runner commit from a base commit by its author mail (reconcile step 1). git lets
# an exported GIT_AUTHOR_*/GIT_COMMITTER_* outrank `-c user.*`, so an operator environment that
# exports them would make finalize commit under a foreign identity, and harvest would then read the
# merged fix as `dropped`. finalize must commit as nightshift whatever the Runner's environment says.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-commit-identity: $*" >&2; exit 1; }

git init -q --bare "$TMP/remote.git"
git init -q --template= -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
h() { git -C "$TMP/repo" -c user.name=human -c user.email=human@example.com "$@"; }
h add -A
h commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"
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
    test_cmd: true
    base: main
EOF

GIT_AUTHOR_NAME=someone GIT_AUTHOR_EMAIL=someone@else \
GIT_COMMITTER_NAME=someone GIT_COMMITTER_EMAIL=someone@else \
RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err" >&2; fail "night run failed"; }

LEDGER="$TMP/state/ledger.jsonl"
jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1 \
  || { jq -c . "$LEDGER" >&2; fail "nothing shipped"; }
branch="$(git -C "$TMP/remote.git" for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*' | head -1)"
[ -n "$branch" ] || fail "no nightshift/* branch on the remote"
ident="$(git -C "$TMP/remote.git" log -1 --format='%an <%ae> / %cn <%ce>' "$branch")"
[ "$ident" = "nightshift <nightshift@localhost> / nightshift <nightshift@localhost>" ] \
  || fail "the Runner committed as '$ident'"

# A human merges the branch; harvest must recognise the Runner's commit in main as `merged`.
git -C "$TMP/repo" fetch -q origin
h merge -q --no-ff --no-edit "origin/$branch"
git -C "$TMP/repo" push -q origin main
STATE_DIR="$TMP/state" LEDGER="$LEDGER" RULEBOOK="$TMP/rulebook.yaml" \
  bash "$ROOT/bin/harvest.sh" >"$TMP/harvest" 2>&1 || { cat "$TMP/harvest" >&2; fail "harvest failed"; }
got="$(jq -rs --arg b "$branch" '[.[]|select(.outcome=="verdict" and .branch==$b)]|last|.verdict // "-"' "$LEDGER")"
[ "$got" = merged ] || { cat "$TMP/harvest" >&2; fail "harvest recorded '$got' for the merged branch, expected 'merged'"; }

echo "test-commit-identity: ok"
