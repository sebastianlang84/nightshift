#!/usr/bin/env bash
# Sourced by bin/nightshift.sh after its path globals are initialized.
# --------------------------------------------------------------- ship gate ----
# The Review stage proves the FINDING is fixed; it does not prove nothing ELSE broke. Regressions
# therefore shipped unnoticed unless the host repo happened to have CI — and only one of four did.
# (Observed 2026-08-04: repo-a PR #10 dropped a dependency that looked unreferenced in src/
# but was imported by tests across a service boundary; three tests broke, the PR shipped.)
#
# So the repo's own suite runs against the worktree, INSIDE the fix<->review loop rather than after
# it: a failure is a revision request, not a death sentence. The Fix stage caused the breakage and
# is still in the loop with budget left, so it gets the failing output back and repairs its own
# damage (see stage_prompt). Only an item that leaves the loop still broken is refused.
# The gate EXECUTES candidate-controlled repository content — `npm ci` alone runs preinstall /
# prepare / pretest straight out of a package.json the Fix stage may just have written. Unsandboxed,
# that is the most direct route there is from a prompt-injected fix to full host execution as this
# account: SSH keys, the gh token, ~/.claude credentials, /etc secrets, the docker
# socket (host-root equivalent), sudo. So it does not run as this account. See ADR 0026.
#
# bubblewrap: no daemon, no setuid, no privileged helper, one process per gate, and the filesystem
# is an ALLOWLIST — nothing is visible unless it was bound in. Nothing else on this host removes
# credential reach as cheaply; docker would grant the very socket that is the risk.
TEST_SANDBOX="${NIGHTSHIFT_TEST_SANDBOX:-bwrap}"
declare -a TEST_SANDBOX_ARGV=()

