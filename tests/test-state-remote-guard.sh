#!/usr/bin/env bash
set -euo pipefail

# ADR 0017 unit test: guard_state_remote_incoherence ABORTS (exit 1) only when the ledger is
# non-canonical ($STATE_DIR != $NIGHTSHIFT_HOME/state) AND origin is a network remote — with an
# NIGHTSHIFT_ALLOW_SPLIT_STATE=1 override that downgrades to a warning. A local sandbox remote or the
# canonical ledger must pass silently. Also covers is_network_remote (git's colon-before-first-slash
# rule, incl. ssh-config aliases and no-user host:path). Sources the runner (NIGHTSHIFT_SOURCED=1).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
       NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- is_network_remote: git's classification ---------------------------------------------------
for u in "git@github.com:me/repo.git" "https://github.com/me/repo.git" \
         "ssh://git@host/repo.git" "git://host/repo.git" \
         "git@github.com-sebastianlang84:sebastianlang84/nightshift.git" \
         "github.com:me/repo.git" "myalias:repo.git"; do
  is_network_remote "$u" || fail "expected network: $u"
done
for u in "/srv/sandbox/remote.git" "./remote.git" "file:///srv/x.git" "$TMP/remote.git" \
         "/srv/x@y:z"; do
  is_network_remote "$u" && fail "expected local: $u"
done

# --- guard: build a repo with a controllable origin -------------------------------------------
REPO="$TMP/target"; git init -q "$REPO"
set_origin() { git -C "$REPO" remote remove origin 2>/dev/null || true; git -C "$REPO" remote add origin "$1"; }
REPO_PATHS=("$REPO")            # the guard iterates this global (populated by load_rulebook in prod)
NIGHTSHIFT_HOME="$TMP/home"; mkdir -p "$NIGHTSHIFT_HOME/state"

# runs the guard in a subshell so its `exit 1` doesn't kill the test; echoes "rc=<n>" + any output
run_guard() { local out rc; out="$( ( guard_state_remote_incoherence ) 2>&1 )"; rc=$?; printf '%s\nrc=%s' "$out" "$rc"; }

# Case 1: non-canonical ledger + NETWORK origin, no override -> must ABORT (rc=1) and name the repo.
STATE_DIR="$TMP/state"                       # != $NIGHTSHIFT_HOME/state
set_origin "git@github.com:me/repo.git"
res="$(run_guard)"
grep -q "rc=1" <<<"$res" || fail "case1: expected abort (rc=1) for non-canonical ledger + network remote (got: '$res')"
grep -q "ABORT" <<<"$res" || fail "case1: expected ABORT message"
grep -q "$(basename "$REPO")" <<<"$res" || fail "case1: abort should name the offending repo"

# Case 1b: same, WITH override -> must PASS (rc=0) and warn instead of abort.
res="$(NIGHTSHIFT_ALLOW_SPLIT_STATE=1 run_guard)"
grep -q "rc=0" <<<"$res" || fail "case1b: override must let the run proceed (got: '$res')"
grep -q "WARNING (NIGHTSHIFT_ALLOW_SPLIT_STATE=1)" <<<"$res" || fail "case1b: expected downgraded warning"

# Case 2: non-canonical ledger + LOCAL bare remote -> must PASS silently (legit sandbox e2e).
set_origin "$TMP/sandbox-remote.git"
res="$(run_guard)"
grep -q "rc=0" <<<"$res" || fail "case2: local sandbox remote must not abort (got: '$res')"
grep -qE "ABORT|WARNING" <<<"$res" && fail "case2: local remote must be silent (got: '$res')"

# Case 3: CANONICAL ledger + NETWORK origin -> must PASS silently (production layout).
STATE_DIR="$NIGHTSHIFT_HOME/state"
set_origin "git@github.com:me/repo.git"
res="$(run_guard)"
grep -q "rc=0" <<<"$res" || fail "case3: canonical ledger must not abort (got: '$res')"
grep -qE "ABORT|WARNING" <<<"$res" && fail "case3: canonical ledger must be silent (got: '$res')"

# Case 3b: non-canonical but INSIDE home ($home/sandbox/state) + network -> must ABORT (Fable defect 2).
STATE_DIR="$NIGHTSHIFT_HOME/sandbox/state"
res="$(run_guard)"
grep -q "rc=1" <<<"$res" || fail "case3b: non-canonical-but-inside-home ledger + network must abort (got: '$res')"

# Case 4: NIGHTSHIFT_STATE_DIR unset -> guard is a no-op regardless of remote.
saved="$NIGHTSHIFT_STATE_DIR"; unset NIGHTSHIFT_STATE_DIR
STATE_DIR="$TMP/state"; set_origin "git@github.com:me/repo.git"
res="$(run_guard)"
export NIGHTSHIFT_STATE_DIR="$saved"
grep -q "rc=0" <<<"$res" || fail "case4: unset NIGHTSHIFT_STATE_DIR must be a no-op (got: '$res')"

echo "test-state-remote-guard: ok"
