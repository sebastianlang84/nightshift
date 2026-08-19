#!/usr/bin/env bash
set -euo pipefail

# Recon must inspect the same configured base that Explore branches from. Auto-detecting main while
# a repo declares develop gives the expensive stage a different codebase and caches that mismatch.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf 'main\n' > "$TMP/repo/base.txt"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add base.txt
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m main
git -C "$TMP/repo" push -q -u origin main
git -C "$TMP/repo" switch -q -c develop
printf 'develop\n' > "$TMP/repo/base.txt"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -qam develop
git -C "$TMP/repo" push -q -u origin develop
git -C "$TMP/repo" switch -q main

cat > "$TMP/rulebook.yaml" <<EOF
recon:
  enabled: true
repos:
  - path: $TMP/repo
    mode: findings-only
    base: develop
EOF

export RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_STATE_DIR="$TMP/state" \
  NIGHTSHIFT_RUNS_DIR="$TMP/runs" NIGHTSHIFT_DIGEST_DIR="$TMP/digests" \
  NIGHTSHIFT_WORKTREES="$TMP/worktrees"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
load_rulebook

# Capture the actual detached worktree HEAD while preserving the result shape ensure_recon expects.
run_agent() {
  local stage="$1" wd="$2" id="$3"
  [ "$stage" = recon ] || return 1
  git -C "$wd" rev-parse HEAD > "$TMP/seen-head"
  jq -n '{dimensions:{correctness:{yield:"normal",hint:"test"}},notes:"test"}' > "$id/recon.json"
}

ensure_recon "$TMP/repo"
expected="$(git -C "$TMP/repo" rev-parse origin/develop)"
[ "$(cat "$TMP/seen-head")" = "$expected" ] || {
  echo "test-recon-configured-base: Recon did not inspect configured base" >&2; exit 1;
}
jq -e --arg head "$expected" '.head == $head' "$(recon_cache_path "$TMP/repo")" >/dev/null || {
  echo "test-recon-configured-base: cache invalidation tracks the wrong HEAD" >&2; exit 1;
}

echo "test-recon-configured-base: ok"
