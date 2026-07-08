# Design note — Self-evaluation

> **⚠️ Superseded by [ADR 0004](../adr/0004-v1-scope-branch-isolated-steward.md).** The pre-flight
> critic-as-gate, the retrospective long-loop (reading human verdicts), and the auto trust-ramp below are
> all **cut from v1**. The value bar is now *soft* — the agent's own justification + confidence, the
> Review stage, and mechanical smallness limits — acceptable because output is branch-isolated and never
> merged. The trust-ramp is a **manual** per-repo `mode` knob (`findings-only` → `branch-fix`) in
> `rulebook.yaml`, not autonomy earned via self-eval. Kept for history.

- Status: **idea-stage, not decided.** Captures the 2026-07-08 discussion for review.
- No implementation details on purpose.

## Idea: the steward checks its own work — on two horizons

The wish: "how was my work? could I have done better?" — both quantitative and qualitative. These
are really **two loops on two time horizons**, not one.

### Short loop — pre-flight critic (before the PR)
A **separate** LLM instance, with a critical prompt and a concrete rubric, judges the diff *before*
it goes out as a draft-PR: "would a senior engineer merge this? Is the scope right? Is this noise?
Is it reversible?" If it falls below the value bar → **abandon + backlog, do not ship.**

- This is simultaneously the answer to the anti-churn value bar (OPEN-QUESTIONS §5).
- Fresh context = less self-confirmation bias than grading yourself in the same thread.

### Long loop — retrospective (each morning / weekly)
The agent reads the ledger **plus the human verdicts** (was the PR merged? closed? edited?) and
writes a self-assessment into semantic memory: "my usability suggestions on repo X get ignored →
down-weight that lens." This **closes the loop** — it feeds back into score & cadence. This is the
literal "could I have done better?".

- The quantitative side (acceptance-rate per repo/lens, diff size, CI outcomes) is where
  **autoresearch** could mine the ledger for patterns.

## Idea: the honesty caveat (important)

LLM self-evaluation has known bias (self-preference, sycophancy). So:

- The critic judges the **artifact** (the diff/PR against a rubric), not an abstract "was I good".
- The **human verdict (merged/closed)** is ground truth and outweighs any self-praise. Metrics beat
  self-report where available.
- Otherwise the agent optimises itself into an echo chamber.

## Bonus ideas raised

- **Escalation mode:** when uncertain, do *not* act — write a question into the digest ("should I
  touch the CI config in repo X?"). A "do-nothing-but-ask" path.
- **Trust-ramp via self-eval** (OPEN-QUESTIONS §7): a new repo starts review-only; only once the
  retrospective shows enough acceptance does it graduate to fix-mode. Autonomy is *earned*, not
  granted.

## Open decision (do not resolve yet)

- **May the retrospective adjust the selection weights *live* (full autonomy, the agent turns its
  own dials), or only *propose* adjustments a human approves in the morning?** Recommendation:
  default to *propose-only* on an enterprise server; make *live self-adjust* unlockable via
  `rulebook.md`. — *user to decide.*

_Related: [memory-model.md](memory-model.md) (retrospective writes into semantic memory),
[execution-modes.md](execution-modes.md), [constitution-and-rulebook.md](constitution-and-rulebook.md),
OPEN-QUESTIONS §5 & §7._
