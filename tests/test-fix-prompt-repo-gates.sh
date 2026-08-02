#!/usr/bin/env bash
set -euo pipefail

# The Fix stage cannot commit, so it never sees a repo hook fire: an unmet convention shows up only
# as `commit-failed` after the model is gone, and the whole change is discarded. The fix prompt
# therefore names the gates the runner's commit will face — DETECTED from the worktree, never
# assumed. Nothing present, nothing claimed; and no other stage carries the section.
#
# `--template=` is deliberate: this host installs pre-commit/pre-push into every new repo via
# init.templateDir, which would make an "ungated repo" case impossible to construct otherwise.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk() { git init -q --template= -b main "$1"; }
mkdir -p "$TMP/item"
jq -nc '{fingerprint:"f",summary:"s",type:"bug"}' > "$TMP/item/finding.json"

NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh" 2>/dev/null

# --- 1. gated repo: both gates named ------------------------------------------------
mk "$TMP/gated"
printf '# Changelog\n\n## [Unreleased]\n' > "$TMP/gated/CHANGELOG.md"
mkdir -p "$TMP/gated/.git/hooks"
printf '#!/bin/sh\nexit 1\n' > "$TMP/gated/.git/hooks/pre-commit"
chmod +x "$TMP/gated/.git/hooks/pre-commit"

p="$(stage_prompt fix "$TMP/gated" "$TMP/item")"
grep -q "Gates this repo applies" <<<"$p" || { echo "gated repo: no gates section" >&2; exit 1; }
grep -q 'CHANGELOG.md` is present' <<<"$p" || { echo "gated repo: CHANGELOG gate not named" >&2; exit 1; }
grep -q 'pre-commit` hook is installed' <<<"$p" || { echo "gated repo: hook gate not named" >&2; exit 1; }
# The consequence must be stated — a gate the model may treat as optional is not a gate.
grep -qi "discards the ENTIRE fix" <<<"$p" || { echo "gated repo: consequence not stated" >&2; exit 1; }

# --- 2. ungated repo: nothing claimed -----------------------------------------------
mk "$TMP/plain"
p="$(stage_prompt fix "$TMP/plain" "$TMP/item")"
grep -q "Gates this repo applies" <<<"$p" \
  && { echo "ungated repo: invented a gates section" >&2; exit 1; }

# --- 3. only the gate that exists is named ------------------------------------------
mk "$TMP/cl-only"
printf '# Changelog\n' > "$TMP/cl-only/CHANGELOG.md"
p="$(stage_prompt fix "$TMP/cl-only" "$TMP/item")"
grep -q 'CHANGELOG.md` is present' <<<"$p" || { echo "cl-only: CHANGELOG gate missing" >&2; exit 1; }
grep -q 'pre-commit` hook is installed' <<<"$p" \
  && { echo "cl-only: claimed a pre-commit hook that does not exist" >&2; exit 1; }

# An alternate spelling is recognised too — the convention, not the exact filename, is the gate.
mk "$TMP/changes"
printf '# Changes\n' > "$TMP/changes/CHANGES.md"
grep -q 'CHANGES.md` is present' <<<"$(stage_prompt fix "$TMP/changes" "$TMP/item")" \
  || { echo "CHANGES.md not recognised as a changelog" >&2; exit 1; }

# --- 4. the section belongs to Fix alone --------------------------------------------
grep -q "Gates this repo applies" <<<"$(stage_prompt explore "$TMP/gated" "$TMP/item")" \
  && { echo "explore stage carries the fix-only gates section" >&2; exit 1; }
grep -q "Gates this repo applies" <<<"$(stage_prompt review "$TMP/gated" "$TMP/item")" \
  && { echo "review stage carries the fix-only gates section" >&2; exit 1; }

# --- 5. the standing rule is in the prompt file itself ------------------------------
grep -q "commit conventions" "$ROOT/prompts/fix.md" \
  || { echo "prompts/fix.md lost the commit-convention rule" >&2; exit 1; }

echo "test-fix-prompt-repo-gates: ok"
