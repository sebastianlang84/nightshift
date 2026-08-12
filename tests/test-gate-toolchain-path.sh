#!/usr/bin/env bash
set -euo pipefail

# The ship gate (ADR 0022) runs the repo's OWN suite, so it needs the developer toolchain — under nvm
# that is node/npm/pnpm, none of which a systemd user service has on PATH. bin/nightshift-cron.sh
# resolves it into NIGHTSHIFT_TEST_PATH and the Runner prepends it for the `test_cmd` subprocess only.
#
# Regression for the night of 2026-08-12: /usr/bin/node is v18, so pi-ext-memory's
# `node --experimental-strip-types` gate exited 9 and partflow's `pnpm` gate exited 127. Six finished
# fixes were discarded as "the fix broke the suite", and because `tests-failed` is not latched
# (ADR 0022) the same work is re-attempted and re-discarded every night.
#
# Asserted here, in both directions:
#   1. a binary that exists ONLY in NIGHTSHIFT_TEST_PATH is reachable from `test_cmd`, and the gate
#      passes because of it;
#   2. that directory does NOT enter the Runner's own PATH — a `git` planted there must never be the
#      git the Runner runs (R10/N4: the system dirs stay in front for the Runner's unqualified calls).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-gate-toolchain-path: $*" >&2; exit 1; }

# The toolchain dir stands in for ~/.nvm/versions/node/vX/bin: it holds the tool the suite needs …
mkdir -p "$TMP/toolchain"
cat > "$TMP/toolchain/repo-toolchain" <<'EOF'
#!/usr/bin/env bash
echo "toolchain reached"
EOF
# … and a `git` that fails loudly. The Runner shells out to git constantly (worktree, commit, push),
# so if this directory ever reached the Runner's PATH the night could not get past setup — which is
# exactly the shadowing R10/N4 exists to prevent.
cat > "$TMP/toolchain/git" <<'EOF'
#!/usr/bin/env bash
echo "SHADOWED: the toolchain git was used by the Runner" >&2
exit 66
EOF
chmod +x "$TMP/toolchain/repo-toolchain" "$TMP/toolchain/git"

d="$TMP/night"
mkdir -p "$d/state" "$d/runs" "$d/digests" "$d/worktrees"
git init -q --bare "$d/remote.git"
git init -q -b main "$d/repo"
git -C "$d/repo" remote add origin "$d/remote.git"
# `teh` is what the mock Explore finds and the mock Fix repairs, so the night reaches the gate.
printf '# Demo\n\nThis is teh demo.\n' > "$d/repo/README.md"
git -C "$d/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$d/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$d/repo" push -q -u origin main

# The gate passes only if the toolchain binary resolved — an unqualified call, like a real `pnpm test`.
cat > "$d/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
recon:
  enabled: false
dimensions:
  - docs
repos:
  - path: $d/repo
    mode: branch-fix
    base: main
    test_cmd: repo-toolchain
EOF

run_night() { # extra env assignments are passed as VAR=VALUE arguments
  env "$@" \
    RULEBOOK="$d/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
    NIGHTSHIFT_STATE_DIR="$d/state" NIGHTSHIFT_RUNS_DIR="$d/runs" \
    NIGHTSHIFT_DIGEST_DIR="$d/digests" NIGHTSHIFT_WORKTREES="$d/worktrees" \
    "$ROOT/bin/nightshift.sh" >"$d/out" 2>"$d/err"
}

# --- 1. without the variable the gate cannot find the tool (the 2026-08-12 shape) ---------------
set +e
NIGHTSHIFT_TEST_PATH="" run_night
set -e
grep -q "test gate failed" "$d/err" \
  || { cat "$d/err" >&2; fail "expected the gate to fail when the toolchain is not on PATH"; }
# RUNS_DIR/<night>/<item>/tests.log — the gate writes the suite's output only when it fails.
grep -rq 'repo-toolchain' --include=tests.log "$d/runs" \
  || { find "$d/runs" -name tests.log -exec cat {} \; >&2; fail "the gate failed for some other reason than the missing tool"; }
if [ -f "$d/state/ledger.jsonl" ] && jq -e 'select(.outcome=="shipped")' "$d/state/ledger.jsonl" >/dev/null 2>&1; then
  fail "a branch shipped although the gate never ran the suite"
fi

# --- 2. with it, the same night ships — and the Runner's own git is untouched -------------------
rm -rf "$d/state" "$d/runs" "$d/digests" "$d/worktrees"
mkdir -p "$d/state" "$d/runs" "$d/digests" "$d/worktrees"
git -C "$d/repo" push -q --delete origin --all 2>/dev/null || true
git -C "$d/repo" push -q -u origin main

NIGHTSHIFT_TEST_PATH="$TMP/toolchain" run_night \
  || { cat "$d/err" >&2; fail "the night exited non-zero with the toolchain present"; }

grep -q "test gate passed" "$d/err" \
  || { cat "$d/err" >&2; fail "the gate did not reach the tool in NIGHTSHIFT_TEST_PATH"; }
grep -q "SHADOWED" "$d/err" "$d/out" \
  && fail "the toolchain dir leaked into the Runner's own PATH — R10/N4 shadowing is back"
jq -e 'select(.outcome=="shipped")' "$d/state/ledger.jsonl" >/dev/null 2>&1 \
  || { cat "$d/err" >&2; fail "nothing shipped although the gate passed"; }

echo "test-gate-toolchain-path: ok"
