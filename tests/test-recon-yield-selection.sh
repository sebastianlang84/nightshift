#!/usr/bin/env bash
set -euo pipefail

# ADR 0015 unit test: recon reprioritizes via yield weights and never excludes. Exercises the pure
# selection functions by sourcing the runner (NIGHTSHIFT_SOURCED=1) so the weighting is deterministic
# and independent of a full mock night. Covers: dim_weight (yield->weight, missing cache => normal),
# evidence_override (a shipped row newer than recon floors the weight), and select_dimension
# (high-yield wins at equal staleness; evidence lifts a low lens above another low lens).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
       NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"

REPO="/tmp/fake-repo-adr0015"        # never touched on disk — only used as a ledger/cache key
DIMENSIONS=(security craft)          # a controlled two-lens candidate set

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- dim_weight: yield -> integer weight, missing cache => normal (never drops) ------------------
[ "$(dim_weight "$REPO" security)" = "$DIM_W_NORMAL" ] || fail "missing cache should weight normal"

cache="$(recon_cache_path "$REPO")"; mkdir -p "$(dirname "$cache")"
gen_ts="$(date -Iseconds -d '@'"$(( $(date +%s) - 3600 ))")"   # recon looked 1h ago
jq -nc --arg ts "$gen_ts" --arg r "$REPO" \
  '{repo:$r, head:"deadbeef", ts:$ts,
    dimensions:{security:{yield:"low",hint:"x"}, craft:{yield:"high",hint:"y"}}}' > "$cache"

[ "$(dim_weight "$REPO" security)" = "$DIM_W_LOW" ]  || fail "yield low should map to DIM_W_LOW"
[ "$(dim_weight "$REPO" craft)"    = "$DIM_W_HIGH" ] || fail "yield high should map to DIM_W_HIGH"

# --- select_dimension: at equal staleness, the higher-yield lens wins -----------------------------
now=$(date +%s)
mkdir -p "$SCAN_DIR"
touch -d "@$((now-100))" "$(dim_scan_marker "$REPO" security)"
touch -d "@$((now-100))" "$(dim_scan_marker "$REPO" craft)"
pick="$(select_dimension "$REPO")"
[ "$pick" = craft ] || fail "high-yield craft should beat low-yield security at equal staleness (got $pick)"

# --- evidence_override: a shipped finding newer than recon lifts a low lens ----------------------
# Make BOTH lenses low, so only the override can decide. A shipped `security` finding that postdates
# recon (but is 90s old, so security's staleness is slightly BELOW craft's) floors security to normal;
# that lift is what flips selection to security. Without the override, low security (age 90) would
# score below low craft (age 100). Proves recon's verdict yields to ledger evidence — no cache mutation.
jq -c '.dimensions.craft.yield="low"' "$cache" > "$cache.t" && mv "$cache.t" "$cache"
touch -d "@$((now-300))" "$(dim_scan_marker "$REPO" security)"
jq -nc --arg r "$REPO" --arg ts "$(date -Iseconds -d "@$((now-90))")" \
  '{repo:$r, dimension:"security", outcome:"shipped", branch:"nightshift/x", ts:$ts}' >> "$LEDGER"

evidence_override "$REPO" security || fail "shipped row newer than recon should trigger evidence_override"
evidence_override "$REPO" craft    && fail "craft has no shipped row — override must not trigger"

pick2="$(select_dimension "$REPO")"
[ "$pick2" = security ] || fail "evidence should lift low security above low craft (got $pick2)"

echo "test-recon-yield-selection: ok"
