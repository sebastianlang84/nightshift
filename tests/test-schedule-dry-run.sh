#!/usr/bin/env bash
set -euo pipefail

# `schedule.sh dry-run` advertises "no cost, proves wiring". It used to set NIGHTSHIFT_AGENT=mock and
# nothing else, which bought no isolation at all: state/runs/digests and the rulebook default under
# $NIGHTSHIFT_HOME, so the "dry-run" was a production night — harvest on the live ledger, an `empty`
# row per clean (repo,dim) pass (the evidence rows ADR 0023 exists to retract), the day's digest
# overwritten, and — there being no no-push mode in the orchestrator — a mock-authored nightshift/*
# branch pushed to a real origin.
#
# Asserted here: the night genuinely runs (so the "untouched" assertions are not vacuous), it runs
# entirely inside a throwaway sandbox, it writes nothing under NIGHTSHIFT_HOME, and it does not take
# the nightly flock — a dry-run must never make the real 04:00 run skip as "already running".
#
# A `systemctl` stub is on PATH even though dry-run does not call it: `systemctl --user` ignores
# XDG_CONFIG_HOME and reaches the operator's live bus, so any test that runs schedule.sh keeps the
# stub as a standing guard (see test-scheduler-overrides.sh).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/systemctl"
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

# The dry-run mktemps its sandbox under TMPDIR; pointing that at the test dir keeps the whole thing
# inside the trap, and puts the DEFAULT lock path ($TMPDIR/nightshift.lock) somewhere we can hold.
export TMPDIR="$TMP"

fail() { echo "FAIL: $*" >&2; exit 1; }

# A signature of the live state dirs: path + size, so an appended ledger row or a rewritten digest
# shows up. Absent dirs are recorded as absent — creating one is a change too.
sig() {
  local d
  for d in state runs digests; do
    if [ -d "$ROOT/$d" ]; then find "$ROOT/$d" -type f -printf '%p %s\n' | sort; else echo "ABSENT $d"; fi
  done
}
before="$(sig)"

# Hold the nightly single-instance lock. If dry-run shared it, the launcher would report "another run
# holds ..." and exit 0 without running a thing — a green dry-run that proved nothing.
exec 8>"$TMP/nightshift.lock"
flock -n 8 || fail "could not take the default lock for the test"

out="$TMP/dry-run.out"
bash "$ROOT/bin/schedule.sh" dry-run >"$out" 2>&1 || { echo "dry-run failed:" >&2; cat "$out" >&2; exit 1; }

grep -q "another run holds" "$out" && { cat "$out" >&2; fail "dry-run shares the nightly flock — it would be skipped by (and would skip) a real run"; }

SB="$(sed -n 's/^dry-run sandbox: \([^ ]*\).*/\1/p' "$out" | head -1)"
[ -n "$SB" ] && [ -d "$SB" ] || { cat "$out" >&2; fail "dry-run did not report a sandbox directory"; }

# The night really ran: a ledger, a digest and a launcher log, all inside the sandbox.
[ -s "$SB/state/ledger.jsonl" ] || { cat "$out" >&2; fail "no sandbox ledger — the night did not run"; }
[ -n "$(find "$SB/digests" -name '*.md' 2>/dev/null)" ] || fail "no digest written in the sandbox"
[ -n "$(find "$SB/logs" -name '*.log' 2>/dev/null)" ] || fail "no launcher log written in the sandbox"

# ... and it reached the push path, into the sandbox's LOCAL bare remote rather than a real origin.
git -C "$SB/remote.git" for-each-ref --format='%(refname:short)' refs/heads | grep -q '^nightshift/' \
  || fail "no nightshift/* branch in the sandbox remote — the push path was not exercised"

# The whole point: nothing under NIGHTSHIFT_HOME moved.
[ "$(sig)" = "$before" ] || {
  diff <(printf '%s\n' "$before") <(sig) >&2 || true
  fail "dry-run wrote into the live state/runs/digests under $ROOT"
}
[ -z "$(find "$TMP" -maxdepth 1 -name 'nightshift-worktrees' 2>/dev/null)" ] \
  || fail "dry-run used the default worktree dir instead of the sandbox's"

echo "test-schedule-dry-run: ok"
