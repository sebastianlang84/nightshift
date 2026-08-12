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

# The repos' ship gates (ADR 0022) run the repo's OWN suite, so they need the developer toolchain —
# node, npm and the corepack shims (pnpm) — which lives under nvm and is therefore absent from the
# PATH above. It must stay absent there: that PATH puts the system dirs first so nothing planted
# under a $HOME directory can shadow the Runner's own unqualified jq/git/python3/gh calls (R10/N4),
# and prepending an nvm bin would reopen exactly that hole. So it is exported as its own variable and
# the Runner prepends it for the `test_cmd` subprocess only — a process that already executes the
# repo's package scripts, so its PATH is not a security boundary.
#
# Observed 2026-08-12 with this missing: /usr/bin/node is v18, so pi-ext-memory's
# `node --experimental-strip-types` gate exited 9 and partflow's `pnpm` gate exited 127. Six finished
# fixes were discarded as "the fix broke the suite" that night, and the same work is re-attempted and
# re-discarded every night because `tests-failed` is deliberately not latched (ADR 0022).
#
# Set NIGHTSHIFT_TEST_PATH yourself to override; set it empty to opt out entirely.
nvm_toolchain_bin() { # -> bin dir of the default (else newest) nvm Node, or nothing at all
  local d="$HOME/.nvm/versions/node" want="" newest
  [ -d "$d" ] || return 0
  [ -r "$HOME/.nvm/alias/default" ] && want="$(cat "$HOME/.nvm/alias/default")"
  # The default alias is usually symbolic ("lts/*", "node"); only a concrete vX.Y.Z names a directory.
  case "$want" in
    v*) [ -x "$d/$want/bin/node" ] && { printf '%s' "$d/$want/bin"; return 0; } ;;
  esac
  newest="$(ls -1 "$d" 2>/dev/null | sort -V | tail -n1)"
  [ -n "$newest" ] && [ -x "$d/$newest/bin/node" ] && printf '%s' "$d/$newest/bin"
  return 0
}
export NIGHTSHIFT_TEST_PATH="${NIGHTSHIFT_TEST_PATH-$(nvm_toolchain_bin)}"

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
# Which Node the ship gates will see. Logged because the failure it prevents is silent: a gate that
# exits 9 or 127 on a toolchain problem is reported as "the fix broke the suite".
if [ -n "${NIGHTSHIFT_TEST_PATH:-}" ]; then
  echo "[nightshift-cron] test gates prepend $NIGHTSHIFT_TEST_PATH (node $("$NIGHTSHIFT_TEST_PATH/node" -v 2>/dev/null || echo 'not runnable'))" | tee -a "$LOG"
else
  echo "[nightshift-cron] no nvm toolchain found — test gates run on $(command -v node || echo 'no node at all')" | tee -a "$LOG"
fi
# The orchestrator's exit status is the thing this launcher exists to record, so the
# pipeline below must NOT be allowed to kill the shell: under `set -e` + `pipefail` a
# nonzero exit from nightshift.sh (e.g. a rulebook parse error, or the split-state
# guard) fails the pipeline and terminates the launcher right here — leaving the
# unattended log with a `start` line, no `done rc=` footer, and no recorded status,
# which is precisely the case the footer is for.
#
# `set +e` rather than `|| true`: `||` runs a second command on the failure path, and
# every command — a bare `true` included — resets PIPESTATUS. Nothing may execute
# between the pipeline and the capture.
set +e
"$NIGHTSHIFT_HOME/bin/nightshift.sh" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "=== nightshift done rc=$rc $(date -Iseconds) ===" | tee -a "$LOG"
# Propagate: Type=oneshot with no Restart=, so this only marks the unit failed
# (visible in `systemctl --user status nightshift.service`) — it does not re-run.
exit "$rc"
