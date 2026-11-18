#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export NIGHTSHIFT_WORKTREE="$TMP"

for payload in '{"tool_name":"Write",' '{"tool_name":"Write","tool_input":{"unknown_path":"file"}}'; do
  printf '%s' "$payload" | bash "$ROOT/hooks/pretooluse-guard.sh" \
    | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
done

# NotebookEdit is confined by the notebook it writes, not by a decoy file_path.
printf '%s' "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"file_path\":\"$TMP/ok\",\"notebook_path\":\"/tmp/outside.ipynb\"}}" \
  | bash "$ROOT/hooks/pretooluse-guard.sh" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
# An in-tree write is still allowed (no decision printed).
[ -z "$(printf '%s' "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/ok\"}}" | bash "$ROOT/hooks/pretooluse-guard.sh")" ]

echo 'test-guard-malformed-input: ok'
