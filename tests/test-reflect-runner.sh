#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# `bin/reflect.sh` decides WHICH transcripts a day's reflection reads (ADR 0035), and it decides it
# before any model is called. That selection is the part a model cannot correct afterwards: a
# transcript left out is simply not in the evidence, and no stage downstream can tell the difference
# between "the generator read this and found nothing" and "the generator was never shown this".
#
# Everything here runs through `--dry-run --keep`, which performs the whole selection and extraction
# and stops before the first model call. What is asserted:
#
#   1. the day window is half-open and exact at BOTH ends. Midnight of the day belongs to the day;
#      the last fractional second belongs to the day; midnight of the next day does not. A
#      `find -newermt` pair gets all three wrong, which is why they are fixtures and not a comment.
#   2. transcripts that are not conversations are excluded — a subagent run, which repeats its
#      parent's material under a second id, and a peer-debate benchmark run, which has no person in
#      it at all — and so is a symlink named like a transcript, which reaches outside the configured
#      trees. The exclusion list is configurable and can be switched off entirely;
#   3. `--max-sessions` caps the set by IDENTITY, not merely by count — a cap applied before the
#      subagent filter would still produce the right number of sessions and the wrong ones;
#   4. a transcript that yields NO turns still appears in the manifest, exactly once. That is the
#      three-state inventory the judge is given: cited / examined and dropped / never read;
#   5. an extraction that FAILS stops the run. It must not be recorded as an examined empty session —
#      that would put a session in the inventory whose evidence nobody ever read;
#   6. two transcripts whose session ids collide are refused, because they would share one turn file
#      and one of them would vanish with nothing saying so;
#   7. the argument guards refuse rather than fall back: a malformed day, a cap of zero, an option
#      with no value.
#
# `pi` is stubbed on PATH. The runner only checks that it exists at this point, and a test must
# never reach a real model: it would cost money, and its answer would not be a fixture.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFLECT="$ROOT/bin/reflect.sh"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

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

C="$TMP/claude/projects/-home-x-proj"
X="$TMP/codex/sessions/2026/09/20"

A="$C/aaaaaaaa-1111-4111-8111-111111111111.jsonl"          # squarely inside the day
B="$C/bbbbbbbb-1111-4111-8111-111111111111.jsonl"          # squarely inside the day
MIDNIGHT="$C/11111111-1111-4111-8111-111111111111.jsonl"   # 00:00:00.000 — inside
LASTTICK="$C/22222222-1111-4111-8111-111111111111.jsonl"   # 23:59:59.9  — inside
NEXTDAY="$C/33333333-1111-4111-8111-111111111111.jsonl"    # next 00:00:00 — outside
OLD="$C/cccccccc-1111-4111-8111-111111111111.jsonl"        # the day before — outside
LATER="$C/ffffffff-1111-4111-8111-111111111111.jsonl"      # the day after  — outside
SUB="$X/subagents/dddddddd-1111-4111-8111-111111111111.jsonl"
EMPTY="$X/eeeeeeee-1111-4111-8111-111111111111.jsonl"

for v in A B MIDNIGHT LASTTICK NEXTDAY OLD LATER SUB; do
  f="${!v}"; claude_turn "$f" "$(basename "$f" | cut -c1-8)" "SENTINEL_$v"
done

