#!/usr/bin/env bash
# Manage the nightshift nightly scheduler — a systemd *user* timer that fires
# bin/nightshift-cron.sh at 06:00 local. This is the create/edit/delete tooling
# for the schedule, so you never hand-edit unit files.
#
#   schedule.sh install     # write + reload the user units (idempotent)
#   schedule.sh enable      # start the nightly timer (+ linger so it fires logged out)
#   schedule.sh disable     # stop the timer, keep the units installed
#   schedule.sh status      # is it enabled? when does it next fire?
#   schedule.sh logs [N]    # last N journal lines from the service (default 50)
#   schedule.sh dry-run     # run the launcher NOW, mock agent + throwaway sandbox (no cost, no writes)
#   schedule.sh uninstall   # stop + remove the units
set -euo pipefail

NIGHTSHIFT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$NIGHTSHIFT_HOME/scheduler"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# True only when systemd itself reports the timer can no longer fire: not active and not enabled.
# A query that fails (no user manager, say) is unknown, never "off" — `show` exits non-zero then,
# while for a unit that is not installed it still answers (ActiveState=inactive, empty file state).
timer_off() {
  local out active file
  out="$(systemctl --user show nightshift.timer -p ActiveState -p UnitFileState 2>/dev/null)" || return 1
  active="$(sed -n 's/^ActiveState=//p' <<<"$out")"
  file="$(sed -n 's/^UnitFileState=//p' <<<"$out")"
  case "$active" in inactive|failed) ;; *) return 1 ;; esac
  case "$file" in ""|disabled|masked|masked-runtime) return 0 ;; *) return 1 ;; esac
}

# systemd drop-ins (…/nightshift.timer.d/*.conf, e.g. from `systemctl --user edit`) override the
# committed unit, so the EFFECTIVE cadence can silently differ from scheduler/nightshift.timer.
# Surface them wherever we report state, and point at the authoritative merged view.
report_overrides() {
  local d found=0
  for d in "$UNIT_DIR/nightshift.timer.d" "$UNIT_DIR/nightshift.service.d"; do
    if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
      found=1
      echo "override drop-ins in $d:"
      ls -1 "$d" | sed 's/^/  - /'
    fi
  done
  if [ "$found" -eq 1 ]; then
    echo "WARN: the drop-ins above may change the EFFECTIVE schedule — the committed nightshift.timer"
    echo "      is not the whole story. Authoritative merged view: systemctl --user cat nightshift.timer"
  fi
}

