# nightshift — open design decisions

Only unresolved choices with lasting architectural consequences belong here. Once decided, record
the decision in an ADR and remove the section. Implementation work belongs in [`todo.md`](todo.md).

## 1. Finding identity and lifecycle

Nightshift must recognize the same defect across rewording, line movement, and multi-file
descriptions. The current model-produced fingerprint is unstable, and the append-only ledger does
not yet express a complete carry/clear/invalidate lifecycle.

Decide:

1. Stable identity: normalized locations and type, symbol/semantic target, content signature, or a
   layered combination?
2. Multi-file canonicalization: how is file order made irrelevant?
3. Lifecycle: which verdicts mean unresolved, cleared, or permanently ignored?
4. Exploration: how does the model receive known work and keep searching rather than spend its
   result budget on an item the runner suppresses?
5. Invalidation: when does a code change make an old identity eligible again?

Constraints already decided:

- the v1 ledger is central and append-only;
- human verdicts outrank reconciliation ([ADR 0007](docs/adr/0007-human-verdicts-outrank-machine-reconcile.md));
- surfaced ambiguity remains human-owned until cleared ([ADR 0006](docs/adr/0006-surface-intent-ambiguous-divergences.md));
- wording and drifting line numbers alone are insufficient identity.

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
