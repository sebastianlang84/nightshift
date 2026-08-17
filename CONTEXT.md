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
5. both **reviews** and **fixes** — in **v1**, fixes land on isolated `nightshift/*` **branches**,
   never auto-merged; the pushed branch is the unit of review. Opening a PR per branch is
   opt-in and needs per-host API credentials — off by default
   ([ADR 0004](docs/adr/0004-v1-scope-branch-isolated-steward.md));
6. is **budget-aware** — it works until its time/quota window is spent, then checkpoints and stops.

Guiding image: the *Heinzelmännchen* — works at night within its rules, stops when observed / out
of budget. Steady, not heroic.

## Architecture (intended)

Ports-and-adapters. The **core is harness-neutral**; only the runner knows a specific tool.

| Layer | Holds | Portable? |
|-------|-------|-----------|
| **Brain** | selection (explore/exploit), the budget loop, policy evaluation | yes — plain scripts + files |
| **Memory** | the ledger: done / attempted-and-abandoned, per-target, with SHAs, plus `verdict` events from harvest (merged/dropped for branches) and from finding closure (resolved for TODOs, ADR 0021) — the feedback loop | yes — data only (JSONL/sqlite) |
| **Policy** | the rulebook: repo whitelist + per-repo mode, limits, tool allowlist, prohibitions | yes — declarative (YAML/MD) |
| **Runner (adapter)** | invokes the LLM agent headless for one bounded task | **no — harness-specific** |

The Brain never calls `claude` (or `codex`) directly; it calls `run_agent(prompt, cwd, perm, budget)`.
This boundary is what lets nightshift be **Claude-Code-first now, harness-agnostic later** by adding
adapters without touching the core. Known per-harness leak points: the permission model and how to
tell that the budget window is exhausted — both live in the adapter.

## Scope: build the brain, borrow the body

A prior-art survey ([`docs/prior-art.md`](docs/prior-art.md)) found no off-the-shelf fit, but most
pieces exist. So nightshift builds only its **novel core — cross-repo self-prioritization + the
ledger (Brain + Memory)** — and borrows the rest: `claude -p`/Ralph-loop for the runtime,
oss-autopilot's scoring as the selection template, and the existing `nightly-review-pipeline` for
the fix flow.

The decisions behind this live in the ADRs, not here — this section points, it does not restate:

- [ADR 0002](docs/adr/0002-build-the-brain-borrow-the-body.md) — build the brain, borrow the body.
- [ADR 0003](docs/adr/0003-subscription-safe-execution.md) — execution stays on the first-party CLI.
- [ADR 0004](docs/adr/0004-v1-scope-branch-isolated-steward.md) — the v1 cut: branch-isolated output,
  the run pipeline, the budget cap, the force-push hook.
- [ADR 0005](docs/adr/0005-configurable-limits-in-rulebook.md) — per-run bounds in the rulebook.
- [ADR 0022](docs/adr/0022-a-repos-own-tests-gate-the-ship.md) — a repo's own tests gate the ship.
- [ADR 0023](docs/adr/0023-an-unusable-agent-aborts-the-night.md) — an agent that cannot
  authenticate aborts the night; an outage must never forge the record of a clean fleet.
- [ADR 0026](docs/adr/0026-the-ship-gate-runs-in-a-sandbox.md) — that gate *executes* what the Fix
  stage wrote, so it runs in a bwrap sandbox with no credential reach — and a `branch-fix` repo
  without a gate no longer ships ungated, it fails the parse.

## Relationship to `nightly-review-pipeline`

A separate Claude Code skill (`~/.claude/skills/nightly-review-pipeline`) provided the original
"hands": a safe review → test → draft-PR flow with isolated worktrees, dedup, and findings written
into a repo's task file. Nightshift borrows its worktree, orchestration, and review patterns but has
no code dependency on the skill; it supersedes the per-repo memory and PR-first flow with its central
ledger and branch-first workflow ([ADR 0004](docs/adr/0004-v1-scope-branch-isolated-steward.md)).

## Vocabulary

- **steward** — the overnight agent as a whole.
- **work item** — one unit the steward picks: (repo, target, action ∈ {review, fix}).
- **lens** — a kind of review (e.g. bug screen, usability). Borrowed from the pipeline.
- **ledger** — the persistent memory of past work items and their outcomes.
- **rulebook** — the *operator*-authored, agent-read file of what is allowed: repo whitelist and
  per-repo mode, limits, tool allowlist, prohibitions. Read-only to the steward.
  _Avoid_: policy, ruleset.
- **constitution** — a *different* layer from the rulebook: the system prompt shipped with
  nightshift (identity, stakes, prime directives), authored by us rather than the operator.
  Idea-stage, not implemented — see
  [`docs/design/constitution-and-rulebook.md`](docs/design/constitution-and-rulebook.md).
  _Avoid_: using it as a synonym for **rulebook**; the whole point is that they have different
  authors and different mutability.
- **budget window** — the nightly time/quota envelope the steward runs within.

## Non-goals (current)

- No auto-merge, ever. In v1 the output is isolated `nightshift/*` branches; humans review (and
  merge) them in the morning. Opening a PR per branch is an opt-in convenience requiring per-host
  API credentials — off by default; the branch itself is the deliverable
  ([ADR 0004](docs/adr/0004-v1-scope-branch-isolated-steward.md)).
- Not a hosted SaaS; self-hosted, uses your own subscription/key.
- Not a general task runner — scope is review and fix of code in allowed repos.
