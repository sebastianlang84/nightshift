#!/usr/bin/env bash
set -euo pipefail

# H1 regression: a malformed rulebook must ABORT the run, not silently truncate the
# fleet. Before the fix, parse_rulebook.py died mid-stream on the bad repo and the
# runner — reading it via process substitution — saw only the repos emitted BEFORE
# the error, servicing a partial fleet with no error surfaced.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo1"
git -C "$TMP/repo1" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo1/README.md"
git -C "$TMP/repo1" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo1" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo1" push -q -u origin main

# repo1 is valid and FIRST; the bad findings override sits on repo #2. A truncating
# parser would still hand the runner repo1 and let it ship — the bug this guards.
cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 3
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo1
    mode: branch-fix
  - path: /srv/second
    mode: branch-fix
    findings: nope
  - path: /srv/third
    mode: findings-only
EOF

set +e
RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/stdout" 2>"$TMP/stderr"
rc=$?
set -e

[ "$rc" -ne 0 ] || { echo "runner did NOT abort on a malformed rulebook (exit $rc)" >&2; cat "$TMP/stderr" >&2; exit 1; }
grep -q "rulebook parse failed" "$TMP/stderr" || { echo "missing abort message" >&2; cat "$TMP/stderr" >&2; exit 1; }
# repo1 must be untouched: no nightshift/* branch, no ledger written.
[ "$(git --git-dir="$TMP/remote.git" for-each-ref 'refs/heads/nightshift/*' | wc -l)" -eq 0 ] \
  || { echo "runner serviced repo1 despite the parse error" >&2; exit 1; }
[ ! -f "$TMP/state/ledger.jsonl" ] || { echo "ledger written despite abort" >&2; exit 1; }

echo "test-rulebook-runner-abort: ok"
