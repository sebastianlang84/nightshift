#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# harvest manual-verdict UX + ledger hardening:
#  - a corrupt ledger line aborts loudly (never a silent no-op exiting 0);
#  - re-recording an identical manual verdict appends nothing (idempotent);
#  - a selector spanning >1 repo-scoped identity is refused and shows stable item ids.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "$ROOT/.test-verdict.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
LEDGER="$TMP/ledger.jsonl"
RB="$ROOT/rulebook.example.yaml"
run() {
  NIGHTSHIFT_HOME="$ROOT" STATE_DIR="$TMP" LEDGER="$LEDGER" RULEBOOK="$RB" \
    PROBE_SNAPSHOT="$TMP/findings-probe.json" bash "$ROOT/bin/harvest.sh" "$@"
}

ship() { # branch sha fingerprint
  jq -nc --arg b "$1" --arg s "$2" --arg fp "$3" \
    '{night:"2026-07-13",item:("i-"+$s),repo:"/r",fingerprint:$fp,branch:$b,sha:$s,
      outcome:"shipped",pr_url:null,schema_version:2}' >> "$LEDGER"
}

# --- idempotent manual verdict -----------------------------------------------------
ship "nightshift/b1" "sha1" "/r:x:L1"
run verdict nightshift/b1 merged >/dev/null
n1=$(wc -l < "$LEDGER")
run verdict nightshift/b1 merged >/dev/null   # identical -> must append nothing
n2=$(wc -l < "$LEDGER")
[ "$n1" = "$n2" ] || { echo "idempotency: re-recording appended a row ($n1 -> $n2)" >&2; exit 1; }
# a genuine change still records
run verdict nightshift/b1 wontfix >/dev/null
[ "$(wc -l < "$LEDGER")" -gt "$n2" ] || { echo "verdict change was not recorded" >&2; exit 1; }

# --- ambiguous selectors fail closed ------------------------------------------------
ship "nightshift/b2" "sha2" "/r:shared:L9"
ship "nightshift/b3" "sha3" "/r:shared:L9"   # same fingerprint, two branches
before=$(wc -l < "$LEDGER")
rc=0; run verdict "/r:shared:L9" merged >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" = 2 ] || { echo "ambiguous fingerprint should exit 2, got $rc" >&2; exit 1; }
grep -q "ambiguous selector" "$TMP/err" || { echo "ambiguity was not explained" >&2; exit 1; }
[ "$(wc -l < "$LEDGER")" = "$before" ] || { echo "ambiguous verdict still wrote the ledger" >&2; exit 1; }

# The same branch name can exist in two repos. Branch-only counting called that one target and
# silently chose the newest row; repo-scoped identity must reject it too.
jq -nc '{night:"2026-07-13",item:"other-item",repo:"/other",fingerprint:"other:fp",branch:"nightshift/b1",sha:"other-sha",outcome:"shipped",schema_version:2}' >> "$LEDGER"
rc=0; run verdict nightshift/b1 merged >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" = 2 ] || { echo "cross-repo branch selector should exit 2, got $rc" >&2; exit 1; }
grep -q 'use an item id' "$TMP/err"

# Finding fingerprints and scoped adoption selectors can have the same spelling.
# A repo path can include both spaces and colons.
repo="/r: team/project"
selector="orphan-adopt:$repo:nightshift/shared"
jq -nc --arg fp "$selector" \
  '{item:"finding-shared",repo:"/r",fingerprint:$fp,outcome:"finding"}' >> "$LEDGER"
before=$(wc -l < "$LEDGER")
if run verdict --adopted "$selector" merged >/dev/null 2>&1; then
  echo "adoption selector fell back to a finding" >&2; exit 1
fi
[ "$(wc -l < "$LEDGER")" = "$before" ]

