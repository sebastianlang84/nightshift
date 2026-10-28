# ADR 0039 — "nothing found" is a result, and every finding names who it affects

- Status: accepted
- Date: 2026-10-28
- Touches: [ADR 0010](0010-recon-dimensions-and-coverage-rotation.md) (each night services a lens) · [ADR 0029](0029-a-serviced-lens-needs-depth-evidence.md) (a serviced lens needs depth evidence) · [ADR 0015](0015-recon-reprioritizes-never-excludes.md) (empty out-of-scope passes suggest an exclusion)

## Context

The operator asked whether nightshift ships mostly relevant fixes. An audit on 2026-10-28 read all
64 nightshift fixes merged into partflow `develop` (counted) and classed each by the caller or user
path it reaches:

- 9 fix a defect with real user or data impact, 38 an edge case or minor impact, and 17 nothing a
  caller reaches: comment and JSDoc moves, a removed dead branch, guards the system already
  enforces, test-only commits, a dev-only lockfile bump.
- 4 merged fixes needed a correction after the merge, and 12 introduced a defect the operator
  corrected before merging. One regression stayed live on `develop` for about a month.

The explore stage almost never comes back empty: 165 of 171 passes reported a finding over all
nights, and 19 of 19 in October (counted from `runs/*/item-*/explore.out`). The prompt pushed in
that direction. It said "a rejected branch costs nothing", and found:false read as the exception
to justify. A branch costs the morning reviewer time, and every merged change can regress.

Dropping the lenses that produced no high-impact fix (docs, perf, infra, tests, deps) was
considered and rejected: the operator values documentation fixes, and the problem is a finding
with no affected party, which every lens can produce.

## Decision

1. **found:false is a valid, expected result.** `prompts/explore.md` and the findings budget
   appended by `bin/nightshift.sh` say so, and the prompt no longer claims a branch is free.
2. **Every finding names who it affects.** For code, the claim names a real caller, user path,
   import or request that reaches the defect, and the observable wrong outcome. For docs and
   comments, it names the reader and the wrong action the text leads them to. Without one, the
   pass reports found:false.
3. **Review enforces it.** `prompts/review.md` abandons a claim whose named affected party does not
   reach the defect on current code, with a reason beginning `no-affected-party:`.
4. **The digest shows how often each lens finds nothing.** A section "Nothing found, by dimension
   (all-time)" counts explore passes and empty passes per lens from the ledger. A lens that never
   comes back empty is visible as one that may be manufacturing findings.

## Consequences

- Fewer branches per night is the intended effect, not a regression. The coverage rotation is
  unchanged: an empty pass still services its lens.
- The rule lives in the prompts only, so the model can still ignore it. The digest section is the
  check: on 2026-10-28 the rate of empty passes was 0–15% per lens (counted), and it should rise.
- A real defect whose caller the explore stage cannot trace is not reported. A later pass finds it
  only if it can trace the caller then; a defect whose callers live outside the repository can stay
  unreported for good.
