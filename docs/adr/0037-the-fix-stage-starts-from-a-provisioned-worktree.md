# ADR 0037 — the Fix stage starts from a provisioned worktree

- Status: accepted
- Date: 2026-10-02
- Extends: [ADR 0026](0026-the-ship-gate-runs-in-a-sandbox.md) (a second command runs in the gate's sandbox) · [ADR 0028](0028-gate-egress-goes-through-a-vetting-proxy.md) (with the same egress)
- Touches: [ADR 0022](0022-a-repos-own-tests-gate-the-ship.md) (the gate now purges ignored files before it runs) · [ADR 0027](0027-the-reviewed-tree-is-what-ships.md) (a setup may not add to the reviewed tree)

## Context

Since 2026-09-30 every partflow stage runs on codex. Its Fix stage can execute commands inside the
worktree (`--sandbox workspace-write`, network off), so it tries to run the repo's own checks before
it hands back a change. On the night of 2026-10-01 it could not run any of them. Its seven notes in
`state/agent-notes.md` say why, and `codex sandbox` with the launcher's PATH reproduces each part:

- `node` resolves to `/usr/bin/node` v18.20.6. The launcher keeps the system directories first on
  purpose (R10/N4) and gives the nvm toolchain only to the gate (`NIGHTSHIFT_TEST_PATH`) and to pi
  (`NIGHTSHIFT_PI_PATH`). partflow's pnpm 11 refuses to start below Node 22.13.
- A fresh worktree has no `node_modules`. partflow installs them per worktree with
  `scripts/worktree-setup.sh`, which a Claude Code session hook runs; nightshift ran it only inside
  the ship gate, as the first part of `test_cmd`.
- The Fix stage cannot install them itself. Its sandbox has no network (DNS fails) and cannot write
  `~/.local/share/pnpm/store` ("Read-only file system").

The ship gate was not affected: the night's log shows all five gates passing on node v24.13.0 after
a full install. What never ran was everything the gate does not run — typecheck, lint, the
Postgres integration suites — and every check the Fix stage meant to use while it worked. Two of the
five branches were dependency upgrades with lockfiles edited by hand.

The pi nights before that (2026-09-25 note) reported the same missing `node_modules`, but pi's Fix
stage has no shell at all, so installed dependencies would not have helped it.

## Decision

**A repo may declare a `setup_cmd`. The Runner runs it in the ship gate's sandbox, over the
worktree, before every Fix stage. The gate purges every ignored file before it runs. The codex
subprocess gets the repo's toolchain first on its PATH.**

- **The setup runs where the gate runs.** `gate_exec` is the gate's execution half, factored out:
  the same bwrap sandbox (no `$HOME`, no credentials, writable only the worktree and a disposable
  HOME) and the same vetting proxy when the repo has `test_net`. No new execution context exists,
  and the Fix stage's own sandbox is not widened at all: it still has no network and still cannot
  write outside the worktree.
- **An aid, not a gate.** A failed setup is logged and the Fix stage runs anyway. Two failures do
  refuse the item: a `.git` pointer the setup rewrote (R15, as in the gate), and a setup that
  changed tracked or un-ignored files. Those changes would be staged as the Fix stage's own change
  and committed under its name. The comparison is by bytes, type and permission bits of every
  file `git add -A` would stage. A status comparison misses a rewrite of a file the Fix stage
  already modified, and a tree id misses a rewrite that `.gitattributes` normalises away.
- **The gate does not trust what a stage left.** Installed dependencies sit in a worktree the Fix
  stage can write, and `pnpm install --frozen-lockfile` keeps a `node_modules` it finds instead of
  re-verifying it. So the gate first runs `git clean -ffdX` and refuses the item if any ignored file
  survives, if a submodule path is not empty, or if any directory in the worktree cannot be read
  and searched (git skips such a directory with a warning and exit 0). Neither `git clean` nor `git ls-files` looks inside
  a submodule path, every worktree starts with its submodules uninitialised, and a file a stage
  wrote there would otherwise reach the suite unseen. That hole predates this ADR; the purge is
  where it gets closed. A fresh worktree holds no ignored file, so every gate starts from the state the first
  one always had. This also closes the same hole for the second fix iteration, where the previous
  gate's own install had been left behind.
- **The toolchain.** The launcher exports `NIGHTSHIFT_CODEX_PATH` (the nvm bin directory, as for
  pi), and `codex_run` prepends it for the codex subprocess alone. The binary is resolved first, so
  that directory cannot decide which `codex` runs.
- **pnpm's store.** Inside the sandbox, HOME is a separate mount, so pnpm puts the setup's store in
  `<worktree>/.pnpm-store`. Outside it, pnpm 11 would resolve the shared store and reinstall before
  every `pnpm run`/`exec`, which fails on the read-only store. When that directory exists, the codex
  Fix stage gets `pnpm_config_store_dir` pointing at it. The store is inside the worktree, the repo
  ignores it, and the gate purges it.

partflow's entry gets `setup_cmd: bash scripts/worktree-setup.sh`.

## Consequences

- Measured on a partflow worktree, 2026-10-02: the setup takes about 95 s per Fix iteration. Inside
  the codex sandbox, with node v24.13.0, backend typecheck, frontend typecheck, frontend lint and
  all 72 frontend test files pass. 72 of 89 backend suites pass.
- The other 17 backend suites open a listening socket, which codex's network-off sandbox forbids
  (`listen EPERM`). They run only in the gate. The Postgres integration suites still run nowhere in
  a night, because neither sandbox can reach Docker.
- Every gate after the first installs from a cold store again, where it used to reuse the previous
  gate's `node_modules`. That costs time, and it is what makes the gate's result describe the
  lockfile.
- The setup runs for every adapter. It helps only one whose Fix stage executes commands (codex
  today). On a claude or pi night it costs time and buys nothing, so leave `setup_cmd` unset there.
- The pnpm store setting is package-manager knowledge in the codex adapter. It is the one place
  where the sandbox's mount layout and the host's layout disagree, and it does nothing when the
  directory does not exist.
- A test whose state survived between gates in an ignored file no longer works.
  `test-ship-test-gate.sh` keeps that marker outside the worktree, unsandboxed.
- Since the gate now runs on a worktree it just cleaned, its after-run check (ADR 0027) also
  refuses what git's own comparison cannot see: a byte change that `.gitattributes` normalises
  away, a directory made unreadable, and files inside an uninitialised submodule path.
- The Runner keeps only absolute `PATH` entries. It runs commands after `cd` into a worktree a
  stage can write, where a relative entry would resolve to a planted binary.

Covered by `tests/test-fix-stage-provisioning.sh`, `tests/test-reviewed-tree-ships.sh` and
`tests/test-codex-adapter.sh`.
