# ADR 0018 — harvest adopts orphan branches instead of only reporting them

- Status: accepted
- Date: 2026-07-19
- Related: ADR [0016](0016-reconcile-detects-squash-merges-and-fails-closed.md) (orphan sweep),
  ADR [0017](0017-warn-on-state-remote-incoherence.md) (run-start guard).

## Context

An orphan is a `nightshift/*` branch on origin with no `shipped` row in the ledger `harvest` reads
(ADR 0016). It occurs whenever a `shipped` record is lost — a crash in the push→`ledger_append`
window, or (the 2026-07-19 incident) a fully divorced run that pushed to the real origin while its
ledger lived elsewhere.

Until now the sweep was **read-only**: it reported orphans and told the operator to "adopt (review +
merge) or delete on origin". But adoption was not actually possible in the tool — `reconcile`
iterates `shipped` rows, and an orphan has none, so it never receives a machine verdict;
`manual_verdict` matches only existing `shipped`/`finding` rows, so it too could not attach. The
branch's verdict was therefore **permanently unrecordable** — a self-inflicted limitation, since the
branch name embeds its provenance and the real sha is available from `ls-remote`.

The run-start guard (ADR 0017) cannot cover this class: it only sees runs that execute in this
checkout, and orphans by definition come from runs that did not.

## Decision

The orphan sweep **adopts** each orphan: it appends a synthetic `shipped` row (`adopt_orphan`) so the
branch re-enters the normal reconcile loop and its verdict (merged/open/dropped) derives on the next
harvest. The row carries the real branch and sha; `fingerprint`/`dimension`/`type`/`verifiability`
are genuinely unknown and set null; `outcome:"shipped"` with `adopted:true` and `source:"orphan-adopt"`
marks it so it is never mistaken for a first-hand record or double-counted in provenance metrics.

- **Idempotent:** once written, the branch is in the ledger's `known` set and is never adopted again.
- **`--dry-run` reports only** ("would adopt"), preserving the read-only preview.
- Adoption acts on what is really on origin, so it repairs orphans from **any** source — a foreign
  `NIGHTSHIFT_HOME`, another host, or a lost local append — which no run-start guard can.

## Consequences

- Orphans stop being a dead end: their verdicts become recordable, closing the ground-truth loop for
  branches whose provenance was lost.
- `harvest` now WRITES `shipped` rows, not only `verdict` rows — a widened contract. The marker
  fields keep adopted provenance auditable and separable from genuine ships.
- Merge-rate breakdowns (by dimension/type/verifiability/proof) see adopted rows as uncategorized —
  honest, since that provenance is truly unknown, not fabricated.
- The operator still merges or deletes the branch on origin as usual; adoption only restores the
  ledger record, it does not decide the verdict.
