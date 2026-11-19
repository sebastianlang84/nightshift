#!/usr/bin/env bash
# Unattended launcher for the nightly scheduler (the "dumb" side: the timer fires
# this, this fires the smart orchestrator bin/nightshift.sh). It adds the three
# things an unattended run needs that an interactive one gets for free:
#   1. a single-instance flock — a long run must NEVER overlap the next night's;
#   2. an explicit PATH — systemd user services start with a minimal env, but
#      nightshift shells out to claude/gh which may live under ~/.local/bin;
#   3. a timestamped log file (everything also still goes to journald);
#   4. optionally, a quota check before the night starts (NIGHTSHIFT_QUOTA_CMD) and one line to the
#      operator when it pauses the night (NIGHTSHIFT_NOTIFY_CMD) — ADR 0044.
set -euo pipefail

NIGHTSHIFT_HOME="${NIGHTSHIFT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export NIGHTSHIFT_HOME
# Nightly runs are real work by default; the mock is only for --dry-run testing. But this default
# must not overrule the rulebook's `agent.primary` (ADR 0031): the Runner treats a SET
# NIGHTSHIFT_AGENT as the caller's explicit choice and lets it win, so exporting one here
# unconditionally made that key dead in unattended runs.
#
# So the default is applied only when the rulebook names no adapter. Asking the parser is the one
# way to know that without duplicating its rules here; a rulebook that does not parse leaves the
# answer empty and falls back to `claude`, which is what a run would have done before this existed
# (the Runner then aborts on the same parse error and says so).
if [ -z "${NIGHTSHIFT_AGENT:-}" ]; then
  _rb="${RULEBOOK:-$NIGHTSHIFT_HOME/rulebook.yaml}"
  [ -f "$_rb" ] || _rb="$NIGHTSHIFT_HOME/rulebook.example.yaml"
  _primary="$(python3 "$NIGHTSHIFT_HOME/lib/parse_rulebook.py" "$_rb" 2>/dev/null \
              | awk -F'\t' '$1 == "primary_agent" { print $2 }')" || _primary=""
  [ -n "$_primary" ] || export NIGHTSHIFT_AGENT=claude
  unset _rb _primary
fi
# Make the tools nightshift invokes findable under systemd's minimal PATH.
# System dirs come FIRST so a binary planted under ~/.local/bin (which a write
# primitive could reach) cannot shadow the Runner's unqualified jq/git/gh/
# python3 calls — see docs/design/risk-analysis.md R10/N4. Agent tools
# that live only under ~/.local/bin (claude/gh) are still resolved there.
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:${PATH:-}"

# The repos' ship gates (ADR 0022) run the repo's OWN suite, so they need the developer toolchain —
# node, npm and the corepack shims (pnpm) — which lives under nvm and is therefore absent from the
# PATH above. It must stay absent there: that PATH puts the system dirs first so nothing planted
# under a $HOME directory can shadow the Runner's own unqualified jq/git/python3/gh calls (R10/N4),
# and prepending an nvm bin would reopen exactly that hole. So it is exported as its own variable and
# the Runner prepends it for the `test_cmd` subprocess only — a process that already executes the
# repo's package scripts, so its PATH is not a security boundary.
#
# Observed 2026-08-12 with this missing: /usr/bin/node is v18, so an extension's
# `node --experimental-strip-types` gate exited 9 and web-app's `pnpm` gate exited 127. Six finished
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

# The operator's rule for unattended runs: a (nearly) spent Claude week pauses the night and says so
# in one line; it never switches models (ADR 0044). NIGHTSHIFT_QUOTA_CMD is the host's check, run
# once before the night: exit 75 (EX_TEMPFAIL) = pause, with the first line of its stdout as the
# reason; any other exit = go. Pause is a positive signal so a check that crashes, cannot run or times
# out lets the night run (logged): a broken check must never silently stop every night. A pause is not
# a failure — exit 0, and its digest entry is `PAUSED`, never `ABORTED`.
if [ -n "${NIGHTSHIFT_QUOTA_CMD:-}" ]; then
  quota_rc=0
  quota_out="$(timeout -k 5 "${NIGHTSHIFT_QUOTA_TIMEOUT:-60}" sh -c "$NIGHTSHIFT_QUOTA_CMD" </dev/null 2>>"$LOG")" \
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

# `${…:-}` and not a bare expansion: since the launcher stopped pinning an adapter when the rulebook
# names one, this variable is legitimately unset — and under `set -u` a bare read aborts the run
# before it starts. The Runner announces the adapter it resolved on its own line either way.
echo "=== nightshift start $(date -Iseconds) (agent=${NIGHTSHIFT_AGENT:-from rulebook}) ===" | tee -a "$LOG"
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
# The digest is the only report. The Runner writes one on a normal end, an agent abort and a signal,
# but not when it exits before or outside write_digest (a rulebook parse error, the split-state
# guard, an invalid ledger, an errexit death). Record such a night here, with the marker
# aborted_streak counts, so the morning sees that nights are being lost instead of the last good
# digest. A digest this run already wrote (newer than its start) is left alone.
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
