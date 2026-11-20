#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# The two ledger aggregates that used to fork `date -d` once per row now convert their whole batch
# in one lib/ledger.py pass, and median_gap reads a cached per-repo index instead of
# re-slurping the never-pruned ledger on every lens selection. Pin timestamp parsing, the median,
# bootstrap floors, retraction exclusion (ADR 0023), and cache invalidation. Cadence counts parent
# Explore passes, so sibling findings must not shorten it or advance the bootstrap service count.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
# The conversions the index commands apply to their @tsv rows, fed TSV directly.
tsv_epochs() { # stdin TSV -> the same TSV with field 4 as an epoch
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger
for line in sys.stdin: sys.stdout.write(ledger.epoch_field(line.rstrip("\n"), 4) + "\n")' "$ROOT/lib"
}
median_gaps() { # stdin "repo<TAB>ts<TAB>item" -> "repo<TAB>n<TAB>median" per repo
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger
sys.stdout.write("".join(l + "\n" for l in ledger.median_gap_lines([l.rstrip("\n") for l in sys.stdin])))' "$ROOT/lib"
}

# --- tsv-epochs: field N converted in place, every other field and the row ALIGNMENT untouched ----
# The index loop reads `kind repo dim epoch` positionally and skips a row whose ts is empty while
# scoring an unparsable one 0, so an empty field must stay empty and a bad row must not shift the
# rows after it.
iso="2026-08-28T01:02:03+00:00"; want="$(date -d "$iso" +%s)"
out="$(printf 'svc\t/r\tperf\t%s\nsvc\t/r\tdocs\t\nship\t/r\tcraft\tnot-a-timestamp\n' "$iso" \
        | tsv_epochs)"
[ "$(sed -n 1p <<<"$out")" = "$(printf 'svc\t/r\tperf\t%s' "$want")" ] \
  || fail "a parsed ts should convert to the same epoch \`date -d\` gave (got $(sed -n 1p <<<"$out"))"
[ "$(sed -n 2p <<<"$out")" = "$(printf 'svc\t/r\tdocs\t')" ] \
  || fail "an empty ts must stay empty (the loop's skip), not become 0"
[ "$(sed -n 3p <<<"$out")" = "$(printf 'ship\t/r\tcraft\t0')" ] \
  || fail "an unparsable ts must score 0 for its own row only"

# Naive local timestamps must stay on GNU date's compatibility path. Around a DST fold Python's
# datetime.timestamp() chooses the earlier occurrence while `date -d` chooses the later one; using
# the Python fast path would silently move an imported/hand-edited ledger row by one hour.
dst="2026-10-25T02:30:00"
dst_want="$(TZ=Europe/Vienna date -d "$dst" +%s)"
dst_got="$(printf 'svc\t/r\tperf\t%s\n' "$dst" \
            | TZ=Europe/Vienna tsv_epochs | cut -f4)"
[ "$dst_got" = "$dst_want" ] \
  || fail "a naive DST-fold timestamp must match \`date -d\` (want $dst_want, got $dst_got)"

# `int()` truncates a negative fractional epoch toward zero, while GNU date floors it. Pre-epoch
# rows are not produced by nightshift today, but the converter promises the old parser's answers.
pre="1969-12-31T23:59:59.500000+00:00"
pre_want="$(date -d "$pre" +%s)"
pre_got="$(printf 'svc\t/r\tperf\t%s\n' "$pre" \
            | tsv_epochs | cut -f4)"
[ "$pre_got" = "$pre_want" ] \
  || fail "a pre-epoch timestamp must match \`date -d\` (want $pre_want, got $pre_got)"

# --- median-gaps: the median of the consecutive intervals, over PARSED epochs only ----------------
base=1700000000
gapin() { for e in "$@"; do printf '/r\t%s\n' "$(date -Iseconds -d "@$e")"; done; }
mg="$( { gapin $((base)) $((base+100)) $((base+300)) $((base+400)); \
         printf '/r\t\n/r\tnot-a-timestamp\n'; } | median_gaps )"
# gaps 100,200,100 -> sorted 100,100,200 -> median 100; the two unusable rows are not services.
[ "$mg" = "$(printf '/r\t4\t100')" ] || fail "median-gaps should report 4 services and median 100 (got $mg)"

# Siblings collapse to their earliest VALID epoch, even out of order and across UTC offsets.
# A parent row and its siblings also share one service; grouping must stay scoped to the repo.
mg="$(printf '%s\n' \
  $'/r\t2026-08-28T01:02:00+00:00\titem-100-f1' \
  $'/r\t2026-08-28T03:00:00+02:00\titem-100-f0' \
  $'/r\tnot-a-timestamp\titem-100-f2' \
  $'/r\t\titem-100-f3' \
  $'/r\t2026-08-28T01:10:00+00:00\titem-200' \
  $'/r\t2026-08-28T01:11:00+00:00\titem-200-f0' \
  $'/s\t2026-08-28T01:05:00+00:00\titem-100-f0' \
  $'/s\t2026-08-28T01:06:00+00:00\titem-100-f1' | median_gaps)"
