# nightshift — context & concept

Canonical description of what nightshift is and the language we use for it. Keep this current;
decisions that change the design should land here and as an ADR under `docs/adr/`.

## Problem

Coding subscriptions (Claude Code, OpenAI Codex, …) include large usage windows that sit idle
overnight. Meanwhile, repositories accumulate latent bugs, rough edges, and small improvements
that never rise to the top of a human's day. nightshift turns idle nighttime capacity into
steady, low-risk, reviewable improvement across several repositories.

## Concept

An **unattended overnight steward**. Given a set of repositories it is allowed to touch, it:

1. runs on a schedule (nightly), with no human watching;
2. works across **multiple** repos and **self-selects** what to review or fix next;
3. keeps a **persistent memory (ledger)** of what it did, so it does not repeat work;
4. obeys a **configurable rulebook** (allowed repos, tools, change-size limits, hard "don't touch");
5. both **reviews** and **fixes** — fixes land as test-gated **draft PRs**, never auto-merged;
6. is **budget-aware** — it works until its time/quota window is spent, then checkpoints and stops.

Guiding image: the *Heinzelmännchen* — works at night within its rules, stops when observed / out
of budget. Steady, not heroic.

## Architecture (intended)

Ports-and-adapters. The **core is harness-neutral**; only the runner knows a specific tool.

| Layer | Holds | Portable? |
|-------|-------|-----------|
| **Brain** | selection (explore/exploit), the budget loop, policy evaluation | yes — plain scripts + files |
| **Memory** | the ledger: done / attempted-and-abandoned, per-target, with SHAs | yes — data only (JSONL/sqlite) |
| **Policy** | the rulebook: repo whitelist + per-repo mode, limits, tool allowlist, prohibitions | yes — declarative (YAML/MD) |
| **Runner (adapter)** | invokes the LLM agent headless for one bounded task | **no — harness-specific** |

The Brain never calls `claude` (or `codex`) directly; it calls `run_agent(prompt, cwd, perm, budget)`.
This boundary is what lets nightshift be **Claude-Code-first now, harness-agnostic later** by adding
adapters without touching the core. Known per-harness leak points: the permission model and how to
tell that the budget window is exhausted — both live in the adapter.

## Scope: build the brain, borrow the body

A prior-art survey ([`docs/prior-art.md`](docs/prior-art.md)) found no off-the-shelf fit, but most
pieces exist. So nightshift builds only its **novel core — cross-repo self-prioritization + the
ledger (Brain + Memory)** — and borrows the rest: `claude -p`/Ralph-loop for the runtime, a wrapper
like MartinLoop for the budget/verify gate, oss-autopilot's scoring as the selection template, and
the existing `nightly-review-pipeline` for the fix flow. See [ADR 0002](docs/adr/0002-build-the-brain-borrow-the-body.md).
Execution stays on the **first-party CLI** (subscription-safe, not a custom API wrapper) —
[ADR 0003](docs/adr/0003-subscription-safe-execution.md).

## Relationship to `nightly-review-pipeline`

A separate Claude Code skill (`~/.claude/skills/nightly-review-pipeline`) already implements the
"hands": a safe review → test → draft-PR flow with isolated worktrees, dedup, and findings written
into a repo's task file. nightshift is the "brain" on top: self-direction, memory, and policy. The
open question is whether nightshift *reuses* that pipeline as a tool or supersedes it — see
`OPEN-QUESTIONS.md`.

## Vocabulary

- **steward** — the overnight agent as a whole.
- **work item** — one unit the steward picks: (repo, target, action ∈ {review, fix}).
- **lens** — a kind of review (e.g. bug screen, usability). Borrowed from the pipeline.
- **ledger** — the persistent memory of past work items and their outcomes.
- **rulebook / constitution / policy** — the human-authored, agent-read rules of what is allowed.
- **budget window** — the nightly time/quota envelope the steward runs within.

## Non-goals (current)

- No auto-merge, ever. Humans review the morning-after PRs.
- Not a hosted SaaS; self-hosted, uses your own subscription/key.
- Not a general task runner — scope is review and fix of code in allowed repos.
