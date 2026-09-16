#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # CI runs the suite with GIT_CONFIG_* set; every test clears it (AGENTS.md)

# Stage 2 of ADR 0035 is the one stage the whole design rests on, and it is the cheapest to get
# wrong unnoticed: a checker that quietly keeps everything looks exactly like a checker that had
# nothing to reject. So this proves both directions — what must be refused IS refused, and what is
# sound is not.
#
# Three of the cases below are not invented. They are the defects the prototype actually shipped on
# 2026-09-16, and each one would have become a rule in a real AGENTS.md:
#
#   * a quote reversing what its source said ("Otto fetcht nicht" for "…fetcht also")
#   * a finding asserting an order the transcript has the other way round
#   * a quote broken off right before the clause that reversed it — an exact substring, and the
#     reason the elided flag is set by the omission MARKER and not by counting fragments
#
# The last of those is also the limit this stage cannot pass: an elided quote resolves. It is
# flagged, not refused, and the flag is what stage 3 acts on.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACT="$ROOT/lib/extract_session.py"
CHECK="$ROOT/lib/check_citations.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-citation-check: $1" >&2; exit 1; }

cat > "$TMP/a.jsonl" <<'EOF'
{"type":"user","uuid":"aaaaaaaa-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:28:07.735Z","origin":{"kind":"human"},"message":{"role":"user","content":"hat nightshift gearbeitet?"}}
{"type":"assistant","uuid":"bbbbbbbb-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:28:20.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Otto hat vor 6 Tagen gepusht, fetcht also. Mit [ref] adressiert kommen sie ebenfalls nicht an."}]}}
{"type":"user","uuid":"dddddddd-1111-2222-3333-444444444444","timestamp":"2026-09-15T19:29:50.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"achso er fetcht nicht alles?!"}}
EOF
cat > "$TMP/b.jsonl" <<'EOF'
{"type":"user","uuid":"eeeeeeee-1111-2222-3333-444444444444","timestamp":"2026-09-15T20:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"kurzfassung bitte"}}
EOF

python3 "$EXTRACT" "$TMP/a.jsonl" --session-id sa > "$TMP/a.turns" || fail "extract failed (a)"
python3 "$EXTRACT" "$TMP/b.jsonl" --session-id sb > "$TMP/b.turns" || fail "extract failed (b)"

cat > "$TMP/verdict.py" <<'PY'
import json, sys
fid, path, what = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
if what == "verdict":
    if any(f.get("id") == fid for f in d["kept"]):
        print("kept")
    elif any((x["finding"] or {}).get("id") == fid for x in d["dropped"]):
        print("dropped")
    else:
        print("absent")
elif what == "elided":
    for f in d["kept"]:
        if f.get("id") == fid:
            print("yes" if f.get("elided") else "no")
            break
    else:
        print("absent")
elif what == "kept-count":
    print(sum(1 for f in d["kept"] if f.get("id") == fid))
PY

verdict()        { python3 "$TMP/verdict.py" "$1" "$TMP/result.json" verdict; }
flagged_elided() { python3 "$TMP/verdict.py" "$1" "$TMP/result.json" elided; }
kept_count()     { python3 "$TMP/verdict.py" "$1" "$TMP/result.json" kept-count; }

# The fields the generate prompt requires. Spelling them out per case would bury what each case is
# actually testing, so only the schema cases below leave one out on purpose.
req() { printf '"id":"%s","title":"t","observation":"o","diagnosis":"d","recommendation":"r","cost":"c"' "$1"; }

cat > "$TMP/findings.json" <<EOF
{"findings": [
 {$(req exact),          "quotes":[{"turn":"sa:bbbbbbbb","text":"Otto hat vor 6 Tagen gepusht, fetcht also."}]},
 {$(req reversed),       "quotes":[{"turn":"sa:bbbbbbbb","text":"Otto fetcht nicht"}]},
 {$(req invented),       "quotes":[{"turn":"sa:99999999","text":"anything at all"}]},
 {$(req no-evidence)},
 {$(req elided),         "quotes":[{"turn":"sa:bbbbbbbb","text":"Otto hat vor 6 Tagen ... fetcht also."}]},
 {$(req elided-trailing),"quotes":[{"turn":"sa:bbbbbbbb","text":"Otto hat vor 6 Tagen gepusht, fetcht also. Mit [ref] ..."}]},
 {$(req elided-leading), "quotes":[{"turn":"sa:bbbbbbbb","text":"... kommen sie ebenfalls nicht an."}]},
 {$(req elided-swapped), "quotes":[{"turn":"sa:bbbbbbbb","text":"fetcht also ... Otto hat vor"}]},
 {$(req order-ok),       "quotes":[{"turn":"sa:aaaaaaaa","text":"hat nightshift gearbeitet?"}],
                         "ordering":[{"before":"sa:aaaaaaaa","after":"sa:dddddddd"}]},
 {$(req order-wrong),    "quotes":[{"turn":"sa:dddddddd","text":"achso er fetcht nicht alles?!"}],
                         "ordering":[{"before":"sa:dddddddd","after":"sa:bbbbbbbb"}]},
 {$(req cross-session),  "quotes":[{"turn":"sb:eeeeeeee","text":"kurzfassung bitte"}],
                         "ordering":[{"before":"sa:aaaaaaaa","after":"sb:eeeeeeee"}]},
 {$(req one-bad-quote),  "quotes":[{"turn":"sa:aaaaaaaa","text":"hat nightshift gearbeitet?"},
                                   {"turn":"sa:bbbbbbbb","text":"never said this"}]},
 {$(req typography),     "quotes":[{"turn":"sa:bbbbbbbb","text":"Mit [ref] adressiert kommen sie ebenfalls nicht an."}]},
 {"id":"no-recommendation","title":"t","observation":"o","diagnosis":"d","cost":"c",
                         "quotes":[{"turn":"sa:aaaaaaaa","text":"hat nightshift gearbeitet?"}]},
 {"id":"blank-title","title":"   ","observation":"o","diagnosis":"d","recommendation":"r","cost":"c",
                         "quotes":[{"turn":"sa:aaaaaaaa","text":"hat nightshift gearbeitet?"}]},
 {$(req exact),          "quotes":[{"turn":"sa:aaaaaaaa","text":"hat nightshift gearbeitet?"}]}
]}
EOF

python3 "$CHECK" --findings "$TMP/findings.json" --turns "$TMP/a.turns" "$TMP/b.turns" \
  --out "$TMP/result.json" >/dev/null || fail "checker exited non-zero on a well-formed input"

# --- what must be refused -----------------------------------------------------
expect_dropped() {
  local got; got="$(verdict "$1")"
  [ "$got" = dropped ] || fail "$1 was $got, expected dropped — $2"
}
expect_dropped reversed         "a quote reversing its source is the defect this stage exists for"
expect_dropped invented         "a citation to a turn that does not exist must never resolve"
expect_dropped no-evidence      "a finding with no quotes is the whole point of the stage"
expect_dropped elided-swapped   "elided fragments must appear in the order the quote puts them"
expect_dropped order-wrong      "an ordering claim the transcript contradicts must be refused"
expect_dropped one-bad-quote    "a finding stands or falls with ALL its evidence, not its best piece"
# The generate prompt requires these fields. Checking them here is what makes that a contract
# rather than a request: a finding with no recommendation is not something an operator can act on.
expect_dropped no-recommendation "a finding missing a required field cannot be acted on"
expect_dropped blank-title       "whitespace is not a value — a blank required field is a missing one"

# --- what must survive --------------------------------------------------------
expect_kept() {
  local got; got="$(verdict "$1")"
  [ "$got" = kept ] || fail "$1 was $got, expected kept — $2"
}
expect_kept exact          "an exact quote must resolve"
expect_kept elided         "elision is allowed; it is flagged, not refused"
expect_kept elided-trailing "a trailing elision still resolves — it is the FLAG that must fire"
expect_kept elided-leading  "a leading elision still resolves"
expect_kept order-ok       "an ordering claim the transcript supports must resolve"
expect_kept typography     "bracketed text must not trip the matcher"

# --- the limit this stage cannot pass -----------------------------------------
# An elided quote resolves even when the dropped clause reverses its meaning. That is not a bug to
# fix here — it is why stage 3 exists — so the flag reaching stage 3 is itself load-bearing.
[ "$(flagged_elided elided)" = yes ] || fail "an elided quote was kept WITHOUT the elided flag"
[ "$(flagged_elided exact)"  = no  ] || fail "a quote with no elision was flagged as elided"
# The prototype's worst finding had a TRAILING elision: an exact substring stopping right before the
# clause that reversed it. One fragment is left, so counting fragments calls it unelided and waves
# it through — the flag has to come from the omission marker itself.
[ "$(flagged_elided elided-trailing)" = yes ] \
  || fail "a trailing elision was not flagged — the exact shape of the defect that motivated the flag"
[ "$(flagged_elided elided-leading)" = yes ] \
  || fail "a leading elision was not flagged"

# --- a duplicate id is refused, once ------------------------------------------
# Two findings under one heading make the judge's verdicts unattributable. The first holder keeps
# the id; the second is dropped.
[ "$(kept_count exact)" = 1 ] || fail "a duplicate finding id was kept twice"

# --- cross-session ordering rests on timestamps, and says so ------------------
[ "$(verdict cross-session)" = kept ] \
  || fail "cross-session ordering with timestamps on both sides should resolve"

# --- a checker that cannot read its inputs fails loudly ----------------------
if python3 "$CHECK" --findings "$TMP/findings.json" --turns "$TMP/nonexistent.turns" \
     --out "$TMP/x.json" >/dev/null 2>&1; then
  fail "missing turns file exited 0 — everything would silently drop as unresolvable"
fi

echo "test-citation-check: ok"
