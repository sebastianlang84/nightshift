# Design note — Constitution, rulebook, and enforcement

- Status: **idea-stage, not decided.** Captures the 2026-07-08 discussion for review.
- No implementation details on purpose.

## The problem this addresses

We want to lean on modern-LLM intelligence for **maximum autonomy** — but the target could be a
**production / enterprise server** where the highest caution and strict rules are mandatory. An
autonomous agent that can act unattended overnight is only acceptable if "be careful" is more than
a hope.

## Idea: three layers, defence-in-depth

Safety is **not** a single prompt. Three layers, each stricter than the last:

| Layer | What it holds | Who authors it | Agent may change it? |
|---|---|---|---|
| **Constitution (system prompt)** | identity, motivation, stakes, prime directives | *us* (ships with nightshift) | no |
| **`rulebook.md`** | deployment policy: allowed repos, prohibitions, limits, tool allowlist | *the operator* (enterprise tightens) | no — read only |
| **Hard enforcement** | branch protection, worktree isolation, allowlist, `--max-turns`, budget cap, spawn governor | the runner/adapter | **cannot be bypassed** |

**Precedence:** the rulebook may only make the constitution *stricter*, never looser. The critical
rules (never `main`, never secrets/CI/deps, no force-push, no deletes) are **mechanically enforced**,
not left to the agent's goodwill. Prompt = intent; enforcement = guarantee.

## Idea: the four pillars of the constitution

The system prompt should ground the agent in *why it exists and what is at stake*, not just tasks:

- **Responsibility:** every repo leaves the night *better or unchanged* — never worse. Every change
  is human-reviewable in the morning (draft-PR, never a merge).
- **Motivation:** steady, low-risk improvement. The diligent *Heinzelmännchen* — steady, not heroic.
- **Avoid:** noise/churn (trivial diffs that cost review time), risky/irreversible changes,
  forbidden zones, work outside the budget.
- **Stakes & the guiding asymmetry:** *"This may be a production / enterprise server. A bad
  autonomous change, while nobody is watching, is expensive and destroys trust. The cost of a
  **missed** improvement is zero; the cost of a bad merge-able change is high. When in doubt: **do
  nothing, log it, defer to the backlog."*

That asymmetry is the one sentence that makes autonomy *safe*: the agent is always allowed to do
**nothing**.

## `rulebook.md` — what an operator can set (idea-level)

- Repo whitelist + per-repo mode (review-only vs. fix-PR).
- Prohibitions: no `main`, no secrets/CI/deps, no deletes, no force-push, "don't touch" globs.
- Change-size limits: max lines/files per PR, max PRs per night.
- Tool allowlist.
- Which **execution modes** are permitted (see [execution-modes.md](execution-modes.md)) — e.g. a
  locked-down server forces single-mode only.
- Whether the agent may **self-adjust** its selection weights or only *propose* adjustments
  (see [self-evaluation.md](self-evaluation.md)).

## Open decisions (do not resolve yet)

- How much may the agent *interpret* rules vs. how much is hard-enforced? (OPEN-QUESTIONS §3.)
- Does the constitution ship as one file (`SYSTEM-PROMPT.md`) or as composable fragments?
- Enterprise default posture: assume most-restrictive unless the rulebook opens things up?

_Related: [memory-model.md](memory-model.md), [execution-modes.md](execution-modes.md),
[self-evaluation.md](self-evaluation.md), OPEN-QUESTIONS §3._
