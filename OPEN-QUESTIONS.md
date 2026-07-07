# Open questions

The design tensions we still need to resolve. Move each to an ADR once decided.

## 1. Selection — how does the steward choose work? (explore vs. exploit)
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
(episodic JSONL + semantic Markdown), self-authored backlog, reflect/compaction. Open: central vs
per-repo notes; SQLite trigger; staleness rule.

## 3. The rulebook — scope and format
Repo whitelist + per-repo mode (review-only vs. fix-PR), prohibitions (no main, no secrets/CI/deps,
no deletes), tool allowlist, change-size limits (max lines/files per PR, max PRs/night). Declarative
(YAML) with human ownership. How much should the agent be trusted to interpret vs. hard-enforced?
**Elaborated:** [`docs/design/constitution-and-rulebook.md`](docs/design/constitution-and-rulebook.md)
— three layers (constitution / rulebook / hard-enforcement), precedence, the four pillars.

## 4. Budget model — the real break from a per-task timer
Instead of a timer per task: one outer loop `{pick work item → bounded run → record outcome}` that
repeats until the time/quota window is spent. Inner runs stay bounded (no drift); the outer loop
consumes the night. How do we detect "window exhausted" per harness (adapter concern)?
_Refined by ADR 0003: detect the window via usage observation (`ccusage`, `claude-token-lens`), not
a metered API client. MartinLoop can supply the per-run budget/verify gate (ADR 0002)._
**Elaborated:** [`docs/design/execution-modes.md`](docs/design/execution-modes.md) — the outer loop
as single/chain/parallel modes, plus the self-chaining governor (hard spawn caps in the runner).

## 5. Anti-churn — the value bar
Biggest risk: "steady improvement" becomes steady noise (trivial diffs that cost review time). The
steward must be allowed to do **nothing** when nothing is worth it (adaptive backoff survives).
What is the value bar, and how is it enforced?
**Elaborated:** [`docs/design/self-evaluation.md`](docs/design/self-evaluation.md) — the pre-flight
critic enforces the value bar before a PR ships (abandon + backlog if below bar).

## 6. Morning digest
The human should wake to a **summary of the night**, not 30 raw PRs. What does the digest contain,
and where does it live?

## 7. Trust ramp
Start review-only, graduate to fixes as confidence grows. Is this per-repo config, or automatic
based on ledger outcomes?
**Elaborated:** [`docs/design/self-evaluation.md`](docs/design/self-evaluation.md) — trust-ramp via
the retrospective loop (autonomy earned from measured acceptance). Open: may the retrospective
self-adjust selection weights live, or only propose?

## 8. Reuse vs. supersede `nightly-review-pipeline`
Does nightshift call the existing pipeline as its "fix" tool, or absorb/replace it? See CONTEXT.md.

## 9. Adopt vs. build — RESOLVED (ADR 0002)
Prior-art survey done (`docs/prior-art.md`): no off-the-shelf fit. **Decision: build only the brain**
(cross-repo self-prioritization + ledger), **borrow the body** (`claude -p`/Ralph-loop runtime,
MartinLoop budget/verify gate, oss-autopilot scoring, and the existing `nightly-review-pipeline`
fix flow). Open sub-question moved to §8. Next: verify licenses/maturity of the borrowed pieces.
