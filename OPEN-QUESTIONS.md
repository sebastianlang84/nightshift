# nightshift — open design decisions

Only unresolved choices with lasting architectural consequences belong here. Once decided, record
the decision in an ADR and remove the section. Implementation work belongs in [`todo.md`](todo.md).

_No open design decisions at present._

## Resolved decisions

Selection, rulebook shape, branch backpressure, anti-churn, morning digest, trust ramp, pipeline
reuse, build-vs-adopt, repo ordering, dimension rotation, and multi-finding output are resolved in
ADRs 0002–0011 and are intentionally not duplicated here.

The **Recon exclusion policy** (whether Recon may exclude a dimension or only reprioritize it) is
resolved by [ADR 0015](docs/adr/0015-recon-reprioritizes-never-excludes.md): Recon reprioritizes
via yield weights and never excludes; only the human rulebook excludes. Anti-starvation rests on a
finite weight floor, backstopped by a cadence-relative overdue ceiling.
