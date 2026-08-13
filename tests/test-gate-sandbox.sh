#!/usr/bin/env bash
set -euo pipefail

# ADR 0026 — the ship gate EXECUTES candidate-controlled repository content. `npm ci` alone runs
# preinstall/prepare/pretest out of a package.json the Fix stage may just have written, and until
# this landed the gate ran that as the operator's own account: SSH keys, the gh token, ~/.claude,
# /etc secrets, the docker socket, sudo. A malicious `pretest` could read a secret, ship it, exit 0,
# and the night would report a PASSING gate.
#
# The test that matters is §2: a gate command that tries to read a planted secret must come back
# empty-handed. Everything else here defends a specific hole in the sandbox that would make §2 pass
# for the wrong reason (an inherited env var, an unbound $HOME, an accidental network).
#
# run_test_gate is exercised directly rather than through a whole night: the sandbox is the unit,
# and a full night per case would run the mock agent four times for nothing.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-gate-sandbox: $*" >&2; exit 1; }
skip() { echo "test-gate-sandbox: SKIP — $*"; exit 0; }

# This file asserts what the sandbox does, so it must not inherit an ambient opt-out. A CI host that
# cannot run bwrap sets NIGHTSHIFT_TEST_SANDBOX=none for the rest of the suite; here that would turn
# every assertion below into a test of the unsandboxed path passing itself. Skip instead — §5 sets
# the variable deliberately, per case.
unset NIGHTSHIFT_TEST_SANDBOX NIGHTSHIFT_TEST_SANDBOX_ROBIND NIGHTSHIFT_TEST_SANDBOX_HOME \
      NIGHTSHIFT_TEST_ENV_PASS NIGHTSHIFT_TEST_PATH

command -v bwrap >/dev/null 2>&1 || skip "bwrap is not installed (the gate would refuse to ship here)"
# An unprivileged user namespace is a kernel-policy question, not a package question: some hosts
# (hardened kernels, AppArmor-restricted Ubuntu, nested containers) refuse it. Without one there is
# nothing to assert about the sandbox — but §5 below still pins the FAIL-CLOSED behavior, which is
# the part that protects such a host.
# (the symlinks are not optional even for `true`: without /lib64 there is no dynamic loader)
bwrap --unshare-all --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
      --symlink usr/lib64 /lib64 --proc /proc --dev /dev \
      /bin/true >/dev/null 2>&1 || skip "unprivileged user namespaces are unavailable on this host"

# --- the harness -------------------------------------------------------------
# Sources the Runner for its functions (NIGHTSHIFT_SOURCED defines them without running a night),
# fakes the one rulebook row run_test_gate reads, and runs the gate. The command always exits 1 so
# tests.log survives — the gate deletes it on success on purpose (ADR 0022).
mkdir -p "$TMP/wt" "$TMP/item" "$TMP/worktrees"
echo "worktree content" > "$TMP/wt/tracked.txt"

cat > "$TMP/probe.sh" <<'PROBE'
set +u
NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
set +e
TEST_TIMEOUT="${GATE_TIMEOUT:-60}"; TEST_MEMORY_MB=4096; TEST_MAX_PROCS=2048
REPO_PATHS=(/fake); REPO_MODES=(branch-fix)
REPO_TEST_NETS=("${GATE_NET:-false}"); REPO_TEST_CMDS=("$GATE_CMD; exit 1")
run_test_gate /fake "$WT" "$ID"; echo "GATE_RC=$?"
cat "$ID/tests.log" 2>/dev/null
PROBE

gate() { # $1 = command run inside the sandbox; extra VAR=VALUE args are exported for the probe
  local cmd="$1"; shift
  rm -f "$TMP/item/tests.log"
  env "$@" ROOT="$ROOT" WT="$TMP/wt" ID="$TMP/item" GATE_CMD="$cmd" \
      NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
      bash "$TMP/probe.sh" 2>&1
}

# --- 1. the sandbox is actually entered --------------------------------------
out="$(gate 'echo "marker=$NIGHTSHIFT_TEST_SANDBOX_ACTIVE"')"
grep -q 'marker=1' <<<"$out" || { echo "$out" >&2; fail "the gate did not run inside a sandbox at all"; }

