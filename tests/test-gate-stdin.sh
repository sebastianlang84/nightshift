#!/usr/bin/env bash
set -euo pipefail

# The outer fleet loop feeds select_order through stdin. A repo test that reads stdin must see EOF,
# not consume the next repo row and silently truncate the night.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/item"

git init -q "$TMP/repo"
printf 'demo\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" worktree add -q --detach "$TMP/wt" HEAD

cat > "$TMP/rulebook.yaml" <<EOF
limits:
  test_timeout_seconds: 10
repos:
  - path: $TMP/repo
    mode: branch-fix
    test_cmd: if IFS= read -r stolen; then echo "stole:\$stolen"; exit 91; fi
EOF

export RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_TEST_SANDBOX=none \
  NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
load_rulebook

run_test_gate "$TMP/repo" "$TMP/wt" "$TMP/item" < <(printf 'next-repo\tbranch-fix\tmain\n') || {
  cat "$TMP/item/tests.log" >&2
  echo "test-gate-stdin: suite inherited and consumed the fleet input" >&2
  exit 1
}

echo "test-gate-stdin: ok"
