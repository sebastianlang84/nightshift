#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main
# Exercise systemd's process-group TERM during an in-flight stage, in isolated state.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
pid=""
cleanup() {
  if [ -n "$pid" ]; then kill -KILL -- "-$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
cat > "$TMP/rulebook.yaml" <<EOF_RB
repos:
  - path: $TMP/repo
    mode: findings-only
EOF_RB
cat > "$TMP/runner.sh" <<'EOF_RUN'
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
# Keep initialization real, replacing the first agent-bearing phase with a blocked stage.
verify_findings() {
  made=2; open=3
  jq -nc --arg n "$NIGHT" '{night:$n,outcome:"shipped",repo:"demo",branch:"nightshift/preserved",summary:"completed fix"}, {night:$n,outcome:"finding",repo:"demo",fingerprint:"pending",summary:"persisted finding"}' > "$LEDGER"
  sleep 60 &
  echo "$!" > "$TEST_TMP/worker"
  touch "$TEST_TMP/ready"
  wait
}
main
EOF_RUN
ROOT="$ROOT" TEST_TMP="$TMP" RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
setsid bash "$TMP/runner.sh" > "$TMP/out" 2> "$TMP/err" &
pid=$!
for ((i=0; i<100; i++)); do
  [ ! -f "$TMP/ready" ] || break
  sleep 0.05
done
[ -f "$TMP/ready" ] || { cat "$TMP/err"; echo 'stage never started' >&2; exit 1; }
kill -TERM -- "-$pid"
rc=0
wait "$pid" || rc=$?
[ "$rc" -eq 143 ] || { echo "interrupted runner returned $rc instead of 143" >&2; exit 1; }
digest="$TMP/digests/$(date +%Y-%m-%d).md"
[ -f "$digest" ] || { echo 'interrupted run lost its digest' >&2; exit 1; }
grep -q 'ABORTED: interrupted by SIGTERM' "$digest"
grep -q 'shipped this run: 2' "$digest"
grep -q 'nightshift/preserved' "$digest"
grep -q 'persisted finding' "$digest"
! grep -q 'night done:' "$TMP/err"
# A dead child may briefly be a zombie awaiting init's reaper; it must not be running.
worker_state=$(ps -o stat= -p "$(cat "$TMP/worker")" || true)
[[ -z "$worker_state" || "$worker_state" = Z* ]] || { echo 'stage survived termination' >&2; exit 1; }
echo 'test-interrupted-digest: ok'
