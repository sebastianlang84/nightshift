#!/usr/bin/env bash
set -euo pipefail

# ADR 0014 — finding identity & lifecycle. Covers the four dimensions the design calls for:
# identity stability, starvation (known-work feed), carry-forward, and clearing (+ invalidation).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

# ---- Part A: pure-function unit checks (source the Runner without running the night) ----
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
       NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" NIGHTSHIFT_SOURCED=1
# shellcheck disable=SC1090
source "$ROOT/bin/nightshift.sh"

fp() { printf '%s' "$1" > "$TMP/f.json"; finding_fingerprint "$TMP/f.json"; }

# Identity is prose- and line-independent, and type-case/whitespace-normalized.
a=$(fp '{"file":"a.py","type":"Bug","symbol":"parse_config","line_window":"L1-L9","summary":"wording one"}')
b=$(fp '{"file":"a.py","type":"bug","symbol":"parse_config","line_window":"L88-L92","summary":"utterly different words"}')
[ "$a" = "$b" ] || { echo "identity not stable across wording/line/case: '$a' != '$b'" >&2; exit 1; }
# Multi-file order-independence.
c=$(fp '{"files":["z.py","a.py"],"type":"dup"}')
d=$(fp '{"files":["a.py","z.py"],"type":"dup"}')
[ "$c" = "$d" ] || { echo "multi-file order changed identity: '$c' != '$d'" >&2; exit 1; }
# A different semantic target is a different identity.
e=$(fp '{"file":"a.py","type":"bug","symbol":"other_fn"}')
[ "$a" != "$e" ] || { echo "distinct symbols collapsed to one identity" >&2; exit 1; }
# Unusable finding → empty identity (caller drops it).
[ -z "$(fp '{"summary":"no anchor at all"}')" ] || { echo "expected empty identity for anchorless finding" >&2; exit 1; }

# Lifecycle suppression + invalidation.
: > "$TMP/state/ledger.jsonl"
ledger_append itemX repoX "a.py:bug:parse_config" "" "" finding "a surfaced thing" "" "" "" correctness "" "SIG1"
already_surfaced "a.py:bug:parse_config" "SIG1" || { echo "matching-sig finding not suppressed" >&2; exit 1; }
! already_surfaced "a.py:bug:parse_config" "SIG2" || { echo "invalidation failed: stale-sig finding still suppressed" >&2; exit 1; }
# known_work lists the still-open finding for its repo (before any clearing verdict).
grep -q "a.py:bug:parse_config" <<<"$(known_work repoX)" || { echo "known_work omitted the open finding" >&2; exit 1; }

# A human wontfix is permanent — suppressed even after the code changed (new sig) — and drops from known_work.
printf '{"outcome":"verdict","fingerprint":"a.py:bug:parse_config","verdict":"wontfix","ts":"2026-07-12T00:00:00+00:00"}\n' >> "$TMP/state/ledger.jsonl"
already_surfaced "a.py:bug:parse_config" "SIG2" || { echo "wontfix not permanently suppressing" >&2; exit 1; }
! grep -q "a.py:bug:parse_config" <<<"$(known_work repoX)" || { echo "known_work still lists a wontfix'd finding" >&2; exit 1; }

# ---- Part B: end-to-end carry-forward + clearing via the mock runner ----
unset NIGHTSHIFT_SOURCED   # must NOT leak into the child, or main() never runs
BTMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "$BTMP"' EXIT
mkdir -p "$BTMP/state" "$BTMP/runs" "$BTMP/digests" "$BTMP/worktrees"
git init -q --bare "$BTMP/remote.git"
git init -q -b main "$BTMP/repo"
git -C "$BTMP/repo" remote add origin "$BTMP/remote.git"
printf '# p\n' > "$BTMP/repo/README.md"
printf 'AMBIGUOUS divergence needing a human\n' > "$BTMP/repo/NOTES.md"
git -C "$BTMP/repo" -c user.name=t -c user.email=t@l add -A
git -C "$BTMP/repo" -c user.name=t -c user.email=t@l commit -q -m init
git -C "$BTMP/repo" push -q -u origin main
cat > "$BTMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $BTMP/repo
    mode: branch-fix
EOF
brun() {
  RULEBOOK="$BTMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$BTMP/state" NIGHTSHIFT_RUNS_DIR="$BTMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$BTMP/digests" NIGHTSHIFT_WORKTREES="$BTMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$BTMP/out.$1" 2>"$BTMP/err.$1"
}
BLEDGER="$BTMP/state/ledger.jsonl"

brun 1
grep -q "## Open findings (all nights" "$BTMP/digests"/*.md || { echo "digest missing carry-forward section" >&2; exit 1; }
grep -q "ambiguous divergence in NOTES.md" "$BTMP/digests"/*.md || { echo "open finding not carried forward" >&2; exit 1; }

# Clear it with a human resolved verdict; the next digest must drop it from Open findings.
fpv="$(jq -r 'select(.outcome=="finding")|.fingerprint' "$BLEDGER" | head -1)"
STATE_DIR="$BTMP/state" LEDGER="$BLEDGER" RULEBOOK="$BTMP/rulebook.yaml" \
  bash "$ROOT/bin/harvest.sh" verdict "$fpv" resolved >/dev/null
brun 2
open_after="$(sed -n '/## Open findings (all nights/,/^## /p' "$BTMP/digests"/*.md | grep -c 'NOTES.md' || true)"
[ "$open_after" -eq 0 ] || { echo "resolved finding still listed as open" >&2; exit 1; }

echo "test-finding-identity: ok"
