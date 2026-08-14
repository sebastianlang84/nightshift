# ADR 0026 — the ship gate runs in a sandbox, or it does not run

- Status: accepted
- Date: 2026-08-14
- Extends: [ADR 0022](0022-a-repos-own-tests-gate-the-ship.md) (the gate this confines), and closes
  the ungated ship path that ADR 0022 §4 deliberately left open
- Related: [`docs/design/risk-analysis.md`](../design/risk-analysis.md) (R15, M2),
  [`docs/design/hook-spec.md`](../design/hook-spec.md) (the agent-side confinement this sits beside)

## Context

An independent cross-vendor architecture review (gpt-5.6-sol, 2026-08-14) named this the single
highest-priority finding in the repository, and it is not hypothetical.

`run_test_gate()` ran the rulebook's per-repo `test_cmd` through an unsandboxed `bash -c` inside the
candidate worktree, as the operator's own account. That worktree holds code the **Fix stage just
wrote**. For a JS repo the command is `npm ci && npm test` — which executes `preinstall`, `prepare`
and `pretest` lifecycle scripts straight out of a `package.json` the agent is free to modify.

So the shortest path from candidate-controlled repository content to arbitrary host execution ran
straight through the safety mechanism. The account it lands on is the one described in
risk-analysis.md §1: SSH private keys, a `gh` OAuth token carrying `repo` and `admin:public_key`,
`~/.claude` and `~/.codex` credentials, `/etc` secrets, membership in `docker` (host-root
equivalent) and `sudo`. A `pretest` that reads `~/.ssh/id_ed25519`, posts it somewhere, and exits 0
would be reported by the night as **a passing gate**.

Everything the project already built points the other way. Fix has no `Bash` at all; `Write`/`Edit`
are confined to the worktree by the PreToolUse guard (R8/N1); the Codex adapter runs Fix
OS-sandboxed with network disabled. The one component that *deliberately executes* the resulting
code had no boundary of its own — the strongest primitive in the pipeline sat behind the weakest
confinement. That inversion is the finding.

The exposure is live every night, and it is independent of any auto-merge plan: it fires the moment
a fix reaches a `ship` verdict, long before a human sees the branch.

## Decision

**1. The gate executes in a disposable bubblewrap sandbox with no credential reach.**

`run_test_gate()` builds the sandbox per invocation (`build_test_sandbox`) and runs the command as
pid 1 inside it:

- **Filesystem is an allowlist.** `/usr` read-only, the host's merged-`/usr` symlinks recreated, a
  fresh `/proc` and `/dev`, and a **size-capped** `tmpfs` on `/tmp` and `/run`. `/etc` is never
  bound as a directory — a named set (`passwd`, `group`, `nsswitch.conf`, `localtime`,
  `alternatives`, the CA bundles) is bound file by file, because `/etc` is where this host keeps
  `/etc/ai_stack`. `$HOME` is not bound at all, so `~/.ssh`, `~/.config/gh`, `~/.claude` and
  `~/.codex` do not exist inside. Neither does `/var/run/docker.sock`.
- **Writable: the worktree and a HOME, nothing else.** The worktree because it is what carries the
  fix and what is about to be committed; a scratch `HOME` because npm, uv and cargo will not run
  without one. The HOME is created per gate and deleted after it.
- **The environment is an allowlist, not a filtered inheritance.** `--clearenv` drops everything
  and eight variables are set back (`HOME`, `PATH`, `TMPDIR`, `TERM`, `LANG`, `LC_ALL`, `USER`,
  `NIGHTSHIFT_TEST_SANDBOX_ACTIVE`). `SSH_AUTH_SOCK`, `GH_TOKEN`, `GITHUB_TOKEN`,
  `ANTHROPIC_API_KEY`, every `AWS_*` and `DOCKER_HOST` are gone by construction rather than by
  denylist — a denylist would need updating every time a new tool invents a new variable name.
- **Namespaces:** user, IPC, PID, UTS, cgroup and (by default) network. `--new-session` removes the
  controlling terminal, so a suite cannot push characters back into the Runner's tty with `TIOCSTI`.
  `--die-with-parent` means the sandbox cannot outlive the `timeout` that bounds it.

**2. Network egress is denied by default and opted into per repo.**

New per-repo key `test_net: true`. Default `false`.

`npm ci` and `uv run --with-requirements` genuinely need a registry, so a blanket denial would break
real gates and the pressure would be to disable the sandbox entirely. Making it a per-repo key keeps
the grant narrow, visible in the host-owned rulebook, and attached to the repo that actually needs
it. With `test_net: true` the sandbox still holds **no credentials**, so what the channel can carry
is worktree content — code that is already on the repo's forge — not the SSH key or the token. That
is the whole difference between "the suite can talk to the network" and "the attacker gets the
account".

