#!/usr/bin/env bash
set -euo pipefail

# A night that ships and then fills the open-branch cap is the NORMAL end of a productive night
# (the cap is only reached BY shipping). The digest for such a night must carry the FULL STOP
# banner AND every content section — the banner tells the human to harvest branches, and
# `## Shipped` is what names them. ADR 0004: the digest reports shipped and considered-but-abandoned.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

# Cap of 1: the first pass ships one branch, the next pass boundary sees open=1 >= 1 and stops
# with stop_reason=backpressure while `made` is already 1 — the exact reported end state.
cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 1
recon:
  enabled: false
dimensions:
  - docs
repos:
  - path: $TMP/repo
    mode: branch-fix
    base: main
EOF

LEDGER="$TMP/state/ledger.jsonl"
RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out" 2>"$TMP/err"

grep -q "open-branch cap reached" "$TMP/err" "$TMP/out" \
  || { echo "run did not stop on backpressure" >&2; cat "$TMP/err" >&2; exit 1; }

branch="$(jq -rs '[.[]|select(.outcome=="shipped")|.branch][0] // ""' "$LEDGER")"
[ -n "$branch" ] || { echo "expected a shipped branch before the cap was hit" >&2; exit 1; }

# Exactly one digest per run; glob rather than `ls | head` so no pipe can trip pipefail.
digest=""; for d in "$TMP/digests"/*.md; do digest="$d"; done
[ -f "$digest" ] || { echo "no digest written" >&2; exit 1; }
grep -q "FULL STOP" "$digest" \
  || { echo "digest missing the FULL STOP banner" >&2; cat "$digest" >&2; exit 1; }
for section in "## Shipped" "## Findings (surfaced" "## Considered but not shipped" \
               "## Open findings (all nights"; do
  grep -qF "$section" "$digest" \
    || { echo "backpressure digest dropped section: $section" >&2; cat "$digest" >&2; exit 1; }
done
# The banner says "harvest some branches" — the digest must name which.
grep -qF "$branch" "$digest" \
  || { echo "backpressure digest does not name the shipped branch $branch" >&2; cat "$digest" >&2; exit 1; }
# The header's own count must not contradict the body.
grep -q "shipped this run: 1" "$digest" \
  || { echo "digest header lost the shipped count" >&2; cat "$digest" >&2; exit 1; }

echo "test-digest-backpressure-sections: ok"
