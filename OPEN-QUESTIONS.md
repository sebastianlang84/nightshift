# nightshift — open design decisions

Only unresolved choices with lasting architectural consequences belong here. Once decided, record
the decision in an ADR and remove the section. Implementation work belongs in [`todo.md`](todo.md).

## 3. Recon exclusion policy

v2 Recon can mark a review dimension inapplicable. A false negative can silently starve that lens
until HEAD/TTL invalidates the cache.

Decide whether Recon may exclude dimensions or only reprioritize them. If exclusion remains, define
the maximum exclusion lifetime, operator override, and visibility required in the digest.

Constraints already decided:

- configured per-repo dimensions override the global set;
- selection must always retain at least one fallback dimension;
- Recon is advisory orientation, not authority over repository policy (ADR 0010).

## Resolved decisions

Selection, rulebook shape, branch backpressure, anti-churn, morning digest, trust ramp, pipeline
reuse, build-vs-adopt, repo ordering, dimension rotation, and multi-finding output are resolved in
ADRs 0002–0011 and are intentionally not duplicated here.