# --- 2. THE ONE THAT MATTERS: a malicious command cannot read a planted secret ---
# Stands in for `pretest` in a package.json the Fix stage wrote. Two shapes: the operator's real
# credential locations (~/.ssh, ~/.config/gh, ~/.claude), and a secret at a path the test controls
# so the assertion does not depend on this host happening to have any of them.
SECRET_DIR="$TMP/secrets"; mkdir -p "$SECRET_DIR"
printf 'nightshift-canary-8f3a1c\n' > "$SECRET_DIR/api-key"
out="$(gate "cat '$SECRET_DIR/api-key' 2>&1; cat ~/.ssh/id_ed25519 ~/.ssh/id_rsa 2>&1; ls ~/.config/gh ~/.claude ~/.codex /etc/ai_stack 2>&1")"
if grep -q 'nightshift-canary-8f3a1c' <<<"$out"; then
  echo "$out" >&2; fail "the gate READ A PLANTED SECRET — the sandbox does not contain it (ADR 0026 R15)"
fi
if grep -qi 'BEGIN OPENSSH PRIVATE KEY\|BEGIN RSA PRIVATE KEY' <<<"$out"; then
  fail "the gate read a real private key out of \$HOME"
fi
# The docker socket is host root for this account (risk-analysis R2), so assert the path does not
# RESOLVE — "present but unreadable" would be one `chmod` away from reopening the whole blast radius.
out="$(gate 'for s in /var/run/docker.sock /run/docker.sock; do [ -e "$s" ] && echo "SOCKET-PRESENT $s"; done; echo checked')"
if grep -q 'SOCKET-PRESENT' <<<"$out"; then
  echo "$out" >&2; fail "the docker socket exists inside the gate sandbox (host-root equivalent)"
fi

# --- 3. the environment is an allowlist, not a filtered inheritance ----------
# A denylist would need a new entry every time a tool invents a variable; --clearenv + setenv means
# a NEW credential variable is excluded by default rather than after someone remembers it.
out="$(gate 'env' \
  SSH_AUTH_SOCK=/leak/agent.sock GH_TOKEN=ghp_leaked GITHUB_TOKEN=ghp_leaked2 \
  ANTHROPIC_API_KEY=sk-ant-leaked AWS_SECRET_ACCESS_KEY=aws-leaked DOCKER_HOST=tcp://leak:2375 \
  SOME_FUTURE_CREDENTIAL=leaked-by-default)"
for v in leak/agent.sock ghp_leaked ghp_leaked2 sk-ant-leaked aws-leaked tcp://leak:2375 leaked-by-default; do
  if grep -qF "$v" <<<"$out"; then
    echo "$out" >&2; fail "\`$v\` reached the gate environment — the allowlist leaks"
  fi
done
# …and the escape hatch works, by NAME, for the suite that genuinely needs one.
out="$(gate 'echo "passed=$UV_CACHE_DIR"' UV_CACHE_DIR=/tmp/uv-cache NIGHTSHIFT_TEST_ENV_PASS=UV_CACHE_DIR)"
grep -q 'passed=/tmp/uv-cache' <<<"$out" \
  || { echo "$out" >&2; fail "NIGHTSHIFT_TEST_ENV_PASS did not forward the named variable"; }

# --- 4. network: denied by default, granted only by the repo's own opt-in ----
# `getent ahosts` needs no server to be reachable — with --unshare-net the resolver itself fails.
out="$(gate 'getent ahosts example.invalid >/dev/null 2>&1; getent ahosts localhost >/dev/null 2>&1 && echo NET-UP || echo NET-DOWN')"
grep -q 'NET-DOWN' <<<"$out" || { echo "$out" >&2; fail "the gate has network egress without test_net: true"; }
out="$(gate 'getent ahosts localhost >/dev/null 2>&1 && echo NET-UP || echo NET-DOWN' GATE_NET=true)"
grep -q 'NET-UP' <<<"$out" || { echo "$out" >&2; fail "test_net: true did not restore the loopback/resolver path"; }

# --- 5. no sandbox is a REFUSAL to ship, never a licence to ship unconfined --
# rc=2 ("the gate could not run"), distinct from rc=1 (a red suite) so the caller does not hand a
# host problem back to the Fix stage as a regression to repair.
# A mirror of the system bin dirs with exactly one binary missing. Cheaper alternatives (a PATH with
# a hand-picked tool list) keep failing for the wrong reason the moment the Runner reaches for one
# more coreutil — and "the gate refused because `mkdir` was gone" proves nothing about bwrap.
mkdir -p "$TMP/nobwrap"
for d in /usr/local/bin /usr/bin /bin; do
  [ -d "$d" ] || continue
  for p in "$d"/*; do
    n="${p##*/}"
    [ "$n" = bwrap ] && continue
    [ -e "$TMP/nobwrap/$n" ] || ln -s "$p" "$TMP/nobwrap/$n" 2>/dev/null || true
  done
