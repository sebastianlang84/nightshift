#!/usr/bin/env bash
# Unattended launcher: the timer fires this, this fires bin/nightshift.sh. It adds what an
# unattended run lacks:
#   1. a single-instance flock — a long run must NEVER overlap the next night's;
#   2. an explicit PATH — systemd user services start with a minimal env, but
#      nightshift shells out to claude/codex/gh which may live under ~/.local/bin;
#   3. a timestamped log file (everything also still goes to journald);
#   4. optionally, a quota check before the night starts (NIGHTSHIFT_QUOTA_CMD) and one line to the
#      operator when it pauses the night (NIGHTSHIFT_NOTIFY_CMD) — ADR 0044.
set -euo pipefail

NIGHTSHIFT_HOME="${NIGHTSHIFT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export NIGHTSHIFT_HOME
# Default to the real adapter, but only when the rulebook's `agent.primary` names none: the Runner
# lets a SET NIGHTSHIFT_AGENT win over the rulebook. A rulebook that does not parse falls back to
# `claude`, and the Runner then aborts on the same parse error.
if [ -z "${NIGHTSHIFT_AGENT:-}" ]; then
  _rb="${RULEBOOK:-$NIGHTSHIFT_HOME/rulebook.yaml}"
  [ -f "$_rb" ] || _rb="$NIGHTSHIFT_HOME/rulebook.example.yaml"
  _primary=""
  # Sourced only here: a run with NIGHTSHIFT_AGENT set never reads the rulebook in the launcher.
  # shellcheck source=../lib/rulebook.sh
  if source "$NIGHTSHIFT_HOME/lib/rulebook.sh" 2>/dev/null && rulebook_load "$_rb" 2>/dev/null; then
    _primary="${RB[agent.primary]}"
  fi
  [ -n "$_primary" ] || export NIGHTSHIFT_AGENT=claude
  unset _rb
fi
# Make the tools nightshift invokes findable under systemd's minimal PATH; two tests anchor here.
# System dirs come FIRST so a binary planted under ~/.local/bin cannot shadow the Runner's
# unqualified jq/git/gh/python3 calls (docs/design/risk-analysis.md R10/N4); claude/codex/gh that
# live only there still resolve.
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:${PATH:-}"

# The ship gates (ADR 0022) run the repo's own suite and need the developer toolchain (node under
# nvm, uv under ~/.local/bin). It must stay off the Runner's PATH above (R10/N4), so it is exported
# separately and prepended for the suite only. The gate sandbox has no $HOME (ADR 0026), so these
# `:`-separated dirs are also the ones bound into it: a tool not named here does not exist there.
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
  # ~/.local/bin (uv, pipx tools) must be named to exist inside a gate at all.
  for d in "$HOME/.local/bin"; do
    [ -d "$d" ] && out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}
export NIGHTSHIFT_TEST_PATH="${NIGHTSHIFT_TEST_PATH-$(gate_toolchain_path)}"

# The operator's user site-packages, bound READ-ONLY so `pip install --user` packages exist inside a
# gate. It is under $HOME, not $HOME itself, so the sandbox's $HOME refusal still holds. Nothing is
# added to an import path: a suite that needs them sets PYTHONPATH in its own `test_cmd`.
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

# Single instance: a previous night's run still going means skip, never two runs on the same repos.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "[nightshift-cron] another run holds $LOCK — skip $(date -Iseconds)" | tee -a "$LOG" >&2
  exit 0
fi

night="$(date +%Y-%m-%d)"
digest="${NIGHTSHIFT_DIGEST_DIR:-$NIGHTSHIFT_HOME/digests}/$night.md"

# One line to the operator through the host's command, `$1` = the line. Optional, bounded and never
# fatal: a missing or failing command is logged and the launcher goes on as it would have anyway.
# The Runner calls the same contract when a running night stops for `agent_unavailable`.
notify_operator() { # line
  [ -n "${NIGHTSHIFT_NOTIFY_CMD:-}" ] || return 0
  timeout "${NIGHTSHIFT_NOTIFY_TIMEOUT:-60}" sh -c "$NIGHTSHIFT_NOTIFY_CMD" sh "$1" \
    </dev/null >/dev/null 2>&1 \
    || echo "[nightshift-cron] notify command failed (rc=$?) — the operator was not told" | tee -a "$LOG"
}

