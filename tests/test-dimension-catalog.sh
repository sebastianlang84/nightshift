#!/usr/bin/env bash
set -euo pipefail

# Built-in lenses have prompt + Recon + mock representations. The default candidate set is smaller:
# `knowledge` is deliberately opt-in per repo, so ordinary code repos do not eventually spend a pass
# on wiki maintenance merely because Recon's finite low weight keeps every configured lens rotating.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

builtins=(correctness security infra docs tests perf ui-ux deps bloat knowledge craft)
defaults=(correctness security infra docs tests perf ui-ux deps bloat craft)
mapfile -t configured < <(
  python3 "$ROOT/lib/parse_rulebook.py" "$ROOT/rulebook.example.yaml" |
    awk -F '\t' '$1=="dimension" {print $2}'
)
[ "${configured[*]}" = "${defaults[*]}" ] || {
  echo "dimension template drift: got '${configured[*]}'" >&2; exit 1;
}

mapfile -t prompt_files < <(
  find "$ROOT/prompts/dimensions" -maxdepth 1 -type f -name '*.md' -printf '%f\n' |
    sed 's/\.md$//' | sort
)
mapfile -t expected_sorted < <(printf '%s\n' "${builtins[@]}" | sort)
[ "${prompt_files[*]}" = "${expected_sorted[*]}" ] || {
  echo "dimension prompt catalog drift: got '${prompt_files[*]}'" >&2; exit 1;
}

for dim in "${builtins[@]}"; do
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
[ "${DIMENSIONS[*]}" = "${defaults[*]}" ] || {
  echo "runner fallback drift: got '${DIMENSIONS[*]}'" >&2; exit 1;
}

mkdir -p "$TMP/item"
printf '%s\n' '{"languages":["py"],"has_knowledge":true}' > "$TMP/item/signals.json"
mock_recon "$TMP/repo" "$TMP/item"
expected_json="$(printf '%s\n' "${builtins[@]}" | jq -R . | jq -sc .)"
jq -e --argjson expected "$expected_json" '
  ((.dimensions | keys | sort) == ($expected | sort)) and
  all(.dimensions[]; (.yield == "high" or .yield == "normal" or .yield == "low")) and
  (.dimensions.bloat.yield == "normal") and
  (.dimensions.knowledge.yield == "high")
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

git init -q "$TMP/repo"
printf '# Knowledge fixture\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m fixture
python3 "$ROOT/lib/knowledge_probe.py" "$TMP/repo" > "$TMP/item/knowledge-probe.json"
NIGHTSHIFT_DIMENSION=knowledge stage_prompt explore "$TMP/repo" "$TMP/item" > "$TMP/knowledge.prompt"
grep -q "^## Tonight's lens: knowledge$" "$TMP/knowledge.prompt" || {
  echo "explore prompt did not select knowledge" >&2; exit 1;
}
grep -q '^## Lens: KNOWLEDGE$' "$TMP/knowledge.prompt" || {
  echo "explore prompt did not inject the knowledge lens" >&2; exit 1;
}
grep -q '^## knowledge_probe ' "$TMP/knowledge.prompt" || {
  echo "explore prompt did not inject deterministic knowledge evidence" >&2; exit 1;
}

echo "test-dimension-catalog: ok"
