#!/usr/bin/env bash
set -euo pipefail

# Recon cache hardening: a good recon writes a valid cache atomically (no leftover temp files,
# no recon_failed marker), and a fresh cache (same HEAD, within ttl) is reused — recon does NOT
# re-run on the next pass.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# clean project\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 3
recon:
  enabled: true
  ttl_days: 7
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: branch-fix
EOF

run() {
  RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out.$1" 2>"$TMP/err.$1"
}
recon_runs() { jq -s '[.[]|select(.stage=="recon")]|length' "$TMP/state/runs.jsonl"; }

run 1
cache="$(find "$TMP/state/recon" -name '*.json' 2>/dev/null | head -1)"
[ -n "$cache" ] || { echo "no recon cache written" >&2; exit 1; }
jq -e '(.recon_failed != true) and ((.head|length)>0) and ((.ts|length)>0) and (.repo|length>0)' "$cache" >/dev/null \
  || { echo "recon cache is not a valid good-path entry" >&2; cat "$cache" >&2; exit 1; }
# Atomic write leaves no temp files behind.
[ -z "$(find "$TMP/state/recon" -name '*.tmp*' 2>/dev/null)" ] || { echo "leftover recon temp file" >&2; exit 1; }
r1="$(recon_runs)"; [ "$r1" -ge 1 ] || { echo "recon did not run on pass 1" >&2; exit 1; }

# Pass 2: HEAD unchanged and within ttl → cache is fresh → recon must NOT re-run.
run 2
r2="$(recon_runs)"
[ "$r2" -eq "$r1" ] || { echo "recon re-ran despite a fresh cache ($r1 -> $r2)" >&2; exit 1; }

echo "test-recon-cache: ok"
