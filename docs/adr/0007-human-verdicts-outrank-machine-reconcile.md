# ADR 0007 — human verdicts are ground truth; reconcile never clobbers them

- Status: accepted
- Date: 2026-07-11

## Context

`bin/harvest.sh` reconciles every shipped branch against git reality and appends a
`verdict` event. `reconcile()` can only DERIVE three values — `merged` (sha is an ancestor
of base), `open` (unmerged, ref still on origin), `dropped` (unmerged, ref gone). The nightly
loop writes a new verdict whenever the derived state differs from the last recorded one.

Humans also record verdicts by hand (`harvest.sh verdict <sel> <merged|dropped|resolved|
wontfix|open> [reason]`), including two — `resolved` and `wontfix` — that reconcile can never
produce. Because the loop compared only the verdict *value*, a machine reconcile silently
overwrote a human decision:

- A manual `dropped` recorded on a branch **before** its ref was deleted (with a meaningful
  reason, e.g. "superseded by handoff branch") was flipped back to `open` on the next run,
  because the ref still existed so reconcile derived `open != dropped` and wrote it.
- The same trap would clobber a `resolved`/`wontfix` on a shipped branch — reconcile derives
  `merged|open|dropped`, sees a mismatch, and overwrites the human label.

The dashboard reads the latest verdict per branch as status, so this churn also produced
spurious duplicate rows and lost the human's reason (observed 2026-07-10 on
`nightshift/smell-partflow-20260710-223406`: `dropped(manual)` → `open` → `dropped`).

## Decision

A human decision outranks machine reconciliation. Verdicts now carry provenance: manual
verdicts are stamped `source:"manual"`; reconcile writes leave `source` null.

The reconcile loop **holds** (writes nothing for) a branch whose last verdict is human-owned:
- `resolved` or `wontfix` — always (reconcile can never derive these), regardless of source;
- `merged` or `dropped` — when `source == "manual"`.

**Sole exception:** an objective merge always wins. If reconcile derives `merged` (the sha is
contained in base — a fact, not a label), it records `merged` even over a held verdict, because
the code demonstrably landed.

## Consequences

- A manual `dropped`/`resolved`/`wontfix` survives nightly re-runs with its reason intact; the
  ground-truth signal is no longer self-erasing.
- `source` is an additive, nullable field on `verdict` rows (schema_version stays 2); existing
  and downstream readers (the dashboard parses defensively) ignore it safely.
- Provenance is coarse: any `harvest.sh verdict …` invocation is "manual". A machine that must
  legitimately move a manually-held branch off `dropped`/`resolved` (other than via a real
  merge) has no path except a human re-issuing the verdict — acceptable, since that is exactly
  the human-owned case.
- Provenance is forward-only: ledger rows written before this change carry no `source`, so a
  legacy manual `dropped`/`merged` is not protected and could still be clobbered by reconcile.
  Verified 2026-07-11 that no such row is currently at risk (the existing manual `dropped`
  branches have their refs already gone from origin, so reconcile derives the same `dropped`).
  The escape hatch for any future case is to re-issue `harvest.sh verdict …`, which stamps it.
- The read-side still shows one row per event; collapsing the ledger event stream to one
  current-state row per branch is a separate dashboard concern (llmstack), tracked in `todo.md`.