jq -nc --arg r "$repo" --arg sel "$selector" \
  '{item:"orphan-adopt",repo:"/other",branch:"nightshift/shared",sha:"adopted-sha",
    fingerprint:null,outcome:"shipped",adopted:true} | ., (.item = $sel | .repo = $r)' >> "$LEDGER"
rc=0; run verdict nightshift/shared merged >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" = 2 ]
grep -Fq "[--adopted '$selector']" "$TMP/err"
before=$(wc -l < "$LEDGER")
rc=0; run verdict "$selector" wontfix >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" = 2 ]
grep -q 'ambiguous selector' "$TMP/err"
[ "$(wc -l < "$LEDGER")" = "$before" ]
if run close "orphan-adopt:/other:nightshift/shared" >/dev/null 2>&1; then
  echo "close accepted an adopted branch" >&2; exit 1
fi
[ "$(wc -l < "$LEDGER")" = "$before" ]
run verdict --adopted "$selector" merged >/dev/null
jq -es --arg r "$repo" 'last | .repo == $r and .branch == "nightshift/shared"
  and .outcome == "verdict" and .verdict == "merged" and .fingerprint == null' "$LEDGER" >/dev/null
run verdict --adopted "orphan-adopt:/other:nightshift/shared" dropped >/dev/null
jq -es 'last | .repo == "/other" and .item == "orphan-adopt" and .verdict == "dropped"' "$LEDGER" >/dev/null
run verdict --fingerprint "$selector" wontfix >/dev/null
jq -es 'last | .item == "finding-shared" and .branch == null and .verdict == "wontfix"' "$LEDGER" >/dev/null
unique="orphan-adopt:$repo:nightshift/unique"
jq -nc --arg r "$repo" --arg id "$unique" \
  '{item:$id,repo:$r,branch:"nightshift/unique",outcome:"shipped",adopted:true}' >> "$LEDGER"
run verdict "$unique" dropped >/dev/null
jq -es --arg id "$unique" 'last | .item == $id and .verdict == "dropped"' "$LEDGER" >/dev/null
jq -nc '{item:"open-finding",repo:"/r",fingerprint:"/r:open:L1",outcome:"finding"}' >> "$LEDGER"
run close open-finding >/dev/null
jq -es 'last | .item == "open-finding" and .branch == null and .verdict == "resolved"' "$LEDGER" >/dev/null
before=$(wc -l < "$LEDGER")
if run close open-finding >/dev/null 2>&1; then
  echo "close accepted an already closed finding" >&2; exit 1
fi
[ "$(wc -l < "$LEDGER")" = "$before" ]

# --- unrecognised arguments are rejected, never silently harvested -----------------
# A typo'd preview flag must NOT fall through to the argument-less (ledger-writing) path.
before=$(wc -l < "$LEDGER")
for bad in --dryrun -n --dry_run nightshift/b1 verdict "verdict nightshift/b1"; do
  rc=0
  # shellcheck disable=SC2086 -- deliberate word-splitting: these are argv fixtures
  run $bad >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "arg '$bad' should exit 2, got $rc" >&2; exit 1; }
done
rc=0; run --dry-run stray >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "trailing argument should exit 2, got $rc" >&2; exit 1; }
rc=0; run verdict nightshift/b1 merged unquoted multi word >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "unquoted multi-word reason should exit 2, got $rc" >&2; exit 1; }
[ "$(wc -l < "$LEDGER")" = "$before" ] \
  || { echo "a rejected invocation still wrote to the ledger" >&2; exit 1; }
run --help > "$TMP/help.out"   # exits 0 and prints usage on stdout
grep -q -- '--dry-run' "$TMP/help.out" || { echo "--help did not print usage" >&2; exit 1; }

# --- corrupt ledger aborts loudly --------------------------------------------------
printf 'not json at all\n' >> "$LEDGER"
if run --dry-run >/dev/null 2>&1; then
  echo "corrupt ledger did NOT abort (silent no-op)" >&2; exit 1
fi

echo "test-harvest-manual-verdict: ok"
