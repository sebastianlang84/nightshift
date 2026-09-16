#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # CI runs the suite with GIT_CONFIG_* set; every test clears it (AGENTS.md)

# Stage 3 of ADR 0035 answers the question stage 2 cannot: does the quote still mean what the
# finding says it means. That question is unanswerable from the quote alone, so this builder's job
# is to hand the judge what the quote leaves out — and to refuse, loudly, when it cannot.
#
# The properties below are the ones a silent regression would destroy. Each is asserted INSIDE the
# section of the finding it belongs to, not against the whole document: two findings citing the
# same turn make a document-wide grep true even when one of them was rendered without any context
# at all.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACT="$ROOT/lib/extract_session.py"
CHECK="$ROOT/lib/check_citations.py"
BUILD="$ROOT/lib/build_judge_input.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-judge-input: $1" >&2; exit 1; }

# Everything between one finding's header and the next. The unit every context assertion uses.
section() { # finding-id file -> that finding's block
  awk -v id="--- finding $1 ---" '
    $0 == id {inside = 1; next}
    inside && /^--- finding /  {exit}
    inside && /^===== /        {exit}
    inside {print}
  ' "$2"
}

# Session A: the quoted claim is walked back two turns later — the shape the judge exists to catch,
# and exactly what a quote shown alone would hide.
cat > "$TMP/a.jsonl" <<'EOF'
{"type":"user","uuid":"a0000000-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:26:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"FAR_EARLIER_TURN"}}
{"type":"assistant","uuid":"a0000001-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:27:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"filler so the cited turn sits outside the default window of the far turns"}]}}
{"type":"user","uuid":"aaaaaaaa-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:28:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"warum steht der vorgang still?"}}
{"type":"assistant","uuid":"bbbbbbbb-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:28:20.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Die Cron-Zeile fehlt, deshalb bekommt dort nie ein Agent einen Zug."}]}}
{"type":"user","uuid":"cccccccc-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:29:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"er nutzt claude code"}}
{"type":"assistant","uuid":"dddddddd-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:29:30.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Damit faellt meine Cron-Erklaerung von vorhin weg."}]}}
{"type":"user","uuid":"e0000000-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:40:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"FAR_LATER_TURN"}}
EOF

# Session B is cited only through an ordering endpoint — never quoted.
cat > "$TMP/b.jsonl" <<'EOF'
{"type":"user","uuid":"ffffffff-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:50:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"ORDERING_ONLY_TURN"}}
EOF

# Session C is cited only by a finding that the citation check drops: examined, not a coverage gap.
cat > "$TMP/c.jsonl" <<'EOF'
{"type":"user","uuid":"c1111111-1111-2222-3333-444444444444","timestamp":"2026-09-15T20:10:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"DROPPED_ONLY_TURN"}}
EOF

# Session D is cited by nothing at all: the real coverage gap.
cat > "$TMP/d.jsonl" <<'EOF'
{"type":"user","uuid":"d1111111-1111-2222-3333-444444444444","timestamp":"2026-09-15T20:20:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"kurzfassung bitte"}}
EOF

for s in a b c d; do
  python3 "$EXTRACT" "$TMP/$s.jsonl" --session-id "s$s" > "$TMP/$s.turns" || fail "extract failed ($s)"
done
TURNS=("$TMP/a.turns" "$TMP/b.turns" "$TMP/c.turns" "$TMP/d.turns")

req() { # id title -> the required fields, so the schema check is not what a case is testing
  printf '"id":"%s","title":"%s","observation":"o","diagnosis":"d","recommendation":"r","cost":"c"' "$1" "$2"
}

cat > "$TMP/findings.json" <<EOF
{"findings": [
 {$(req retracted "quotes a claim the agent later withdrew"),
  "quotes":[{"turn":"sa:bbbbbbbb","text":"Die Cron-Zeile fehlt"}]},
 {$(req with-elision "a trailing elision, the dangerous kind"),
  "quotes":[{"turn":"sa:bbbbbbbb","text":"Die Cron-Zeile fehlt ..."}]},
 {$(req ordering-only "leans on session B without quoting it"),
  "quotes":[{"turn":"sa:aaaaaaaa","text":"warum steht der vorgang still?"}],
  "ordering":[{"before":"sa:aaaaaaaa","after":"sb:ffffffff"}]},
 {$(req unresolvable "cites a turn that is not there"),
  "quotes":[{"turn":"sc:c1111111","text":"NEVER SAID THIS"}]}
]}
EOF

python3 "$CHECK" --findings "$TMP/findings.json" --turns "${TURNS[@]}" \
  --out "$TMP/checked.json" >/dev/null || fail "checker exited non-zero"
python3 "$BUILD" --checked "$TMP/checked.json" --turns "${TURNS[@]}" \
  --out "$TMP/judge.txt" || fail "builder exited non-zero"
out="$(cat "$TMP/judge.txt")"

# --- 1. each finding gets its own evidence, in its own section ----------------
sec="$(section retracted "$TMP/judge.txt")"
grep -q '^\[turn sa:bbbbbbbb agent .*<-- CITED' <<<"$sec" \
  || fail "retracted: the cited turn is not rendered, or not marked, in its own section"
grep -q 'Damit faellt meine Cron-Erklaerung von vorhin weg' <<<"$sec" \
  || fail "retracted: the turn withdrawing the quoted claim is missing — the judge cannot see it"
grep -q 'warum steht der vorgang still' <<<"$sec" \
  || fail "retracted: the turn before the quote is missing"

# --- 2. the window's edges are visible ----------------------------------------
# A window that stops one turn short of the retraction looks exactly like a session that ends
# there. The judge is asked to answer "cannot tell" in that case, which it can only do if the
# clipping is marked.
grep -q 'FAR_EARLIER_TURN' <<<"$sec" \
  && fail "retracted: context width is not being honoured — a distant turn was included"
grep -q 'earlier turn(s) in sa not shown' <<<"$sec" \
  || fail "retracted: turns were clipped from the start without saying so"
grep -q 'later turn(s) in sa not shown' <<<"$sec" \
  || fail "retracted: turns were clipped from the end without saying so"

# --- 3. a trailing elision is flagged -----------------------------------------
# This is the prototype's worst case: an exact quote that stops right before the clause reversing
# it. Counting fragments calls that unelided, so it must be the omission MARKER that sets the flag.
sec="$(section with-elision "$TMP/judge.txt")"
grep -q 'ELIDED' <<<"$sec" \
  || fail "with-elision: a trailing elision was not flagged — the judge loses the pointer at the omission"

# --- 4. an ordering endpoint is evidence too ----------------------------------
sec="$(section ordering-only "$TMP/judge.txt")"
grep -q 'ORDERING_ONLY_TURN' <<<"$sec" \
  || fail "ordering-only: the ordering endpoint's turn was not rendered"
grep -q 'sb: 1 turns — cited by a surviving finding' <<<"$out" \
  || fail "a session cited only through ordering was not counted as cited"

# --- 5. the inventory keeps three states apart --------------------------------
# "Examined but dropped" is not a coverage gap, and reporting it as one sends the operator looking
# for a hole that is not there.
grep -q 'sc: 1 turns — examined, but its only finding(s) failed the citation check' <<<"$out" \
  || fail "a session cited only by a dropped finding was not reported as examined"
grep -q 'sd: 1 turns — NO FINDING CITES THIS SESSION' <<<"$out" \
  || fail "the one genuinely uncited session was not flagged"
grep -q 'sa: .* — cited by a surviving finding' <<<"$out" \
  || fail "a cited session was misreported"

# --- 6. dropped findings are counted, never quoted ----------------------------
grep -q 'DROPPED BEFORE YOU SAW THEM: 1' <<<"$out" \
  || fail "the dropped count is missing, so the report hides how much was refused"
grep -q 'NEVER SAID THIS' <<<"$out" \
  && fail "a dropped finding's unresolvable quote text was handed to the judge anyway"

# --- 7. the manifest, not the turn files, says what the generator was given ----
# A transcript that failed to extract leaves no turns, so reconstructing the inventory from the
# turn files makes the session vanish — the coverage gap disappears exactly when it is real.
printf '{"sessions": ["sa", "sb", "sc", "sd", "se"]}\n' > "$TMP/manifest.json"
man="$(python3 "$BUILD" --checked "$TMP/checked.json" --turns "${TURNS[@]}" --manifest "$TMP/manifest.json")" \
  || fail "builder failed with a manifest"
grep -q 'se: 0 turns — NO FINDING CITES THIS SESSION' <<<"$man" \
  || fail "a manifest session with no extracted turns vanished from the inventory"

printf '{"sessions": ["sa"]}\n' > "$TMP/short-manifest.json"
short="$(python3 "$BUILD" --checked "$TMP/checked.json" --turns "${TURNS[@]}" --manifest "$TMP/short-manifest.json")"
grep -q 'sd: 1 turns — NOT IN THE MANIFEST' <<<"$short" \
  || fail "a session absent from the manifest was not reported as possibly unseen"

# --- 8. rulebooks reach the judge ---------------------------------------------
# judge.md tells the judge to check a recommendation against the existing rules. Without this the
# instruction is unanswerable from the input it is given.
printf 'RULEBOOK_SENTINEL: never repeat a global rule in a repo file.\n' > "$TMP/rules.md"
withrules="$(python3 "$BUILD" --checked "$TMP/checked.json" --turns "${TURNS[@]}" --rulebook "$TMP/rules.md")"
grep -q 'RULEBOOK_SENTINEL' <<<"$withrules" \
  || fail "a rulebook passed with --rulebook did not reach the output"

# --- 9. the refusals ----------------------------------------------------------
# A refusal is a DIAGNOSIS, not a crash. A traceback also exits non-zero, so a test that only
# checks the exit status cannot tell "this input is untrustworthy, here is why" from "this input
# hit an unhandled KeyError" — and the second leaves an operator with a stack trace at 05:30.
expect_refused() { # label, args...
  local label="$1" out rc; shift
  set +e; out="$("$@" 2>&1)"; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "$label exited 0 instead of refusing"
  grep -q 'Traceback (most recent call last)' <<<"$out" \
    && fail "$label crashed instead of reporting: the operator gets a stack trace, not a reason"
  grep -q '^build_judge_input: ' <<<"$out" \
    || fail "$label exited non-zero without saying why"
}
# The same session twice: one id, two bodies. Picking a version silently hands the judge context
# from the wrong copy — and it does not reliably crash, because the surviving copy's window is
# self-consistent. This case needs findings that cite ONLY session A, or the refusal comes from the
# unrelated missing-transcript check and the duplicate goes untested.
cat > "$TMP/a-only.json" <<EOF
{"findings": [
 {$(req a-only "cites nothing but session A"),
  "quotes":[{"turn":"sa:bbbbbbbb","text":"Die Cron-Zeile fehlt"}]}
]}
EOF
python3 "$CHECK" --findings "$TMP/a-only.json" --turns "$TMP/a.turns" \
  --out "$TMP/checked-a-only.json" >/dev/null || fail "checker failed on the session-A fixture"
python3 "$BUILD" --checked "$TMP/checked-a-only.json" --turns "$TMP/a.turns" >/dev/null \
  || fail "the session-A fixture must build cleanly when the transcript is passed once"
dup_out="$(python3 "$BUILD" --checked "$TMP/checked-a-only.json" \
             --turns "$TMP/a.turns" "$TMP/a.turns" 2>&1)" && \
  fail "the same transcript passed twice was accepted — the judge would get context from one of two copies"
grep -q 'appears in both' <<<"$dup_out" \
  || fail "the duplicate turn id was refused for some other reason: $dup_out"
# A negative width renders no evidence at all while looking like a success.
expect_refused "a negative --context" \
  python3 "$BUILD" --checked "$TMP/checked.json" --turns "${TURNS[@]}" --context -1
expect_refused "a missing turns file" \
  python3 "$BUILD" --checked "$TMP/checked.json" --turns "$TMP/nonexistent.turns"
expect_refused "a checked file that is not an object" \
  bash -c "printf '[]' > '$TMP/bad.json'; python3 '$BUILD' --checked '$TMP/bad.json' --turns '$TMP/a.turns'"
# Checked against one transcript set, built against another: the finding would otherwise print as
# though it carried evidence nobody can see.
expect_refused "a cited turn missing from the supplied transcripts" \
  python3 "$BUILD" --checked "$TMP/checked.json" --turns "$TMP/a.turns"

# --- 10. nothing proposed and everything dropped are different outcomes -------
printf '{"findings": []}\n' > "$TMP/none.json"
python3 "$CHECK" --findings "$TMP/none.json" --turns "$TMP/a.turns" --out "$TMP/checked-none.json" >/dev/null
grep -q 'proposed no findings at all' \
  <<<"$(python3 "$BUILD" --checked "$TMP/checked-none.json" --turns "$TMP/a.turns")" \
  || fail "an empty generation was reported as though its findings had been rejected"

cat > "$TMP/alldropped.json" <<EOF
{"findings": [{$(req gone "all of it dropped"), "quotes":[{"turn":"sa:99999999","text":"never said"}]}]}
EOF
python3 "$CHECK" --findings "$TMP/alldropped.json" --turns "$TMP/a.turns" --out "$TMP/checked-all.json" >/dev/null
grep -q 'every finding the generating stage proposed was dropped' \
  <<<"$(python3 "$BUILD" --checked "$TMP/checked-all.json" --turns "$TMP/a.turns")" \
  || fail "an all-dropped run was not distinguished from an empty one"

echo "test-judge-input: ok"
