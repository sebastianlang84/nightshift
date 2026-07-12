#!/usr/bin/env bash
set -euo pipefail

# schedule.sh must surface systemd drop-in overrides (which can silently change the effective
# cadence) in `status`, and `uninstall` must remove the drop-in directory rather than leaving a
# hidden schedule behind. systemctl calls are guarded, so this runs without a user session bus.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

echo "test-scheduler-overrides: ok"
