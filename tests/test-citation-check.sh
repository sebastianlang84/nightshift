#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# Stage 2 of ADR 0035 is the one stage the whole design rests on, and it is the cheapest to get
# wrong unnoticed: a checker that quietly keeps everything looks exactly like a checker that had
# nothing to reject. So this proves both directions — what must be refused IS refused, and what is
# sound is not.
#
# Two of the cases below are not invented. They are the defects the prototype actually shipped on
# 2026-09-16, and each one would have become a rule in a real AGENTS.md:
#
#   * a quote reversing what its source said ("Otto fetcht nicht" for "…fetcht also")
#   * a finding asserting an order the transcript has the other way round
#
# The third case is the one this stage CANNOT catch, and the test pins that limit rather than
# papering over it: an elided quote resolves, and must be flagged so stage 3 looks at it.

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

verdict() { # finding-id -> "kept" | "dropped" | "absent"
  python3 - "$1" "$TMP/result.json" <<'PY'
import json, sys
fid, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
if any(f.get("id") == fid for f in d["kept"]):
    print("kept")
elif any((x["finding"] or {}).get("id") == fid for x in d["dropped"]):
    print("dropped")
else:
    print("absent")
PY
}

flagged_elided() {
  python3 - "$1" "$TMP/result.json" <<'PY'
import json, sys
fid, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
for f in d["kept"]:
    if f.get("id") == fid:
        print("yes" if f.get("elided") else "no"); break
else:
    print("absent")
PY
}

cat > "$TMP/findings.json" <<'EOF'
{"findings": [
 {"id":"exact",        "quotes":[{"turn":"sa:bbbbbbbb","text":"Otto hat vor 6 Tagen gepusht, fetcht also."}]},
 {"id":"reversed",     "quotes":[{"turn":"sa:bbbbbbbb","text":"Otto fetcht nicht"}]},
 {"id":"invented",     "quotes":[{"turn":"sa:99999999","text":"anything at all"}]},
 {"id":"no-evidence",  "title":"a claim with nothing under it"},
 {"id":"elided",       "quotes":[{"turn":"sa:bbbbbbbb","text":"Otto hat vor 6 Tagen ... fetcht also."}]},
 {"id":"elided-swapped","quotes":[{"turn":"sa:bbbbbbbb","text":"fetcht also ... Otto hat vor"}]},
 {"id":"order-ok",     "quotes":[{"turn":"sa:aaaaaaaa","text":"hat nightshift gearbeitet?"}],
                       "ordering":[{"before":"sa:aaaaaaaa","after":"sa:dddddddd"}]},
 {"id":"order-wrong",  "quotes":[{"turn":"sa:dddddddd","text":"achso er fetcht nicht alles?!"}],
                       "ordering":[{"before":"sa:dddddddd","after":"sa:bbbbbbbb"}]},
 {"id":"cross-session","quotes":[{"turn":"sb:eeeeeeee","text":"kurzfassung bitte"}],
                       "ordering":[{"before":"sa:aaaaaaaa","after":"sb:eeeeeeee"}]},
 {"id":"one-bad-quote","quotes":[{"turn":"sa:aaaaaaaa","text":"hat nightshift gearbeitet?"},
                                 {"turn":"sa:bbbbbbbb","text":"never said this"}]},
 {"id":"typography",   "quotes":[{"turn":"sa:bbbbbbbb","text":"Mit [ref] adressiert kommen sie ebenfalls nicht an."}]}
]}
EOF

python3 "$CHECK" --findings "$TMP/findings.json" --turns "$TMP/a.turns" "$TMP/b.turns" \
  --out "$TMP/result.json" >/dev/null || fail "checker exited non-zero on a well-formed input"

# --- what must be refused -----------------------------------------------------
expect_dropped() {
  local got; got="$(verdict "$1")"
  [ "$got" = dropped ] || fail "$1 was $got, expected dropped — $2"
}
expect_dropped reversed       "a quote reversing its source is the defect this stage exists for"
expect_dropped invented       "a citation to a turn that does not exist must never resolve"
expect_dropped no-evidence    "a finding with no quotes is the whole point of the stage"
expect_dropped elided-swapped "elided fragments must appear in the order the quote puts them"
expect_dropped order-wrong    "an ordering claim the transcript contradicts must be refused"
expect_dropped one-bad-quote  "a finding stands or falls with ALL its evidence, not its best piece"

# --- what must survive --------------------------------------------------------
expect_kept() {
  local got; got="$(verdict "$1")"
  [ "$got" = kept ] || fail "$1 was $got, expected kept — $2"
}
expect_kept exact        "an exact quote must resolve"
expect_kept elided       "elision is allowed; it is flagged, not refused"
expect_kept order-ok     "an ordering claim the transcript supports must resolve"
expect_kept typography   "bracketed text must not trip the matcher"

# --- the limit this stage cannot pass -----------------------------------------
# An elided quote resolves even when the dropped clause reverses its meaning. That is not a bug to
# fix here — it is why stage 3 exists — so the flag reaching stage 3 is itself load-bearing.
[ "$(flagged_elided elided)" = yes ] || fail "an elided quote was kept WITHOUT the elided flag"
[ "$(flagged_elided exact)"  = no  ] || fail "a quote with no elision was flagged as elided"

# --- cross-session ordering rests on timestamps, and says so ------------------
[ "$(verdict cross-session)" = kept ] \
  || fail "cross-session ordering with timestamps on both sides should resolve"

# --- a checker that cannot read its inputs fails loudly ----------------------
if python3 "$CHECK" --findings "$TMP/findings.json" --turns "$TMP/nonexistent.turns" \
     --out "$TMP/x.json" >/dev/null 2>&1; then
  fail "missing turns file exited 0 — everything would silently drop as unresolvable"
fi

echo "test-citation-check: ok"
