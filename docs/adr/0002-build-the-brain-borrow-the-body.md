# ADR 0002 — Build the brain, borrow the body

- Status: accepted (design phase)
- Date: 2026-07-08

## Context

A prior-art survey ([`docs/prior-art.md`](../prior-art.md)) found no self-hostable product that
covers all 7 requirements. The capabilities split cleanly:

- **Solved and borrowable:** review/fix quality (Qodo PR-Agent, Sweep, OpenHands), the budget/test
  gate (MartinLoop), the DIY overnight runtime (Ralph-loop on `claude -p`), multi-repo scheduling
  patterns (Aeon, Renovate), and repo-scoring heuristics (oss-autopilot).
- **Unsolved by anyone as a product:** cross-repo **self-prioritization** ("scan N of my repos,
  score candidate work, pick what's due") plus a **dedicated ledger** that makes progress *across
  nights* instead of repeating. Every review bot is PR-triggered; every coding agent is task-driven.

## Decision

Do not build a monolith. **Build only the orchestration brain — cross-repo self-prioritization +
ledger — and borrow the body:**

- **Runtime:** `claude -p` headless in the Ralph-loop pattern (see ADR 0001 adapter boundary; ADR
  0003 for the subscription-safe constraint).
- **Budget + test gate:** MartinLoop (or an equivalent wrapper) for the per-run `--budget`/`--verify`.
- **Prioritization heuristics:** adapt oss-autopilot's repo-scoring approach to our own repos.
- **Fix mechanism:** reuse the existing `nightly-review-pipeline` skill's safe review → test →
  draft-PR flow where possible (resolve reuse-vs-supersede in a later ADR; OPEN-QUESTIONS #8).

## Consequences

- Scope shrinks dramatically: the novel code is the selector + ledger + policy glue, not agents,
  budget wrappers, or PR machinery.
- We take on integration risk with 3–4 external pieces (their licenses/maturity must be verified
  before depending on them).
- The design must keep the borrowed pieces behind seams so any one can be swapped (fits ADR 0001).
