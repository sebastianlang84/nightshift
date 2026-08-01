# nightshift — open design decisions

Only unresolved choices with lasting architectural consequences belong here. Once decided, record
the decision in an ADR and remove the section. Implementation work belongs in [`todo.md`](todo.md).

## Does nightshift now pin its own claude model?

Stage isolation excludes the CLI's whole `user` settings scope (`--setting-sources project,local`) —
that is what keeps the operator's personal `CLAUDE.md` out of pushed commit bodies, see
[`docs/design/hook-spec.md`](docs/design/hook-spec.md). The scope is the smallest unit the CLI offers:
there is no knob that drops `~/.claude/CLAUDE.md` while keeping `~/.claude/settings.json`, so a
machine-wide **model pin** is collateral damage and the nightly model silently becomes whatever the
CLI resolves on its own.

Unresolved: whether "nightshift commits no model of its own" survives that. Options — (a) keep it and
make `NIGHTSHIFT_CLAUDE_MODEL` the documented per-host duty (today's state), (b) pin a model in the
Runner-owned `state/claude-settings.json`, which is loaded regardless of scope, (c) fail the run when
no model is pinned anywhere. (a) is honest but silent: a host that loses its pin only finds out from
`runs.jsonl`. Revisit if the CLI ever separates memory scopes from settings scopes.

## Resolved decisions

Selection, rulebook shape, branch backpressure, anti-churn, morning digest, trust ramp, pipeline
reuse, build-vs-adopt, repo ordering, dimension rotation, and multi-finding output are resolved in
ADRs 0002–0011 and are intentionally not duplicated here.

The **Recon exclusion policy** (whether Recon may exclude a dimension or only reprioritize it) is
resolved by [ADR 0015](docs/adr/0015-recon-reprioritizes-never-excludes.md): Recon reprioritizes
via yield weights and never excludes; only the human rulebook excludes. Anti-starvation rests on a
finite weight floor, backstopped by a cadence-relative overdue ceiling.
