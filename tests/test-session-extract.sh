#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# The reflection job (ADR 0035) can only check a finding's evidence if the evidence has an address.
# That address is the turn id this extractor assigns, so three properties are load-bearing and each
# one is checked here:
#
#   1. a turn id is derived from the SOURCE, not from position in the output — so a citation
#      recorded against one compaction still resolves against the next one;
#   2. a human turn survives verbatim, because an operator's correction is the one line in a
#      transcript no model wrote;
#   3. what is NOT conversation stays out: a tool result wearing the user role, and the harness
#      instructions Codex delivers through it.
#
# The fixtures are hand-written. A live session is not a test fixture: it changes under the test and
# it carries content that has no business in a repository.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACT="$ROOT/lib/extract_session.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-session-extract: $1" >&2; exit 1; }

# --- fixtures -----------------------------------------------------------------
cat > "$TMP/claude.jsonl" <<'EOF'
{"type":"user","uuid":"aaaaaaaa-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:28:07.735Z","origin":{"kind":"human"},"message":{"role":"user","content":"hat nightshift gearbeitet?"}}
{"type":"assistant","uuid":"bbbbbbbb-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:28:20.000Z","message":{"role":"assistant","content":[{"type":"text","text":"PROSE_START and then a great deal more prose than anyone needs to read PROSE_TAIL"},{"type":"tool_use","name":"Bash","input":{"command":"ls -t state/"}}]}}
{"type":"user","uuid":"cccccccc-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:28:21.000Z","message":{"role":"user","content":[{"type":"text","text":"TOOL_RESULT_SENTINEL"}]}}
{"type":"user","uuid":"dddddddd-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:29:50.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"achso er fetcht nicht alles?!"}}
EOF

cat > "$TMP/codex.jsonl" <<'EOF'
{"timestamp":"2026-09-14T21:54:02.745Z","ordinal":0,"type":"session_meta","payload":{"cwd":"/home/x","thread_source":"guardian_review"}}
{"timestamp":"2026-09-14T21:54:03.541Z","ordinal":2,"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>\n</permissions instructions>"}]}}
{"timestamp":"2026-09-14T21:54:04.000Z","ordinal":3,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<harness instructions>INJECTED</harness instructions>"}]}}
{"timestamp":"2026-09-14T21:54:10.000Z","ordinal":4,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hast du die feedbacks schon mal angesehen?"}]}}
{"timestamp":"2026-09-14T21:54:20.000Z","ordinal":5,"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":\"grep -rn feedback\"}"}}
EOF

# --- 1. Claude: the conversation survives, the plumbing does not ---------------
out="$(python3 "$EXTRACT" "$TMP/claude.jsonl")" || fail "extractor failed on the Claude fixture"

grep -q '^hat nightshift gearbeitet?$' <<<"$out" \
  || fail "a human turn did not survive verbatim"
grep -q 'tool Bash: ls -t state/' <<<"$out" \
  || fail "the tool call name and hint are missing"
# The sentinel arrives as a text block on a user-role line with no `origin.kind: human` — which is
# exactly the shape a tool result has. Only the origin check keeps it out; nothing else would.
grep -q 'TOOL_RESULT_SENTINEL' <<<"$out" \
  && fail "a tool result wearing the user role reached the output"
[ "$(grep -c '^\[turn ' <<<"$out")" = 3 ] \
  || fail "expected exactly 3 turns from the Claude fixture, got $(grep -c '^\[turn ' <<<"$out")"

# --- 2. prose is truncated, human text never is -------------------------------
short="$(python3 "$EXTRACT" "$TMP/claude.jsonl" --max-prose 20)" || fail "extractor failed with --max-prose"
grep -q 'PROSE_TAIL' <<<"$short" && fail "agent prose was not truncated by --max-prose"
grep -q 'PROSE_START' <<<"$short" || fail "truncation removed the start of the agent prose too"
grep -q '^achso er fetcht nicht alles?!$' <<<"$short" \
  || fail "--max-prose truncated a human turn, which must never happen"

# --- 3. turn ids come from the source, not from position ----------------------
# The whole citation scheme rests on this: a citation recorded against one extract must still
# resolve against the next one, even though the session has grown and the filters have changed.
#
# Comparing two extracts of the SAME turns proves nothing — positional ids would match there too.
# The discriminating case is a transcript whose EARLIER turns differ: prepend a turn, and a
# positional scheme shifts every id after it while a source-derived scheme does not.
ids_default="$(grep -o '^\[turn [^ ]*' <<<"$out" | sort)"
ids_short="$(grep -o '^\[turn [^ ]*' <<<"$short" | sort)"
[ "$ids_default" = "$ids_short" ] \
  || fail "turn ids changed when the compaction rules changed"

{ echo '{"type":"user","uuid":"00000000-9999-2222-3333-444444444444","timestamp":"2026-09-15T19:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"an earlier question"}}'
  cat "$TMP/claude.jsonl"
} > "$TMP/grown.jsonl"
grown="$(python3 "$EXTRACT" "$TMP/grown.jsonl" --session-id claude)"
for id in $(grep -o '^\[turn [^ ]*' <<<"$out" | cut -d' ' -f2); do
  grep -q "^\[turn $id " <<<"$grown" \
    || fail "turn id $id vanished when an earlier turn was prepended — ids are positional"
done
grep -q '^\[turn claude:00000000 ' <<<"$grown" \
  || fail "the prepended turn did not get its own source-derived id"

# ...and across a re-run, which is the cheap half of the same property.
again="$(python3 "$EXTRACT" "$TMP/claude.jsonl")"
[ "$out" = "$again" ] || fail "extracting the same transcript twice produced different output"

# --- 4. Codex: format is detected from content, not from the path -------------
# The fixture sits in /tmp, nowhere near ~/.codex, so a path-based guess would read it as Claude
# and silently emit nothing.
cout="$(python3 "$EXTRACT" "$TMP/codex.jsonl")" || fail "extractor failed on the Codex fixture"
grep -q '^hast du die feedbacks schon mal angesehen?$' <<<"$cout" \
  || fail "the Codex human turn is missing — format detection probably fell back to Claude"
grep -q 'tool shell' <<<"$cout" || fail "the Codex tool call is missing"
grep -q 'INJECTED' <<<"$cout" \
  && fail "harness instructions delivered through the user role reached the output"
grep -q 'permissions instructions' <<<"$cout" \
  && fail "a developer-role turn reached the output"

# --- 5. an empty transcript is a failure, not an empty success ----------------
: > "$TMP/empty.jsonl"
if python3 "$EXTRACT" "$TMP/empty.jsonl" >/dev/null 2>&1; then
  fail "an empty transcript exited 0 — a silent empty extract would read as a quiet day"
fi

echo "test-session-extract: ok"
