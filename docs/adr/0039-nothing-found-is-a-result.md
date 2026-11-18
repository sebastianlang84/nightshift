# ADR 0039 — "nothing found" is a result, and every finding names who it affects

- Status: accepted
- Date: 2026-10-28
- Touches: [ADR 0010](0010-recon-dimensions-and-coverage-rotation.md) (each night services a lens) · [ADR 0029](0029-a-serviced-lens-needs-depth-evidence.md) (a serviced lens needs depth evidence) · [ADR 0015](0015-recon-reprioritizes-never-excludes.md) (empty out-of-scope passes suggest an exclusion)

## Context

A reviewer can consume time on changes that reach no user, caller, or reader. Prompting Explore
as if every pass should produce a finding encourages low-value branches and avoidable regressions.
An empty pass is useful coverage evidence when it follows a real investigation.

Dropping whole dimensions would discard relevant documentation, performance, infrastructure,
and dependency findings. The requirement should instead apply to every finding: name the affected
party and the observable consequence.

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
- The rule lives in the prompts only, so the model can still ignore it. The digest section makes
  the empty-pass rate visible so the operator can inspect that behavior.
- A real defect whose caller the explore stage cannot trace is not reported. A later pass finds it
  only if it can trace the caller then; a defect whose callers live outside the repository can stay
  unreported for good.
