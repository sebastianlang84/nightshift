# ADR 0004 — v1 scope: the branch-isolated steward

- Status: accepted
- Date: 2026-07-08

## Context

An unattended maintainer needs a reviewable output boundary before it needs complex learning,
parallel planning, or automatic trust promotion. Isolated branches let the operator inspect and
reject work without changing the base branch. Branch isolation alone does not protect secrets
that could leave the host when a branch is pushed.

## Decision

- The runner produces `nightshift/*` branches and never merges. PR creation is optional and off
  by default. Pushing uses the target's existing Git transport; opening a PR requires separate
  forge API credentials, which may represent a different identity from the SSH transport.
- Stages are separated: Select, Explore, Fix, Review, and Finalize. Each stage gets a fresh
  agent invocation, with handoffs through files and Git. Later ADRs add Recon and Verify.
- The runner enforces Fix/Review iteration limits, branch backpressure, and run budgets.
  `max_open_branches` governs throughput across repositories; a per-run branch ceiling is a
  runaway backstop. [ADR 0025](0025-the-cap-counts-pending-verdicts-not-unmerged-refs.md)
  defines the cap as branches awaiting verdicts rather than all unmerged refs.
- A Git pre-push hook checks resolved refs and refuses destinations outside `nightshift/*`,
  ref deletion, tags, and non-fast-forward updates. Adapter confinement prevents bypasses;
  see [hook-spec.md](../design/hook-spec.md).
- The operator's rulebook defines authorized repositories, `findings-only` or `branch-fix`
  mode, review dimensions, models, and limits. Hard safety constraints live in mechanisms.
- A central append-only ledger records attempts and outcomes. Finding identity prevents repeat
  proposals; [ADR 0014](0014-finding-identity-and-lifecycle.md) defines stable fingerprints.
  Harvest reconciles branches if a run fails between push and ledger append.
- A local digest reports shipped work, abandoned attempts, and empty nights. No notification
  service is required. Telemetry records stage duration and usage without automatically
  changing the operator's policy.

## Consequences

The implementation remains a runner, adapters, rulebook, ledger, confinement hooks, and reports.
A valid outcome is to do nothing. Branch review costs operator time, and pushed code may trigger
remote CI before merge. The sandboxed ship gate and tree-integrity contract are described in
ADRs [0022](0022-a-repos-own-tests-gate-the-ship.md),
[0026](0026-the-ship-gate-runs-in-a-sandbox.md), and
[0027](0027-the-reviewed-tree-is-what-ships.md).

Automatic trust promotion, semantic memory, calibrated value learning, and a general task-plan
executor remain outside this decision. Optional external merging is a separate deployment
choice described in [ADR 0040](0040-optional-external-merge-job.md).
