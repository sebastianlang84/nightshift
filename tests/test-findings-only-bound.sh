#!/usr/bin/env bash
set -euo pipefail

# Findings-only work must not keep the multi-pass loop alive. Findings surface once (they
# dedup/latch) and consume no branch slot, so a nondeterministic findings-only repo could
# otherwise spin passes forever. The loop is gated on SHIPPABLE progress: a pass that only
# surfaces findings stops with an explicit reason.

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

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: findings-only
EOF

RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/stdout" 2>"$TMP/stderr"

LEDGER="$TMP/state/ledger.jsonl"
# Surfaced a finding, shipped nothing.
[ "$(jq -s '[.[]|select(.outcome=="finding")]|length' "$LEDGER")" -ge 1 ] || { echo "no finding surfaced" >&2; exit 1; }
[ "$(jq -s '[.[]|select(.outcome=="shipped")]|length' "$LEDGER")" -eq 0 ] || { echo "findings-only shipped a branch" >&2; exit 1; }
# The loop stopped after ONE pass with the explicit findings-only reason.
grep -q "pass 1: only surfaced findings, no shippable work — stop" "$TMP/stderr" \
  || { echo "missing explicit findings-only stop reason" >&2; cat "$TMP/stderr" >&2; exit 1; }
# It did NOT spin into a second pass.
! grep -q "pass 2" "$TMP/stderr" || { echo "loop spun into pass 2 on findings-only work" >&2; exit 1; }

echo "test-findings-only-bound: ok"