# A (nearly) spent quota window pauses the night with one line; it never switches models (ADR 0044).
# NIGHTSHIFT_QUOTA_CMD runs once: exit 75 (EX_TEMPFAIL) = pause, first stdout line = reason; any
# other exit = go, so a broken check never silently stops every night. A pause exits 0 and its digest
# entry is `PAUSED`, never `ABORTED`.
if [ -n "${NIGHTSHIFT_QUOTA_CMD:-}" ]; then
  quota_rc=0
  quota_out="$(NIGHTSHIFT_AGENT="${NIGHTSHIFT_AGENT:-$_primary}" timeout -k 5 "${NIGHTSHIFT_QUOTA_TIMEOUT:-60}" sh -c "$NIGHTSHIFT_QUOTA_CMD" </dev/null 2>>"$LOG")" \
    || quota_rc=$?
  quota_why="$(printf '%s\n' "$quota_out" | head -n 1 | tr -d '\r' | cut -c1-300)"
  case "$quota_rc" in
    0) echo "[nightshift-cron] quota check: go${quota_why:+ ($quota_why)}" | tee -a "$LOG" ;;
    75)
      quota_why="${quota_why:-the quota check gave no reason}"
      echo "=== nightshift paused $(date -Iseconds): quota check exited $quota_rc — $quota_why ===" | tee -a "$LOG"
      mkdir -p "$(dirname "$digest")"
      {
        [ -f "$digest" ] && echo || printf '# nightshift digest — %s\n\n' "$night"
        echo "- **PAUSED: the quota check stopped tonight's run before it started** — $quota_why. Nothing ran and nothing was recorded; the next scheduled night checks again."
      } >> "$digest"
      notify_operator "nightshift $night paused: $quota_why"
      exit 0 ;;
    *)
      echo "[nightshift-cron] quota check failed (rc=$quota_rc) — starting the night anyway" | tee -a "$LOG" ;;
  esac
fi

# `${…:-}`: NIGHTSHIFT_AGENT is legitimately unset when the rulebook names the adapter (`set -u`).
echo "=== nightshift start $(date -Iseconds) (agent=${NIGHTSHIFT_AGENT:-from rulebook}) ===" | tee -a "$LOG"
# Log which Node the gates see: a toolchain failure in a gate otherwise reads as a broken fix.
if [ -n "${NIGHTSHIFT_TEST_PATH:-}" ]; then
  # `command -v` with the list as PATH: it is `:`-separated, not one directory.
  echo "[nightshift-cron] test gates bind + prepend $NIGHTSHIFT_TEST_PATH (node $(PATH="$NIGHTSHIFT_TEST_PATH" command -v node >/dev/null 2>&1 && PATH="$NIGHTSHIFT_TEST_PATH" node -v || echo 'not runnable'), uv $(PATH="$NIGHTSHIFT_TEST_PATH" command -v uv >/dev/null 2>&1 && echo present || echo 'not found'))" | tee -a "$LOG"
else
  echo "[nightshift-cron] no nvm toolchain found — test gates run on $(command -v node || echo 'no node at all')" | tee -a "$LOG"
fi
if [ -n "${NIGHTSHIFT_TEST_SANDBOX_ROBIND:-}" ]; then
  echo "[nightshift-cron] test gates bind read-only $NIGHTSHIFT_TEST_SANDBOX_ROBIND" | tee -a "$LOG"
fi
# A stop signal is forwarded to the runner, which writes its own digest; the launcher then ends
# normally (footer, fallback digest). systemd's stop timeout bounds the wait.
stop_signal=""
forward_stop() { # signal
  stop_signal="$1"
  [ -z "${runner_pid:-}" ] || kill -s "$1" "$runner_pid" 2>/dev/null || true
}

run_start=$(date +%s)
trap 'forward_stop TERM' TERM
trap 'forward_stop INT' INT
# tee ignores TERM so a stop signal to the whole cgroup cannot close the runner's pipe early.
exec {log_fd}> >(trap '' TERM; exec tee -a "$LOG")
tee_pid=$!
env --default-signal=INT "$NIGHTSHIFT_HOME/bin/nightshift.sh" >&"$log_fd" 2>&1 {log_fd}>&- &
runner_pid=$!
exec {log_fd}>&-
[ -z "$stop_signal" ] || kill -s "$stop_signal" "$runner_pid" 2>/dev/null || true
# A trap interrupts `wait`; wait again until the runner itself is reaped (it then leaves the job table).
while :; do
  wait "$runner_pid" && rc=0 || rc=$?
  jobs -p | grep -qx "$runner_pid" || break
done
trap '' TERM INT
runner_pid=""
wait "$tee_pid" || true
echo "=== nightshift done rc=$rc $(date -Iseconds) ===" | tee -a "$LOG"
# The digest is the only report, and the Runner writes none when it exits before or outside
# write_digest (parse error, split-state guard, invalid ledger, errexit). Record such a night here
# with the marker aborted_streak counts; a digest newer than this run's start is left alone.

if [ "$rc" -ne 0 ] && { [ ! -f "$digest" ] || [ "$(stat -c %Y "$digest")" -lt "$run_start" ]; }; then
  mkdir -p "$(dirname "$digest")"
  {
    [ -f "$digest" ] && echo || printf '# nightshift digest — %s\n\n' "$night"
    echo "- **ABORTED: the runner exited with status $rc before writing a digest** — nothing below the log tail reflects tonight's code. Last log lines:"
    echo
    echo '```'
    tail -n 20 "$LOG"
    echo '```'
  } >> "$digest"
fi
# Propagate: Type=oneshot with no Restart=, so this only marks the unit failed
# (visible in `systemctl --user status nightshift.service`) — it does not re-run.
exit "$rc"
