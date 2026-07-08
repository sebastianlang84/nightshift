# ADR 0004 — v1 scope: the branch-isolated steward

- Status: accepted (design phase)
- Date: 2026-07-08

## Context

The design notes captured many good ideas but left the core tensions (OPEN-QUESTIONS §1, §4, §5,
§7) open, and the fable review (`docs/design/fable-review-2026-07-08.md`) flagged that much of the
safety apparatus — value-bar calibration, shadow-nights, a calibrated pre-flight critic, two-tier
semantic memory, chain/parallel modes — was solving problems that only exist if bad output can reach
a human as something merge-able.

A 2026-07-08 working session collapsed most of that complexity with one decision about the output
boundary: **nightshift never merges and never opens PRs in v1 — it only pushes to `nightshift/*`
branches.** Once output is branch-isolated and human-reviewed at leisure, a bad change is a branch
you delete, not an incident. The value-bar stops being a *safety* problem and becomes a *quality /
taste* problem, which does not need calibration machinery to be acceptable.

## Decision

v1 is a deliberately small, branch-isolated steward. Concretely:

**North star — value-per-night (OQ §1, §5).** The selector optimises for expected value, not
coverage; "do nothing" is a first-class success outcome. The value bar in v1 is *soft*: the agent's
own justification + confidence, the Review stage as a quality check, and mechanical smallness limits
— acceptable precisely because nothing merges. No shadow-nights, no calibrated critic-as-gate.

**Output — branches only, never PRs, never merge (v1).** Work lands on `nightshift/*` branches with
documenting commit messages. This refines CONTEXT.md's "test-gated draft PRs"; PRs may return later
as an option.

**Pipeline — separated single-job runs.** `Select → Explore → Fix ⟷ Review → Finalize`, each a
fresh headless `claude -p`; hand-off is via files/git (per
[documentation-system.md](../design/documentation-system.md)). Exploration uses sub-agents so the
file-heavy survey stays in throwaway contexts. The `Fix ⟷ Review` loop is capped at N iterations,
enforced by the **runner**, not the agent. This supersedes the chain/parallel modes and the
agent-proposed `{mode, items[]}` plan in `execution-modes.md` (fable kill-list §3.1, §3.2).

**Budget (OQ §4).** A hard cap of `max_runs_per_night` (small, e.g. 1–3) is the primary control,
plus per-run bounds (`--max-turns`, wall-clock) with **auto-compact off** so a run hard-stops instead
of compacting past its ceiling. Usage-window observation (ADR 0003) is a backstop, not the mechanism.
This supersedes "MartinLoop as the budget gate" (ADR 0002); the verify idea survives only as a
CI-green check in Review (resolves the ADR 0002 vs 0003 contradiction fable §2 flagged).

**Safety — mechanism, not promise.** Unattended permission mode (no prompts) **+** a PreToolUse hook
that hard-blocks *only irreversible* git operations (`push --force`, `--force-with-lease`, ref/branch
deletes). Normal pushes — including to `main` — are allowed: on the owner's own repos a wrong push is
reversible, so we do not block it; we block only what a revert cannot undo. This refines
`constitution-and-rulebook.md`'s "never main" to "never irreversibly."

**Habitat — the owner's own repos.** Prompt-injection hardening and the enterprise/multi-owner story
are explicitly **out of v1** (fable §2, kill-list §4); documented as a boundary, revisited when
foreign repos enter scope.

**Documentation & state** — as ratified in [documentation-system.md](../design/documentation-system.md):
central append-only `ledger.jsonl`, derived per-repo views, `runs/` hand-off, derived morning digest.

**Rulebook (OQ §3)** — a minimal `rulebook.yaml`: allowed repos, per-repo `mode`
(`findings-only` | `branch-fix`), and limits (`max_runs_per_night`, `max_files/lines_per_change`,
`branch_prefix`). Hard prohibitions live in the hook, not here. The mode knob **is** the trust-ramp
(OQ §7), reduced to a manual per-repo edit — no auto-graduation.

**Morning digest (OQ §6)** — a derived `digests/<date>.md`, file-only in v1 (no push/notification).
Reports both shipped branches (repo, what, why, confidence) **and** what was considered-but-abandoned
and why (fable's "do-nothing report"), so restraint is observable. Empty nights still get one.

**Reuse `nightly-review-pipeline` (OQ §8)** — borrow its proven *patterns* (worktree isolation, the
`claude -p` orchestration shape, the review lenses); supersede its per-repo task-file memory (→ the
central ledger) and its draft-PR flow (→ branches). No code dependency; it is a skill, not a library.

## Consequences

- The novel code shrinks to: the Brain (select + budget loop + iteration governor), the ledger, the
  rulebook parser, the hook, and the digest generator. Everything else is prompt + borrowed pattern.
- Dropped from v1 (revisit later, not deleted as ideas): PRs, shadow-nights, calibrated critic,
  semantic-memory tier, reflect/compaction, chain/parallel modes, live weight self-adjustment,
  auto trust-ramp, enterprise habitat, MartinLoop budget gate.
- Still open, non-blocking: the ledger staleness rule (finding-hash / file-SHA), and verifying the
  exact `claude -p` flags for sub-agents / auto-compact-off at build time.
- Because output is branch-isolated, the whole system can be built and run against the owner's own
  repos with acceptable risk before any of the deferred hardening exists.