# A Codex rollout that carries only its header: it parses, it is a real session, and it yields no
# turn. This is the case property 4 is about.
cat > "$EMPTY" <<EOF
{"timestamp":"${DAY}T09:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"cwd":"/home/x"}}
EOF

# Distinct times inside the day: the runner sorts newest first and the cap cuts from the tail, so
# equal timestamps would make the selection depend on readdir order.
touch -d "$DAY 23:59:59.9" "$LASTTICK"
touch -d "$DAY 11:00:00"   "$A"
touch -d "$DAY 10:30:00"   "$SUB"
touch -d "$DAY 10:00:00"   "$B"
touch -d "$DAY 09:00:00"   "$EMPTY"
touch -d "$DAY 00:00:00"   "$MIDNIGHT"
touch -d "$NEXT 00:00:00"  "$NEXTDAY"
touch -d "$NEXT 10:00:00"  "$LATER"
touch -d "$PREV 10:00:00"  "$OLD"

# A peer-debate benchmark run: two models arguing on a fixed brief, no person in it. Claude Code
# flattens the working directory into the project name, so the marker arrives with dashes, not
# slashes — a pattern anchored on `/peer-debates/` would match nothing.
mkdir -p "$TMP/claude/projects/-home-x-peer-debates-2026-09-20-topic"
DEBATE="$TMP/claude/projects/-home-x-peer-debates-2026-09-20-topic/55555555-1111-4111-8111-111111111111.jsonl"
claude_turn "$DEBATE" 55555555 "SENTINEL_DEBATE"
touch -d "$DAY 10:45:00" "$DEBATE"

# A symlink named like a transcript, pointing outside both trees. Without `-type f` it is selected
# and the reflection reads a file from somewhere nobody configured.
mkdir -p "$TMP/elsewhere"
OUTSIDE="$TMP/elsewhere/secret.jsonl"
claude_turn "$OUTSIDE" 44444444 "SENTINEL_OUTSIDE"
LINK="$C/44444444-1111-4111-8111-111111111111.jsonl"
ln -s "$OUTSIDE" "$LINK"
touch -h -d "$DAY 10:15:00" "$LINK"

run() {  # prints the runner's stdout and stderr together; the caller greps it
  PATH="$TMP/bin:$PATH" \
  NIGHTSHIFT_REFLECT_CLAUDE_DIR="$TMP/claude/projects" \
  NIGHTSHIFT_REFLECT_CODEX_DIR="$TMP/codex/sessions" \
  NIGHTSHIFT_REFLECT_DIR="$TMP/out" \
    bash "$REFLECT" "$@" 2>&1
}

selected() { grep -o '[0-9a-f]\{8\}-1111-4111-8111-111111111111\.jsonl' <<<"$1" | sort -u; }

# --- 1-2. the window is exact at both ends, and a subagent stays out ----------
out="$(run --day "$DAY" --dry-run --max-sessions 99)" || fail "the dry run failed: $out"

# EMPTY is in the selection too: it is read and found to hold no turns, which is a state of its
# own and not an exclusion.
want="$(printf '%s\n' "$(basename "$A")" "$(basename "$B")" "$(basename "$MIDNIGHT")" \
                      "$(basename "$LASTTICK")" "$(basename "$EMPTY")" | sort)"
got="$(selected "$out")"
[ "$got" = "$want" ] || fail "wrong selection for $DAY:
want:
$want
got:
$got"

# --- 3. the cap cuts by identity ---------------------------------------------
# Cap 2 across the subagent: newest first is LASTTICK, A, then the subagent, then B. A cap applied
# before the subagent filter would spend a slot on the subagent and lose A.
capped="$(run --day "$DAY" --dry-run --max-sessions 2)" || fail "the capped dry run failed: $capped"
want="$(printf '%s\n' "$(basename "$LASTTICK")" "$(basename "$A")" | sort)"
got="$(selected "$capped")"
[ "$got" = "$want" ] || fail "--max-sessions 2 selected the wrong sessions:
want:
$want
got:
$got"
grep -q 'of 5 eligible' <<<"$capped" || fail "the capped run did not report how many it left out"

# --- 3a. the exclusions are configurable, and off by request -----------------
# On 2026-09-21 benchmark runs were 21 of the day's 32 transcripts, so this is not noise reduction:
# without it they crowd real sessions out past the cap while the report still counts them as read.
opened="$(NIGHTSHIFT_REFLECT_EXCLUDE="" run --day "$DAY" --dry-run --max-sessions 99)" \
  || fail "the run with no exclusions failed: $opened"
grep -q "$(basename "$DEBATE")" <<<"$opened" \
  || fail "an empty NIGHTSHIFT_REFLECT_EXCLUDE still excluded something"
grep -q "$(basename "$SUB")" <<<"$opened" \
  || fail "an empty NIGHTSHIFT_REFLECT_EXCLUDE still excluded the subagent"

# --- 3b. a directory `find` cannot read stops the run ------------------------
# Losing a subtree must not shorten the day quietly: an unreadable directory makes `find` exit
# non-zero, and that status has to reach the caller rather than be discarded with its diagnostics.
# `-maxdepth 2` from the Claude root, so the locked directory sits at depth 1 — deep enough that
# find must open it, shallow enough that it is inside the search.
LOCKED="$TMP/claude/projects/locked"
mkdir -p "$LOCKED"
chmod 000 "$LOCKED"
if blind="$(run --day "$DAY" --dry-run --max-sessions 99)"; then
  chmod 755 "$LOCKED"
  fail "an unreadable directory did not stop the run: $blind"
fi
chmod 755 "$LOCKED"
grep -q 'could not list' <<<"$blind" || fail "the unreadable directory gave no usable reason: $blind"
rmdir "$LOCKED"

# --- 4. a session that yields nothing is named in the manifest, once ----------
kept="$(run --day "$DAY" --dry-run --keep --max-sessions 99)" || fail "the kept dry run failed: $kept"
work="$(sed -n 's/.*kept working directory: //p' <<<"$kept" | tail -1)"
[ -n "$work" ] && [ -d "$work" ] || fail "--keep did not report a working directory"

grep -q 'read, no turns in it' <<<"$kept" \
  || fail "the empty Codex rollout was expected to be reported as read and empty"

manifest="$work/manifest.json"
[ -f "$manifest" ] || fail "no manifest at $manifest"
python3 - "$manifest" <<'PY' || fail "the manifest does not carry every examined session exactly once"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["day"] == "2026-09-20", m["day"]
s = m["sessions"]
assert len(s) == len(set(s)), f"a session id appears twice in the manifest: {s}"
assert set(s) == {"aaaaaaaa", "bbbbbbbb", "11111111", "22222222", "eeeeeeee"}, \
    f"the manifest is not the examined set: {sorted(s)}"
PY
rm -rf "$work"

# --- 5. an extraction that fails stops the run -------------------------------
chmod 000 "$B"
if broke="$(run --day "$DAY" --dry-run --max-sessions 99)"; then
  chmod 644 "$B"
  fail "an unreadable transcript did not stop the run: $broke"
fi
chmod 644 "$B"
grep -q 'missing that session' <<<"$broke" \
  || fail "the unreadable transcript gave no usable reason: $broke"
if grep -q 'read, no turns in it' <<<"$broke"; then
  fail "a failed extraction was recorded as an examined empty session"
fi

# --- 6. colliding session ids are refused ------------------------------------
# `default_session_id` takes the first eight hex characters of the filename's UUID, so these two
# distinct transcripts claim the same handle — and the same turn file.
mkdir -p "$TMP/coll/claude/-p" "$TMP/coll/codex"
T1="$TMP/coll/claude/-p/99999999-1111-4111-8111-111111111111.jsonl"
T2="$TMP/coll/codex/99999999-2222-4111-8111-222222222222.jsonl"
claude_turn "$T1" 99999999 "SENTINEL_ONE"
claude_turn "$T2" 88888888 "SENTINEL_TWO"
touch -d "$DAY 12:00:00" "$T1" "$T2"
if coll="$(PATH="$TMP/bin:$PATH" \
    NIGHTSHIFT_REFLECT_CLAUDE_DIR="$TMP/coll/claude" \
    NIGHTSHIFT_REFLECT_CODEX_DIR="$TMP/coll/codex" \
    NIGHTSHIFT_REFLECT_DIR="$TMP/out" bash "$REFLECT" --day "$DAY" --dry-run 2>&1)"; then
  fail "two transcripts sharing a session id were accepted: $coll"
fi
grep -q "used by two transcripts" <<<"$coll" || fail "the collision gave no usable reason: $coll"

# --- 7. the argument guards ---------------------------------------------------
guard() {  # $1 = expected message fragment, rest = arguments
  local want="$1"; shift
  local got
  if got="$(run "$@")"; then fail "reflect.sh $* was accepted"; fi
  grep -q "$want" <<<"$got" || fail "reflect.sh $* gave no usable reason: $got"
}
guard 'must be YYYY-MM-DD' --day 20.09.2026 --dry-run
guard 'at least 1'         --day "$DAY" --max-sessions 0 --dry-run
guard 'needs a value'      --day

# --- 8. no model was called ---------------------------------------------------
if grep -q 'pi must not be called' <<<"$out$capped$kept$broke$coll$blind$opened"; then
  fail "the dry run reached the model stub"
fi

echo "test-reflect-runner: ok"
