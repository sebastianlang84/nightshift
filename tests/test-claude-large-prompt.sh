#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/item"
git init -q "$TMP/repo"
seq -f 'review fixture line %09g, padded to create a large diff' 5000 > "$TMP/repo/large.txt"
printf '{}\n' > "$TMP/item/finding.json"

cat > "$TMP/bin/claude" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" = -p && "$2" = --output-format ]]
cat > "$CAPTURED_PROMPT"
printf '%s\n' '{"type":"result","result":"{\"verdict\":\"ship\"}"}'
CLI
chmod +x "$TMP/bin/claude"

export PATH="$TMP/bin:$PATH" CAPTURED_PROMPT="$TMP/received" NIGHTSHIFT_AGENT=claude
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
stage_prompt review "$TMP/repo" "$TMP/item" > "$TMP/expected"
[ "$(wc -c < "$TMP/expected")" -gt 204800 ]
run_agent review "$TMP/repo" "$TMP/item"
cmp "$TMP/expected" "$TMP/received"
[ "$AGENT_LAST_WALLED" -eq 0 ]
jq -e '.stage == "review" and .exit == 0' "$RUNSLOG" >/dev/null

echo 'test-claude-large-prompt: ok'
