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
mkdir -p "$TMP/item" "$TMP/worktrees"
# A REAL repo + linked worktree, because that is what the gate always gets in production — and the
# .git pointer guard (§11) validates the worktree against its repo, so a bare directory here would
# be testing a shape the Runner never produces.
HREPO="$TMP/harness-repo"
git init -q -b main "$HREPO"
echo "worktree content" > "$HREPO/tracked.txt"
git -C "$HREPO" -c user.name=t -c user.email=t@localhost add -A
git -C "$HREPO" -c user.name=t -c user.email=t@localhost commit -q -m init
git -C "$HREPO" worktree add -q --detach "$TMP/wt"

cat > "$TMP/probe.sh" <<'PROBE'
set +u
NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
set +e
TEST_TIMEOUT="${GATE_TIMEOUT:-60}"; TEST_MEMORY_MB=4096; TEST_MAX_PROCS=2048
REPO_PATHS=("$REPO"); REPO_MODES=(branch-fix)
REPO_TEST_NETS=("${GATE_NET:-false}"); REPO_TEST_CMDS=("$GATE_CMD; exit 1")
run_test_gate "$REPO" "$WT" "$ID"; echo "GATE_RC=$?"
cat "$ID/tests.log" 2>/dev/null
PROBE

gate() { # $1 = command run inside the sandbox; extra VAR=VALUE args are exported for the probe
  local cmd="$1"; shift
  rm -f "$TMP/item/tests.log"
  # WT leads so a case can point the gate at a different worktree via the extra args (§9 does).
  env WT="$TMP/wt" REPO="$HREPO" "$@" ROOT="$ROOT" ID="$TMP/item" GATE_CMD="$cmd" \
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
# The positive half can only assert that test_net RESTORES what the surrounding environment has.
# nightshift gates ITSELF (ADR 0026), so this suite routinely runs inside a netless gate sandbox
# where /etc/hosts is unbound and no resolver works at any nesting depth — asserting NET-UP there
# fails for the environment, not for the code, and would turn nightshift's own nightly gate red.
if getent ahosts localhost >/dev/null 2>&1; then
  out="$(gate 'getent ahosts localhost >/dev/null 2>&1 && echo NET-UP || echo NET-DOWN' GATE_NET=true)"
  grep -q 'NET-UP' <<<"$out" || { echo "$out" >&2; fail "test_net: true did not restore the loopback/resolver path"; }
else
  echo "test-gate-sandbox: note — test_net positive case skipped (this environment has no resolver)"
fi

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
out="$(gate 'echo "nproc=$(ulimit -u) data=$(ulimit -d) cpu=$(ulimit -t)"')"
grep -q 'nproc=2048' <<<"$out" || { echo "$out" >&2; fail "RLIMIT_NPROC (limits.test_max_procs) was not applied"; }
grep -q 'data=4194304' <<<"$out" || { echo "$out" >&2; fail "RLIMIT_DATA (limits.test_memory_mb) was not applied"; }
grep -q 'cpu=60'     <<<"$out" || { echo "$out" >&2; fail "RLIMIT_CPU was not derived from the gate timeout"; }
# The wall clock still bounds a suite that hangs — and the sandbox dies with the timeout, so a
# --die-with-parent regression would leave the sleep running and this case would hang, not fail.
out="$(gate 'sleep 30' GATE_TIMEOUT=1)"
grep -q 'GATE_RC=1' <<<"$out" || { echo "$out" >&2; fail "a hanging sandboxed suite was not bounded by the timeout"; }

# --- 9. git still works in the worktree, and the real repo stays read-only ---
# The gate ALWAYS runs in a linked worktree (`git worktree --detach`), whose `.git` is a FILE
# containing `gitdir: <repo>/.git/worktrees/<name>`. Bind only the worktree and every git command
# resolves out of the sandbox into a repo that is not there: `git ls-files` exits 128 and any suite
# that consults git fails for a reason unrelated to the change under test. Observed against
# nightshift's own gate, whose `lib/check_docs.py` does exactly that.
GREPO="$TMP/gitrepo"
git init -q -b main "$GREPO"
echo "content" > "$GREPO/tracked.md"
git -C "$GREPO" -c user.name=t -c user.email=t@localhost add -A
git -C "$GREPO" -c user.name=t -c user.email=t@localhost commit -q -m initial
git -C "$GREPO" worktree add -q --detach "$TMP/linked"

out="$(gate 'git ls-files 2>&1; git rev-parse --is-inside-work-tree 2>&1' WT="$TMP/linked" REPO="$GREPO")"
grep -q 'tracked.md' <<<"$out" \
  || { echo "$out" >&2; fail "git cannot read the linked worktree inside the sandbox — the repo's git dir is unbound"; }

# …and it is bound READ-ONLY. Writable, a `pretest` could plant a hook or rewrite refs in the REAL
# repository — an escape straight past the disposable worktree the whole design rests on.
out="$(gate 'echo "#!/bin/sh" > "$(git rev-parse --git-common-dir)/hooks/post-checkout" 2>&1; echo tried' WT="$TMP/linked" REPO="$GREPO")"
[ -e "$GREPO/.git/hooks/post-checkout" ] \
  && { echo "$out" >&2; fail "the gate planted a hook in the REAL repository — the git dir is writable"; }

# --- 10. the toolchain is bound AND on PATH, without over-mounting its parent ---
# NIGHTSHIFT_TEST_PATH is read as a colon-separated PATH fragment: the fleet needs node from nvm and
# `uv` from ~/.local/bin in the SAME gate, and a directory that is bound but not on PATH (or on PATH
# but not bound) leaves the tool exactly as unreachable as before.
mkdir -p "$TMP/tc-a" "$TMP/tc-b"
printf '#!/bin/sh\necho tool-a-ran\n' > "$TMP/tc-a/tool-a"; chmod +x "$TMP/tc-a/tool-a"
printf '#!/bin/sh\necho tool-b-ran\n' > "$TMP/tc-b/tool-b"; chmod +x "$TMP/tc-b/tool-b"
out="$(gate 'tool-a; tool-b' NIGHTSHIFT_TEST_PATH="$TMP/tc-a:$TMP/tc-b")"
grep -q 'tool-a-ran' <<<"$out" || { echo "$out" >&2; fail "the first NIGHTSHIFT_TEST_PATH entry was not reachable"; }
grep -q 'tool-b-ran' <<<"$out" || { echo "$out" >&2; fail "a SECOND NIGHTSHIFT_TEST_PATH entry was not reachable (colon list not honoured)"; }

# A node install needs its prefix (node resolves lib/ via `..`) — but only a SELF-CONTAINED one.
# `lib/node_modules` alone is npm's global prefix, which on a real host sits at ~/.local: binding
# that parent would mount ~/.local/share into the sandbox. Pinned in both directions.
mkdir -p "$TMP/prefix/bin" "$TMP/prefix/lib/node_modules" "$TMP/prefix/secret"
printf 'prefix-secret\n' > "$TMP/prefix/secret/creds"
printf '#!/bin/sh\necho fake-node\n' > "$TMP/prefix/bin/node"; chmod +x "$TMP/prefix/bin/node"
out="$(gate "cat '$TMP/prefix/secret/creds' 2>&1" NIGHTSHIFT_TEST_PATH="$TMP/prefix/bin")"
grep -q 'prefix-secret' <<<"$out" \
  || { echo "$out" >&2; fail "a self-contained node prefix was not bound — node cannot resolve its own lib/"; }

mkdir -p "$TMP/npmglobal/bin" "$TMP/npmglobal/lib/node_modules" "$TMP/npmglobal/share"
printf 'must-not-leak\n' > "$TMP/npmglobal/share/private"
printf '#!/bin/sh\necho uvish\n' > "$TMP/npmglobal/bin/uvish"; chmod +x "$TMP/npmglobal/bin/uvish"
out="$(gate "uvish; cat '$TMP/npmglobal/share/private' 2>&1" NIGHTSHIFT_TEST_PATH="$TMP/npmglobal/bin")"
grep -q 'uvish' <<<"$out" || { echo "$out" >&2; fail "the toolchain dir itself was not bound"; }
grep -q 'must-not-leak' <<<"$out" \
  && { echo "$out" >&2; fail "a bin dir whose parent merely HAS lib/node_modules mounted that parent — ~/.local would be exposed"; }

# --- 11. a suite cannot booby-trap `.git` for the Runner to detonate -----------
# The sharpest hole this design had, and it made the sandbox look closed while it was not: the
# sandbox contains the suite WHILE IT RUNS, but `$wt/.git` is a plain pointer file in the writable
# worktree, and every git command finalize runs NEXT — `checkout -b`, `add -A`, `commit` — happens
# OUTSIDE the sandbox as the operator and reads whatever gitdir that file names. Pointed at a gitdir
# the suite built inside the worktree, `core.fsmonitor` is arbitrary command execution and
# `hooks/pre-commit` is another. Both were verified firing before this was closed.
# Two independent layers, so §11 tests both: the pointer is re-bound read-only INSIDE the sandbox
# (prevention), and it is validated against the repo afterwards (detection — which is what covers
# NIGHTSHIFT_TEST_SANDBOX=none, and a hostile pointer the FIX stage wrote, since the R8 guard
# confines that stage to the worktree and this file is in the worktree).
TREPO="$TMP/trap-repo"
git init -q -b main "$TREPO"
echo hi > "$TREPO/f.txt"
git -C "$TREPO" -c user.name=t -c user.email=t@localhost add -A
git -C "$TREPO" -c user.name=t -c user.email=t@localhost commit -q -m init

trap_attack() { # worktree canary -> the gate command that rewires .git at a gitdir it controls
  printf '%s' 'git init -q .evil 2>/dev/null; mkdir -p .evil/.git/hooks;
printf "#!/bin/sh\ntouch '"$2"'\n" > .evil/.git/hooks/pre-commit; chmod +x .evil/.git/hooks/pre-commit;
printf "gitdir: %s/.evil/.git\n" "$PWD" > .git 2>/dev/null'
}

# (a) sandboxed: the write itself must not land.
git -C "$TREPO" worktree add -q --detach "$TMP/trap-a"
out="$(gate "$(trap_attack "$TMP/trap-a" "$TMP/canary-a")" WT="$TMP/trap-a" REPO="$TREPO")"
grep -qF 'gitdir: '"$TREPO"'/.git/worktrees/trap-a' "$TMP/trap-a/.git" \
  || { echo "$out" >&2; cat "$TMP/trap-a/.git" >&2; fail "the gate REWROTE .git inside the sandbox — the read-only re-bind is not in effect (is it ordered after the worktree bind?)"; }

# (b) unsandboxed opt-out: the write lands, so detection must refuse the item.
git -C "$TREPO" worktree add -q --detach "$TMP/trap-b"
out="$(gate "$(trap_attack "$TMP/trap-b" "$TMP/canary-b")" WT="$TMP/trap-b" REPO="$TREPO" NIGHTSHIFT_TEST_SANDBOX=none)"
grep -q 'GATE_RC=2' <<<"$out" \
  || { echo "$out" >&2; fail "a rewritten .git pointer did not refuse the item (rc=2) — finalize would detonate it"; }

# And rc=2 is the status that keeps finalize away: it is NOT rc=1, which loops back into Fix and
# would simply run the hostile command again.
grep -q 'GATE_RC=1' <<<"$out" && fail "the tamper was classified as a red suite — Fix would re-run it"

echo "test-gate-sandbox: ok"