Resolver config (`/etc/resolv.conf`, `/etc/hosts`) is bound only when egress is granted.

**3. Resource ceilings, not just a wall clock.**

`timeout` bounded wall clock and nothing else, so a suite could pin every core or exhaust RAM for
the full ten minutes. Inside the sandbox: `RLIMIT_NPROC` from `limits.test_max_procs` (2048), the
fork-bomb bound; `RLIMIT_AS` from `limits.test_memory_mb` (4096); `RLIMIT_CPU` set to
`test_timeout_seconds`, so no single process burns more CPU-seconds than the run has wall seconds;
and the `/tmp` tmpfs capped at 1 GiB, because a tmpfs is RAM and an uncapped one is an OOM away from
taking the host down. The rlimits are applied by the sandbox's own pid 1, never by the Runner —
they must bound the suite without bounding the Runner.

**4. No sandbox means no gate, and no gate means no ship.**

If `bwrap` is missing, or bubblewrap fails to construct the sandbox (its own exit code 125), the
gate returns a distinct status: **the gate could not run**. The item is refused (`tests-failed`, no
branch, no PR) and — unlike a red suite — it does **not** loop back into Fix. A host problem is not
a regression the Fix stage can repair, and treating it as one would spend every remaining fix
iteration, every night, on a misconfiguration no model can fix.

There is exactly one way out, and it is loud, explicit and host-owned:
`NIGHTSHIFT_TEST_SANDBOX=none` runs the old unsandboxed path and logs, on every gate, that the
suite is running with the account's full reach.

**5. A `branch-fix` repo must declare a `test_cmd`. The parse aborts otherwise.**

This revises ADR 0022 §4, which let a repo without the key ship "exactly as it did before" with a
`shipping UNGATED` line in the log. That concession has not aged well. `branch-fix` means nightshift
pushes machine-written code and invites a human to merge it; the Review stage only ever proves *the
finding* is fixed, never that nothing else broke. Shipping with no suite at all is the one remaining
silent path to a merge-ready branch, and its only warning scrolled past in a log nobody reads at
04:00.

A repo with no runnable suite is not a repo nightshift should be writing branches for. Saying so is
one word: `mode: findings-only`, which reports without ever pushing. So `lib/parse_rulebook.py`
refuses the silence — same fail-closed treatment the closed key sets and `REPO_MODES` already get,
and the operator finds out at parse time rather than at merge time. `findings-only` repos are
unaffected; they never reach the gate.

## Consequences

**The most direct route from candidate content to host execution is closed.** A `pretest` planted by
a prompt-injected Fix stage now runs somewhere with no SSH key, no token, no `~/.claude`, no
`/etc/ai_stack`, no docker socket, no network unless the host granted it, and nothing writable it
can carry into the next night.

**The gate needs its dependencies bound in.** `$HOME` is gone, and under nvm the toolchain lives
there — so every entry of `NIGHTSHIFT_TEST_PATH` (read as a `:`-separated PATH fragment, because
this fleet needs `node` from nvm and `uv` from `~/.local/bin` in the same gate) is bound read-only
*and* placed on the gate's `PATH`; bound-but-not-on-`PATH` is just as unreachable. A self-contained
node install additionally gets its prefix bound, gated on the directory holding a `node` binary
**and** the prefix holding a node-modules tree — both conditions, because either one alone mounts
`~/.local`, which is npm's global prefix on this host.
Anything else is named by the host in `NIGHTSHIFT_TEST_SANDBOX_ROBIND`, and a bind that would
re-expose `$HOME` — `/`, `/home`, `$HOME` itself — is refused with a log line rather than mounted.

**The repository's git dir is bound read-only.** The gate always runs in a linked worktree, whose
`.git` is a *file* pointing at `<repo>/.git/worktrees/<name>`; without the bind every git command
inside the sandbox exits 128 and any suite that consults git fails for a reason unrelated to the
change under test — nightshift's own `lib/check_docs.py` was the first casualty. Read-only is the
security half: writable, a `pretest` could plant a hook or rewrite refs in the real repository and
walk straight past the disposable worktree the whole design rests on.

**Cold caches, unless the host says otherwise.** A disposable `HOME` means npm and uv start empty on
every gate, which for a `test_net: true` repo costs a real download inside the timeout.
`NIGHTSHIFT_TEST_SANDBOX_HOME` pins a persistent one; that turns the cache into a cross-run write
channel a malicious `pretest` could poison for the next night, which is why it is not the default.

**`bubblewrap` becomes a deployment dependency**, and so does an unprivileged-user-namespace kernel.
Both hold on the target host (Debian 13, bwrap 0.11.0). A host where they do not hold gets no
branches until it installs them or explicitly opts out — that is the intended failure direction.

