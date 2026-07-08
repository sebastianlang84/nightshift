# Design note — Constitution, rulebook, and enforcement

- Status: **idea-stage, not decided.** Captures the 2026-07-08 discussion for review.
- No implementation details on purpose.

## The problem this addresses

We want to lean on modern-LLM intelligence for **maximum autonomy** — but an agent that acts
unattended overnight is only acceptable if "be careful" is more than a hope. In v1 the habitat is
**the owner's own repositories** (not a production / enterprise server — that story is explicitly
deferred, [ADR 0004](../adr/0004-v1-scope-branch-isolated-steward.md)), and the load-bearing safety
property is not a prompt at all: output can only ever land on isolated `nightshift/*` branches —
**never a PR, never a merge** — and that confinement is enforced mechanically by the git hook in
[hook-spec.md](hook-spec.md), not by the agent's goodwill. A bad change is therefore a branch the
owner deletes, not an incident.

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
  is human-reviewable in the morning as an isolated `nightshift/*` branch — never a PR, never merged.
- **Motivation:** steady, low-risk improvement. The diligent *Heinzelmännchen* — steady, not heroic.
- **Avoid:** noise/churn (trivial diffs that cost review time), risky/irreversible changes,
  forbidden zones, work outside the budget.
- **Stakes & the guiding asymmetry:** *"These are the owner's own repositories, and your output is
  an isolated branch that is never merged, so a bad change is cheap to throw away. But your work is
  reviewed by a human in the morning, and their time is not free. The cost of a **missed**
  improvement is zero; the cost of noise — a trivial or wrong change that costs review time — is
  real. When in doubt: **do nothing and log why.**"*

That asymmetry is the one sentence that makes autonomy *safe*: the agent is always allowed to do
**nothing**.

## `rulebook.md` — what an operator can set (idea-level)

> **Note:** this is the original idea-level wish-list. The ratified v1 rulebook is narrower — a
> minimal `rulebook.yaml` (allowed repos, per-repo `mode` = `findings-only` | `branch-fix`, and
> limits) per [ADR 0004](../adr/0004-v1-scope-branch-isolated-steward.md) and
> [documentation-system.md](documentation-system.md). In particular: output is **branches, not PRs**
> (so "fix-PR" / "max PRs per night" read as branch modes / `max_branches_per_night`); execution
> modes and live weight self-adjust are **cut**; and hard prohibitions live in the git hook
> ([hook-spec.md](hook-spec.md)), not the rulebook.

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
