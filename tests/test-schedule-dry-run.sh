#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

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
TMP="$(mktemp -d "$ROOT/.test-schedule.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/systemctl"
chmod +x "$TMP/bin/systemctl"
system_path=/usr/local/bin:/usr/bin:/bin
fail() { echo "FAIL: $*" >&2; exit 1; }

# The launcher searches /usr/local/bin first. Give that exact path private command
# names so updates to the host's provider files or bin symlink cannot redirect them.
for provider in claude; do
  stub="$TMP/bin/$provider"
  cat > "$stub" <<'EOF'
#!/bin/sh
printf '%s\n' "${0##*/}" >> "$PROVIDER_ATTEMPTS"
exit 1
EOF
  chmod +x "$stub"
done
isolated=(bwrap --unshare-user --ro-bind / / --proc /proc --dev /dev --bind "$TMP" "$TMP" --tmpfs /usr)
for entry in /usr/*; do
  [ "$entry" = /usr/local ] || isolated+=(--ro-bind "$entry" "$entry")
done
isolated+=(--tmpfs /usr/local)
for entry in /usr/local/*; do
  if [ "$entry" != /usr/local/bin ] && [ -e "$entry" ]; then
    isolated+=(--ro-bind "$entry" "$entry")
  fi
done

shadow="$TMP/commands"
mkdir -p "$shadow"
if [ -d /usr/local/bin ]; then
  original="$(realpath -e -- /usr/local/bin)"
  alias=/usr/local/.nightshift-test-bin
  python3 - "$original" "$alias" "$shadow" <<'PY'
import os
import sys
from pathlib import Path

original, alias, shadow = map(Path, sys.argv[1:])
for entry in original.iterdir():
    if entry.name not in {"claude", "systemctl"}:
        # Resolve relative symlinks in the original directory before relocating commands.
        target = Path(os.path.realpath(entry))
        if target.is_relative_to(original):
            target = alias / target.relative_to(original)
        (shadow / entry.name).symlink_to(target)
PY
  isolated+=(--ro-bind "$original" "$alias")
fi
cp -- "$TMP/bin/"{claude,systemctl} "$shadow/"
isolated+=(--ro-bind "$shadow" /usr/local/bin --)

# The dry-run mktemps its sandbox under TMPDIR; pointing that at the test dir keeps the whole thing
# inside the trap, and puts the DEFAULT lock path ($TMPDIR/nightshift.lock) somewhere we can hold.
export TMPDIR="$TMP"

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

run_dry_run() {
  local mode="$1" out="$TMP/$1.out" attempts="$TMP/$1.provider-attempts" rc=0
  shift
  # Start without inherited PATH, functions, credentials or routes. Configure each route explicitly.
  "${isolated[@]}" env -i HOME="$TMP/home" PATH="$TMP/bin:$system_path" TMPDIR="$TMP" \
    PROVIDER_ATTEMPTS="$attempts" NIGHTSHIFT_AGENT=claude \
    "$@" bash "$ROOT/bin/schedule.sh" dry-run >"$out" 2>&1 || rc=$?

  [ ! -e "$attempts" ] || { cat "$attempts" >&2; fail "$mode: dry-run attempted a production provider route"; }
  # Check route selection even if a CLI lookup fails or there are no branches to advise on.
  if grep -E '^\[nightshift\] (agent=claude |claude (review )?model: |branch advisors: )' "$out" >&2; then
    fail "$mode: dry-run selected a production provider route"
  fi
  [ "$rc" -eq 0 ] || { tail -40 "$out" >&2; fail "$mode: dry-run exited $rc"; }
  if grep -q "another run holds" "$out"; then
    fail "$mode: dry-run shares the nightly flock"
  fi

  local sb
  sb="$(sed -n 's/^dry-run sandbox: \(.*\) (throwaway .*$/\1/p' "$out" | head -1)"
  [ -n "$sb" ] && [ -d "$sb" ] || { tail -40 "$out" >&2; fail "$mode: no sandbox directory reported"; }

  [ -s "$sb/state/ledger.jsonl" ] || fail "$mode: no sandbox ledger"
  [ -n "$(find "$sb/digests" -name '*.md' 2>/dev/null)" ] || fail "$mode: no sandbox digest"
  [ -n "$(find "$sb/logs" -name '*.log' 2>/dev/null)" ] || fail "$mode: no sandbox launcher log"

  jq -es 'any(.[]; .stage == "review" and .exit == 0) and
          all(.[]; .model == "mock" and .stage != "advise")' "$sb/state/runs.jsonl" >/dev/null \
    || fail "$mode: expected a successful mock review and no production adapters or branch advice"

  # The mock ran the push path against the sandbox's local bare remote.
  git -C "$sb/remote.git" for-each-ref --format='%(refname:short)' refs/heads | grep -q '^nightshift/' \
    || fail "$mode: no nightshift/* branch in the sandbox remote"
}

# The production quota check and notify command must not run either: a smoke test never pauses a
# night or messages the operator.
run_dry_run modern NIGHTSHIFT_ADVISORS=claude NIGHTSHIFT_REVIEW_MODEL=review-model \
  NIGHTSHIFT_QUOTA_CMD='printf "quota check\n" >> "$PROVIDER_ATTEMPTS"; exit 1' \
  NIGHTSHIFT_NOTIFY_CMD='printf "notify\n" >> "$PROVIDER_ATTEMPTS"'

cat > "$TMP/nightly-env" <<'EOF'
export NIGHTSHIFT_AGENT=claude NIGHTSHIFT_ADVISORS=claude
EOF
run_dry_run legacy BASH_ENV="$TMP/nightly-env" \
  NIGHTSHIFT_BRANCH_REVIEW=1

# The whole point: nothing under NIGHTSHIFT_HOME moved.
[ "$(sig)" = "$before" ] || {
  diff <(printf '%s\n' "$before") <(sig) >&2 || true
  fail "dry-run wrote into the live state/runs/digests under $ROOT"
}
[ -z "$(find "$TMP" -maxdepth 1 -name 'nightshift-worktrees' 2>/dev/null)" ] \
  || fail "dry-run used the default worktree dir instead of the sandbox's"

echo "test-schedule-dry-run: ok"
