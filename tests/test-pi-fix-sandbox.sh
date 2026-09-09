#!/usr/bin/env bash
set -euo pipefail

# The pi adapter's Fix stage may write, and pi has no hook and no sandbox of its own to bound where
# (hook-spec.md Layer 2b). Until 2026-09-06 `agent.pi_allow_fix: true` therefore bought a writer
# whose only bound was the model choosing relative paths — and that failed the first time it was
# looked at: the partflow fix of that night left a note at /tmp/nightshift-install-marker.txt,
# outside its worktree, where no branch review could ever see it.
#
# pi_sandbox_argv wraps the agent process in the same bwrap hull the ship gate uses (ADR 0026). What
# this file pins is the part that has to hold: the writable set is the worktree and the stage's own
# agent dir, nothing else, and the wrapper refuses to run at all rather than fall back to an
# unconfined writer.
#
# No model is called here. The confinement is a property of the argv, so the assertions run a plain
# shell inside it — a real pi turn would test the provider, not the sandbox.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
# The "outside" directory must NOT live under /tmp: the sandbox mounts its own tmpfs there, so a
# write to /tmp/... fails to reach the host for a reason that has nothing to do with the confinement
# — the assertion would pass even with the bind rules removed. The ship gate has no /var/tmp;
# there, use its writable checkout, outside the nested pi worktree and agent home.
OUTSIDE_PARENT=/var/tmp
if [ ! -w "$OUTSIDE_PARENT" ]; then OUTSIDE_PARENT="$ROOT"; fi
case "$OUTSIDE_PARENT" in
  /tmp|/tmp/*)
    rm -rf "$TMP"
    echo 'test-pi-fix-sandbox: SKIP — no writable fixture path outside /tmp'
    exit 0 ;;
esac
OUTSIDE="$(mktemp -d "$OUTSIDE_PARENT/.nightshift-pi-sandbox.XXXXXX")"
trap 'rm -rf "$TMP" "$OUTSIDE"' EXIT

fail() { echo "test-pi-fix-sandbox: $*" >&2; exit 1; }
skip() { echo "test-pi-fix-sandbox: SKIP — $*"; exit 0; }

# This file asserts what the sandbox does, so an ambient opt-out would turn every case below into a
# test of the unsandboxed path passing itself. §4 sets it deliberately, per case.
unset NIGHTSHIFT_PI_SANDBOX NIGHTSHIFT_TEST_SANDBOX_ROBIND NIGHTSHIFT_TEST_PATH \
      NIGHTSHIFT_PI_PATH NIGHTSHIFT_PI_EXTENSIONS

command -v bwrap >/dev/null 2>&1 || skip "bwrap is not installed (the fix stage would refuse to run here)"
bwrap --unshare-all --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
      --symlink usr/lib64 /lib64 --proc /proc --dev /dev \
      /bin/true >/dev/null 2>&1 || skip "unprivileged user namespaces are unavailable on this host"

mkdir -p "$TMP/item" "$TMP/wt" "$TMP/pi-home"
echo "untouched" > "$OUTSIDE/secret.txt"

# The Runner is sourced for its functions; NIGHTSHIFT_SOURCED defines them without running a night.
run_in_sandbox() { # command -> its output, run inside the pi fix hull
  ROOT="$ROOT" TMP="$TMP" CMD="$1" bash -c '
    set +u
    NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
    set +e
    pi_sandbox_argv "$TMP/wt" "$TMP/pi-home" "$TMP/item" || { echo "ARGV_REFUSED"; exit 0; }
    [ "${#TEST_SANDBOX_ARGV[@]}" -gt 0 ] || { echo "ARGV_EMPTY"; exit 0; }
    "${TEST_SANDBOX_ARGV[@]}" /bin/sh -c "$CMD" 2>&1
  '
}

# --- 1. the worktree is writable — a fix that cannot edit its own tree is no fix ---
out="$(run_in_sandbox 'echo fixed > ./file.txt && cat ./file.txt')"
[ "$out" = fixed ] || fail "the worktree is not writable inside the sandbox: $out"
[ -f "$TMP/wt/file.txt" ] || fail "a write to the worktree did not reach the real worktree"

# --- 2. the stage's own agent dir is writable — pi keeps state there ---
out="$(run_in_sandbox "echo ok > '$TMP/pi-home/state.txt' && cat '$TMP/pi-home/state.txt'")"
[ "$out" = ok ] || fail "the pi stage home is not writable inside the sandbox: $out"

# --- 3. THE ONE THAT MATTERS: an absolute path outside both is not writable ---
# The realistic failure is not malice but a confused absolute path — a worktree named `partflow`
# and a live repo at ~/partflow are one keystroke apart, and such a write appears in no diff.
run_in_sandbox "echo ESCAPED > '$OUTSIDE/escape.txt'" >/dev/null 2>&1 || true
[ -e "$OUTSIDE/escape.txt" ] && fail "a write outside the worktree reached the host filesystem"
[ "$(cat "$OUTSIDE/secret.txt")" = untouched ] \
  || fail "an existing file outside the worktree was modified from inside the sandbox"
# …and the same path is not even readable, so a fix cannot exfiltrate what it cannot write.
out="$(run_in_sandbox "cat '$OUTSIDE/secret.txt'" || true)"
case "$out" in *untouched*) fail "a file outside the worktree was readable inside the sandbox" ;; esac

# --- 4. the documented opt-out restores the old behaviour, out loud ---
out="$(NIGHTSHIFT_PI_SANDBOX=none run_in_sandbox 'true')"
[ "$out" = ARGV_EMPTY ] || fail "NIGHTSHIFT_PI_SANDBOX=none did not disable the wrapper: $out"

# --- 5. no bwrap means no fix stage, not an unconfined one ---
# PATH is emptied so `command -v bwrap` misses; the wrapper must refuse rather than return an argv
# that would run the agent unwrapped.
out="$(ROOT="$ROOT" TMP="$TMP" bash -c '
  set +u
  NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
  set +e
  PATH=/nonexistent pi_sandbox_argv "$TMP/wt" "$TMP/pi-home" "$TMP/item" >/dev/null 2>&1 \
    && echo ACCEPTED || echo REFUSED
')"
[ "$out" = REFUSED ] || fail "the fix stage did not fail closed without bwrap: $out"

echo "test-pi-fix-sandbox: ok"
