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
    systemctl --user disable --now nightshift.timer || true
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
    #
    # Setting NIGHTSHIFT_AGENT=mock and nothing else (what this used to do) buys no isolation: state,
    # runs, digests and the rulebook all default under $NIGHTSHIFT_HOME, so a "dry-run" was a full
    # production night. Harvest appended verdicts to the live ledger; every clean (repo,dim) pass
    # appended an `empty` row, which the service cadence and the ADR 0015 exclusion window later read
    # as evidence that lens was reviewed (the rows ADR 0023 exists to retract); dim-scan markers
    # advanced rotation; the day's digest was overwritten; and since the orchestrator has no no-push
    # mode, a managed repo containing one of the mock's trigger strings got a mock-authored
    # nightshift/* branch pushed to its real origin.
    #
    # So isolation is what makes the claim true. The SAME launcher and orchestrator run, against a
    # throwaway sandbox: its own rulebook, state, runs, digests, worktrees, log and flock, and a
    # target repo whose origin is a LOCAL bare remote (is_network_remote treats it as local, so the
    # ADR 0017 split-state guard stays quiet and the push path is still exercised — into the sandbox).
    # Its own flock, too: a dry-run must never make the real nightly run skip as "already running".
    SB="$(mktemp -d "${TMPDIR:-/tmp}/nightshift-dry-run.XXXXXX")"
    echo "dry-run sandbox: $SB (throwaway — live ledger, digests and managed repos are untouched)"
    bash "$NIGHTSHIFT_HOME/bin/setup-sandbox.sh" "$SB" >/dev/null

    # Isolating the run takes the live rulebook out of the picture, and that file is the first thing
    # a real night reads — a malformed one aborts it. Check it the one way that writes nothing.
    if [ -f "$NIGHTSHIFT_HOME/rulebook.yaml" ]; then
      python3 "$NIGHTSHIFT_HOME/lib/parse_rulebook.py" "$NIGHTSHIFT_HOME/rulebook.yaml" >/dev/null \
        || { echo "FAIL: the live rulebook.yaml does not parse — a real night would abort here" >&2; exit 1; }
      echo "live rulebook.yaml parses (read-only check; the run below uses the sandbox's)"
    else
      echo "WARN: no rulebook.yaml — a real night would fall back to rulebook.example.yaml" >&2
    fi

    env NIGHTSHIFT_HOME="$NIGHTSHIFT_HOME" \
        NIGHTSHIFT_AGENT=mock \
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
