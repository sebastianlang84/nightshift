#!/usr/bin/env bash
set -euo pipefail

# An agent CLI that cannot authenticate must ABORT the night, not be absorbed into "found nothing".
#
# Regression for the night of 2026-08-05: all 8 stages died in 1-3s with `authentication_failed`
# ("Not logged in · Please run /login"), and every layer above reported a quiet, healthy night —
# the log said "nothing worth doing" once per repo, four `empty` rows went into the ledger, four
# negative recon caches took a 6h backoff, and the run exited rc=0. The failure was invisible
# because the adapter sent stderr to /dev/null AND dropped the captured stdout on a non-zero exit.
#
# Asserted here: the reason is captured and logged, the night stops at the FIRST failing stage,
# nothing derived is recorded, and the non-zero exit reaches the caller.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

for r in repo-a repo-b; do
  git init -q --bare "$TMP/$r.git"
  git init -q -b main "$TMP/$r"
  git -C "$TMP/$r" remote add origin "$TMP/$r.git"
  printf '# Demo\n\nThis is teh demo.\n' > "$TMP/$r/README.md"
  git -C "$TMP/$r" -c user.name=test -c user.email=test@localhost add README.md
  git -C "$TMP/$r" -c user.name=test -c user.email=test@localhost commit -q -m initial
  git -C "$TMP/$r" push -q -u origin main
done

# TWO repos: a night that merely logged the failure per repo would still walk both. The abort must
# stop the fleet at the first one.
cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 3
  max_findings_per_item: 1
  max_branches_per_run: 2
  max_fix_iterations: 1
recon:
  enabled: true
  ttl_days: 7
dimensions:
  - correctness
repos:
  - path: $TMP/repo-a
    mode: branch-fix
    test_cmd: true
    base: main
  - path: $TMP/repo-b
    mode: branch-fix
    test_cmd: true
    base: main
EOF

# The observed failure shape: the claude CLI reports the credential problem on STDOUT (it is a
# result object of the -p session, not a usage error) and exits non-zero. Stderr stays empty, which
# is the harder half to get right — the old adapter discarded the captured stdout along with the
# exit code, leaving an item dir with no trace of the reason at all.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo 'Not logged in · Please run /login'
exit 1
EOF
chmod +x "$TMP/bin/claude"

set +e
PATH="$TMP/bin:/usr/bin:/bin" \
RULEBOOK="$TMP/rulebook.yaml" \
NIGHTSHIFT_AGENT=claude \
NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e

# 1. The night exits non-zero, so nightshift-cron.sh logs a verdict and systemd marks the unit failed.
[ "$rc" -eq 3 ] || { echo "expected exit 3 (aborted night), got $rc" >&2; cat "$TMP/err" >&2; exit 1; }

# 2. The reason is in the log, named — not merely "no result".
grep -q 'FATAL:.*no usable credentials' "$TMP/err" \
  || { echo "log does not name the credential failure" >&2; cat "$TMP/err" >&2; exit 1; }
grep -q 'stage recon FAILED (exit 1)' "$TMP/err" \
  || { echo "log does not report the failing stage and its exit code" >&2; cat "$TMP/err" >&2; exit 1; }

# 3. The CLI's own words survive on disk for the morning. Stdout is the path that used to be lost.
raw="$(find "$TMP/runs" -name '.raw_recon' | head -1)"
[ -n "$raw" ] || { echo "adapter kept no raw stdout for the failed stage" >&2; exit 1; }
grep -q 'Not logged in' "$raw" || { echo "raw stdout does not carry the CLI's message" >&2; exit 1; }
[ -n "$(find "$TMP/runs" -name 'recon.err' | head -1)" ] \
  || { echo "adapter did not create a stderr file for the failed stage" >&2; exit 1; }

# 4. Nothing derived was recorded. These are the four artifacts that made 2026-08-05 look clean.
[ -z "$(find "$TMP/state/recon" -name '*.json' 2>/dev/null)" ] \
  || { echo "a recon cache was written despite the agent being dead" >&2; exit 1; }
if [ -f "$TMP/state/ledger.jsonl" ]; then
  n=$(jq -s '[.[]|select(.outcome=="empty")]|length' "$TMP/state/ledger.jsonl")
  [ "$n" -eq 0 ] || { echo "$n forged 'empty' ledger rows written" >&2; exit 1; }
fi
[ -z "$(find "$TMP/state/dim-scans" -type f 2>/dev/null)" ] \
  || { echo "dimension rotation advanced on a stage that never ran" >&2; exit 1; }

# 5. The fleet stops at the first failure instead of walking every repo into the same wall.
stages=$(jq -s 'length' "$TMP/state/runs.jsonl")
[ "$stages" -eq 1 ] || { echo "expected 1 stage invocation before the abort, got $stages" >&2; exit 1; }
jq -se 'all(.exit != 0)' "$TMP/state/runs.jsonl" >/dev/null \
  || { echo "runs.jsonl recorded the failed stage as a success" >&2; exit 1; }

# 6. The digest — the one artifact read in the morning — says the night is not evidence about the code.
digest="$(find "$TMP/digests" -name '*.md' | head -1)"
[ -n "$digest" ] || { echo "no digest written" >&2; exit 1; }
grep -q 'ABORTED' "$digest" || { echo "digest does not announce the abort" >&2; cat "$digest" >&2; exit 1; }

# 7. The throwaway worktree is cleaned up on the abort path too.
[ -z "$(find "$TMP/worktrees" -mindepth 1 -maxdepth 1 2>/dev/null)" ] \
  || { echo "worktree left behind on the abort path" >&2; exit 1; }

echo "test-agent-auth-abort: ok"
