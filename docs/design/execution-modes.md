# Design note — Execution modes & the self-chaining governor

> **⚠️ Superseded by [ADR 0004](../adr/0004-v1-scope-branch-isolated-steward.md).** The chain/parallel
> modes and the agent-proposed `{mode, items[], depth}` plan below are **cut from v1**. The pipeline is
> instead a fixed sequence of separated single-job runs, and the only self-chaining is the `Fix ⟷ Review`
> loop, capped at N iterations **by the runner** (not the agent). Kept for history / possible revival.

- Status: **idea-stage, not decided.** Captures the 2026-07-08 discussion for review.
- No implementation details on purpose.

## Idea: let the agent choose *how much* to run, within a hard limit

The agent should be able to decide the number of runs (up to a cap) and pick the tasks freely.
These map onto the outer budget loop (OPEN-QUESTIONS §4): `{pick → bounded run → record}`. The
"modes" are just shapes of that loop:

- **single** — one bounded run, done.
- **chain** — sequential self-spawn: a run ends → chooses the next task → spawns a successor (up to
  N, e.g. 6). Each link runs in a **fresh context** (Ralph-loop); the ledger carries state between
  links.
- **parallel** — fan out over K *distinct* work-items (distinct repos/worktrees), bounded concurrency.

Budget-dependent mode selection is natural: low budget → force single; plenty → allow parallel.

## Idea: the governor — the non-negotiable safety piece

An agent that can freely self-spawn on an enterprise server is a **fork / budget bomb**. So
self-chaining is **mechanically bounded**, never by the agent's goodwill:

- The agent only **proposes** a plan `{mode, items[], depth}`. The **runner enforces** the caps and
  actually spawns. The agent **never** calls `claude -p` on itself.
- Caps: max chain-depth (e.g. 6), max parallel fan-out (e.g. 3), max runs/night, and finally the
  **budget window** as the ultimate ceiling.
- Every spawn is logged to the ledger **before it starts**, so a runaway is visible and killable.
- **Parallel only across distinct repos** (avoids worktree/branch collisions; the ledger is
  append-only = safe, but `notes.md` compaction must stay serialised).

## Idea: who decides what

- **Mode *availability*** = policy. `rulebook.md` can force "single only, depth=1" on a locked-down
  server.
- **Mode *selection*** within what's allowed = the Brain.
- **Enforcement** of the caps = the Runner/adapter (fits the ADR 0001 boundary — the spawn cap is a
  per-harness leak point that belongs in the adapter).

## Open decisions (do not resolve yet)

- Default cap values (depth 6? fan-out 3?) — placeholders, not decisions.
- Is parallel-mode on by default, or opt-in per rulebook?
- Does "the agent picks the next task" need a human-set menu of allowed task *kinds*, or is it free
  within the lens set?

_Related: [self-evaluation.md](self-evaluation.md) (a chain link can be a critic pass),
[constitution-and-rulebook.md](constitution-and-rulebook.md), OPEN-QUESTIONS §4._
