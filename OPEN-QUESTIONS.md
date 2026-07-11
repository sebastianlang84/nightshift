# Open questions

The design tensions we still need to resolve. Move each to an ADR once decided.

## 1. Selection — how does the steward choose work? (explore vs. exploit)
**RESOLVED (ADR 0004): north star = value-per-night**, not coverage. Selector optimises expected
value; "do nothing" is a success outcome. Signals/scoring detail deferred to build.
Pure random is wasteful; pure signal-driven (churn, missing tests, TODO/FIXME, open backlog)
misses new ground. What is the balance, and what signals feed it? The ledger is the anti-repeat
mechanism. **North star to settle first:** value-per-night (few high-value changes) vs. coverage
(systematically touch everything) — this largely determines the selection design.
_Reference: oss-autopilot's repo score (1–10) + threshold + skip-rules is a concrete model to adapt
(see prior-art.md). This selector + the ledger (§2) is the novel core we are building (ADR 0002)._

## 2. Memory — what exactly does the ledger store, and where?
Proposed: append-only `(repo, target, action, outcome, PR, SHA, timestamp)`, plus an explicit
"attempted & abandoned" set so the same false positive is not retried nightly. Entries go stale
when a file's SHA changes. Central store vs. per-repo? File format (JSONL vs. sqlite)?
_References: Aeon uses `MEMORY.md` + reflect/flush; nodeglobal/agents uses SQLite; Ralph-loop uses
the filesystem/git/TODO as the substrate. Pick per format decision above._
**Elaborated:** [`docs/design/memory-model.md`](docs/design/memory-model.md) — two-tier
(episodic JSONL + semantic Markdown), self-authored backlog, reflect/compaction. *(That two-tier
design is now superseded for v1 — see the banner on that note and the resolution below.)*
**Partly resolved** by [`docs/design/documentation-system.md`](docs/design/documentation-system.md):
v1 is **central**, one append-only `ledger.jsonl`, per-repo views *derived* (not stored); semantic
tier and reflect/compaction dropped from v1. Still open: staleness rule (finding-hash / file-SHA).

## 3. The rulebook — scope and format
**RESOLVED (ADR 0004): minimal `rulebook.yaml`** — allowed repos, per-repo `mode`
(`findings-only`|`branch-fix`), limits. Hard prohibitions live in the hook, not here.
Repo whitelist + per-repo mode (review-only vs. fix-PR), prohibitions (no main, no secrets/CI/deps,
no deletes), tool allowlist, change-size limits (max lines/files per PR, max PRs/night). Declarative
(YAML) with human ownership. How much should the agent be trusted to interpret vs. hard-enforced?
**Elaborated:** [`docs/design/constitution-and-rulebook.md`](docs/design/constitution-and-rulebook.md)
— three layers (constitution / rulebook / hard-enforcement), precedence, the four pillars.

## 4. Budget model — the real break from a per-task timer
**RESOLVED (ADR 0004, amended 2026-07-09 + ADR 0005): no per-night cap.** Throughput is governed
solely by open-branch backpressure (`max_open_branches`); the earlier per-night production count
(`max_branches_per_night`) was reverted and removed. Per-run bounds + a per-run runaway ceiling
(`max_branches_per_run`, backstop not policy) + auto-compact off apply; usage-window observation is a
backstop. Supersedes MartinLoop as gate.
Instead of a timer per task: one outer loop `{pick work item → bounded run → record outcome}` that
repeats until the time/quota window is spent. Inner runs stay bounded (no drift); the outer loop
consumes the night. How do we detect "window exhausted" per harness (adapter concern)?
_Refined by ADR 0003: detect the window via usage observation (`ccusage`, `claude-token-lens`), not
a metered API client. MartinLoop can supply the per-run budget/verify gate (ADR 0002)._
**Elaborated:** [`docs/design/execution-modes.md`](docs/design/execution-modes.md) — the outer loop
as single/chain/parallel modes, plus the self-chaining governor (hard spawn caps in the runner).

## 5. Anti-churn — the value bar
**RESOLVED (ADR 0004): the value bar is *soft* in v1** — agent justification + confidence, the Review
stage, and smallness limits — acceptable because output is branch-isolated and never merged (a bad
change is a branch you delete). No calibrated critic / shadow-nights needed.
Biggest risk: "steady improvement" becomes steady noise (trivial diffs that cost review time). The
steward must be allowed to do **nothing** when nothing is worth it (adaptive backoff survives).
What is the value bar, and how is it enforced?
**Elaborated:** [`docs/design/self-evaluation.md`](docs/design/self-evaluation.md) — the pre-flight
critic enforces the value bar before a PR ships (abandon + backlog if below bar). *(Superseded by the
RESOLVED decision above — the critic-as-gate is cut; the value bar is soft. See that note's banner.)*

## 6. Morning digest
**RESOLVED (ADR 0004): derived `digests/<date>.md`, file-only in v1.** Reports shipped branches
*and* considered-but-abandoned (the "do-nothing report"); empty nights still get one.
The human should wake to a **summary of the night**, not 30 raw PRs. What does the digest contain,
and where does it live?

## 7. Trust ramp
**RESOLVED (ADR 0004): manual, via the rulebook `mode` knob** — a repo starts `findings-only`, the
human edits the YAML to graduate it to `branch-fix`. No auto-graduation in v1.
Start review-only, graduate to fixes as confidence grows. Is this per-repo config, or automatic
based on ledger outcomes?
**Elaborated:** [`docs/design/self-evaluation.md`](docs/design/self-evaluation.md) — trust-ramp via
the retrospective loop (autonomy earned from measured acceptance). *(Superseded by the RESOLVED
decision above — the retrospective/auto trust-ramp is cut; the ramp is the manual `mode` knob. See
that note's banner.)*

## 8. Reuse vs. supersede `nightly-review-pipeline`
**RESOLVED (ADR 0004): borrow patterns, supersede memory + PR flow.** Borrow worktree isolation, the
`claude -p` orchestration shape, and the review lenses; supersede the per-repo task-file memory (→
central ledger) and the draft-PR flow (→ branches). No code dependency — it is a skill, not a library.
Does nightshift call the existing pipeline as its "fix" tool, or absorb/replace it? See CONTEXT.md.

## 9. Adopt vs. build — RESOLVED (ADR 0002)
Prior-art survey done (`docs/prior-art.md`): no off-the-shelf fit. **Decision: build only the brain**
(cross-repo self-prioritization + ledger), **borrow the body** (`claude -p`/Ralph-loop runtime,
MartinLoop budget/verify gate, oss-autopilot scoring, and the existing `nightly-review-pipeline`
fix flow). Open sub-question moved to §8. Next: verify licenses/maturity of the borrowed pieces.
