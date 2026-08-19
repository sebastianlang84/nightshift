#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASES="$ROOT/evals/deep-review/cases.json"
name="${1:?case name}"
out="${2:?output directory}"
model="${NIGHTSHIFT_EVAL_MODEL:-claude-opus-5}"
budget="${NIGHTSHIFT_EVAL_FINDINGS:-3}"

case_json="$(jq -ce --arg name "$name" '.[] | select(.name==$name)' "$CASES")" || {
  echo "unknown deep-review eval case: $name" >&2; exit 2;
}
commit="$(jq -r '.commit' <<<"$case_json")"
lens="$(jq -r '.lens' <<<"$case_json")"
case_dir="$out/$name"
repo="$case_dir/repo"
state="$case_dir/state"
mkdir -p "$case_dir" "$state" "$case_dir/runs" "$case_dir/digests" "$case_dir/worktrees"

git clone -q --no-hardlinks "$ROOT" "$repo"
git -C "$repo" checkout -q "$commit"

export NIGHTSHIFT_HOME="$ROOT" NIGHTSHIFT_AGENT=claude NIGHTSHIFT_CLAUDE_MODEL="$model"
export NIGHTSHIFT_STATE_DIR="$state" NIGHTSHIFT_RUNS_DIR="$case_dir/runs"
export NIGHTSHIFT_DIGEST_DIR="$case_dir/digests" NIGHTSHIFT_WORKTREES="$case_dir/worktrees"
export NIGHTSHIFT_OPEN_PR=0 NIGHTSHIFT_FINDINGS_N="$budget" NIGHTSHIFT_DIMENSION="$lens"
export RULEBOOK="$ROOT/rulebook.example.yaml"

# shellcheck disable=SC1091
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
MAX_FILES=15
MAX_LINES=400
write_claude_settings
write_codemap_mcp

if command -v codemap >/dev/null 2>&1 \
    && codemap index --approve --repo "$repo" >"$case_dir/codemap.out" 2>"$case_dir/codemap.err"; then
  export NIGHTSHIFT_CODEMAP_REPO="$repo"
else
  unset NIGHTSHIFT_CODEMAP_REPO
fi

recon_id="$case_dir/recon"
mkdir -p "$recon_id"
"$ROOT/lib/recon_signals.sh" "$repo" > "$recon_id/signals.json"
started="$(date +%s)"
claude_run recon "$repo" "$recon_id"
recon_done="$(date +%s)"
export NIGHTSHIFT_RECON_NOTES
NIGHTSHIFT_RECON_NOTES="$(jq -r '.notes // ""' "$recon_id/recon.json")"

explore_id="$case_dir/explore"
mkdir -p "$explore_id"
claude_run explore "$repo" "$explore_id"
python3 "$ROOT/lib/validate_explore.py" "$repo" "$explore_id/finding.json"
finished="$(date +%s)"

jq -n \
  --arg name "$name" --arg commit "$commit" --arg lens "$lens" --arg model "$model" \
  --arg system_commit "$(git -C "$ROOT" rev-parse HEAD)" \
  --arg system_diff_sha "$(git -C "$ROOT" diff | sha256sum | awk '{print $1}')" \
  --argjson findings_budget "$budget" --argjson recon_seconds "$((recon_done-started))" \
  --argjson explore_seconds "$((finished-recon_done))" \
  --slurpfile finding "$explore_id/finding.json" \
  --slurpfile recon_usage "$recon_id/.usage_recon" \
  --slurpfile explore_usage "$explore_id/.usage_explore" \
  '{name:$name,commit:$commit,lens:$lens,model:$model,system_commit:$system_commit,
    system_diff_sha:$system_diff_sha,findings_budget:$findings_budget,
    recon_seconds:$recon_seconds,explore_seconds:$explore_seconds,
    recon_usage:($recon_usage[0]//{}),explore_usage:($explore_usage[0]//{}),
    finding:($finding[0]//{})}' > "$case_dir/result.json"
