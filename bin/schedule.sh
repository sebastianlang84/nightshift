#!/usr/bin/env bash
# Manage the nightshift nightly scheduler — a systemd *user* timer that fires
# bin/nightshift-cron.sh at 03:00 local. This is the create/edit/delete tooling
# for the schedule, so you never hand-edit unit files.
#
#   schedule.sh install     # write + reload the user units (idempotent)
#   schedule.sh enable      # start the nightly timer (+ linger so it fires logged out)
#   schedule.sh disable     # stop the timer, keep the units installed
#   schedule.sh status      # is it enabled? when does it next fire?
#   schedule.sh logs [N]    # last N journal lines from the service (default 50)
#   schedule.sh dry-run     # run the launcher NOW with the mock agent (no cost, proves wiring)
#   schedule.sh uninstall   # stop + remove the units
set -euo pipefail

NIGHTSHIFT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$NIGHTSHIFT_HOME/scheduler"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

cmd="${1:-status}"
case "$cmd" in
  install)
    mkdir -p "$UNIT_DIR"
    sed "s#__NIGHTSHIFT_HOME__#$NIGHTSHIFT_HOME#g" "$SRC/nightshift.service" > "$UNIT_DIR/nightshift.service"
    cp "$SRC/nightshift.timer" "$UNIT_DIR/nightshift.timer"
    systemctl --user daemon-reload
    echo "installed units into $UNIT_DIR (ExecStart -> $NIGHTSHIFT_HOME/bin/nightshift-cron.sh)"
    echo "next: '$0 enable' to start the nightly timer"
    ;;
  enable)
    systemctl --user enable --now nightshift.timer
    # Linger lets the user timer fire while you're logged out (the whole point at 03:00).
    if loginctl enable-linger "$USER" 2>/dev/null; then
      echo "linger enabled — timer fires even when you're logged out"
    else
      echo "WARN: could not enable linger; the timer only fires while you have an active session" >&2
    fi
    systemctl --user list-timers nightshift.timer --no-pager || true
    ;;
  disable)
    systemctl --user disable --now nightshift.timer || true
    echo "timer disabled (units still installed; '$0 enable' to resume)"
    ;;
  status)
    systemctl --user is-enabled nightshift.timer 2>/dev/null && echo "(enabled)" || echo "(not enabled)"
    systemctl --user list-timers nightshift.timer --no-pager || true
    ;;
  logs)
    journalctl --user -u nightshift.service --no-pager -n "${2:-50}"
    ;;
  dry-run)
    # Prove the launcher + orchestrator wiring now, with the mock agent (no quota, no PRs).
    NIGHTSHIFT_AGENT="${NIGHTSHIFT_AGENT:-mock}" "$NIGHTSHIFT_HOME/bin/nightshift-cron.sh"
    ;;
  uninstall)
    systemctl --user disable --now nightshift.timer 2>/dev/null || true
    rm -f "$UNIT_DIR/nightshift.timer" "$UNIT_DIR/nightshift.service"
    systemctl --user daemon-reload
    echo "removed units from $UNIT_DIR"
    ;;
  *)
    echo "usage: $0 {install|enable|disable|status|logs [N]|dry-run|uninstall}" >&2
    exit 2
    ;;
esac
