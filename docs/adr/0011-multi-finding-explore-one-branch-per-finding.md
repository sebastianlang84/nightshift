# ADR 0011 — explore emits up to N findings; each ships on its own branch

- Status: accepted
- Date: 2026-07-11

## Context

The Runner explored each repo and took exactly ONE finding from it per pass
(`main()` in `bin/nightshift.sh`), so a repo full of improvements yielded a single trivial
branch a night. The operator wants nightshift to find and fix several issues per repo when
configured — "3, 4, up to 10" — not one mini change. ADR 0009 fixed the *value* of a single
finding; this fixes the *count*.

The safety architecture (worktree isolation, branch-only, push confinement, human merge
gate — nothing auto-merges or auto-deploys) means volume is as safe as it is bold: each
extra finding is one more `nightshift/*` branch a human rejects at zero cost. The only real
constraint is the human's morning review capacity, which is already governed by the
open-branch cap (ADR 0004/0005).

## Decision

**Explore emits up to N findings**, ranked best-first (the ADR 0009 enumerate-then-rank
discipline, top-N instead of top-1). N is `limits.max_findings_per_item` (default **1** in
the parser for backward compatibility; the live rulebook sets it), overridable per repo with
a `findings:` key. The Runner truncates the returned array to N defensively.

Output schema is now a container `{"found":bool,"findings":[ …per-finding objects… ]}`. The
per-finding object is exactly the pre-v2 finding schema. The Runner normalises both shapes
(`if .findings then … elif .found then [.] else []`), so prompt and Runner deploy
independently and any old single-object emitter still works.

**Each finding ships on its own branch** — not one branch with N commits, not one branch per
dimension. Reasons, in order of weight:
1. **Verdict granularity (ADR 0007).** `harvest.sh reconcile()` derives merged/open/dropped
   per branch sha and the human-verdict machinery keys on the branch. N commits on one branch
   would force all-or-nothing verdicts and destroy the per-finding merge-rate signal.
2. **Morning ergonomics.** A rejected finding must not hold good ones hostage — independent
   branches are independent zero-cost rejects.
3. **Exact cap accounting.** 1 finding = 1 branch = 1 slot in `open_branch_count()`; the cap
   stays the honest governor of review load.

**Each fix runs in its own FRESH worktree from base.** Explore runs once (read-only) and its
worktree is removed before fixes begin; every finding then gets a new worktree, so diffs never
compound and each branch carries exactly one finding's change. Branch names get a per-run
monotonic suffix (`-<seq>`) because several findings can finalise within the same clock second
in one repo and their timestamped names would otherwise collide.

Dedup (`already_done/acted/surfaced`) and the surface-vs-fix guard (ADR 0006) apply per
finding, unchanged. The fingerprint stays dimension-free (see ADR 0010) so the same defect is
never double-shipped.

## Consequences

- A productive repo yields several reviewable branches per night instead of one.
- More branches per morning — intended. The open-branch cap sizes this to the operator's
  appetite and remains the sole throughput governor; the cap is checked between findings, so
  backpressure granularity is finer, not coarser.
- One extra `worktree add` per finding (seconds); mandatory for diff independence.
- Mock adapter emits the container with up to N planted defects and `mock_fix` dispatches on
  the finding's file, so the whole multi-finding path is exercised deterministically
  (verified: 2 planted defects → 2 independent branches, dedup on re-run, exact cap count).
- `max_findings_per_item` default is 1 in the parser: a rulebook that omits the key keeps the
  pre-v2 single-finding behaviour. The live rulebook sets it to 2 (operator's choice, paired
  with the cap of 5).
