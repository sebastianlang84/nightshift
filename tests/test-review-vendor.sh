#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT

# `review_agent: auto`: a host command picks the reviewing vendor before every Review stage; anything
# but `claude` means codex, and a reviewer of the fix's own vendor gets the adversarial brief.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/wd" "$TMP/item"

export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_AGENT=codex
unset NIGHTSHIFT_REVIEW_AGENT
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
source "$ROOT/bin/nightshift.sh"
git init -q "$TMP/wd"

fail() { echo "FAIL: $*"; exit 1; }
RB_REVIEW_AGENT=auto

NIGHTSHIFT_REVIEW_VENDOR_TIMEOUT=2
for case in "echo claude:claude" "echo codex:codex" "echo junk:codex" "false:codex" "true:codex" \
            "printf ' claude\nx':claude" \
            "echo claude; exit 1:codex" "echo claude; sleep 200:codex"; do
  NIGHTSHIFT_REVIEW_VENDOR_CMD="${case%:*}" REVIEW_VENDOR=""
  refresh_review_vendor 2>/dev/null
  got="$(review_stage_agent)"
  [ "$got" = "${case##*:}" ] || fail "'${case%:*}' routed review to '$got', want '${case##*:}'"
done

# An explicit env value still wins over the rulebook's auto, and auto never asks without it set.
NIGHTSHIFT_REVIEW_VENDOR_CMD="echo claude"; refresh_review_vendor
NIGHTSHIFT_REVIEW_AGENT=codex; [ "$(review_stage_agent)" = codex ] || fail "env did not win over auto"
NIGHTSHIFT_REVIEW_AGENT=""
[ "$(review_stage_agent)" = "$NIGHTSHIFT_AGENT" ] || fail "empty env did not disable review routing"
unset NIGHTSHIFT_REVIEW_AGENT
RB_REVIEW_AGENT=claude
[ "$(review_stage_agent)" = claude ] || fail "rulebook did not route review to Claude"
RB_REVIEW_AGENT=auto

# Same vendor: run_review_stage sets the flag, and stage_prompt carries the adversarial section.
calls=""
run_agent() { calls="$calls $1:${NS_REVIEW_SAME_VENDOR:-0}:$NIGHTSHIFT_AGENT"; }
NIGHTSHIFT_REVIEW_VENDOR_CMD="echo codex"; run_review_stage "$TMP/wd" "$TMP/item"
NIGHTSHIFT_REVIEW_VENDOR_CMD="echo claude"; run_review_stage "$TMP/wd" "$TMP/item"
[ "$calls" = " review:1:codex review:0:claude" ] || fail "run_review_stage calls: '$calls'"

NS_REVIEW_SAME_VENDOR=1 stage_prompt review "$TMP/wd" "$TMP/item" 2>/dev/null | grep -q 'same model family' \
  || fail "same-vendor review prompt lacks the adversarial section"
stage_prompt review "$TMP/wd" "$TMP/item" 2>/dev/null | grep -q 'same model family' \
  && fail "cross-vendor review prompt carries the same-vendor section"

# The parser accepts auto and still rejects a typo.
mk() { printf 'agent:\n  review_agent: %s\nrepos:\n  - path: %s\n' "$1" "$TMP/wd" > "$TMP/rb.yaml"; }
mk auto; python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rb.yaml" | grep -q $'^review_agent\tauto$' \
  || fail "parser did not emit review_agent auto"
mk autoo; python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rb.yaml" >/dev/null 2>&1 \
  && fail "parser accepted review_agent autoo"

echo "PASS test-review-vendor"
