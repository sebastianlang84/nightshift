#!/usr/bin/env bash
set -euo pipefail

# Spend control: a wall-clock budget stops the night before any further mutation, with an explicit
# stop reason in log and digest; a generous budget does not interfere.

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
  - docs
repos:
  - path: $TMP/repo
    mode: branch-fix
EOF

run() { # tag  budget_seconds
  NIGHTSHIFT_MAX_RUN_SECONDS="$2" \
  RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out.$1" 2>"$TMP/err.$1"
}
branch_count() { git --git-dir="$TMP/remote.git" for-each-ref 'refs/heads/nightshift/*' | wc -l; }
digest() { ls -t "$TMP/digests"/*.md | head -1; }

# Zero budget: stop before any work.
run A 0
[ "$(branch_count)" -eq 0 ] || { echo "shipped despite an exhausted budget" >&2; exit 1; }
grep -q "time budget (0s) exhausted — stop" "$TMP/err.A" || { echo "missing budget stop log" >&2; cat "$TMP/err.A" >&2; exit 1; }
grep -q "Stopped: time budget exhausted" "$(digest)" || { echo "digest missing budget note" >&2; cat "$(digest)" >&2; exit 1; }

# Generous budget: normal run ships, no budget note.
run B 3600
[ "$(branch_count)" -eq 1 ] || { echo "generous budget blocked shipping" >&2; cat "$TMP/err.B" >&2; exit 1; }
! grep -q "Stopped: time budget exhausted" "$(digest)" || { echo "budget note under generous budget" >&2; exit 1; }

# Parser rejects a malformed max_run_minutes.
cat > "$TMP/bad.yaml" <<'EOF'
limits:
  max_run_minutes: soon
repos:
  - path: /srv/x
    mode: branch-fix
EOF
if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/bad.yaml" >/dev/null 2>"$TMP/perr"; then
  echo "parser accepted non-numeric max_run_minutes" >&2; exit 1
fi
grep -q "limits.max_run_minutes must be a positive integer" "$TMP/perr"

echo "test-spend-budget: ok"