cmd="${1:-status}"
case "$cmd" in
  install)
    mkdir -p "$UNIT_DIR"
    sed "s#__NIGHTSHIFT_HOME__#$NIGHTSHIFT_HOME#g" "$SRC/nightshift.service" > "$UNIT_DIR/nightshift.service"
    cp "$SRC/nightshift.timer" "$UNIT_DIR/nightshift.timer"
    systemctl --user daemon-reload
    echo "installed units into $UNIT_DIR (ExecStart -> $NIGHTSHIFT_HOME/bin/nightshift-cron.sh)"
    report_overrides
    echo "next: '$0 enable' to start the nightly timer"
    ;;
  enable)
    systemctl --user enable --now nightshift.timer
    # Linger lets the user timer fire while you're logged out (the whole point at 06:00).
    if loginctl enable-linger "$USER" 2>/dev/null; then
      echo "linger enabled — timer fires even when you're logged out"
    else
      echo "WARN: could not enable linger; the timer only fires while you have an active session" >&2
    fi
    systemctl --user list-timers nightshift.timer --no-pager || true
    report_overrides
    ;;
  disable)
    # `|| true` keeps disabling an already-disabled timer idempotent; the check after it is what
    # says the timer is really off, so a failed call (no user manager, say) is not reported as done.
    systemctl --user disable --now nightshift.timer || true
    timer_off || { echo "ERROR: nightshift.timer is still enabled or active, or its state could not be read — not disabled" >&2; exit 1; }
    echo "timer disabled (units still installed; '$0 enable' to resume)"
    ;;
  status)
    systemctl --user is-enabled nightshift.timer 2>/dev/null && echo "(enabled)" || echo "(not enabled)"
    systemctl --user list-timers nightshift.timer --no-pager || true
    report_overrides
    ;;
  logs)
    journalctl --user -u nightshift.service --no-pager -n "${2:-50}"
    ;;
  dry-run)
    # Prove the launcher + orchestrator wiring now — WITHOUT touching the installation it is proving.
    # NIGHTSHIFT_AGENT=mock alone isolates nothing: state, runs, digests and the rulebook default
    # under $NIGHTSHIFT_HOME, and the orchestrator has no no-push mode. So the same launcher runs
    # against a throwaway sandbox with its own rulebook, state, runs, digests, worktrees, log and
    # flock (so the real night never skips as "already running"), and a target repo whose origin is
    # a LOCAL bare remote (the ADR 0017 guard stays quiet and the push path is still exercised).
    SB="$(mktemp -d "${TMPDIR:-/tmp}/nightshift-dry-run.XXXXXX")"
    echo "dry-run sandbox: $SB (throwaway — live ledger, digests and managed repos are untouched)"
    bash "$NIGHTSHIFT_HOME/bin/setup-sandbox.sh" "$SB" >/dev/null

    # The sandbox run does not read the live rulebook, which a real night aborts on if malformed, so
    # check it here without writing anything.
    if [ -f "$NIGHTSHIFT_HOME/rulebook.yaml" ]; then
      # shellcheck source=../lib/rulebook.sh
      ( source "$NIGHTSHIFT_HOME/lib/rulebook.sh" && rulebook_load "$NIGHTSHIFT_HOME/rulebook.yaml" ) \
        || { echo "FAIL: the live rulebook.yaml does not parse — a real night would abort here" >&2; exit 1; }
      echo "live rulebook.yaml parses (read-only check; the run below uses the sandbox's)"
    else
      echo "WARN: no rulebook.yaml — a real night would fall back to rulebook.example.yaml" >&2
    fi

    # An explicitly empty NIGHTSHIFT_ADVISORS turns branch advice off, the legacy
    # NIGHTSHIFT_BRANCH_REVIEW route included. BASH_ENV is unset because a
    # bash startup file could re-export the nightly routes after these overrides.

    env -u BASH_ENV NIGHTSHIFT_HOME="$NIGHTSHIFT_HOME" \
        NIGHTSHIFT_AGENT=mock \
        NIGHTSHIFT_ADVISORS= \
        NIGHTSHIFT_QUOTA_CMD= \
        NIGHTSHIFT_NOTIFY_CMD= \
        RULEBOOK="$SB/rulebook.yaml" \
        NIGHTSHIFT_STATE_DIR="$SB/state" \
        NIGHTSHIFT_RUNS_DIR="$SB/runs" \
        NIGHTSHIFT_DIGEST_DIR="$SB/digests" \
        NIGHTSHIFT_WORKTREES="$SB/worktrees" \
        NIGHTSHIFT_LOG_DIR="$SB/logs" \
        NIGHTSHIFT_LOCK="$SB/nightshift.lock" \
        "$NIGHTSHIFT_HOME/bin/nightshift-cron.sh"

    echo
    echo "dry-run ok — digest: $SB/digests/  launcher log: $SB/logs/"
    echo "nothing was written under $NIGHTSHIFT_HOME; discard with: rm -rf $SB"
    ;;
  uninstall)
    systemctl --user disable --now nightshift.timer 2>/dev/null || true
    timer_off || { echo "ERROR: nightshift.timer is still enabled or active, or its state could not be read — units left in place" >&2; exit 1; }
    rm -f "$UNIT_DIR/nightshift.timer" "$UNIT_DIR/nightshift.service"
    # Remove drop-in override dirs too, so uninstall leaves no hidden schedule behind. Report each
    # removed file first, since these are operator-created (e.g. via `systemctl --user edit`).
    for d in "$UNIT_DIR/nightshift.timer.d" "$UNIT_DIR/nightshift.service.d"; do
      if [ -d "$d" ]; then
        echo "removing override drop-in dir $d:"; ls -1 "$d" 2>/dev/null | sed 's/^/  - /'
        rm -rf "$d"
      fi
    done
    systemctl --user daemon-reload || true
    echo "removed units from $UNIT_DIR"
    ;;
  *)
    echo "usage: $0 {install|enable|disable|status|logs [N]|dry-run|uninstall}" >&2
    exit 2
    ;;
esac
