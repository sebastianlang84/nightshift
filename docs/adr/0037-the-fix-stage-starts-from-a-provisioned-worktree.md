# ADR 0037 — the Fix stage starts from a provisioned worktree

- Status: accepted; **the Codex toolchain PATH, the pnpm-store setting and `setup_cmd` superseded by [ADR 0044](0044-claude-only-opus-works-a-review-model-reviews.md)** — the Codex adapter was removed on 2026-11-19, and `setup_cmd` on 2026-11-20 because a Claude Fix stage has no shell to use what it installs. The gate's purge of ignored files stays
- Date: 2026-10-02
- Extends: [ADR 0026](0026-the-ship-gate-runs-in-a-sandbox.md) (a second command runs in the gate's sandbox) · [ADR 0028](0028-gate-egress-goes-through-a-vetting-proxy.md) (with the same egress)
- Touches: [ADR 0022](0022-a-repos-own-tests-gate-the-ship.md) (the gate now purges ignored files before it runs) · [ADR 0027](0027-the-reviewed-tree-is-what-ships.md) (a setup may not add to the reviewed tree)

## Context

Codex Fix can execute checks inside its workspace sandbox, but a fresh worktree has no installed
dependencies. Network is disabled and shared package stores may be read-only. A minimal service
PATH can also resolve an older runtime than a project's tools require.

Running setup only inside the final ship gate leaves Fix unable to test while it works.
The runner must provision dependencies before Fix without exposing host credentials or allowing
setup output to become part of the proposed commit.

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

For example, a repository entry can declare `setup_cmd: bash scripts/worktree-setup.sh`.

## Consequences

- Provisioning costs time on every Fix iteration. It enables checks whose dependencies and runtime
  are available inside the Fix sandbox.
- Tests needing listening sockets may still fail in Codex's network-off sandbox. They belong in
  the gate; Docker-dependent integration tests cannot run without separately designed support.
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

Covered by `tests/test-pre-gate-purge.sh` (the purge; the `setup_cmd` cases were removed 2026-11-20), `tests/test-reviewed-tree-ships.sh` and
test-codex-adapter.sh (removed 2026-11-19; its PATH-filter check moved to test-runner-path.sh).