done
[ -e "$TMP/nobwrap/bwrap" ] && fail "the no-bwrap PATH still contains bwrap"
out="$(gate 'true' PATH="$TMP/nobwrap")"
grep -q 'GATE_RC=2' <<<"$out" \
  || { echo "$out" >&2; fail "a missing bwrap must return 2 (cannot run), not fall back to an unsandboxed gate"; }
grep -q 'bwrap is not installed' <<<"$out" \
  || { echo "$out" >&2; fail "the refusal does not say why the gate could not run"; }
# The explicit, host-owned opt-out still works — and says so every time.
out="$(gate 'echo unconfined-ran' NIGHTSHIFT_TEST_SANDBOX=none)"
grep -q 'unconfined-ran' <<<"$out" || { echo "$out" >&2; fail "NIGHTSHIFT_TEST_SANDBOX=none did not run the suite"; }
grep -q 'sandbox DISABLED' <<<"$out" || { echo "$out" >&2; fail "the disabled sandbox was not announced"; }

# --- 6. a read-only bind may never hand $HOME back ---------------------------
# The escape hatch for a dependency outside /usr is also the obvious way to undo the whole ADR:
# `NIGHTSHIFT_TEST_SANDBOX_ROBIND=$HOME` would restore ~/.ssh while the run still logs a sandbox.
out="$(gate 'ls ~/.ssh /home 2>&1; echo done' NIGHTSHIFT_TEST_SANDBOX_ROBIND="${HOME:-/home}")"
grep -q 'REFUSING read-only bind' <<<"$out" \
  || { echo "$out" >&2; fail "a read-only bind of \$HOME was accepted — the sandbox can be silently widened"; }
# …while a legitimate bind outside /usr still arrives.
mkdir -p "$TMP/dep"; echo "dependency" > "$TMP/dep/marker"
out="$(gate "cat '$TMP/dep/marker'" NIGHTSHIFT_TEST_SANDBOX_ROBIND="$TMP/dep")"
grep -q 'dependency' <<<"$out" || { echo "$out" >&2; fail "NIGHTSHIFT_TEST_SANDBOX_ROBIND did not bind a legitimate path"; }

# --- 7. writable: the worktree, and nothing outside it -----------------------
out="$(gate "echo fix > gate-wrote.txt; echo escape > /usr/gate-escaped 2>&1; echo escape > /etc/gate-escaped 2>&1; echo escape > '$TMP/gate-escaped' 2>&1")"
[ -f "$TMP/wt/gate-wrote.txt" ] || { echo "$out" >&2; fail "the gate could not write the worktree it is meant to test"; }
for p in /usr/gate-escaped /etc/gate-escaped "$TMP/gate-escaped"; do
  [ -e "$p" ] && fail "the gate wrote OUTSIDE the worktree: $p"
done
# The sandbox HOME is disposable: nothing a suite leaves behind survives into the next gate, so a
# poisoned dependency cache cannot be the vector for tomorrow night.
out="$(gate 'echo poison > "$HOME/cache-poison"; echo "sbhome=$HOME"')"
sbhome="$(sed -n 's/^sbhome=//p' <<<"$out" | head -1)"
[ -n "$sbhome" ] || { echo "$out" >&2; fail "could not determine the gate's sandbox HOME"; }
[ -e "$sbhome" ] && fail "the gate's HOME ($sbhome) survived the gate — a cross-run write channel"

# --- 8. resource ceilings are applied inside, not just the wall clock --------
out="$(gate 'echo "nproc=$(ulimit -u) as=$(ulimit -v) cpu=$(ulimit -t)"')"
grep -q 'nproc=2048' <<<"$out" || { echo "$out" >&2; fail "RLIMIT_NPROC (limits.test_max_procs) was not applied"; }
grep -q 'as=4194304' <<<"$out" || { echo "$out" >&2; fail "RLIMIT_AS (limits.test_memory_mb) was not applied"; }
grep -q 'cpu=60'     <<<"$out" || { echo "$out" >&2; fail "RLIMIT_CPU was not derived from the gate timeout"; }
# The wall clock still bounds a suite that hangs — and the sandbox dies with the timeout, so a
# --die-with-parent regression would leave the sleep running and this case would hang, not fail.
out="$(gate 'sleep 30' GATE_TIMEOUT=1)"
grep -q 'GATE_RC=1' <<<"$out" || { echo "$out" >&2; fail "a hanging sandboxed suite was not bounded by the timeout"; }

echo "test-gate-sandbox: ok"
