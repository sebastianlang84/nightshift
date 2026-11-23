#!/usr/bin/env bash
# Sourced by bin/nightshift.sh after its path globals are initialized.
# --------------------------------------------------------------- ship gate ----
# The repo's own suite runs over the worktree INSIDE the fix<->review loop: a red suite is a
# revision request that hands Fix the failing output (stage_prompt), and only an item that leaves
# the loop still red is refused (ADR 0022).
# The suite executes candidate-written content (`npm ci` runs package.json lifecycle scripts), so it
# never runs as this account: bubblewrap, whose filesystem and environment are allowlists, or not at
# all, unless the operator sets NIGHTSHIFT_TEST_SANDBOX=none (ADR 0026). docker is no substitute:
# its socket is host-root.
TEST_SANDBOX="${NIGHTSHIFT_TEST_SANDBOX:-bwrap}"
declare -a TEST_SANDBOX_ARGV=()

_test_robind() { # path [declared] -> append a read-only bind, refusing anything that would re-expose $HOME
  local p="$1" declared="${2:-}" rp
  [ -n "$p" ] || return 0
  rp="$(realpath -m -- "$p" 2>/dev/null || printf '%s' "$p")"
  # A missing DECLARED path (NIGHTSHIFT_TEST_SANDBOX_ROBIND, rulebook test_robind) is logged: dropped
  # quietly it shows up only as a red suite that Fix is asked to repair.
  if [ ! -e "$rp" ]; then
    [ -n "$declared" ] && log "  test sandbox: read-only bind $p does not exist — not bound"
    return 0
  fi
  case "$rp" in /usr|/usr/*) return 0 ;; esac   # already bound whole
  # A bind of $HOME or any ancestor hands the suite ~/.ssh and the forge token back. Refuse it out
  # loud: a silently widened sandbox is worse than none.
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
  # ALWAYS its own network namespace, `test_net` or not: the host's would expose its loopback and
  # LAN. A test_net repo's egress crosses through a vetting proxy's unix socket, a filesystem object
  # rather than a route (ADR 0028).
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
  # /etc is bound file by file, never whole: it holds service secrets. Not /etc/ssl or /etc/pki
  # wholesale either, since /etc/ssl/private holds private keys. `-try` because the set spans
  # distributions.
  for p in /etc/passwd /etc/group /etc/nsswitch.conf /etc/localtime /etc/alternatives \
           /etc/ssl/certs /etc/ssl/openssl.cnf /etc/pki/tls/certs \
           /etc/ca-certificates /etc/ca-certificates.conf; do
    TEST_SANDBOX_ARGV+=( --ro-bind-try "$p" "$p" )
  done
  # No /etc/resolv.conf: names are resolved by the host-side proxy, the only place the answer is
  # checked against the address policy. A synthetic /etc/hosts still maps `localhost` to the
  # sandbox's own loopback (vitest fails without it); the host's file would name this machine's LAN.
  { echo "127.0.0.1 localhost"
    echo "::1 localhost ip6-localhost ip6-loopback"
  } > "$id/gate-hosts"
  TEST_SANDBOX_ARGV+=( --ro-bind "$id/gate-hosts" /etc/hosts )
  # A linked worktree's `.git` points into the repo's git dir, so a suite that runs git needs it
  # bound. READ-ONLY: writable, a `pretest` could plant a hook or rewrite refs in the real repository.
  local gitdir
  gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$gitdir" ] && _test_robind "$gitdir"
  # NIGHTSHIFT_TEST_PATH (a colon-separated PATH fragment, typically under $HOME) is bound read-only
  # here AND prepended to PATH below; either half alone leaves the tool unreachable.
  local -a tcdirs=()
  IFS=: read -r -a tcdirs <<<"${NIGHTSHIFT_TEST_PATH:-}"
  for p in ${tcdirs[@]+"${tcdirs[@]}"}; do
    [ -n "$p" ] || continue
    # node resolves its lib/ relative to `..`, so a node bin dir needs its prefix bound too. Only for
    # a self-contained install (`node` here AND `../lib/node_modules`): either test alone also matches
    # ~/.local/bin and would mount ~/.local into the sandbox.
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
  # Re-bind the `.git` pointer read-only AFTER the worktree bind, which would otherwise cover it.
  # finalize's git commands run outside the sandbox and follow it, so a rewritten pointer is a full
  # escape (ADR 0026); as a mountpoint it also cannot be unlinked or replaced.
  [ -e "$wt/.git" ] && TEST_SANDBOX_ARGV+=( --ro-bind "$wt/.git" "$wt/.git" )
  # After --clearenv, this is the whole environment; credentials stay out by construction.
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
  # The one escape hatch: variables the operator names in NIGHTSHIFT_TEST_ENV_PASS.
  local -a pass=()
  IFS=', ' read -r -a pass <<<"${NIGHTSHIFT_TEST_ENV_PASS:-}"
  for p in ${pass[@]+"${pass[@]}"}; do
    # `continue`, not `[ -n "$p" ] && …`: a trailing separator yields an empty field, whose failing
    # test would be the loop's exit status and would abort the whole night under `set -e`.
    [ -n "$p" ] || continue
    TEST_SANDBOX_ARGV+=( --setenv "$p" "${!p-}" )
  done
}

# Runs as pid 1 of the sandbox, so the rlimits bound the suite and not the Runner (ADR 0026). A
# fixed literal: the command arrives via the environment, so nothing the rulebook wrote is spliced
# into this script. A limit that fails to apply exits 125 ("the gate could not run") rather than
# running the suite without it.
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

# Everything below defends ONE property: no git command the Runner runs against a candidate worktree
# may execute code the candidate chose (ADR 0026). Git offers two doors, so there are two checks.
#
# Door 1 — the `.git` pointer, a plain file that Fix (N1 confines it to the worktree) and the gate
# can write. Pointed at a private gitdir, its config (`core.fsmonitor`, `alias`, `pager`, filters)
# runs commands in whichever git touches the worktree next. The sandbox's read-only bind does not
# cover NIGHTSHIFT_TEST_SANDBOX=none or a pointer Fix wrote, so this check is unconditional.
#
# Compared LITERALLY, never by asking git: a hostile gitdir's `commondir` file makes
# `--git-common-dir` report the real repo. The expected value comes from the repo side,
# `<admin>/gitdir`, which the candidate cannot write. The admin dir's name is git's choice (it
# appends a digit when a stale entry holds the basename), so it is searched for, not derived.
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

# Door 2 — `core.hooksPath`. A relative value (nightshift's own `.githooks`) resolves inside the
# worktree, where the candidate can rewrite the hooks finalize's commit then runs as this account.
# Hooks are not disabled: finalize runs the repo's own hooks deliberately, so it never makes a
# commit the repo would reject (ADR 0022). Only a hooks path inside the worktree is redirected, to
# the git dir's hooks.
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

# The single choke point: every Runner-owned git command on a candidate worktree goes through this
# first, including the Review stage's `git add -A`, which runs before the ship gate.
assert_worktree_git_sane() { # repo worktree -> 0 sane, 1 tampered (and says so)
  local repo="$1" wt="$2"
  git_pointer_ok "$repo" "$wt" && return 0
  log "  $(basename "$repo"): .git POINTER TAMPERED in $(basename "$wt") — refusing to run git against it"
  return 1
}

# A directory this account cannot read or search hides its contents from git (a warning, exit 0)
# and from every content check, so it refuses on its own. A failed search counts as one (fail closed).
has_hidden_dir() { # worktree -> 0 one exists (or the search failed), 1 none
  local found
  found="$(find "$1" -type d \( ! -readable -o ! -executable \) -print -quit 2>&1)" || return 0
  [ -n "$found" ]
}

# Removes every ignored file and fails if anything untracked survives (ADR 0037). `-ff` also takes
# an ignored directory holding its own `.git`. A submodule path is invisible to both `clean` and
# `ls-files` and starts uninitialised, so it must still be empty: anything in it was written by a
# stage. A failed listing counts as a survivor (fail closed).
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

# Runs ONE repo command over a worktree in the disposable bwrap sandbox with the repo's vetted
# egress, both torn down before it returns (ADR 0026, ADR 0028). The ship gate and the red-base
# check (ADR 0041) both run through here, so there is one sandbox for repository content. Output
# lands in `out`; the command's status is returned. GATE_UNAVAILABLE=1 (status 2) means the command
# never ran — no sandbox, no proxy, or a sandbox that did not come up — and `out` or egress.log says
# which.
GATE_UNAVAILABLE=0
gate_exec() { # repo worktree item_dir cmd out label consequence -> the command's status
  local repo="$1" wt="$2" id="$3" tcmd="$4" out="$5" label="$6" consequence="$7" net trc=0 sbhome persist=0
  GATE_UNAVAILABLE=0
  net=$(repo_test_net "$repo")

  # The vetting proxy (ADR 0028) lives exactly as long as this one command.
  TEST_EGRESS_DIR=""; TEST_EGRESS_PORT=""
  local egress_pid=""
  if [ "$net" = 1 ] && [ "$TEST_SANDBOX" != none ]; then
    TEST_EGRESS_DIR="$(mktemp -d "$WORKTREES_DIR/gate-egress.XXXXXX")"
    chmod 700 "$TEST_EGRESS_DIR"
    TEST_EGRESS_PORT=3128
    # The proxy prints one ready line once its socket listens; reading it avoids a startup race.
    exec 8< <(python3 "$NIGHTSHIFT_HOME/lib/egress_proxy.py" "$TEST_EGRESS_DIR/egress.sock" 2>>"$id/egress.log")
    # The pid comes from that line, not `$!`: `$!` names the substitution's subshell, which only some
    # bash versions exec-replace with python3, and killing it would leave the proxy running.
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
    # Only touch fd 8 if this call opened it: `exec 8<&-` on an unopened descriptor is a failed
    # redirection, which terminates a non-interactive shell despite `|| true`.
    if [ -n "${egress_pid:-}" ]; then
      # SIGINT, not SIGTERM: bash reports a substitution job killed by SIGTERM as a stray
      # `Terminated` in the night log; egress_proxy.py exits cleanly on KeyboardInterrupt.
      kill -INT "$egress_pid" 2>/dev/null || true
      exec 8<&-
    fi
    [ -n "${TEST_EGRESS_DIR:-}" ] && rm -rf "$TEST_EGRESS_DIR"
    TEST_EGRESS_DIR=""; egress_pid=""
    return 0
  }

  # No sandbox, no run, unless NIGHTSHIFT_TEST_SANDBOX=none opts out: executing this content as this
  # account is the exposure (ADR 0026).
  if [ "$TEST_SANDBOX" != none ] && ! command -v bwrap >/dev/null 2>&1; then
    printf 'nightshift: bwrap is not installed, so the ship gate has no sandbox.\n%s\n' \
      "Install bubblewrap, or accept the risk explicitly with NIGHTSHIFT_TEST_SANDBOX=none." \
      >"$out"
    log "  $(basename "$repo"): $label cannot run — no sandbox (bwrap missing) — $consequence"
    stop_egress
    GATE_UNAVAILABLE=1; return 2
  fi

  # HOME is disposable by default: a persistent dependency cache is a cross-run write channel.
  # NIGHTSHIFT_TEST_SANDBOX_HOME pins one, at the operator's risk.
  if [ -n "${NIGHTSHIFT_TEST_SANDBOX_HOME:-}" ]; then
    sbhome="$NIGHTSHIFT_TEST_SANDBOX_HOME"; persist=1; mkdir -p "$sbhome"
  else
    sbhome="$(mktemp -d "$WORKTREES_DIR/gate-home.XXXXXX")"
  fi

  # `|| trc=$?` and not `if ! …`: inside an `if !` body `$?` is the negation's 0, not the suite's.
  if [ "$TEST_SANDBOX" = none ]; then
    # NIGHTSHIFT_TEST_PATH is prepended only for the suite: the Runner's own unqualified commands
    # must keep resolving to the system dirs (R10/N4; see bin/nightshift-cron.sh).
    log "  $(basename "$repo"): $label sandbox DISABLED (NIGHTSHIFT_TEST_SANDBOX=none) — it runs with this account's full reach"
    ( cd "$wt" && export PATH="${NIGHTSHIFT_TEST_PATH:+$NIGHTSHIFT_TEST_PATH:}$PATH" \
      && timeout "$TEST_TIMEOUT" bash -c "$tcmd" </dev/null ) >"$out" 2>&1 || trc=$?
  else
    build_test_sandbox "$wt" "$sbhome" "$net" "$id" "$(repo_test_robind "$repo")"
    # Whether the sandbox came up cannot be read off the exit status, which bwrap shares with the
    # child. An `exit-code` record on --json-status-fd appears only once the child ran, so its
    # absence means it never did (`child-pid` is written before the binds, so it proves nothing).
    : >"$id/.sandbox-status"
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
