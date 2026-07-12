#!/usr/bin/env bash
# nightshift confinement hook — Layer 2 (hook-spec.md, re-review §2a + §2b).
#
# A Claude Code PreToolUse hook. Reads the tool-call JSON on stdin. Two jobs:
#  (1) Bash: stop the agent DISABLING Layer 1 (hooks/pre-push) — the hard "which
#      ref" question is Layer 1's, on resolved refs.
#  (2) Write/Edit: confine file writes to the current worktree. The Fix stage grants
#      Write/Edit but no Bash; those tools take ABSOLUTE paths, so without this the
#      agent could edit the runner, hooks, ~/.claude, systemd units, or another repo
#      (R8). Deny any write whose resolved target is outside the worktree root.
#
# NOTE: the exact PreToolUse I/O contract should be verified against the installed
# Claude Code version before relying on this unattended (prototype artifact).
set -euo pipefail

input="$(cat)"

deny() {
  # Block the tool call with a reason.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"nightshift: %s"}}\n' "$1"
  exit 0
}

# ---- (1) Bash: anti-bypass for the git-confinement hook ----
# Keyed on the presence of a command (not tool_name) so the check is robust to
# contract variation and never regresses the git confinement.
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
if [ -n "$cmd" ]; then
  case "$cmd" in
    *--no-verify*)             deny "git --no-verify would bypass the pre-push confinement hook" ;;
    *core.hooksPath*)          deny "overriding core.hooksPath would disable the pre-push confinement hook" ;;
    *"git config"*hooksPath*)  deny "changing hooksPath would disable the pre-push confinement hook" ;;
    # Layer 1 is injected via GIT_CONFIG_* env (nightshift.sh); a command that sets any
    # of these can override/disable it (e.g. GIT_CONFIG_COUNT=0) without naming hooksPath.
    # The Runner's own injection is process env, never an agent command — so denying the
    # string in a command is safe.
    *GIT_CONFIG_COUNT*|*GIT_CONFIG_KEY*|*GIT_CONFIG_VALUE*|*GIT_CONFIG_GLOBAL*|*GIT_CONFIG_SYSTEM*)
                               deny "setting GIT_CONFIG_* would override the injected core.hooksPath (Layer 1 confinement)" ;;
  esac
  exit 0   # a Bash call has no file_path to confine
fi

# ---- (2) Write/Edit/MultiEdit/NotebookEdit: worktree write confinement ----
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)"
[ -z "$path" ] && exit 0   # no path to check — allow

# Worktree root, most-authoritative first: the Runner-injected env (we control it),
# then the hook payload's cwd (claude runs in the worktree), then this process's cwd.
root="${NIGHTSHIFT_WORKTREE:-}"
[ -n "$root" ] || root="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$root" ] || root="$PWD"
root="$(realpath -m "$root" 2>/dev/null || printf '%s' "$root")"

# A relative path is relative to the agent's cwd = the worktree; an absolute path is
# taken as-is. realpath -m normalizes '..' and resolves symlinks in existing prefixes
# (so a symlink escaping the worktree, or '../../etc/x', resolves to its real target).
case "$path" in
  /*) abs="$path" ;;
  *)  abs="$root/$path" ;;
esac
target="$(realpath -m "$abs" 2>/dev/null || printf '%s' "$abs")"

# Trailing-slash-safe containment: equal to root, or strictly beneath root/. This
# rejects a sibling that merely shares the prefix (…/worktree-evil vs …/worktree).
case "$target" in
  "$root"|"$root"/*) exit 0 ;;
  *) deny "Write/Edit outside the worktree is not allowed (resolved: $target)" ;;
esac
