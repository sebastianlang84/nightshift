#!/usr/bin/env bash
set -euo pipefail

# A stage transport/parser failure is not the reviewer's judgment. It must stay visible and
# retryable, never become the durable `abandoned` verdict that suppresses the finding until its
# target changes (ADR 0023).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
D="$TMP/case"

fail() { echo "test-stage-failure-retry: $*" >&2; exit 1; }

mkdir -p "$D/state" "$D/runs" "$D/digests" "$D/worktrees"
git init -q --bare "$D/remote.git"
git init -q -b main "$D/repo"
git -C "$D/repo" remote add origin "$D/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$D/repo/README.md"
git -C "$D/repo" -c user.name=test -c user.email=test@localhost add README.md
git -C "$D/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$D/repo" push -q -u origin main

cat > "$D/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 2
  max_branches_per_run: 1
  max_fix_iterations: 1
recon:
  enabled: false
dimensions:
  - docs
repos:
  - path: $D/repo
    mode: branch-fix
    base: main
    test_cmd: true
EOF

run_night() {
  env "$@" RULEBOOK="$D/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 \
    NIGHTSHIFT_OPEN_PR=0 NIGHTSHIFT_STATE_DIR="$D/state" NIGHTSHIFT_RUNS_DIR="$D/runs" \
    NIGHTSHIFT_DIGEST_DIR="$D/digests" NIGHTSHIFT_WORKTREES="$D/worktrees" \
    "$ROOT/bin/nightshift.sh" >"$D/out" 2>"$D/err"
}

# A fatal agent failure stops the night and writes no finding lifecycle row at all.
set +e
run_night NIGHTSHIFT_MOCK_REVIEW_FATAL=1 NIGHTSHIFT_MOCK_REVIEW_RC=7
fatal_rc=$?
set -e
[ "$fatal_rc" -eq 3 ] || { cat "$D/err" >&2; fail "fatal review exited $fatal_rc instead of 3"; }
if [ -f "$D/state/ledger.jsonl" ] && jq -e \
    'select(.outcome=="stage-failed" or .outcome=="abandoned" or .outcome=="shipped")' \
    "$D/state/ledger.jsonl" >/dev/null 2>&1; then
  jq -c . "$D/state/ledger.jsonl" >&2
  fail "fatal review wrote a derived finding outcome"
fi

# The mock writes no review artifact and exits nonzero: there is no reviewer verdict to record.
run_night NIGHTSHIFT_MOCK_REVIEW_NO_ARTIFACT=1 NIGHTSHIFT_MOCK_REVIEW_RC=7
LEDGER="$D/state/ledger.jsonl"

jq -e 'select(.outcome=="stage-failed")' "$LEDGER" >/dev/null 2>&1 \
  || { cat "$D/err" >&2; fail "failed review was not recorded as retryable stage-failed"; }
if jq -e 'select(.outcome=="abandoned" or .outcome=="shipped")' "$LEDGER" >/dev/null 2>&1; then
  jq -c . "$LEDGER" >&2
  fail "failed review became a durable verdict"
fi
grep -q 'review produced no usable verdict' "$D/err" \
  || { cat "$D/err" >&2; fail "stage failure reason is absent from the night log"; }
digest="$(find "$D/digests" -name '*.md' | head -1)"
grep -q 'stage-failed' "$digest" || { cat "$digest" >&2; fail "digest hides stage-failed"; }

# Because stage-failed is not a verdict, the unchanged finding must be attempted again and ship.
run_night
jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1 \
  || { cat "$D/err" >&2; jq -c . "$LEDGER" >&2; fail "unchanged finding was latched"; }
git -C "$D/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*' | grep -q . \
  || fail "retry produced no remote branch"

echo "test-stage-failure-retry: ok"
