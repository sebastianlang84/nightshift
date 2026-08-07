#!/usr/bin/env bash
set -euo pipefail

# harvest.sh resolves its state dir from the name operators are actually given.
# `NIGHTSHIFT_STATE_DIR` is the documented override for state/ (docs/deployment.md) and the name
# every other entry point reads; harvest must honour it, or `todos`/`close`/`verdict` silently read
# and WRITE the default ledger instead of the redirected one. Precedence, asserted here:
#     STATE_DIR  >  NIGHTSHIFT_STATE_DIR  >  $NIGHTSHIFT_HOME/state
# (the bare name must keep winning: bin/nightshift.sh and the other tests hand the run's state dir
# down under it, and it has to beat an exported outer value).
#
# Everything runs under a fake NIGHTSHIFT_HOME whose lib/ is a symlink to the real one, so a
# regression here writes into the fixture rather than into the live installation's state/.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"
ln -s "$ROOT/lib" "$HOME_DIR/lib"
ln -s "$ROOT/rulebook.example.yaml" "$HOME_DIR/rulebook.example.yaml"

# `harvest.sh` prints the ledger path it resolved and exits 0 when the file is absent — a
# side-effect-free way to read back the resolution for each precedence case.
resolved() { # VAR=VALUE… -> the ledger path harvest reported
  (
    unset STATE_DIR LEDGER PROBE_SNAPSHOT NIGHTSHIFT_STATE_DIR
    export NIGHTSHIFT_HOME="$HOME_DIR"
    while [ "$#" -gt 0 ]; do export "$1"; shift; done   # only VAR=VALUE pairs reach this
    bash "$ROOT/bin/harvest.sh"
  ) | sed -n 's/^no ledger at \(.*\) — nothing to harvest$/\1/p'
}

got="$(resolved NIGHTSHIFT_STATE_DIR="$TMP/redirected")"
[ "$got" = "$TMP/redirected/ledger.jsonl" ] \
  || { echo "NIGHTSHIFT_STATE_DIR ignored: resolved '$got'" >&2; exit 1; }

got="$(resolved NIGHTSHIFT_STATE_DIR="$TMP/redirected" STATE_DIR="$TMP/explicit")"
[ "$got" = "$TMP/explicit/ledger.jsonl" ] \
  || { echo "STATE_DIR must win over NIGHTSHIFT_STATE_DIR: resolved '$got'" >&2; exit 1; }

got="$(resolved)"
[ "$got" = "$HOME_DIR/state/ledger.jsonl" ] \
  || { echo "default must stay \$NIGHTSHIFT_HOME/state: resolved '$got'" >&2; exit 1; }

# --- the derived paths follow, and nothing lands in the default -----------------------
# `todos` reads the ledger and REWRITES the probe snapshot; both must sit in the redirected dir.
mkdir -p "$TMP/redirected"
jq -nc '{night:"2026-08-01",item:"item-x",repo:"/nonexistent/repo",fingerprint:"a.md:bug:sym",
         branch:null,sha:null,outcome:"finding",summary:"REDIRECTED-LEDGER-MARKER",
         code_sig:null,ts:"2026-08-01T02:00:00+02:00",schema_version:2}' \
  > "$TMP/redirected/ledger.jsonl"

out="$(env -u STATE_DIR -u LEDGER -u PROBE_SNAPSHOT \
        NIGHTSHIFT_HOME="$HOME_DIR" NIGHTSHIFT_STATE_DIR="$TMP/redirected" \
        bash "$ROOT/bin/harvest.sh" todos)"
grep -q REDIRECTED-LEDGER-MARKER <<<"$out" \
  || { echo "todos did not read the redirected ledger, got: $out" >&2; exit 1; }
[ -f "$TMP/redirected/findings-probe.json" ] \
  || { echo "probe snapshot did not follow NIGHTSHIFT_STATE_DIR" >&2; exit 1; }
[ ! -e "$HOME_DIR/state" ] \
  || { echo "harvest wrote into the DEFAULT state dir while redirected" >&2; exit 1; }

echo "test-harvest-state-dir-env: ok"