_test_robind() { # path [declared] -> append a read-only bind, refusing anything that would re-expose $HOME
  local p="$1" declared="${2:-}" rp
  [ -n "$p" ] || return 0
  rp="$(realpath -m -- "$p" 2>/dev/null || printf '%s' "$p")"
  # A path someone DECLARED (NIGHTSHIFT_TEST_SANDBOX_ROBIND, rulebook test_robind) that is not there
  # is a typo or a moved checkout, under /usr as much as anywhere. Dropped quietly, it surfaces only
  # as a red suite — which loops back into Fix as a regression to repair, every night, for a host
  # fault no stage can see.
  if [ ! -e "$rp" ]; then
    [ -n "$declared" ] && log "  test sandbox: read-only bind $p does not exist — not bound"
    return 0
  fi
  case "$rp" in /usr|/usr/*) return 0 ;; esac   # already bound whole
  # `/`, `/home`, `$HOME` — a bind of any ancestor of $HOME hands the suite ~/.ssh and the gh token
  # back, i.e. exactly the reach this sandbox exists to remove. Refuse it out loud; a silently
  # widened sandbox is worse than none, because the ADR says it is closed.
  if [ "$rp" = / ] || { [ -n "${HOME:-}" ] && { [ "$rp" = "$HOME" ] || [ "${HOME#"$rp"/}" != "$HOME" ]; }; }; then
    log "  test sandbox: REFUSING read-only bind $p — it contains \$HOME"
    return 0
  fi
  TEST_SANDBOX_ARGV+=( --ro-bind "$rp" "$rp" )
}

build_test_sandbox() { # worktree sandbox_home net(0|1) item_dir [robind] -> fills TEST_SANDBOX_ARGV
  local wt="$1" sbhome="$2" net="$3" id="$4" robind="${5:-}" p
  local -a extra=()
  TEST_SANDBOX_ARGV=(
    bwrap
    --die-with-parent          # the sandbox can never outlive the `timeout` that bounds it
    --new-session              # its own session: no controlling tty, so no TIOCSTI back into ours
    --unshare-user --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup --unshare-net
    --clearenv                 # the environment is an allowlist, built at the bottom of this function
    --proc /proc --dev /dev
    # A tmpfs is RAM. `--size` applies to the NEXT --tmpfs ONLY, so each one needs its own.
    --size $((1024 * 1024 * 1024)) --tmpfs /tmp
    --size $((16 * 1024 * 1024))   --tmpfs /run
    --ro-bind /usr /usr
  )
  # ALWAYS its own network namespace, `test_net` or not. `--share-net` used to hand a test_net repo
  # the HOST's namespace, which is loopback and the LAN — every other service on this machine — and
  # not merely "the internet" (ADR 0028). Egress now leaves through a vetting proxy on a unix
  # socket, which crosses the namespace because it is a filesystem object, not a route.
  if [ "$net" = 1 ] && [ -n "${TEST_EGRESS_DIR:-}" ]; then
    TEST_SANDBOX_ARGV+=(
      --ro-bind "$TEST_EGRESS_DIR" /nightshift-egress
      --ro-bind "$NIGHTSHIFT_HOME/lib/gate_forwarder.py" /nightshift-egress-forwarder.py
      --setenv NIGHTSHIFT_GATE_PROXY_PORT "$TEST_EGRESS_PORT"
    )
  fi
  # merged-/usr: reproduce whatever /bin, /lib … are on this host, so an absolute `#!` still resolves.
  for p in /bin /sbin /lib /lib64 /lib32 /libx32; do
    if [ -L "$p" ]; then TEST_SANDBOX_ARGV+=( --symlink "$(readlink "$p")" "$p" )
    elif [ -d "$p" ]; then TEST_SANDBOX_ARGV+=( --ro-bind "$p" "$p" ); fi
  done
  # /etc is an ALLOWLIST and never a whole-directory bind: /etc/service-secrets and its neighbours are
  # precisely the secrets the gate must not reach. `-try` because the set spans distributions.
  # NOT /etc/ssl or /etc/pki wholesale: `/etc/ssl/private` is the conventional private-key location,
  # and a boundary that holds only because that directory happens to be mode 0700 is not a boundary.
  for p in /etc/passwd /etc/group /etc/nsswitch.conf /etc/localtime /etc/alternatives \
           /etc/ssl/certs /etc/ssl/openssl.cnf /etc/pki/tls/certs \
           /etc/ca-certificates /etc/ca-certificates.conf; do
    TEST_SANDBOX_ARGV+=( --ro-bind-try "$p" "$p" )
  done
  # No /etc/resolv.conf, ever: the sandbox resolves nothing. It hands the proxy a NAME and the proxy
  # resolves it on the host, which is the only place the answer can be checked against the address
  # policy — a resolver inside would just be a second, unchecked opinion.
  #
  # A minimal /etc/hosts IS needed, and not for the network: it is how `localhost` resolves to the
  # sandbox's own loopback. Without it vitest dies at startup with EAI_AGAIN before running a single
  # test. Synthesised rather than bound from the host, whose /etc/hosts names this machine's LAN.
  { echo "127.0.0.1 localhost"
    echo "::1 localhost ip6-localhost ip6-loopback"
  } > "$id/gate-hosts"
  TEST_SANDBOX_ARGV+=( --ro-bind "$id/gate-hosts" /etc/hosts )
  # A linked worktree's `.git` is a FILE (`gitdir: <repo>/.git/worktrees/<name>`), so every git
  # command in the gate resolves out of the worktree and into the repo — which is not bound. Without
  # this, `git ls-files` exits 128 and any suite that consults git fails for a reason that has
  # nothing to do with the change under test (nightshift's own `lib/check_docs.py` is one).
  # READ-ONLY, and that is the whole point: writable, a `pretest` could plant a hook or rewrite
  # history in the REAL repository — an escape straight past the disposable worktree.
  local gitdir
  gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$gitdir" ] && _test_robind "$gitdir"
  # (the pointer file itself is re-bound read-only further down — it must come AFTER the worktree's
  # read-write bind, or that bind simply covers it again)
  # The developer toolchain lives under nvm, i.e. under $HOME, which is NOT bound — so every entry
  # of NIGHTSHIFT_TEST_PATH is bound read-only here as well as prepended to PATH below. It is read
  # as a colon-separated PATH FRAGMENT, which is what it already was on the PATH side: the fleet
  # needs node from nvm and `uv` from ~/.local/bin in the same gate, and binding a directory without
  # putting it on PATH (or the reverse) leaves the tool just as unreachable.
  local -a tcdirs=()
  IFS=: read -r -a tcdirs <<<"${NIGHTSHIFT_TEST_PATH:-}"
  for p in ${tcdirs[@]+"${tcdirs[@]}"}; do
    [ -n "$p" ] || continue
    # node resolves its own lib/ relative to `..`, so an nvm bin dir needs its prefix bound too.
    # Scoped to a SELF-CONTAINED node install (`bin/node` + `lib/node_modules` under one prefix),
    # because the looser tests are both wrong here: a bare `dirname` drags in ~/.local for a
    # ~/.local/bin entry, and `lib/node_modules` alone still matches it — that is npm's global
    # prefix on this very host — mounting ~/.local/share into a sandbox whose entire purpose is
    # that $HOME is not in it.
    [ -x "$p/node" ] && [ -d "$(dirname -- "$p")/lib/node_modules" ] && _test_robind "$(dirname -- "$p")"
    _test_robind "$p"
  done
  # Host-declared extras — a warmed dependency cache, a shared toolchain, a runtime outside /usr.
  IFS=: read -r -a extra <<<"${NIGHTSHIFT_TEST_SANDBOX_ROBIND:-}"
  for p in ${extra[@]+"${extra[@]}"}; do _test_robind "$p" declared; done
  # Repo-declared extras (rulebook `test_robind`) — what only THIS repo's suite needs, typically a
  # local checkout its lockfile names as `git+file:///…`. Same refusals as the host-wide list.
  IFS=: read -r -a extra <<<"$robind"
  for p in ${extra[@]+"${extra[@]}"}; do _test_robind "$p" declared; done
  # The ONLY writable paths: the worktree (which is what is about to be committed) and a HOME.
  TEST_SANDBOX_ARGV+=( --bind "$wt" "$wt" --bind "$sbhome" "$sbhome" --chdir "$wt" )
  # Punch the pointer file back out of that writable area — ORDER MATTERS, bwrap applies binds in
  # sequence and the line above would otherwise cover this one. `$wt/.git` is a plain file naming
  # the gitdir, and every git command finalize runs next (`checkout -b`, `add -A`, `commit`) happens
  # OUTSIDE the sandbox as this account and reads whatever it names. Rewriting it to a gitdir built
  # inside the worktree is a full escape: `core.fsmonitor` is arbitrary command execution and
  # `hooks/pre-commit` is another. Both were verified to fire before this existed. As a mountpoint
  # the file also cannot be unlinked or replaced.
  [ -e "$wt/.git" ] && TEST_SANDBOX_ARGV+=( --ro-bind "$wt/.git" "$wt/.git" )
  # --clearenv dropped everything, SSH_AUTH_SOCK / GH_TOKEN / GITHUB_TOKEN / ANTHROPIC_API_KEY /
  # AWS_* / DOCKER_HOST included. What a suite legitimately needs is short, and it is listed here.
  TEST_SANDBOX_ARGV+=(
    --setenv HOME "$sbhome"
    --setenv PATH "${NIGHTSHIFT_TEST_PATH:+$NIGHTSHIFT_TEST_PATH:}/usr/local/bin:/usr/bin:/bin"
    --setenv TMPDIR /tmp
    --setenv TERM dumb
    --setenv LANG "${LANG:-C.UTF-8}"
    --setenv LC_ALL "${LC_ALL:-C.UTF-8}"
    --setenv USER "${USER:-nightshift}"
    --setenv NIGHTSHIFT_TEST_SANDBOX_ACTIVE 1
  )
  # One escape hatch, host-declared by NAME: a suite that needs UV_CACHE_DIR or CARGO_HOME says so
  # in the environment the operator controls, rather than the gate inheriting the whole session.
  local -a pass=()
  IFS=', ' read -r -a pass <<<"${NIGHTSHIFT_TEST_ENV_PASS:-}"
  for p in ${pass[@]+"${pass[@]}"}; do
    # `continue`, not `[ -n "$p" ] && …`: a trailing separator yields an empty field, whose failing
    # test would be the loop's exit status and would abort the whole night under `set -e`.
    [ -n "$p" ] || continue
    TEST_SANDBOX_ARGV+=( --setenv "$p" "${!p-}" )
  done
}

# Runs as pid 1 of the sandbox. rlimits are set HERE and not by the Runner, because they must bound
# the suite without bounding the Runner. `timeout` already caps wall clock; these cap what a suite
# can do inside that window. Kept as a fixed literal: the command itself arrives via the environment
# so nothing the rulebook wrote is ever spliced into this script.
# A ceiling that fails to apply must not be shrugged off — the suite would then run with the limit
# the operator thinks is in force and isn't. Exit 125 marks it as "the gate could not run".
TEST_GATE_INNER='
set_limit() { # flag value -> apply it, or refuse to run the suite at all
  [ "${2:-0}" -gt 0 ] || return 0
  ulimit "$1" "$2" 2>/dev/null && return 0
  echo "nightshift: could not apply ulimit $1 $2 inside the sandbox" >&2
  exit 125
}
set_limit -u "${NIGHTSHIFT_GATE_MAX_PROCS:-0}"
set_limit -d $(( ${NIGHTSHIFT_GATE_MEM_MB:-0} * 1024 ))
set_limit -t "${NIGHTSHIFT_GATE_CPU_S:-0}"
set_limit -f $(( ${NIGHTSHIFT_GATE_FSIZE_MB:-0} * 1024 ))
# Egress, when the repo has test_net (ADR 0028). The sandbox has its own empty network namespace,
# so this listener is on ITS loopback — unreachable from anywhere else — and every connection it
# accepts is forwarded to the host-side proxy over the bound unix socket, which vets the
# destination. A tool that ignores these variables simply has no network, which is the safe way
# round. Started before the suite and only reported ready once it is listening, so nothing races it.
if [ -n "${NIGHTSHIFT_GATE_PROXY_PORT:-}" ]; then
  # Read its readiness line rather than poking the port: a probe connection would arrive at the
  # proxy as an empty request and be logged as a refusal, which is noise in the one log an operator
  # reads to find out why a gate could not fetch anything.
  exec 7< <(python3 /nightshift-egress-forwarder.py "$NIGHTSHIFT_GATE_PROXY_PORT" /nightshift-egress/egress.sock)
  read -r -t 10 -u 7 _ || true
  export http_proxy="http://127.0.0.1:$NIGHTSHIFT_GATE_PROXY_PORT"
  export https_proxy="$http_proxy" HTTP_PROXY="$http_proxy" HTTPS_PROXY="$http_proxy"
  export ALL_PROXY="$http_proxy" all_proxy="$http_proxy"
  # Loopback is exempt, and must be. A suite that starts a server and talks to it is a normal
  # pattern, and every client honouring the variables above would otherwise hand that request to the
  # forwarder, where the proxy refuses it as an external destination. Seen on repo-a: twelve
  # refused POSTs to 127.0.0.1:9002, its own API, with the suite quietly taking an error path.
  #
  # This grants nothing. The loopback here belongs to the SANDBOX, created by --unshare-net; host
  # services sit on a different one and stay unreachable either way. There is no resolver and
  # localhost comes from the synthetic /etc/hosts, so these three names are exhaustive.
  # NOTE: no apostrophes anywhere in this block — it lives inside a single-quoted string.
  export no_proxy="localhost,127.0.0.1,::1"
  export NO_PROXY="$no_proxy"
fi
exec bash -c "$NIGHTSHIFT_GATE_CMD"
'

# `$wt/.git` is a POINTER FILE in the writable worktree, and every git command finalize runs next —
# `checkout -b`, `add -A`, `commit` — happens outside the sandbox as this account and reads whatever
# gitdir it names. Rewriting it is therefore a full escape (`core.fsmonitor` and `hooks/pre-commit`
# were both verified to fire). The sandbox binds the file read-only, but this records it anyway: the
# `none` opt-out has no such protection, and a guard that only exists inside the thing it guards is
# not a guard. Cheap enough to be unconditional.
# Everything below defends ONE property: no git command the Runner runs against a candidate worktree
# may execute code the candidate chose. Two mechanisms are needed because git offers two doors.
#
# Door 1 — the `.git` pointer. It is a plain file in the writable worktree, and both the Fix stage
# (N1 confines it to the worktree; this file is IN the worktree) and the gate can write it. Point it
# at a private gitdir and its `config` supplies `core.fsmonitor`, `alias`, `pager`, filter drivers —
# all arbitrary commands, run by whichever git touches the worktree next, outside any sandbox.
#
# Compared LITERALLY against what the repo says the pointer must be. An earlier version asked git to
# resolve the worktree and compared `--git-common-dir`, which a hostile gitdir defeats trivially: a
# `commondir` file inside it redirects the common dir back at the real repo, so the comparison
# passes while `$GIT_DIR` stays attacker-owned. Never ask a hostile repository to identify itself.
#
# The admin directory's NAME is git's to choose, not ours to predict: `worktree add` appends a digit
# when the basename is already registered, and one stale entry from a crashed night is enough — the
# path is gone, the entry is merely prunable, and the next worktree of that name becomes `<name>1`.
# Deriving the expected pointer from `basename "$wt"` therefore accused a perfectly sound worktree of
# tampering (seen live on repo-c) and refused the item, every night, until someone pruned. So the
# expected value is read from the REPO side instead: `<admin>/gitdir` is maintained by git outside
# the worktree, where the Fix stage cannot write (N1) and the sandbox binds read-only. That is the
# same trust boundary as before — a fact about the repo, not a claim by the candidate.
git_pointer_ok() { # repo worktree -> 0 if `$wt/.git` is exactly the pointer this repo recorded
  local repo="$1" wt="$2" common have admin
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$common" ] || return 1
  have="$(cat "$wt/.git" 2>/dev/null || true)"
  for admin in "$common"/worktrees/*/; do
    admin="${admin%/}"
    [ -d "$admin" ] || continue
    [ "$(cat "$admin/gitdir" 2>/dev/null || true)" = "$wt/.git" ] || continue
    [ "$have" = "gitdir: $admin" ] && return 0
  done
  return 1
}

