#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
printf '# retrun from here\n' > "$TMP/repo/app.py"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md app.py
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 3
  max_findings_per_item: 2
  max_branches_per_run: 3
  max_fix_iterations: 1
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: branch-fix
    test_cmd: true
    findings: 1
    dimensions: docs
EOF

RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/stdout" 2>"$TMP/stderr"

[ "$(git --git-dir="$TMP/remote.git" for-each-ref --format='%(refname:short)' \
  'refs/heads/nightshift/*' | wc -l)" -eq 1 ]
[ "$(jq -s '[.[] | select(.outcome=="shipped")] | length' "$TMP/state/ledger.jsonl")" -eq 1 ]
jq -e 'select(.outcome=="shipped" and .dimension=="docs")' "$TMP/state/ledger.jsonl" >/dev/null
! grep -q "base '1' not found" "$TMP/stderr"

# max_branches_per_run is a ceiling on THIS run, so it must bind inside a pass: one explore that
# returns two findings used to ship both, because the ceiling was only consulted between passes.
rm -rf "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"
git init -q --bare "$TMP/remote2.git"
git clone -q -b main "$TMP/remote.git" "$TMP/repo2"
git -C "$TMP/repo2" remote set-url origin "$TMP/remote2.git"
git -C "$TMP/repo2" push -q -u origin main
cat > "$TMP/rulebook-ceiling.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
  max_findings_per_item: 2
  max_branches_per_run: 1
  max_fix_iterations: 1
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo2
    mode: branch-fix
    test_cmd: true
    findings: 2
EOF
RULEBOOK="$TMP/rulebook-ceiling.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/stdout" 2>"$TMP/stderr"
shipped=$(git --git-dir="$TMP/remote2.git" for-each-ref --format='%(refname:short)' \
  'refs/heads/nightshift/*' | wc -l)
[ "$shipped" -eq 1 ] || { echo "max_branches_per_run: 1 shipped $shipped branches" >&2; exit 1; }

echo "test-rulebook-runner-overrides: ok"
