#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# `bin/reflect.sh` decides WHICH transcripts a day's reflection reads (ADR 0035), and it decides it
# before any model is called. That selection is the part a model cannot correct afterwards: a
# transcript left out is simply not in the evidence, and no stage downstream can tell the difference
# between "the generator read this and found nothing" and "the generator was never shown this".
#
# So four selection properties are checked here, all through `--dry-run --keep`, which runs the whole
# selection and extraction and stops before the first model call:
#
#   1. the day window is a window at BOTH ends — neither the day before nor the day after;
#   2. a subagent transcript is excluded, because it repeats its parent's material under a second id;
#   3. `--max-sessions` caps the set, so a long day cannot silently grow the payload without bound;
#   4. a transcript that yields NO turns still appears in the manifest. That is the three-state
#      inventory the judge is given: cited / examined and dropped / never read. Dropping the empty
#      session from the manifest would collapse the third state into the second.
#
# Plus the argument guard: a malformed `--day` must refuse rather than fall back to a default day,
# because the day is printed in the report and a wrong one makes every finding unverifiable.
#
# `pi` is stubbed on PATH. The runner only checks that it exists at this point, and a test must
# never reach a real model: it would cost money, and its answer would not be a fixture.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFLECT="$ROOT/bin/reflect.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-reflect-runner: $1" >&2; exit 1; }

DAY="2026-09-20"
PREV="2026-09-19"
NEXT="2026-09-21"

mkdir -p "$TMP/bin" "$TMP/claude/projects/-home-x-proj" "$TMP/codex/sessions/2026/09/20" \
         "$TMP/codex/sessions/2026/09/20/subagents" "$TMP/out"

printf '#!/bin/sh\necho "test-reflect-runner: pi must not be called" >&2\nexit 99\n' > "$TMP/bin/pi"
chmod +x "$TMP/bin/pi"

claude_turn() {  # $1 = file, $2 = uuid prefix, $3 = the human line
  cat > "$1" <<EOF
{"type":"user","uuid":"$2-1111-2222-3333-444444444444","timestamp":"${DAY}T10:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"$3"}}
{"type":"assistant","uuid":"$2-5555-2222-3333-444444444444","timestamp":"${DAY}T10:00:09.000Z","message":{"role":"assistant","content":[{"type":"text","text":"answered"}]}}
EOF
}

A="$TMP/claude/projects/-home-x-proj/aaaaaaaa-1111-4111-8111-111111111111.jsonl"
B="$TMP/claude/projects/-home-x-proj/bbbbbbbb-1111-4111-8111-111111111111.jsonl"
OLD="$TMP/claude/projects/-home-x-proj/cccccccc-1111-4111-8111-111111111111.jsonl"
LATER="$TMP/claude/projects/-home-x-proj/ffffffff-1111-4111-8111-111111111111.jsonl"
SUB="$TMP/codex/sessions/2026/09/20/subagents/dddddddd-1111-4111-8111-111111111111.jsonl"
EMPTY="$TMP/codex/sessions/2026/09/20/eeeeeeee-1111-4111-8111-111111111111.jsonl"

claude_turn "$A" aaaaaaaa "SENTINEL_A"
claude_turn "$B" bbbbbbbb "SENTINEL_B"
claude_turn "$OLD" cccccccc "SENTINEL_OLD"
claude_turn "$LATER" ffffffff "SENTINEL_LATER"
claude_turn "$SUB" dddddddd "SENTINEL_SUB"

# A Codex rollout that carries only its header: it parses, it is a real session, and it yields no
# turn. This is the case property 4 is about.
cat > "$EMPTY" <<EOF
{"timestamp":"${DAY}T09:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"cwd":"/home/x"}}
EOF

# Distinct times inside the day: the runner sorts newest first, and `--max-sessions` cuts from
# the tail. Equal timestamps would make which session survives the cap depend on readdir order.
touch -d "$DAY 11:00:00" "$A"
touch -d "$DAY 10:30:00" "$SUB"
touch -d "$DAY 10:00:00" "$B"
touch -d "$DAY 09:00:00" "$EMPTY"
touch -d "$PREV 10:00:00" "$OLD"
touch -d "$NEXT 10:00:00" "$LATER"

run() {  # prints the runner's stderr; the caller greps it
  PATH="$TMP/bin:$PATH" \
  NIGHTSHIFT_REFLECT_CLAUDE_DIR="$TMP/claude/projects" \
  NIGHTSHIFT_REFLECT_CODEX_DIR="$TMP/codex/sessions" \
  NIGHTSHIFT_REFLECT_DIR="$TMP/out" \
    bash "$REFLECT" "$@" 2>&1
}

# --- 1-2. the day window holds, and a subagent transcript stays out -----------
out="$(run --day "$DAY" --dry-run)" || fail "the dry run failed: $out"

grep -q "$(basename "$A")" <<<"$out" || fail "the day's first session was not selected"
grep -q "$(basename "$B")" <<<"$out" || fail "the day's second session was not selected"
if grep -q "$(basename "$OLD")" <<<"$out"; then
  fail "a transcript written on $PREV was read as part of $DAY"
fi
if grep -q "$(basename "$LATER")" <<<"$out"; then
  fail "a transcript written on $NEXT was read as part of $DAY"
fi
if grep -q "subagents/" <<<"$out"; then fail "a subagent transcript was selected"; fi

# --- 3. the cap is a cap ------------------------------------------------------
capped="$(run --day "$DAY" --dry-run --max-sessions 1)" || fail "the capped dry run failed: $capped"
n="$(grep -c "\.jsonl$" <<<"$capped" || true)"
[ "$n" -eq 1 ] || fail "--max-sessions 1 selected $n session(s)"

# --- 4. a session that yields nothing is still named in the manifest ----------
kept="$(run --day "$DAY" --dry-run --keep)" || fail "the kept dry run failed: $kept"
work="$(sed -n 's/.*kept working directory: //p' <<<"$kept" | tail -1)"
[ -n "$work" ] && [ -d "$work" ] || fail "--keep did not report a working directory"

grep -q 'no turns extracted' <<<"$kept" \
  || fail "the empty Codex rollout was expected to yield no turns, and did not say so"

manifest="$work/manifest.json"
[ -f "$manifest" ] || fail "no manifest at $manifest"
python3 - "$manifest" <<'PY' || fail "the manifest does not carry every examined session"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["day"] == "2026-09-20", m["day"]
s = m["sessions"]
assert "eeeeeeee" in s, f"the session that yielded no turns is missing from the manifest: {s}"
assert "aaaaaaaa" in s and "bbbbbbbb" in s, f"a session with turns is missing: {s}"
assert "cccccccc" not in s, f"a transcript from the previous day reached the manifest: {s}"
assert "ffffffff" not in s, f"a transcript from the next day reached the manifest: {s}"
assert "dddddddd" not in s, f"a subagent transcript reached the manifest: {s}"
PY
rm -rf "$work"

# --- 5. a malformed day refuses ----------------------------------------------
if run --day "20.09.2026" --dry-run >/dev/null 2>&1; then
  fail "--day 20.09.2026 was accepted"
fi
bad="$(run --day "20.09.2026" --dry-run || true)"
grep -q 'must be YYYY-MM-DD' <<<"$bad" || fail "the day guard gave no usable reason: $bad"

# --- 6. no model was called ---------------------------------------------------
if grep -q 'pi must not be called' <<<"$out$capped$kept$bad"; then
  fail "the dry run reached the model stub"
fi

echo "test-reflect-runner: ok"
