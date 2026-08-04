#!/usr/bin/env bash
set -euo pipefail

# schedule.sh must surface systemd drop-in overrides (which can silently change the effective
# cadence) in `status`, and `uninstall` must remove the drop-in directory rather than leaving a
# hidden schedule behind.
#
# XDG_CONFIG_HOME isolates the unit FILES. It does NOT isolate the session BUS: `systemctl --user`
# talks to the operator's live systemd no matter where the unit files live. So `uninstall` — whose
# first act is `systemctl --user disable --now nightshift.timer` — silently DISARMED the real
# nightly timer every time this suite ran on a machine with a user session. (Observed 2026-08-04:
# the live timer went from `enabled/waiting` to `disabled` mid-session; nothing reported it, and
# the next night simply would not have fired. The ship gate of ADR 0022 made it worse — it runs
# this very suite in a worktree, so a gated nightshift ship would disarm the scheduler nightly.)
# The stub below intercepts the unqualified `systemctl` on PATH, so the test exercises the real
# code path and records the calls instead of executing them.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/systemctl.calls"
exit 0
EOF
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

export XDG_CONFIG_HOME="$TMP/config"
UNIT_DIR="$XDG_CONFIG_HOME/systemd/user"
mkdir -p "$UNIT_DIR/nightshift.timer.d"
printf '[Timer]\nOnCalendar=\nOnCalendar=hourly\n' > "$UNIT_DIR/nightshift.timer.d/override.conf"

out="$(bash "$ROOT/bin/schedule.sh" status 2>&1 || true)"
grep -q "override.conf" <<<"$out" || { echo "status did not report the drop-in override" >&2; echo "$out" >&2; exit 1; }
grep -q "may change the EFFECTIVE schedule" <<<"$out" || { echo "status did not warn about effective cadence" >&2; echo "$out" >&2; exit 1; }

uout="$(bash "$ROOT/bin/schedule.sh" uninstall 2>&1 || true)"
grep -q "override.conf" <<<"$uout" || { echo "uninstall did not report the removed drop-in" >&2; echo "$uout" >&2; exit 1; }
[ ! -d "$UNIT_DIR/nightshift.timer.d" ] || { echo "drop-in dir survived uninstall" >&2; exit 1; }

# uninstall genuinely tries to disable the unit — the stub is what keeps that off the live bus.
# This assertion is the reason the stub must stay: it pins that the suite would otherwise reach
# the operator's systemd, so removing the stub fails loudly rather than silently disarming a timer.
grep -q -- "--user disable --now nightshift.timer" "$TMP/systemctl.calls" \
  || { echo "uninstall did not attempt to disable the timer" >&2; cat "$TMP/systemctl.calls" >&2; exit 1; }

echo "test-scheduler-overrides: ok"
