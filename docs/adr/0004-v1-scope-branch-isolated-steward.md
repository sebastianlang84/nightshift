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
(`findings-only` | `branch-fix`), and limits (`max_branches_per_night`, `max_open_branches`,
`max_files/lines_per_change`, `branch_prefix`). Hard prohibitions live in the hook, not here. The
mode knob **is** the trust-ramp (OQ §7), reduced to a manual per-repo edit — no auto-graduation.

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

## Amendments (post fable re-review, 2026-07-08)

Decisions taken while working through `docs/design/fable-rereview-2026-07-08.md`. Appended, not
rewritten, so the evolution stays traceable.

- **Open-branch cap = the sole throughput cap (backpressure).** `max_open_branches` (default **2**,
  a rulebook knob) = the max number of *unmerged* `nightshift/*` branches allowed to exist at once,
  across all repos, counted live from the real remote each iteration. It is **not** a per-night
  production count: merging/closing a branch frees a slot and work resumes, so continuous review lets
  it run all night; when the human stops merging it fills to the cap and stops. This one mechanism
  closes three re-review findings at once: **§2d** (litter bounded), **§5** (production self-throttles
  to zero on neglect — the human's harvesting *is* the feedback signal), and **§3e** (counting
  *remote* branches reconciles against reality, not the ledger's stale "pushed" record).
- **§5 (value measurement) resolved for v1 → do not build it.** With learning / retrospective /
  trust-ramp cut, nothing in v1 consumes a human verdict, so recording one is YAGNI. Value judgment
  is the human's responsibility; if they stop harvesting, the branch cap makes the system idle and
  that neglect is itself the signal to turn nightshift off. Revisit only if learning returns.
- **Finding-identity survives and is still required (§1.7).** The branch cap governs *throughput*;
  it does not prevent *repetition*. A crude finding-identity rule (e.g. file path + finding type +
  line-window) is needed by night two so a human-rejected (deleted) branch is not re-proposed.
- **Branch-only is now mechanically enforced (§2a) → [`hook-spec.md`](../design/hook-spec.md).**
  A git `pre-push` hook checks the *resolved* refs (immune to the `+`/`:`/`--all`/`--mirror`
  spellings) and rejects anything outside `refs/heads/<branch_prefix>*`, plus deletes and tags; a
  thin Claude `PreToolUse` hook only blocks disabling that hook (`--no-verify`, `core.hooksPath`
  overrides). Merge becomes impossible (it needs a push to `main`). This turns the load-bearing
  branch-only claim from a promise into a guarantee.
- **Budget unit (§1.1) — corrected 2026-07-09.** Earlier this amendment had a per-night production
  cap (`max_branches_per_night: 2`); that was wrong and is **removed**. There is no per-night
  production count. Throughput is governed solely by the open-branch cap above (unmerged branches
  lying around). Internal per-stage `claude -p` calls stay bounded by the per-run limits; a safety
  ceiling (`NIGHTSHIFT_MAX_RUN_BRANCHES`, default 50) guards against a runaway if the open-count ever
  misreads. True continuous overnight operation is otherwise bounded by the subscription 5h window.
- **Operational telemetry (not value-learning).** A new append-only `state/runs.jsonl`, written by
  the **Runner** (see [`documentation-system.md`](../design/documentation-system.md)), records one
  line per stage invocation: stage, model, start, duration, tokens (from the CLI's `--output-format
  json` usage where available), exit. This is resource/time instrumentation — distinct from the §5
  value-verdict learning that stays deferred. v1 *records* these stats (and summarises them in the
  digest) but does **not** auto-act on them; the human reads and tunes.

- **Finding-identity rule (§1.7 resolved).** Two findings are "the same" if they share **file +
  issue-type + line-window** (not prose wording). This fingerprint is stored *in the ledger row*, so
  an abandoned/rejected finding is not re-proposed.
- **Ledger ownership gaps (§3a–c) — prototype defaults.** (a) No separate `abandoned.jsonl`: an
  abandoned finding is a `ledger.jsonl` row with `outcome: abandoned|deferred` + the fingerprint;
  Select filters the ledger (resolves the dual-write). (b) The distilled/"already-done-here" views
  are built **in-memory by the Runner** per run, never stored (§3b). (c) Finalize order is *push
  first, then append*; on startup the Runner reconciles real remote `nightshift/*` branches against
  the ledger to catch a crash between the two (§3c).
- **Cold-start selection — prototype default.** Night one runs against an empty ledger; the selector
  picks by recent git activity (most-recently-changed repo/files) with round-robin across repos as
  the tiebreak. Good enough to prototype; refine with real signal later.

Still open (non-blocking for the prototype): the non-git shell scope (§2b); mechanical NIGHTSHIFT.md
enforcement at Finalize (§3d); the `findings-only` landing path (§2e); and the doc-corpus sweep of
statements this ADR overruled (§1.2, §1.4, §1.6, §1.8, §3f) — tracked as a separate cleanup task.