# Door 2 — `core.hooksPath`. A RELATIVE value resolves against the working directory, so a repo that
# sets `core.hooksPath = .githooks` (nightshift's own does, and it is a `branch-fix` target) points
# git straight at a tracked, candidate-writable directory. A green suite rewrites `.githooks/pre-commit`
# and `finalize`'s commit executes it as this account, outside the sandbox.
#
# NOT simply "disable all hooks": finalize runs the target repo's hooks deliberately (ADR 0022 —
# nightshift must not manufacture a commit the host repo would reject), and hooks that live in the
# repo's own git dir are not candidate-controlled. Only the ones reachable INSIDE the worktree are.
# So this neutralises exactly those, by redirecting to the git dir's own hooks, and leaves the rest.
worktree_hook_args() { # repo worktree -> `-c core.hooksPath=…` if the repo's hooks live in the worktree
  local repo="$1" wt="$2" hp common rp
  hp="$(git -C "$wt" config --get core.hooksPath 2>/dev/null || true)"
  [ -n "$hp" ] || return 0                      # unset: git uses <gitdir>/hooks, outside the worktree
  case "$hp" in /*) rp="$hp" ;; *) rp="$wt/$hp" ;; esac
  rp="$(realpath -m -- "$rp" 2>/dev/null || printf '%s' "$rp")"
  # Inside the worktree (or the worktree itself) ⇒ the candidate can write it ⇒ redirect.
  if [ "$rp" = "$wt" ] || [ "${rp#"$wt"/}" != "$rp" ]; then
    common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [ -n "$common" ] && printf -- '-c\ncore.hooksPath=%s/hooks\n' "$common"
  fi
}

# The single choke point. Every Runner-owned git command that touches a candidate worktree goes
# through this first — including the Review stage's `git add -A`, which runs BEFORE the ship gate and
# was therefore the earliest detonation point of all.
assert_worktree_git_sane() { # repo worktree -> 0 sane, 1 tampered (and says so)
  local repo="$1" wt="$2"
  git_pointer_ok "$repo" "$wt" && return 0
  log "  $(basename "$repo"): .git POINTER TAMPERED in $(basename "$wt") — refusing to run git against it"
  return 1
}

# Removes every ignored file from a worktree and reports whether anything git does not track
# survived (ADR 0037). `-ff` also takes an ignored directory that holds its own `.git`, which a plain
# `-f` leaves in place. A submodule path is invisible to both `clean` and `ls-files`: a worktree is
# created with every submodule uninitialised, so such a path must still be empty — anything in it
# was written by a stage, and the suite would run it. A failed listing counts as a survivor: this
# check exists to fail closed.
# A directory this account cannot read or search hides its contents from git (a warning, exit 0)
# and from every content check, so it refuses on its own. Anything that runs in the worktree can
# make one with a plain chmod. A failed search counts as one: this check exists to fail closed.
has_hidden_dir() { # worktree -> 0 one exists (or the search failed), 1 none
  local found
  found="$(find "$1" -type d \( ! -readable -o ! -executable \) -print -quit 2>&1)" || return 0
  [ -n "$found" ]
}

purge_ignored_files() { # worktree -> 0 nothing untracked-and-ignored left, 1 otherwise
  local wt="$1" left
  ! has_hidden_dir "$wt" || return 1
  git -C "$wt" clean -ffdXq >/dev/null 2>&1 || true
  left="$(git -C "$wt" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)" || return 1
  [ -z "$left" ] || return 1
  submodules_empty "$wt"
}

# The worktree is created with every submodule uninitialised, so such a path must still be empty:
# git lists neither its contents nor changes to them, and anything in it was written by something
# that ran there. NUL-separated, so a path git would print quoted and escaped is checked by its real
# bytes. A submodule path that is not an empty, listable directory refuses: one made unreadable is
# not thereby empty.
submodules_empty() { # worktree -> 0 every submodule path empty or absent, 1 otherwise
  local wt="$1" rec sm found
  git -C "$wt" ls-files --stage -z >/dev/null 2>&1 || return 1
  while IFS= read -r -d '' rec; do
    case "$rec" in 160000\ *) ;; *) continue ;; esac
    sm="${rec#*$'\t'}"
    [ -e "$wt/$sm" ] || [ -L "$wt/$sm" ] || continue
    [ -d "$wt/$sm" ] && [ ! -L "$wt/$sm" ] || return 1
    found="$(find "$wt/$sm" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || return 1
    [ -z "$found" ] || return 1
  done < <(git -C "$wt" ls-files --stage -z 2>/dev/null)
  return 0
}

# The exact bytes of everything `git add -A` would stage — tracked and un-ignored files — with each
# entry's type and permission bits, as one digest. Bytes, not a tree id: git normalises content
# through .gitattributes (`eol=lf` hides an LF->CRLF rewrite), and the suite runs on the bytes.
worktree_content_id() { # worktree -> digest, or nothing on failure
  local wt="$1"
  git -C "$wt" ls-files -z --cached --others --exclude-standard 2>/dev/null | python3 -c '
import hashlib, os, stat, sys
root = sys.argv[1]
h = hashlib.sha256()
for p in sorted(set(x for x in sys.stdin.buffer.read().split(b"\0") if x)):
    f = os.path.join(os.fsencode(root), p)
    try:
        st = os.lstat(f)
    except FileNotFoundError:
        h.update(b"x\0" + p + b"\0"); continue
    h.update(b"%o\0" % st.st_mode + p + b"\0")
    if stat.S_ISLNK(st.st_mode):
        h.update(os.readlink(f) + b"\0")
    elif stat.S_ISREG(st.st_mode):
        with open(f, "rb") as fh:
            h.update(hashlib.sha256(fh.read()).digest())
print(h.hexdigest())
' "$wt" 2>/dev/null
}

# The ship gate's execution half (ADR 0026, ADR 0028): ONE repo command, run over the worktree in
# the disposable bwrap sandbox with the repo's vetted egress, both torn down before it returns. The
# gate and the dependency setup before Fix (ADR 0037) both run through here, so there is exactly one
# sandbox for the Runner executing repository content. Output lands in `out`; the command's own
# status is returned. GATE_UNAVAILABLE=1 (status 2) means the command never ran — no sandbox, no
# proxy, or a sandbox that did not come up — and `out` or egress.log says which.
GATE_UNAVAILABLE=0
gate_exec() { # repo worktree item_dir cmd out label consequence -> the command's status
  local repo="$1" wt="$2" id="$3" tcmd="$4" out="$5" label="$6" consequence="$7" net trc=0 sbhome persist=0
  GATE_UNAVAILABLE=0
  net=$(repo_test_net "$repo")

  # A test_net repo gets its egress through the vetting proxy (ADR 0028), never through the host's
  # network namespace. Started per gate and killed after it, so nothing outlives the run it serves.
  TEST_EGRESS_DIR=""; TEST_EGRESS_PORT=""
  local egress_pid=""
  if [ "$net" = 1 ] && [ "$TEST_SANDBOX" != none ]; then
    TEST_EGRESS_DIR="$(mktemp -d "$WORKTREES_DIR/gate-egress.XXXXXX")"
    chmod 700 "$TEST_EGRESS_DIR"
    TEST_EGRESS_PORT=3128
    # `read` on the proxy's stdout: it prints one line once the socket is bound and listening. A
    # sleep here would be a race that only shows up as a flaky "registry unreachable" at 04:00.
    exec 8< <(python3 "$NIGHTSHIFT_HOME/lib/egress_proxy.py" "$TEST_EGRESS_DIR/egress.sock" 2>>"$id/egress.log")
    # The pid comes from the READY LINE, not from `$!`. After `exec 8< <(…)`, `$!` names the subshell
    # bash forks for the substitution; that subshell only *becomes* python3 on a bash that
    # exec-replaces it (5.2 does, the 5.1 on Debian 11 does not), and killing the wrong pid leaves
    # the proxy listening after its socket directory is gone. bash does not promise otherwise, so the
    # process reporting its own pid is the only source that is right on every version.
    if ! read -r -t 10 -u 8 _ready egress_pid; then
      log "  $(basename "$repo"): the egress proxy did not come up — $consequence (see $id/egress.log)"
      exec 8<&-
      # No pid to kill (that is what failed), so reap by the socket path, which mktemp made unique.
      # pkill -f takes an extended regex and the path comes from NIGHTSHIFT_WORKTREES / TMPDIR, so it
      # is escaped and anchored: a `[` or `+` in it would otherwise miss this proxy or hit a sibling's.
      pkill -f -- "egress_proxy\.py $(printf '%s' "$TEST_EGRESS_DIR/egress.sock" | sed 's/[][\\.*^$+?(){}|]/\\&/g')\$" 2>/dev/null || true
      rm -rf "$TEST_EGRESS_DIR"
      GATE_UNAVAILABLE=1; return 2
    fi
  fi
  # Every exit from here on has to take the proxy with it, so it is torn down in one place.
  stop_egress() {
    # Only touch fd 8 if this call actually opened it. `exec 8<&-` on a descriptor that was never
    # opened is a redirection failure, and a failed `exec` redirection TERMINATES a non-interactive
    # shell — `2>/dev/null || true` does not save it. That killed the whole night right after the
    # first gate of every repo without test_net, which reads downstream as "the loop never retried".
    if [ -n "${egress_pid:-}" ]; then
      # SIGINT, not SIGTERM. bash announces a process-substitution job killed by SIGTERM as a bare
      # `Terminated` on stderr — deferred to the next command, so it lands in the night log between
      # "test gate passed" and the push and reads like a crash in a run that succeeded. bash stays
      # silent for SIGINT and SIGPIPE, and `lib/egress_proxy.py` already exits cleanly on
      # KeyboardInterrupt, so the quieter signal costs nothing. Every `test_net` gate did this.
      kill -INT "$egress_pid" 2>/dev/null || true
      exec 8<&-
    fi
    [ -n "${TEST_EGRESS_DIR:-}" ] && rm -rf "$TEST_EGRESS_DIR"
    TEST_EGRESS_DIR=""; egress_pid=""
    return 0
  }

  # A gate that cannot be sandboxed does not run. Not "runs anyway with a warning": the whole point
  # of ADR 0026 is that executing this content as this account is the exposure, so the absence of
  # the sandbox is a refusal to ship, not a licence to ship faster.
  if [ "$TEST_SANDBOX" != none ] && ! command -v bwrap >/dev/null 2>&1; then
    printf 'nightshift: bwrap is not installed, so the ship gate has no sandbox.\n%s\n' \
      "Install bubblewrap, or accept the risk explicitly with NIGHTSHIFT_TEST_SANDBOX=none." \
      >"$out"
    log "  $(basename "$repo"): $label cannot run — no sandbox (bwrap missing) — $consequence"
    stop_egress
    GATE_UNAVAILABLE=1; return 2
  fi

  # HOME is disposable by default, so nothing a suite writes survives into the next night — and a
  # poisoned dependency cache is a cross-run write channel. An operator who cannot afford a cold
  # cache every gate can pin one with NIGHTSHIFT_TEST_SANDBOX_HOME and owns that trade.
  if [ -n "${NIGHTSHIFT_TEST_SANDBOX_HOME:-}" ]; then
    sbhome="$NIGHTSHIFT_TEST_SANDBOX_HOME"; persist=1; mkdir -p "$sbhome"
  else
    sbhome="$(mktemp -d "$WORKTREES_DIR/gate-home.XXXXXX")"
  fi

  # `|| trc=$?` and not `if ! …`: inside an `if !` body `$?` is the negation's 0, not the suite's.
  if [ "$TEST_SANDBOX" = none ]; then
    # NIGHTSHIFT_TEST_PATH is the developer toolchain (node/npm/pnpm) the repo's own suite needs but
    # that a systemd user service does not get — bin/nightshift-cron.sh explains why it is prepended
    # HERE and nowhere else: the Runner's own unqualified jq/git/python3 calls must keep resolving to
    # the system dirs (R10/N4), while this subprocess already runs the repo's package scripts anyway.
    log "  $(basename "$repo"): $label sandbox DISABLED (NIGHTSHIFT_TEST_SANDBOX=none) — it runs with this account's full reach"
    ( cd "$wt" && export PATH="${NIGHTSHIFT_TEST_PATH:+$NIGHTSHIFT_TEST_PATH:}$PATH" \
      && timeout "$TEST_TIMEOUT" bash -c "$tcmd" </dev/null ) >"$out" 2>&1 || trc=$?
  else
    build_test_sandbox "$wt" "$sbhome" "$net" "$id" "$(repo_test_robind "$repo")"
    # Whether the sandbox was actually BUILT cannot be read off the exit status: bubblewrap exits 1
    # for a missing bind source, a bad --chdir and an unknown option alike, and it also propagates
    # the child's own status, so no value is unambiguous. `--json-status-fd` is: bwrap writes an
    # `exit-code` record only once the child has actually run, so its ABSENCE means the sandbox
    # never came up. (`child-pid` is NOT the signal — bwrap forks before it binds, so a failed setup
    # still reports one. Measured against bwrap 0.11.0.)
    : >"$id/.sandbox-status"
    # `--chdir "$wt"` above is what puts the suite in the WORKTREE rather than the repo: the worktree
    # is what carries the fix and what is about to be committed.
    timeout "$TEST_TIMEOUT" \
      "${TEST_SANDBOX_ARGV[@]}" \
      --json-status-fd 9 \
      --setenv NIGHTSHIFT_GATE_CMD "$tcmd" \
      --setenv NIGHTSHIFT_GATE_MAX_PROCS "$TEST_MAX_PROCS" \
      --setenv NIGHTSHIFT_GATE_MEM_MB "$TEST_MEMORY_MB" \
      --setenv NIGHTSHIFT_GATE_CPU_S "$TEST_TIMEOUT" \
      --setenv NIGHTSHIFT_GATE_FSIZE_MB "$TEST_FSIZE_MB" \
      -- /bin/bash -c "$TEST_GATE_INNER" </dev/null >"$out" 2>&1 9>"$id/.sandbox-status" || trc=$?
    # A timeout killed a sandbox that DID come up, so it is a red suite, not a construction failure.
    if [ "$trc" -ne 124 ] && ! grep -q '"exit-code"' "$id/.sandbox-status" 2>/dev/null; then
      { echo "nightshift: bubblewrap did not bring the sandbox up (rc=$trc)."
        echo "The $label never ran, so nothing about this change has been tested."
        echo "--- bwrap output ---"; cat "$out" 2>/dev/null; } >"$id/.gate-refusal"
      mv "$id/.gate-refusal" "$out"
      rm -f "$id/.sandbox-status"
      [ "$persist" = 1 ] || rm -rf "$sbhome"
      log "  $(basename "$repo"): $label could not START its sandbox — $consequence (see $out)"
      stop_egress
      GATE_UNAVAILABLE=1; return 2
    fi
    rm -f "$id/.sandbox-status"
  fi
  [ "$persist" = 1 ] || rm -rf "$sbhome"
  stop_egress
  return "$trc"
}
