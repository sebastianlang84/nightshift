# ADR 0013 — wall-clock spend budget

- Status: accepted
- Date: 2026-07-12
- Resolves: [OPEN-QUESTIONS.md §2 "Spend control"](../../OPEN-QUESTIONS.md)

## Context

Open-branch backpressure and the per-run branch ceiling bound *output* (how many branches land), not
*consumption* (subscription/compute spent). v2 added a Recon stage and processes several findings per
Explore, so a night can spend materially more before hitting an output cap. The operator needs a real
budget signal that ends the night deliberately rather than running until the subscription window
closes mid-mutation.

Constraints (already decided): execution stays on first-party CLIs (`claude`, `codex`) with no
metered API ([ADR 0003](0003-subscription-safe-execution.md)); operator limits live in the rulebook
([ADR 0005](0005-configurable-limits-in-rulebook.md)); exhaustion must be explicit in ledger/digest,
never a silent partial run.

## Decision

**The budget unit is wall-clock time for the whole night.**

1. **Unit — wall clock.** It is the one signal that behaves identically for both first-party CLIs
   without switching to a metered API. Token counts are recorded per stage (telemetry) but are *not*
   the enforced limit: their availability and meaning differ across CLIs and subscription plans, so
   enforcing on them would be unreliable and adapter-specific. Turns are per-stage, not a night-level
   budget. Time is universal, monotonic, and operator-legible ("stop after ~4h").
2. **Scope — the whole night.** One budget for the run, matching the subscription-window framing.
   Not per-repo/adapter/stage: those add knobs without a matching operator need in v1.
3. **Configuration.** `limits.max_run_minutes` in the rulebook (empty ⇒ no cap, preserving current
   behavior). `NIGHTSHIFT_MAX_RUN_SECONDS` overrides it (finer unit; also the deterministic test
   hook). The parser validates a present `max_run_minutes` as a positive integer (fails closed).
4. **Exhaustion behavior — stop before the next mutation.** The budget is checked at the top of each
   pass and again immediately before each fix (the only mutating stage). A read-only stage already in
   flight finishes; findings surfaced this pass stay recorded; but no new branch/fix starts once the
   budget is spent. The run ends with `stop_reason=budget`, surfaced in the digest scoreboard
   ("Stopped: time budget exhausted") and the night-done log.

## Consequences

- A night now has three explicit stop reasons: `backpressure` (open-branch cap), `budget` (time), and
  running out of shippable work — each logged and visible in the digest.
- Enforcement is coarse (checked between stages, not mid-agent): a single long agent invocation can
  overrun the budget by up to one stage. Acceptable for v1 — the goal is a deliberate nightly ceiling,
  not hard real-time preemption.
- Token/cost remain observable in `state/runs.jsonl` for later analysis; a token-based budget can be
  layered on if a reliable cross-CLI signal emerges, without changing this decision's shape.
