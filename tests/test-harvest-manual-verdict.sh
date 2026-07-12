#!/usr/bin/env bash
set -euo pipefail

# harvest manual-verdict UX + ledger hardening:
#  - a corrupt ledger line aborts loudly (never a silent no-op exiting 0);
#  - re-recording an identical manual verdict appends nothing (idempotent);
#  - a selector spanning >1 branch warns and shows them.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LEDGER="$TMP/ledger.jsonl"
RB="$ROOT/rulebook.example.yaml"
run() { STATE_DIR="$TMP" LEDGER="$LEDGER" RULEBOOK="$RB" bash "$ROOT/bin/harvest.sh" "$@"; }

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

# --- multi-branch selector warns ---------------------------------------------------
ship "nightshift/b2" "sha2" "/r:shared:L9"
ship "nightshift/b3" "sha3" "/r:shared:L9"   # same fingerprint, two branches
warn="$(run verdict "/r:shared:L9" merged 2>&1 >/dev/null || true)"
grep -q "distinct branches" <<<"$warn" || { echo "expected multi-branch warning, got: $warn" >&2; exit 1; }

# --- corrupt ledger aborts loudly --------------------------------------------------
printf 'not json at all\n' >> "$LEDGER"
if run --dry-run >/dev/null 2>&1; then
  echo "corrupt ledger did NOT abort (silent no-op)" >&2; exit 1
fi

echo "test-harvest-manual-verdict: ok"
