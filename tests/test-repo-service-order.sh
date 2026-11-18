#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'repos:\n' > "$TMP/rulebook.yaml"
for repo in a-clean b-failed z-never; do
  git init -q "$TMP/$repo"
  printf '  - path: %s/%s\n    mode: findings-only\n' "$TMP" "$repo" >> "$TMP/rulebook.yaml"
done

export RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
load_rulebook
jq -nc --arg root "$TMP" '
  {repo:($root+"/a-clean"), item:"item-1-f1", outcome:"empty", ts:"2026-01-01T01:00:00Z"},
  {repo:($root+"/b-failed"), item:"b", outcome:"gate-blocked", ts:"2026-01-02T01:00:00Z"},
  {repo:($root+"/z-never"), item:"item-1-f10", outcome:"empty", ts:"2026-01-03T01:00:00Z"},
  {repo:($root+"/z-never"), item:"item-1-f10", outcome:"retracted", ts:"2026-01-04T01:00:00Z"},
  {repo:($root+"/z-never"), item:"d", outcome:"verdict", ts:"2026-01-05T01:00:00Z"}
' > "$LEDGER"
# Retracting item-1-f10 must not also void item-1-f1 (exact item match, not substring).
printf '%s\n' "$TMP/z-never" "$TMP/a-clean" "$TMP/b-failed" > "$TMP/expected"
select_order | cut -f1 > "$TMP/order"
diff -u "$TMP/expected" "$TMP/order"

echo 'test-repo-service-order: ok'
