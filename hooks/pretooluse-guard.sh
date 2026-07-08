#!/usr/bin/env bash
# nightshift git-confinement hook — Layer 2 (hook-spec.md, re-review §2a).
#
# A Claude Code PreToolUse hook. Reads the tool-call JSON on stdin. Its ONLY job
# is to stop the agent from DISABLING Layer 1 (hooks/pre-push). The hard work —
# which ref a push actually touches — is Layer 1's, on resolved refs.
#
# NOTE: the exact PreToolUse I/O contract should be verified against the installed
# Claude Code version before relying on this unattended (prototype artifact).
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0   # not a Bash command — allow

deny() {
  # Block the tool call with a reason.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"nightshift: %s"}}\n' "$1"
  exit 0
}

case "$cmd" in
  *--no-verify*)             deny "git --no-verify would bypass the pre-push confinement hook" ;;
  *core.hooksPath*)          deny "overriding core.hooksPath would disable the pre-push confinement hook" ;;
  *"git config"*hooksPath*)  deny "changing hooksPath would disable the pre-push confinement hook" ;;
esac

exit 0