**The fleet's rulebook needs one edit per `branch-fix` repo without a `test_cmd`**, and the night
aborts loudly until it gets one. That is the point, but it will bite once, at the next run after
this lands.

## Residual risk

- **The worktree is writable and it is what gets committed.** The gate runs *after* the reviewer
  saw the staged diff (R9/N3), so a `pretest` can still modify the tree between review and commit,
  and `finalize`'s `git add -A` would pick it up. Closing this needs a comparison of the committed
  path set against what review signed off on — N3's unimplemented stronger half — and it cannot be
  a naive "the tree must not change", because legitimate suites touch lockfiles. Bounded for now by
  human review of the branch before merge (C5).
- **The repository's history is readable inside the gate**, because the git dir is bound. It is the
  same content the worktree already carries, and `.git/config` names remotes — on this host SSH
  URLs, not credentials. A repo that keeps a token in a remote URL would expose it to its own gate.
- **`test_net: true` is an egress channel** for worktree content. Narrowed to the repos that need
  it, holding no credentials, but it is real and it is unproxied.
- **`RLIMIT_AS` is address space, not resident memory.** It stops a runaway allocation; it is not a
  cgroup memory controller, and a value set too low breaks modern runtimes rather than protecting
  anything. `RLIMIT_NPROC` is charged to the *account*, not to the sandbox, so it bounds a fork bomb
  but is not a per-gate process budget.
- **The sandbox protects the host, not the repo.** Inside it, the suite still has full control over
  the worktree and over its own exit status. `test_cmd: true` gates nothing, sandboxed or not
  (ADR 0022) — the rulebook is host-owned and that stays a host decision.
- **Kernel and bubblewrap are now in the trust base.** An unprivileged-userns escape defeats this.
  That is a smaller and much better-studied trust base than "the account's whole ambient authority".

## Alternatives considered

**Do nothing until a dedicated unprivileged service account exists (M1).** M1 is the right long-term
move and remains queued — but it is an account-provisioning change to a shared host, and it does not
by itself stop the gate reading `~/.ssh` of *that* account, or the repos it can reach. The sandbox
is smaller, lands tonight, and composes with M1 rather than competing with it.

**`systemd-run --user --scope` with `MemoryMax`/`CPUQuota`/`TasksMax`.** The only mechanism here
that gives real cgroup accounting, and the reason it lost is that resource limits were never the
main problem — credential reach was, and a user scope inherits the caller's filesystem view and
environment wholesale. Layering it *under* bwrap for cgroup limits was considered and rejected for
now: it needs a live session bus, which an unattended cron path cannot assume, and
`systemctl --user` cannot be exercised safely from this repo's test suite (see `CLAUDE.md` — a test
that touches the user manager disarms the operator's real nightly timer). Revisit if `RLIMIT_AS`
proves insufficient in practice.

**Docker or Podman.** Docker is the sharpest irony available: membership in the `docker` group is
host-root equivalent, so using the daemon to sandbox would mean handing the gate the very socket
that makes R2 severe. It also needs an image per ecosystem and per toolchain version, and a
`docker run` per gate is far heavier than a process. Podman would avoid the socket problem but is
not installed on this host, and rootless Podman ultimately rests on the same unprivileged user
namespaces bwrap uses directly — the same trust base, with a container runtime stacked on top.

**Raw `unshare` + a hand-built mount namespace.** This is what bubblewrap *is*, minus fifteen years
of people finding the sharp edges: `--die-with-parent`, `--new-session`, correct `/proc` handling,
no setuid helper. Reimplementing it in bash would be strictly worse code with a strictly worse
security record.

**A pre-populated dependency cache mounted read-only instead of `test_net`.** Genuinely stronger —
no egress at all — and rejected as the *default* because it is a separate engineering project per
ecosystem (npm, uv, cargo, each with its own cache layout and integrity model), it needs a
network-enabled population step that runs *somewhere*, and its failure mode is a cache miss that
looks exactly like a broken test. The two compose: a repo whose cache is warm simply never sets
`test_net`, and `NIGHTSHIFT_TEST_SANDBOX_ROBIND` is where such a cache would be mounted. Worth
building for the JS repo specifically; not worth blocking this on.

**A network proxy allowlisting registry hosts.** The right answer eventually, and it needs a proxy
to exist, to be maintained, and to be trusted. `test_net` is the honest one-bit version of it, and
the ADR records that it is one bit.

**Keep `shipping UNGATED` and only sandbox the gate.** This leaves the largest hole open: a repo can
still push a merge-ready branch with no regression check at all, and the sandbox makes that *more*
tempting rather than less ("the gate is annoying to configure now"). Fail-closed has to include the
case where the gate is simply absent, or it is a preference rather than a guarantee.
