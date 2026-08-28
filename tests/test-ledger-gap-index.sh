#!/usr/bin/env bash
set -euo pipefail

# The two ledger aggregates that used to fork `date -d` once per row now convert their whole batch
# in one lib/ledger_epochs.py pass, and median_gap reads a cached per-repo index instead of
# re-slurping the never-pruned ledger on every lens selection. Both are pure performance work, so
# what this test pins is that NOTHING about the answers moved: the three parse outcomes the shell
# loops distinguish (empty / unparsable / parsed), the median itself, the bootstrap floors, the
# retraction exclusion (ADR 0023), and the mtime invalidation that keeps the cache honest.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
LIB="$ROOT/lib/ledger_epochs.py"

# --- tsv-epochs: field N converted in place, every other field and the row ALIGNMENT untouched ----
# The index loop reads `kind repo dim epoch` positionally and skips a row whose ts is empty while
# scoring an unparsable one 0, so an empty field must stay empty and a bad row must not shift the
# rows after it.
iso="2026-08-28T01:02:03+00:00"; want="$(date -d "$iso" +%s)"
out="$(printf 'svc\t/r\tperf\t%s\nsvc\t/r\tdocs\t\nship\t/r\tcraft\tnot-a-timestamp\n' "$iso" \
        | python3 "$LIB" tsv-epochs --field 4)"
[ "$(sed -n 1p <<<"$out")" = "$(printf 'svc\t/r\tperf\t%s' "$want")" ] \
  || fail "a parsed ts should convert to the same epoch \`date -d\` gave (got $(sed -n 1p <<<"$out"))"
[ "$(sed -n 2p <<<"$out")" = "$(printf 'svc\t/r\tdocs\t')" ] \
  || fail "an empty ts must stay empty (the loop's skip), not become 0"
[ "$(sed -n 3p <<<"$out")" = "$(printf 'ship\t/r\tcraft\t0')" ] \
  || fail "an unparsable ts must score 0 for its own row only"

# --- median-gaps: the median of the consecutive intervals, over PARSED epochs only ----------------
base=1700000000
gapin() { for e in "$@"; do printf '/r\t%s\n' "$(date -Iseconds -d "@$e")"; done; }
mg="$( { gapin $((base)) $((base+100)) $((base+300)) $((base+400)); \
         printf '/r\t\n/r\tnot-a-timestamp\n'; } | python3 "$LIB" median-gaps )"
# gaps 100,200,100 -> sorted 100,100,200 -> median 100; the two unusable rows are not services.
[ "$mg" = "$(printf '/r\t4\t100')" ] || fail "median-gaps should report 4 services and median 100 (got $mg)"

# --- median_gap: same answers, now served from the mtime-invalidated per-repo index ---------------
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
       NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"

REPO="/tmp/fake-repo-gap-index"      # never touched on disk — only a ledger key
row() { # item outcome epoch
  jq -nc --arg i "$1" --arg r "$REPO" --arg o "$2" --arg ts "$(date -Iseconds -d "@$3")" \
    '{item:$i, repo:$r, dimension:"perf", outcome:$o, ts:$ts}' >> "$LEDGER"
}
row svc-a finding   $((base))
row svc-b shipped   $((base+100))
row svc-c abandoned $((base+300))
row svc-d empty     $((base+400))

[ "$(median_gap "$REPO" 2)" = 100 ] || fail "median_gap should be 100 (got $(median_gap "$REPO" 2))"
[ "$(median_gap "$REPO" 9)" = "$((60*86400))" ] \
  || fail "fewer services than dimensions must bootstrap to 60d"
[ "$(median_gap /tmp/repo-with-no-ledger-rows 1)" = "$((60*86400))" ] \
  || fail "a repo with no service rows must bootstrap, not read another repo's row"
[ -f "$LEDGER_GAP_INDEX" ] || fail "median_gap should have built the gap index"
IFS= read -r first < "$LEDGER_GAP_INDEX"
[ "$first" = "$LEDGER_GAP_INDEX_VERSION" ] || fail "the index must open with its format marker"

# A retracted `empty` is not a service (ADR 0023): counting it would put a 50s gap in the middle and
# drag the median to 75. The append also has to invalidate the index built above.
row retracted-item empty $((base+50))
jq -nc --arg i retracted-item --arg r "$REPO" \
  '{item:$i, repo:$r, dimension:"perf", outcome:"retracted", ts:"2026-01-01T00:00:00+00:00"}' >> "$LEDGER"
[ "$(median_gap "$REPO" 2)" = 100 ] \
  || fail "a retracted empty must not count as a service (got $(median_gap "$REPO" 2))"

# A real service row appended after the index was built must be picked up, not cached away:
# gaps 100,200,100,99600 -> sorted 100,100,200,99600 -> even median (100+200)/2 = 150.
row svc-e shipped $((base+100000))
[ "$(median_gap "$REPO" 2)" = 150 ] \
  || fail "a row appended after the index was built must invalidate it (got $(median_gap "$REPO" 2))"

echo "test-ledger-gap-index: ok"
