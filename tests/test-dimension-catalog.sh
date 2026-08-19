#!/usr/bin/env bash
set -euo pipefail

# The dimension catalog has four representations: the operator template, one prompt per lens,
# Recon's required output, and the Runner's no-dimensions fallback. Drift used to be invisible:
# a new prompt could exist but never rotate, or Recon could omit a configured lens and silently
# give it the neutral weight. Keep the catalog closed and equal at every boundary.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expected=(correctness security infra docs tests perf ui-ux deps bloat craft)
mapfile -t configured < <(
  python3 "$ROOT/lib/parse_rulebook.py" "$ROOT/rulebook.example.yaml" |
    awk -F '\t' '$1=="dimension" {print $2}'
)
[ "${configured[*]}" = "${expected[*]}" ] || {
  echo "dimension template drift: got '${configured[*]}'" >&2; exit 1;
}

mapfile -t prompt_files < <(
  find "$ROOT/prompts/dimensions" -maxdepth 1 -type f -name '*.md' -printf '%f\n' |
    sed 's/\.md$//' | sort
)
mapfile -t expected_sorted < <(printf '%s\n' "${expected[@]}" | sort)
[ "${prompt_files[*]}" = "${expected_sorted[*]}" ] || {
  echo "dimension prompt catalog drift: got '${prompt_files[*]}'" >&2; exit 1;
}

for dim in "${expected[@]}"; do
  grep -q -- "^- $dim —" "$ROOT/prompts/recon.md" || {
    echo "recon does not describe dimension '$dim'" >&2; exit 1;
  }
  grep -q -- "\"$dim\":" "$ROOT/prompts/recon.md" || {
    echo "recon output contract omits dimension '$dim'" >&2; exit 1;
  }
done

cat > "$TMP/rulebook.yaml" <<EOF
repos:
  - path: $TMP/repo
    mode: findings-only
EOF
mkdir -p "$TMP/repo" "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"
export RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_STATE_DIR="$TMP/state" \
  NIGHTSHIFT_RUNS_DIR="$TMP/runs" NIGHTSHIFT_DIGEST_DIR="$TMP/digests" \
  NIGHTSHIFT_WORKTREES="$TMP/worktrees"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
load_rulebook
[ "${DIMENSIONS[*]}" = "${expected[*]}" ] || {
  echo "runner fallback drift: got '${DIMENSIONS[*]}'" >&2; exit 1;
}

mkdir -p "$TMP/item"
printf '%s\n' '{"languages":["py"]}' > "$TMP/item/signals.json"
mock_recon "$TMP/repo" "$TMP/item"
expected_json="$(printf '%s\n' "${expected[@]}" | jq -R . | jq -sc .)"
jq -e --argjson expected "$expected_json" '
  ((.dimensions | keys | sort) == ($expected | sort)) and
  all(.dimensions[]; (.yield == "high" or .yield == "normal" or .yield == "low")) and
  (.dimensions.bloat.yield == "normal")
' "$TMP/item/recon.json" >/dev/null || {
  echo "mock recon dimension catalog or yield drift" >&2; exit 1;
}

NIGHTSHIFT_DIMENSION=bloat stage_prompt explore "$TMP/repo" "$TMP/item" > "$TMP/explore.prompt"
grep -q "^## Tonight's lens: bloat$" "$TMP/explore.prompt" || {
  echo "explore prompt did not select bloat" >&2; exit 1;
}
grep -q '^## Lens: BLOAT$' "$TMP/explore.prompt" || {
  echo "explore prompt did not inject the bloat lens" >&2; exit 1;
}

echo "test-dimension-catalog: ok"
