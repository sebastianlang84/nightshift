#!/usr/bin/env bash
set -euo pipefail

# `harvest.sh retract <night>` withdraws that night's `empty` rows as EVIDENCE.
#
# An `empty` row claims "this lens was reviewed on this repo on this night and was clean". A night
# whose stages never ran makes that claim with nothing behind it — ADR 0023's 2026-08-05 credential
# outage produced four such rows before the abort path existed. The ledger is append-only, so the
# claim is withdrawn rather than deleted: a `retracted` row names the item, and the two readers that
# treat `empty` as evidence skip it.
#
# Asserted here: the retraction is scoped to one night, appends rather than mutates, is idempotent,
# and actually reaches the ADR 0015 exclusion-suggestion window.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LEDGER="$TMP/ledger.jsonl"
REPO="$TMP/repo"
git init -q -b main "$REPO"
printf 'x\n' > "$REPO/a.md"
git -C "$REPO" -c user.name=t -c user.email=t@localhost add -A
git -C "$REPO" -c user.name=t -c user.email=t@localhost commit -qm init

row() { # night item dimension scope
  jq -nc --arg n "$1" --arg i "$2" --arg d "$3" --arg s "$4" --arg r "$REPO" \
    '{night:$n,item:$i,repo:$r,fingerprint:"",branch:null,sha:null,outcome:"empty",
      dimension:$d,scope:$s,summary:"",ts:($n+"T04:00:00+02:00"),schema_version:2}' >> "$LEDGER"
}

# The dead night (three lenses) plus one row from a night that genuinely ran — the retraction must
# not touch the latter.
row 2026-08-05 item-dead-1 deps        in_scope_no_findings
row 2026-08-05 item-dead-2 craft       in_scope_no_findings
row 2026-08-05 item-dead-3 correctness in_scope_no_findings
row 2026-08-06 item-live-1 deps        in_scope_no_findings

run() { STATE_DIR="$TMP" LEDGER="$LEDGER" PROBE_SNAPSHOT="$TMP/probe.json" \
        RULEBOOK="$ROOT/rulebook.example.yaml" bash "$ROOT/bin/harvest.sh" "$@"; }

before=$(wc -l < "$LEDGER")
run retract 2026-08-05 "agent credentials dead — no stage ran" >"$TMP/out1" 2>&1 \
  || { echo "retract failed" >&2; cat "$TMP/out1" >&2; exit 1; }

# Append-only: the original rows survive untouched, three retractions were added.
[ "$(jq -s '[.[]|select(.outcome=="empty")]|length' "$LEDGER")" = 4 ] \
  || { echo "retract must not remove or rewrite the empty rows" >&2; exit 1; }
[ "$(wc -l < "$LEDGER")" -eq "$((before + 3))" ] \
  || { echo "expected exactly 3 appended rows" >&2; exit 1; }
jq -se 'all(.[]|select(.outcome=="retracted"); .retracts=="empty" and .retracted_night=="2026-08-05"
             and .source=="manual" and (.reason|length)>0)' "$LEDGER" >/dev/null \
  || { echo "retraction rows lack their provenance fields" >&2; exit 1; }

# Scoped to the night: the row from the night that ran is untouched.
[ "$(jq -s '[.[]|select(.outcome=="retracted" and .item=="item-live-1")]|length' "$LEDGER")" = 0 ] \
  || { echo "retract crossed into another night" >&2; exit 1; }

# Idempotent: running it again appends nothing.
run retract 2026-08-05 >"$TMP/out2" 2>&1
[ "$(wc -l < "$LEDGER")" -eq "$((before + 3))" ] \
  || { echo "second retract appended duplicate rows" >&2; exit 1; }
grep -q 'nothing to retract' "$TMP/out2" \
  || { echo "a no-op retract must say so, got: $(cat "$TMP/out2")" >&2; exit 1; }

# A malformed night is rejected rather than silently matching nothing.
if run retract 05.08.2026 >/dev/null 2>&1; then
  echo "a non-ISO night must be rejected" >&2; exit 1
fi

# --- the readers must actually honour it ---
# ADR 0015 suggests a rulebook exclusion after 3 consecutive out_of_scope passes for a (repo,dim).
# Two real out_of_scope passes with a RETRACTED row wedged between them must still suggest: the
# retracted row is not a pass, so it must not occupy a slot in the 3-row window and mask the signal.
L2="$TMP/l2.jsonl"; LEDGER="$L2"
row_os() { jq -nc --arg n "$1" --arg i "$2" --arg r "$REPO" \
  '{night:$n,item:$i,repo:$r,outcome:"empty",dimension:"deps",scope:"out_of_scope",
    ts:($n+"T04:00:00+02:00"),schema_version:2}' >> "$L2"; }
row_os 2026-08-01 item-os-1
row_os 2026-08-02 item-os-2
jq -nc --arg r "$REPO" '{night:"2026-08-05",item:"item-dead-9",repo:$r,outcome:"empty",
  dimension:"deps",scope:"in_scope_no_findings",ts:"2026-08-05T04:00:00+02:00",schema_version:2}' >> "$L2"
row_os 2026-08-06 item-os-3

suggestions() { # -> the digest's exclusion-suggestion section for this ledger
  NIGHTSHIFT_SOURCED=1 LEDGER="$L2" jq -rs '
    [.[]|select(.outcome=="retracted")|.item] as $void
    | [.[] | select(.dimension!=null and ([.item]|inside($void)|not)
                    and (.outcome=="empty" or .outcome=="finding" or .outcome=="shipped" or .outcome=="abandoned"))]
    | group_by([.repo,.dimension]) | map(sort_by(.ts) | .[-3:])
    | map(select(length==3 and all(.[]; .outcome=="empty" and .scope=="out_of_scope")))
    | length' "$L2"
}
[ "$(suggestions)" = 0 ] || { echo "unretracted, the wedged row must still mask the suggestion" >&2; exit 1; }

STATE_DIR="$TMP" LEDGER="$L2" PROBE_SNAPSHOT="$TMP/probe.json" \
  RULEBOOK="$ROOT/rulebook.example.yaml" bash "$ROOT/bin/harvest.sh" retract 2026-08-05 >/dev/null 2>&1
[ "$(suggestions)" = 1 ] \
  || { echo "after retraction the three real out_of_scope passes must suggest an exclusion" >&2; exit 1; }

echo "test-retract-empty-night: ok"
