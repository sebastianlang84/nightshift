#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# An agent that notices something about its own working conditions — a missing tool, an instruction
# that contradicts the repository, a check it could not run — had nowhere to put it. The Fix stage's
# worknote becomes the commit message, so a remark about the harness either distorted that message
# or was dropped. On 2026-09-06 an agent created a scratch file it then could not delete and said so
# in its worknote; that reached a human only because someone happened to read the commit body.
#
# The channel is a file the agent writes INSIDE its worktree — the only place it may write — which
# the Runner then moves out. What this pins: the note reaches the notes file, it never survives in
# the worktree (or it would be committed into someone else's repository), and it is deduplicated.
#
# It is deliberately a one-way channel. No stage ever reads these notes back; see collect_agent_note.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-agent-note-channel: $*" >&2; exit 1; }

note() { # note-body [filename] -> run collect_agent_note over a fresh worktree
  ROOT="$ROOT" TMP="$TMP" BODY="$1" NAME="${2:-.nightshift-note}" bash -c '
    set +u
    export NIGHTSHIFT_STATE_DIR="$TMP/state"
    NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
    set +e
    mkdir -p "$TMP/wt"
    printf "%s\n" "$BODY" > "$TMP/wt/$NAME"
    collect_agent_note fix "$TMP/wt" /home/someone/somerepo >/dev/null 2>&1
  '
}
NOTES="$TMP/state/agent-notes.md"

# --- 1. the note reaches the notes file, attributed ---
note "The repo has no test script, so the gate instruction cannot be followed."
[ -f "$NOTES" ] || fail "no notes file was written"
grep -q "test script" "$NOTES" || fail "the note body did not reach the notes file"
grep -q "somerepo" "$NOTES" || fail "the note is not attributed to its repo"

# --- 2. THE ONE THAT MATTERS: the file never survives in the worktree ---
# ADR 0027 commits the reviewed tree as it stands, so a leftover note would be committed into the
# target repository — the harness leaking its own scratch file into someone else's history.
[ -e "$TMP/wt/.nightshift-note" ] && fail "the note file survived in the worktree"

# --- 3. the same note twice is recorded once, even reworded in whitespace ---
note "The  repo has   no test script, so the gate instruction cannot be followed."
[ "$(grep -c '^## ' "$NOTES")" = 1 ] || fail "a repeated note was recorded twice"

# --- 4. a different note is recorded ---
note "codemap index is stale here and I could not refresh it."
[ "$(grep -c '^## ' "$NOTES")" = 2 ] || fail "a genuinely new note was not recorded"

# --- 5. an empty or whitespace-only note is not an entry ---
note "   "
[ "$(grep -c '^## ' "$NOTES")" = 2 ] || fail "a blank note became an entry"
[ -e "$TMP/wt/.nightshift-note" ] && fail "a blank note file survived in the worktree"

# --- 6. the .md spelling works too — a model told to write a note will guess one of the two ---
note "The AGENTS.md here contradicts the prompt about commit conventions." ".nightshift-note.md"
[ "$(grep -c '^## ' "$NOTES")" = 3 ] || fail "the .md spelling of the note file was ignored"
[ -e "$TMP/wt/.nightshift-note.md" ] && fail "the .md note file survived in the worktree"

# --- 7. a runaway note is truncated rather than swallowing the file ---
big="$(head -c 20000 /dev/zero | tr '\0' 'x')"
note "$big"
[ "$(wc -c < "$NOTES")" -lt 12000 ] || fail "an oversized note was recorded in full"

echo "test-agent-note-channel: ok"