[ "$mg" = "$(printf '/r\t2\t600\n/s\t1\t0')" ] \
  || fail "siblings must share the earliest parsed epoch within each repo (got $mg)"

# Distinct passes at the same second remain distinct. Legacy/noncanonical IDs stay intact, and
# rows without IDs must not all merge into a fictitious common parent.
mg="$(for item in item-100-f0 item-200-f0 legacy-f0 legacy-f1 f0 f1 '' ''; do
  printf '/r\t%s\t%s\n' "$iso" "$item"
done | median_gaps)"
[ "$mg" = "$(printf '/r\t8\t0')" ] \
  || fail "distinct passes and unidentified rows at the same second must remain separate (got $mg)"

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

# Ten daily Explore passes with two findings 60s apart used to produce 20 services, median 60s,
# and a 1500s ceiling for ten lenses. They must produce ten services, median 1d, and ceiling 25d.
REPO="/tmp/fake-repo-sibling-cadence"
for day in {0..9}; do
  epoch=$((base + day*86400))
  row "item-$epoch-f0" finding "$epoch"
  row "item-$epoch-f1" shipped "$((epoch+60))"
done
row "item-$base-f2" abandoned "$((base+120))"
[ "$(median_gap "$REPO" 10)" = 86400 ] || fail "daily Explore siblings must give a daily median"
[ "$(dim_ceiling "$REPO" 10)" = "$((25*86400))" ] || fail "ten lenses need a 25d overdue ceiling"
[ "$(median_gap "$REPO" 11)" = "$((60*86400))" ] \
  || fail "sibling findings must not count toward the bootstrap service threshold"
(
  # At equal one-day staleness, Recon must still steer toward high yield. Under the old 1500s
  # ceiling every lens became overdue, giving the first low-yield lens the same score as high.
  repo_dimensions() { echo 'low-a low-b low-c low-d low-e low-f low-g low-h low-i high'; }
  dim_weight() { if [ "$2" = high ]; then echo "$DIM_W_HIGH"; else echo "$DIM_W_LOW"; fi; }
  evidence_override() { return 1; }
  reviewed=$(( $(date +%s) - 86400 ))
  last_dim_epoch() { echo "$reviewed"; }
  [ "$(select_dimension "$REPO")" = high ] || fail "daily siblings must not neutralize Recon yield weights"
)

# The old derived cache has the same columns but different semantics. Even if newer than the
# ledger, its v1 marker must force a rebuild of both count and median.
printf '#nightshift-ledger-gap-idx v1\n%s\t21\t60\n' "$REPO" > "$LEDGER_GAP_INDEX"
touch -d '@4102444800' "$LEDGER_GAP_INDEX"
[ "$(median_gap "$REPO" 10)" = 86400 ] || fail "a v1 index must be rebuilt even when newer"
[ "$(awk -F'\t' -v r="$REPO" '$1==r {print $2}' "$LEDGER_GAP_INDEX")" = 10 ] \
  || fail "the rebuilt index must count ten Explore passes"

# Retract the earliest sibling: surviving siblings still count once, but the withdrawn epoch
# must not win the minimum. Retracting all siblings removes the service and restores bootstrap.
jq -nc --arg i "item-$base-f0" --arg r "$REPO" \
  '{item:$i,repo:$r,outcome:"retracted"}' >> "$LEDGER"
[ "$(median_gap "$REPO" 10)" = 86400 ] || fail "retracting one sibling must leave its pass serviced"
for suffix in f1 f2; do
  jq -nc --arg i "item-$base-$suffix" --arg r "$REPO" \
    '{item:$i,repo:$r,outcome:"retracted"}' >> "$LEDGER"
done
[ "$(median_gap "$REPO" 10)" = "$((60*86400))" ] \
  || fail "a fully retracted pass must not count toward bootstrap"

# With two passes, the gap exposes which sibling supplied the representative epoch directly.
REPO="/tmp/fake-repo-retracted-sibling"
row item-100-f0 empty "$base"
row item-100-f1 finding "$((base+60))"
row item-200 shipped "$((base+86400))"
jq -nc --arg i item-100-f0 --arg r "$REPO" \
  '{item:$i,repo:$r,outcome:"retracted"}' >> "$LEDGER"
[ "$(median_gap "$REPO" 2)" = 86340 ] \
  || fail "a retracted sibling must not supply its parent's earliest timestamp"

echo "test-ledger-gap-index: ok"
