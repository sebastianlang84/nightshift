#!/usr/bin/env bash
set -euo pipefail

# R8 regression: the Fix stage grants Write/Edit but no Bash. Those tools take absolute
# paths, so the PreToolUse guard MUST deny any write resolving outside the worktree —
# otherwise the agent could rewrite the runner, hooks, ~/.claude, systemd units, or
# another repo with no Bash at all. Drives the guard directly (deterministic), the same
# way the Runner invokes it: tool-call JSON on stdin, NIGHTSHIFT_WORKTREE in the env.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/hooks/pretooluse-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WT="$TMP/worktree"; mkdir -p "$WT/sub" "$TMP/worktree-evil"

# echo "deny" if the guard blocks the call, else "allow"
guard() { # tool-json
  local out
  out="$(printf '%s' "$1" | NIGHTSHIFT_WORKTREE="$WT" bash "$GUARD")"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then echo deny; else echo allow; fi
}
w() { jq -nc --arg t "$1" --arg p "$2" '{tool_name:$t,tool_input:{file_path:$p}}'; }

expect() { # want json label
  local got; got="$(guard "$2")"
  [ "$got" = "$1" ] || { echo "FAIL [$3]: want $1 got $got" >&2; exit 1; }
}

# --- inside the worktree → allow ---
expect allow "$(w Write "$WT/new.py")"            "write in worktree"
expect allow "$(w Edit  "$WT/sub/nested.txt")"    "edit nested in worktree"
expect allow "$(w Write "rel/inside.py")"         "relative path resolves into worktree"
expect allow "$(w MultiEdit "$WT/multi.txt")"     "multiedit in worktree"

# --- outside the worktree → deny ---
expect deny "$(w Write "$HOME/.claude/settings.json")"  "write to ~/.claude"
expect deny "$(w Edit  "$ROOT/bin/nightshift.sh")"      "edit the runner itself"
expect deny "$(w Write "/etc/cron.d/evil")"             "write to /etc"
expect deny "$(w Write "../../../etc/passwd")"          "relative traversal out of worktree"
expect deny "$(w Write "$TMP/worktree-evil/x")"         "prefix-sibling is not 'inside'"

# --- Bash confinement must not regress ---
expect deny  '{"tool_name":"Bash","tool_input":{"command":"git push --no-verify origin nightshift/x"}}' "bash --no-verify"
expect deny  '{"tool_name":"Bash","tool_input":{"command":"GIT_CONFIG_COUNT=0 git push"}}'               "bash GIT_CONFIG_* override"
expect allow '{"tool_name":"Bash","tool_input":{"command":"grep -r TODO ."}}'                            "benign bash allowed"

# --- fallback: no env, cwd from payload confines correctly ---
out="$(printf '%s' "$(jq -nc --arg p "/etc/x" --arg c "$WT" '{tool_name:"Write",cwd:$c,tool_input:{file_path:$p}}')" | env -u NIGHTSHIFT_WORKTREE bash "$GUARD")"
printf '%s' "$out" | grep -q '"permissionDecision":"deny"' || { echo "FAIL [payload-cwd fallback]: outside write allowed" >&2; exit 1; }

echo "test-fix-write-confinement: ok"
