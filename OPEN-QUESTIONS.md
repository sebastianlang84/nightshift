# nightshift — open design decisions

Only unresolved choices with lasting architectural consequences belong here. Once decided, record
the decision in an ADR and remove the section. Implementation work belongs in [`todo.md`](todo.md).

## Resolved decisions

Selection, rulebook shape, branch backpressure, anti-churn, morning digest, trust ramp, pipeline
reuse, build-vs-adopt, repo ordering, dimension rotation, and multi-finding output are resolved in
ADRs 0002–0011 and are intentionally not duplicated here.

**Which model a stage runs on** is resolved by
[ADR 0020](docs/adr/0020-the-rulebook-declares-the-stage-model.md): the host declares it in the
rulebook's `agent:` block, the `NIGHTSHIFT_*_MODEL` variables override per run, and every run
announces the effective model and its source. "nightshift commits no model of its own" stands — the
repo ships the key documented and commented out, never set.

The **Recon exclusion policy** (whether Recon may exclude a dimension or only reprioritize it) is
resolved by [ADR 0015](docs/adr/0015-recon-reprioritizes-never-excludes.md): Recon reprioritizes
via yield weights and never excludes; only the human rulebook excludes. Anti-starvation rests on a
finite weight floor, backstopped by a cadence-relative overdue ceiling.
