#!/usr/bin/env bash
set -euo pipefail

# Verify phase (ADR 0021) — the model half of finding closure, exercised through the mock adapter:
#  - a finding whose target code changed AND whose defect is gone gets a `resolved` verdict,
#    stamped source "auto-verify" so it is never mistaken for human ground truth (ADR 0007);
#  - a finding whose code changed but whose defect survives stays open, and the negative result is
#    remembered in the snapshot so the same code is not re-verified;
#  - a finding whose target code never changed is never handed to a model at all;
#  - max_verifies_per_run bounds the phase, and 0 disables it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"

export NIGHTSHIFT_AGENT=mock
export NIGHTSHIFT_STATE_DIR="$TMP/state"
export NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests"
export NIGHTSHIFT_WORKTREES="$TMP/wt"
export NIGHTSHIFT_SOURCED=1
# shellcheck disable=SC1090
source "$ROOT/bin/nightshift.sh"

# --- repo with two planted defects; both targets then change ------------------------
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'teh quick fox\n'      > "$REPO/README.md"
printf '# retrun value\n'     > "$REPO/app.py"
git -C "$REPO" add -A; git -C "$REPO" commit -qm init
printf 'stable\n' > "$REPO/keep.md"
git -C "$REPO" add -A; git -C "$REPO" commit -qm keep

sig_of() { git -C "$REPO" rev-parse "HEAD:$1" | sha1sum | cut -c1-12; }
finding() { # item file
  jq -nc --arg r "$REPO" --arg i "$1" --arg f "$2" --arg cs "$(sig_of "$2")" \
    '{night:"2026-07-20",item:$i,repo:$r,fingerprint:($f+":typo:anchor"),branch:null,sha:null,
      outcome:"finding",summary:("planted defect in "+$f),dimension:"craft",code_sig:$cs,
      ts:"2026-07-20T02:00:00+02:00",schema_version:2}' >> "$LEDGER"
}
finding item-readme README.md   # will be fixed  -> resolved
finding item-app    app.py      # will change but stay broken -> open
finding item-keep   keep.md     # never touched  -> never verified

# README is actually fixed; app.py changes without fixing anything.
printf 'the quick fox\n'                 > "$REPO/README.md"
printf '# retrun value\n# unrelated\n'   > "$REPO/app.py"
git -C "$REPO" commit -qam changes

MAX_VERIFY=5
verify_findings

verdict_of() { jq -rs --arg i "$1" '[.[]|select(.outcome=="verdict" and .item==$i)]|last|.verdict // ""' "$LEDGER"; }
source_of()  { jq -rs --arg i "$1" '[.[]|select(.outcome=="verdict" and .item==$i)]|last|.source  // ""' "$LEDGER"; }
snap_get()   { jq -r --arg i "$1" --arg k "$2" '(.items[]|select(.item==$i)|.verify[$k]) // ""' "$PROBE_SNAPSHOT"; }

[ "$(verdict_of item-readme)" = resolved ] \
  || { echo "a verified fix must record a resolved verdict, got '$(verdict_of item-readme)'" >&2; exit 1; }
[ "$(source_of item-readme)" = auto-verify ] \
  || { echo "a machine verdict must be stamped auto-verify, not '$(source_of item-readme)'" >&2; exit 1; }
[ "$(verdict_of item-app)" = "" ] \
  || { echo "an unfixed finding must NOT get a verdict, got '$(verdict_of item-app)'" >&2; exit 1; }
[ "$(snap_get item-app result)" = open ] \
  || { echo "the negative verify result must be remembered in the snapshot" >&2; exit 1; }
[ "$(snap_get item-keep result)" = "" ] \
  || { echo "an untouched finding must never reach the verify stage" >&2; exit 1; }
# The resolved one leaves the snapshot; the still-open one stays visible.
[ "$(jq '[.items[]|select(.item=="item-readme")]|length' "$PROBE_SNAPSHOT")" = 0 ] \
  || { echo "a resolved finding must drop out of the snapshot" >&2; exit 1; }
[ "$(jq '[.items[]|select(.item=="item-app")]|length' "$PROBE_SNAPSHOT")" = 1 ] \
  || { echo "an open finding must stay in the snapshot" >&2; exit 1; }

# --- idempotence: a second pass must not re-verify what has not moved ---------------
runs_before=$(find "$RUNS_DIR" -maxdepth 1 -name 'verify-*' | wc -l)
verify_findings
[ "$(find "$RUNS_DIR" -maxdepth 1 -name 'verify-*' | wc -l)" = "$runs_before" ] \
  || { echo "unchanged code must not be re-verified" >&2; exit 1; }

# --- the cap bounds the phase, and 0 disables it -------------------------------------
printf 'the quick fox, reworded\n' > "$REPO/README.md"
printf '# retrun value, reworded\n' > "$REPO/app.py"
git -C "$REPO" commit -qam rewrite
MAX_VERIFY=0
verify_findings
[ "$(find "$RUNS_DIR" -maxdepth 1 -name 'verify-*' | wc -l)" = "$runs_before" ] \
  || { echo "max_verifies_per_run=0 must disable the phase" >&2; exit 1; }
MAX_VERIFY=1
verify_findings
[ "$(find "$RUNS_DIR" -maxdepth 1 -name 'verify-*' | wc -l)" = "$((runs_before + 1))" ] \
  || { echo "the cap must bound how many findings are verified per run" >&2; exit 1; }

echo "test-finding-verify: ok"
