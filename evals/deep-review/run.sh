#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/nightshift-deep-review-$(date +%Y%m%d-%H%M%S)}"
JOBS="${NIGHTSHIFT_EVAL_JOBS:-2}"
mkdir -p "$OUT"
mapfile -t cases < <(jq -r '.[].name' "$ROOT/evals/deep-review/cases.json")

declare -a pids=()
rc=0
for name in "${cases[@]}"; do
  "$ROOT/evals/deep-review/run-case.sh" "$name" "$OUT" >"$OUT/$name.log" 2>&1 &
  pids+=("$!")
  if [ "${#pids[@]}" -ge "$JOBS" ]; then
    for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
    pids=()
  fi
done
for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
[ "$rc" -eq 0 ] || { echo "one or more eval cases failed; inspect $OUT/*.log" >&2; exit 1; }
python3 "$ROOT/evals/deep-review/score.py" "$OUT"
echo "deep-review eval artifacts: $OUT"
