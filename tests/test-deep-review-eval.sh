#!/usr/bin/env bash
set -euo pipefail

# The paid eval is opt-in; CI still owns its deterministic scorer, frozen cases, and threshold.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The frozen cases below are git objects, not copied fixtures. Keep CI on a full checkout and fail
# with the real configuration error instead of a misleading "not a valid object" from cat-file.
grep -Eq '^[[:space:]]+fetch-depth:[[:space:]]+0$' "$ROOT/.github/workflows/ci.yml" || {
  echo "test-deep-review-eval: CI checkout must use fetch-depth: 0 for historical cases" >&2
  exit 1
}

for commit in $(jq -r '.[].commit' "$ROOT/evals/deep-review/cases.json"); do
  git -C "$ROOT" cat-file -e "$commit^{commit}"
done

write_result() { # name summary
  mkdir -p "$TMP/$1"
  jq -n --arg name "$1" --arg summary "$2" \
    '{name:$name,recon_usage:{cost_usd:0},explore_usage:{cost_usd:0},
      finding:{findings:[{summary:$summary}]}}' > "$TMP/$1/result.json"
}
write_result unknown_mode   "A typo mode is silently skipped"
write_result malformed_json "extract_json turns malformed output into a clean empty verdict"
write_result suite_mutation  "The test mutates the worktree, so a different tree ships"
write_result dry_run         "dry-run changes live state"
python3 "$ROOT/evals/deep-review/score.py" "$TMP" >/dev/null
jq -e '.pass == true and .hit_at_3 == 4' "$TMP/score.json" >/dev/null

# Two misses are below the frozen 3/4 gate.
write_result suite_mutation "unrelated finding"
write_result dry_run "unrelated finding"
if python3 "$ROOT/evals/deep-review/score.py" "$TMP" >/dev/null 2>&1; then
  echo "test-deep-review-eval: scorer passed below 3/4" >&2; exit 1
fi
jq -e '.pass == false and .hit_at_3 == 2' "$TMP/score.json" >/dev/null

echo "test-deep-review-eval: ok"
