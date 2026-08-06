#!/usr/bin/env bash
set -euo pipefail

# Freshness probe for open findings (ADR 0021) + the harvest front door:
#  - an untouched target signature classifies as `untouched`, a changed one as `code_changed`;
#  - a pre-signature row and a prose fingerprint stay `unknown` — never guessed either way;
#  - a terminal verdict removes the finding from the snapshot entirely;
#  - a verify result survives a re-probe only while its signature still holds;
#  - the snapshot's `dimension` is the explicit lens or blank — never the fingerprint's type;
#  - `todos` numbers the open findings and `close <n>` records a manual `resolved` for that one.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LEDGER="$TMP/ledger.jsonl"
SNAP="$TMP/findings-probe.json"
REPO="$TMP/repo"
PROBE="$ROOT/lib/probe_findings.py"

# --- a repo with two target files ---------------------------------------------------
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'stable\n'  > "$REPO/keep.md"
printf 'defect\n'  > "$REPO/drift.md"
git -C "$REPO" add -A; git -C "$REPO" commit -qm init

sig_of() { # file -> the Runner's code_sig for a single-file finding
  { git -C "$REPO" rev-parse "HEAD:$1"; } | sha1sum | cut -c1-12
}
finding() { # fingerprint code_sig item [dimension]
  jq -nc --arg r "$REPO" --arg fp "$1" --arg cs "$2" --arg i "$3" --arg d "${4:-}" \
    '{night:"2026-07-20",item:$i,repo:$r,fingerprint:$fp,branch:null,sha:null,
      outcome:"finding",summary:("finding for "+$fp),code_sig:($cs|if .=="" then null else . end),
      dimension:($d|if .=="" then null else . end),
      ts:"2026-07-20T02:00:00+02:00",schema_version:2}' >> "$LEDGER"
}
state_of() { jq -r --arg i "$1" '.items[]|select(.item==$i)|.state' "$SNAP"; }
dim_of()   { jq -r --arg i "$1" '.items[]|select(.item==$i)|.dimension' "$SNAP"; }
probe() { python3 "$PROBE" --ledger "$LEDGER" --out "$SNAP" >/dev/null; }

finding "keep.md:doc:anchor"      "$(sig_of keep.md)"  item-keep
finding "drift.md:bug:anchor"     "$(sig_of drift.md)" item-drift
finding "old.md:doc:anchor"       ""                   item-nosig       # pre-ADR-0014 row
finding "some free-form prose"    "deadbeefdead"       item-prose       # no file targets
finding "keep.md:cleanup:widget"  "$(sig_of keep.md)"  item-lens  craft # carries an explicit lens

# Nothing changed yet: both signed, path-shaped findings must read as untouched.
probe
[ "$(state_of item-keep)"  = untouched ] || { echo "keep: expected untouched, got $(state_of item-keep)" >&2; exit 1; }
[ "$(state_of item-drift)" = untouched ] || { echo "drift: expected untouched, got $(state_of item-drift)" >&2; exit 1; }
[ "$(state_of item-nosig)" = unknown ]   || { echo "no baseline signature must be unknown" >&2; exit 1; }
[ "$(state_of item-prose)" = unknown ]   || { echo "prose fingerprint must be unknown, not code_changed" >&2; exit 1; }

# The lens is the explicit `dimension` field or nothing. The fingerprint's middle segment is the
# finding TYPE (ADR 0014) and the fingerprint is dimension-free by decision (ADR 0011), so a row
# without the field must read blank — never `cleanup`/`bug` from the wrong vocabulary.
[ "$(dim_of item-lens)"  = craft ] || { echo "explicit dimension must reach the snapshot, got '$(dim_of item-lens)'" >&2; exit 1; }
[ "$(dim_of item-drift)" = "" ]    || { echo "finding type must not be read as a dimension, got '$(dim_of item-drift)'" >&2; exit 1; }

# Touch ONE target: only that finding may move.
printf 'fixed\n' > "$REPO/drift.md"
git -C "$REPO" commit -qam drift
probe
[ "$(state_of item-keep)"  = untouched ]    || { echo "untouched target must not move" >&2; exit 1; }
[ "$(state_of item-drift)" = code_changed ] || { echo "changed target must read code_changed" >&2; exit 1; }

# A verify result is kept while its signature holds, and dropped once the code moves again.
now=$(jq -r '.items[]|select(.item=="item-drift")|.code_sig_now' "$SNAP")
python3 "$PROBE" record-verify --out "$SNAP" --item item-drift --sig "$now" --result open --reason "still there"
probe
[ "$(jq -r '.items[]|select(.item=="item-drift")|.verify.result' "$SNAP")" = open ] \
  || { echo "verify result must survive a re-probe at the same signature" >&2; exit 1; }
printf 'fixed again\n' > "$REPO/drift.md"
git -C "$REPO" commit -qam drift2
probe
[ "$(jq -r '.items[]|select(.item=="item-drift")|has("verify")' "$SNAP")" = false ] \
  || { echo "verify result made against older code must be dropped" >&2; exit 1; }

# --- harvest front door: todos numbering, close records a manual resolved -------------
run() { STATE_DIR="$TMP" LEDGER="$LEDGER" PROBE_SNAPSHOT="$SNAP" RULEBOOK="$ROOT/rulebook.example.yaml" \
        bash "$ROOT/bin/harvest.sh" "$@"; }
rows() { run todos | grep -cE '^[0-9]+ +[0-9?]+d'; }   # data rows only, not the trailing count line
[ "$(rows)" = 5 ] || { echo "todos must list all five open findings, listed $(rows)" >&2; exit 1; }
# Findings share a ts, so `close 1` may land on any of them — assert on what it reports, not on order.
closed=$(run close 1 "fixed by hand" | sed -n 's/.*\[item=\([^ ]*\).*/\1/p')
[ -n "$closed" ] || { echo "close did not report the item it acted on" >&2; exit 1; }
jq -es --arg i "$closed" 'any(.[]; .outcome=="verdict" and .item==$i and .verdict=="resolved" and .source=="manual")' \
  "$LEDGER" >/dev/null || { echo "close must append a manual resolved verdict" >&2; exit 1; }
[ "$(jq --arg i "$closed" '[.items[]|select(.item==$i)]|length' "$SNAP")" = 0 ] \
  || { echo "a closed finding must leave the snapshot" >&2; exit 1; }
[ "$(rows)" = 4 ] || { echo "todos must drop the closed finding" >&2; exit 1; }

echo "test-finding-probe: ok"
