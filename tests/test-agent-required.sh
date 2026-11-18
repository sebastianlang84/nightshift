#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -qm initial
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
git -C "$TMP/repo" push -qu origin main

cat > "$TMP/rulebook.yaml" <<EOF
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: branch-fix
    base: main
    test_cmd: true
EOF
git --git-dir="$TMP/remote.git" show-ref > "$TMP/before"
export RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_TEST_SANDBOX=none NIGHTSHIFT_OPEN_PR=0
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
if env -u NIGHTSHIFT_AGENT "$ROOT/bin/nightshift.sh" > "$TMP/log" 2>&1; then
  echo 'runner accepted a rulebook with no agent' >&2
  exit 1
fi
grep -q 'no agent configured' "$TMP/log"
git --git-dir="$TMP/remote.git" show-ref > "$TMP/after"
cmp "$TMP/before" "$TMP/after"
[ ! -e "$TMP/state/runs.jsonl" ]

echo 'test-agent-required: ok'
