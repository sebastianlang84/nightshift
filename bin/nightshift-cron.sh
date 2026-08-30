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
# Since ADR 0026 the variable does more than order PATH: the gate runs in a bwrap sandbox with no
# $HOME at all, so these directories are also the ones BOUND into it. A tool that is not named here
# is not merely found late — it does not exist inside the gate. Hence the `:`-separated list below:
# `uv` lives in ~/.local/bin and `node` under nvm, and the fleet needs both in the same gate.
# This still does not touch the Runner's own PATH, so R10/N4 is unaffected.
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
gate_toolchain_path() { # -> `:`-separated dirs the gates need bound and on PATH
  local out="" d
  out="$(nvm_toolchain_bin)"
  # ~/.local/bin is where uv/pipx-style tools land. It is on the Runner's PATH already (last, on
  # purpose), but the sandbox has no $HOME, so it must be named to exist inside a gate at all.
  for d in "$HOME/.local/bin"; do
    [ -d "$d" ] && out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}
export NIGHTSHIFT_TEST_PATH="${NIGHTSHIFT_TEST_PATH-$(gate_toolchain_path)}"

# The `pi` adapter (ADR 0031) needs the nvm toolchain twice over: pi is an npm-global under nvm — NOT
# in ~/.local/bin like claude and codex — and its `#!/usr/bin/env node` shebang resolves whatever
# node is first on PATH, which here is /usr/bin/node v18 while pi requires >= 22.19 (verified: it
# aborts on v18). Both failures land as a dead Review stage, one at a time, all night.
#
# It is exported as its OWN variable rather than merged into PATH, for the same reason
# NIGHTSHIFT_TEST_PATH is: the Runner prepends it for the pi subprocess alone. Putting an nvm bin
# ahead of the system dirs in the Runner's own PATH is precisely the R10/N4 hole the comment above
# warns about, and appending it instead would leave /usr/bin/node v18 winning the shebang.
export NIGHTSHIFT_PI_PATH="${NIGHTSHIFT_PI_PATH-$(nvm_toolchain_bin)}"

# The sandbox has no $HOME, so a python package installed with `pip install --user` is invisible
# inside a gate — the suite then fails on an import, which reads downstream as "the fix broke the
# tests". Naming the user site-packages directory here binds it READ-ONLY; it is a directory under
# $HOME, not $HOME itself, so the sandbox's own refusal of any bind containing $HOME still holds.
# Nothing is added to any gate's import path by this: a suite that needs those packages says so in
# its own `test_cmd` (PYTHONPATH=…), which keeps the operator's packages out of every other repo.
#
# Set NIGHTSHIFT_TEST_SANDBOX_ROBIND yourself to override; set it empty to opt out entirely.
gate_user_site() { # -> the operator's user site-packages dir, if python3 has one that exists
  local d
  d="$(python3 -m site --user-site 2>/dev/null)" || return 0
  [ -n "$d" ] && [ -d "$d" ] && printf '%s' "$d"
  return 0
}
export NIGHTSHIFT_TEST_SANDBOX_ROBIND="${NIGHTSHIFT_TEST_SANDBOX_ROBIND-$(gate_user_site)}"

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
  # `command -v` against the list itself, not "$NIGHTSHIFT_TEST_PATH/node" — the variable is a
  # `:`-separated list now, so indexing it as a single directory would report every node as missing.
  echo "[nightshift-cron] test gates bind + prepend $NIGHTSHIFT_TEST_PATH (node $(PATH="$NIGHTSHIFT_TEST_PATH" command -v node >/dev/null 2>&1 && PATH="$NIGHTSHIFT_TEST_PATH" node -v || echo 'not runnable'), uv $(PATH="$NIGHTSHIFT_TEST_PATH" command -v uv >/dev/null 2>&1 && echo present || echo 'not found'))" | tee -a "$LOG"
else
  echo "[nightshift-cron] no nvm toolchain found — test gates run on $(command -v node || echo 'no node at all')" | tee -a "$LOG"
fi
if [ -n "${NIGHTSHIFT_TEST_SANDBOX_ROBIND:-}" ]; then
  echo "[nightshift-cron] test gates bind read-only $NIGHTSHIFT_TEST_SANDBOX_ROBIND" | tee -a "$LOG"
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
