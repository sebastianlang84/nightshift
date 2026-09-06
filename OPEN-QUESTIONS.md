# nightshift — open design decisions

Only unresolved choices with lasting architectural consequences belong here. Once decided, record
the decision in an ADR and remove the section. Implementation work belongs in [`todo.md`](todo.md).

## How an agent stage reaches a model gateway that is not public

[ADR 0032](docs/adr/0032-the-pi-fix-stage-is-sandboxed.md) put the pi Fix stage inside the ship
gate's bwrap hull and bounded what it may write. It did not bound what it may *reach*: that stage
keeps the host's network namespace, so its network access is as wide as this account's.

Narrowing it needs an egress path the current one cannot provide.
[ADR 0028](docs/adr/0028-gate-egress-goes-through-a-vetting-proxy.md)'s proxy forwards to **public**
addresses on 80/443 and refuses everything else — deliberately, because the address it refuses is
the LAN, i.e. every other service on this machine. But an agent stage's one legitimate destination
*is* on that LAN here (`http://10.40.20.202:5555`), so the policy that protects the test gate
excludes the agent entirely.

The open question is what replaces "public only" for this one caller without reopening the LAN:

- an explicit host-declared destination pin (one `host:port`, from the rulebook, refused unless it
  matches) — narrower than today's proxy policy, but a second policy to keep correct;
- a forwarder bound to a fixed address inside an isolated namespace, so the agent's unchanged
  gateway URL reaches only that one socket — strongest, and needs the sandbox to carry an address
  the agent's configuration already names;
- leaving it as is, on the grounds that the stage has no shell and the branch review sees the diff —
  which is the current state, and is a decision only if it is made deliberately.

Not urgent while the Fix stage has no `bash` tool. It becomes urgent the moment any pi stage is
granted one.

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
