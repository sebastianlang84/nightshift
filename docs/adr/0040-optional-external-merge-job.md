# ADR 0040 — optional external merging of reviewed branches

- Status: accepted as an optional deployment policy
- Date: 2026-10-29
- Extends: [ADR 0004](0004-v1-scope-branch-isolated-steward.md)

## Context

The runner deliberately stops at a pushed `nightshift/*` branch. A deployment may want to process
those branches automatically, but changing the runner's merge authority would weaken that boundary.
Review throughput also controls branch backpressure.

## Decision

An **external merge job** may review and merge branches under explicit operator authorization.
It is outside nightshift and is not included in this repository. Human review and merging remain
the default workflow; this ADR grants no merge authority to the runner.

Such a job should obtain independent advice from two vendors, check the branch against the
current base, and run the repository's tests on the proposed merge. Disagreement, red tests,
conflicts, or an unresolved safety concern must stop automatic merging and leave a result for
the operator. A changed branch requires a fresh review.

The runner continues to push only `nightshift/*`. Its pre-push confinement, worktree isolation,
and ledger semantics remain unchanged. Optional branch-advice artifacts can inform the external
job; the operator controls its credentials, cadence, and policy.

## Consequences

An authorized external job can reduce review backlog without putting merge credentials into
nightshift. Model agreement does not prove safety. Secret exfiltration and privileged-account
risks remain as documented in [the threat model](../design/risk-analysis.md); external merging
does not mitigate them. Operators must assess those risks before enabling unattended merges.
