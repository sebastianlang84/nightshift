# nightshift — todo / future ideas

Running list of enhancements to build later. Not design tensions (those live in OPEN-QUESTIONS.md)
and not the ratified v1 scope (ADR 0004) — just good ideas parked with enough context to act on.

## PR / branch review mode — merge-recommendation layer

A separate mode that reviews **all open `nightshift/*` branches (or PRs)** and gives a
**merge / don't-merge recommendation** per branch — an extra review layer *on top* of the pipeline,
run with an **independent, empty context** (not the thread that produced the change).

**Value:**
- *Convenience / harvest:* turns the morning triage from "fetch + diff + judge each branch" into a
  ranked recommendation list — directly attacks the harvest-friction weak spot (re-review §2d/§5).
- *Extra safety:* a second, independent judgment before the human merges.

**Design notes for later:**
- Read-only + advisory: it recommends, never merges or pushes (consistent with "human merges").
- Fresh/empty context per branch reduces transcript-sycophancy — but same-model review still shares
  the producer's blind spots (re-review §2, fable wild-idea #8). For true decorrelation, run this
  layer on a *different model / vendor* (the opt-in API-key path, ADR 0003 allows it).
- Natural output: append recommendations to the morning digest (or a `reviews/<date>.md`).
- Could reconcile with the ledger: record the recommendation + (later) the human's actual verdict —
  the first place a real merge/verdict signal could re-enter the system (re-review §5).
