#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
pid=""
cleanup() {
  if [ -n "$pid" ]; then kill -KILL -- "-$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

git init -q -b main "$TMP/repo"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -qm initial --allow-empty
cat > "$TMP/rulebook.yaml" <<EOF
recon:
  enabled: false
repos:
  - path: $TMP/repo
    mode: findings-only
    base: main
EOF
mkdir -p "$TMP/launcher/bin"
cat > "$TMP/launcher/bin/nightshift.sh" <<'RUNNER'
#!/usr/bin/env bash
export NIGHTSHIFT_HOME="$ROOT"
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
mock_explore() { touch "$TEST_TMP/ready"; sleep 60; }
main
RUNNER
chmod +x "$TMP/launcher/bin/nightshift.sh"

export ROOT TEST_TMP="$TMP" NIGHTSHIFT_HOME="$TMP/launcher"
export RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_LOCK="$TMP/lock"
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" NIGHTSHIFT_LOG_DIR="$TMP/logs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
setsid bash "$ROOT/bin/nightshift-cron.sh" > "$TMP/log" 2>&1 &
pid=$!
for ((i=0; i<100; i++)); do
  [ ! -f "$TMP/ready" ] || break
  sleep 0.05
done
[ -f "$TMP/ready" ] || { tail -n 20 "$TMP/log" >&2; exit 1; }
pgrep -g "$pid" -x tee >/dev/null
kill -TERM -- "-$pid"
rc=0
wait "$pid" || rc=$?
[ "$rc" -eq 143 ]
grep -q 'ABORTED: interrupted by SIGTERM' "$TMP/digests/$(date +%F).md"
grep -q 'nightshift done rc=143' "$TMP/logs/$(date +%F).log"
pid=""

echo 'test-cron-interrupted-digest: ok'
