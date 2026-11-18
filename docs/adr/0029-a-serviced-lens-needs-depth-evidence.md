# ADR 0029 — a serviced lens needs depth evidence

- Status: accepted
- Date: 2026-08-19
- Extends: [ADR 0010](0010-recon-dimensions-and-coverage-rotation.md) (what “serviced” means) ·
  [ADR 0023](0023-an-unusable-agent-aborts-the-night.md) (failed stages cannot forge clean evidence)

## Context

Rotation measured whether Explore returned, not whether it reviewed deeply. A plausible first finding
or `found:false` advanced the lens with no record of which entrypoints, flows, or invariants were
checked. Almost all tests exercised a mock model, so prompt quality had no regression signal.

A live `claude-opus-5` replay on four historical pre-fix snapshots made the gap measurable. The old
Explore contract rediscovered only one known root cause at `hit@1` and still only one at `hit@3`.
Raising the findings budget alone did not move recall.

## Decision

**A lens is serviced only after Explore returns a valid coverage receipt.** The top-level verdict
names inspected tracked files, at least one traced entrypoint/policy flow, concrete checks, unresolved
surfaces, and a five-class invariant matrix. Code lenses use:

- accepted configuration domains versus downstream dispatch;
- policy sets versus the exact population counted/filtered;
- artifact identity across producers, mutating checks, reviewers, and consumers;
- translation of failure/partial/malformed results into durable state;
- creation through every terminal lifecycle state.

The opt-in `knowledge` lens replaces those classes with canonicality, consistency, routing,
provenance/trust, and lifecycle/freshness. Before Explore, `lib/knowledge_probe.py` produces a
deterministic OKF-v0.2/Markdown graph report without executing target-repo code. The report grounds
structural claims; semantic redundancy and contradiction still require the model to trace the corpus.

`lib/validate_explore.py` enforces the receipt before `considered`, the dimension scan marker, or an
`empty` ledger row can be written. It requires five distinct tracked files (or the whole repository
when smaller), one trace, three checks (or one per tracked file when smaller), and exactly the five
classes selected by the lens. A failed knowledge probe, invalid model JSON, and incomplete receipts
are stage failures, not clean reviews.

**Depth quality has a real-model regression eval.** `evals/deep-review/` runs current Recon+Explore
against four frozen historical snapshots and scores explicit semantic anchors. The opt-in gate is
three of four known root causes within the top three findings. It is intentionally outside CI because
it requires credentials, model spend, and minutes rather than seconds; CI tests its cases, scorer,
threshold, and deterministic Runner enforcement.

The live adapter remains read-only (`Read,Grep,Glob` plus optional CodeMap). Giving Claude unrestricted
shell access would reopen host reach; depth is improved through enforced reasoning/evidence without
weakening the capability boundary.

## Consequences

- A shallow or malformed answer cannot advance coverage or manufacture an `empty` row.
- The kept invariant-matrix experiment reached **3/4 `hit@3`** (from **1/4**) at **$17.60** on
  `claude-opus-5`; `hit@1` remained 1/4. The exact experiment and remaining miss are recorded in
  [`evals/deep-review/experiments/2026-08-19.json`](../../evals/deep-review/experiments/2026-08-19.json).
- Reviews cost more and take longer. The final four-case run spent about $4.40 per repo on average;
  that cost is visible rather than assumed.
- This is a bounded quality claim, not proof of completeness. The remaining replay miss confused a
  green test on a suite-mutated tree with evidence about the restored tree that would ship.
- Real adapters clear stage artifacts before every invocation and materialize valid partial results
  before returning the CLI's nonzero status, so a prior iteration cannot supply fake evidence and a
  turn-limit result is not discarded.
- Regression coverage: `tests/test-explore-coverage.sh`, `tests/test-json-extraction.sh`,
  `tests/test-stage-artifact-isolation.sh`, `tests/test-explore-incomplete.sh`, and
  `tests/test-deep-review-eval.sh`; knowledge-specific structure is covered by
  `tests/test-knowledge-probe.sh` and `tests/test-dimension-catalog.sh`.
