#!/usr/bin/env bash
# Operator status: per-repo overview of what nightshift found or changed and how far each item got
# (reviewed, merged, dropped), plus a clutter check. Read-only apart from `git fetch --prune`.
#   status.sh [--days N] [--no-fetch]
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/status_report.py" "$@"
