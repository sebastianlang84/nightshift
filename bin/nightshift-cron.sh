#!/usr/bin/env bash
# Unattended launcher for the nightly scheduler (the "dumb" side: the timer fires
# this, this fires the smart orchestrator bin/nightshift.sh). It adds the three
# things an unattended run needs that an interactive one gets for free:
#   1. a single-instance flock — a long run must NEVER overlap the next night's;
#   2. an explicit PATH — systemd user services start with a minimal env, but
#      nightshift shells out to claude/codex/gh which may live under ~/.local/bin;
#   3. a timestamped log file (everything also still goes to journald).
set -euo pipefail

NIGHTSHIFT_HOME="${NIGHTSHIFT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export NIGHTSHIFT_HOME
# Nightly runs are real work by default; the mock is only for --dry-run testing.
export NIGHTSHIFT_AGENT="${NIGHTSHIFT_AGENT:-claude}"
# Make the tools nightshift invokes findable under systemd's minimal PATH.
# System dirs come FIRST so a binary planted under ~/.local/bin (which a write
# primitive could reach) cannot shadow the Runner's unqualified jq/git/gh/
# python3/codemap calls — see docs/design/risk-analysis.md R10/N4. Agent tools
# that live only under ~/.local/bin (claude/codex/gh) are still resolved there.
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:${PATH:-}"

LOG_DIR="${NIGHTSHIFT_LOG_DIR:-$HOME/.local/state/nightshift/logs}"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%Y-%m-%d).log"
LOCK="${NIGHTSHIFT_LOCK:-${TMPDIR:-/tmp}/nightshift.lock}"

# Single instance: if a previous night's run is somehow still going, skip rather
# than stack two agents on the same repos.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "[nightshift-cron] another run holds $LOCK — skip $(date -Iseconds)" | tee -a "$LOG" >&2
  exit 0
fi

echo "=== nightshift start $(date -Iseconds) (agent=$NIGHTSHIFT_AGENT) ===" | tee -a "$LOG"
"$NIGHTSHIFT_HOME/bin/nightshift.sh" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
echo "=== nightshift done rc=$rc $(date -Iseconds) ===" | tee -a "$LOG"
exit "$rc"
