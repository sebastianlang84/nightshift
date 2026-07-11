# nightshift

Autonomous overnight steward for code repositories. Given a set of repos it is allowed to
touch, nightshift reviews and fixes code while you sleep — self-selecting what to work on,
remembering what it already did, and staying inside configurable rules and a time/quota budget.

> Like the *Heinzelmännchen*: it does the work at night, within its rules, and stops when the
> budget runs out.

**Status: early prototype.** The v1 scope is decided ([ADR 0004](docs/adr/0004-v1-scope-branch-isolated-steward.md))
and a runnable **mock** prototype exercises the full loop end-to-end against a throwaway sandbox — see
[`docs/design/prototype.md`](docs/design/prototype.md). Run `bin/setup-sandbox.sh` and then the isolated
`RULEBOOK=… NIGHTSHIFT_STATE_DIR=… bash bin/nightshift.sh` command it prints (it no longer overwrites your
live `rulebook.yaml`). The `claude -p` adapter runs the real Recon/Explore/Fix/Review stages.

**v2 (dimension-rotating, multi-finding):** explore now emits several ranked findings per repo — each on
its own branch — aimed by a rotating review *dimension* (correctness, security, infra, ui-ux, …) chosen
per repo from a reconnaissance survey and least-recently-serviced coverage. See
[`docs/design/nightshift-v2.md`](docs/design/nightshift-v2.md) and ADRs 0008–0011.

Start here:
- [`CONTEXT.md`](CONTEXT.md) — what nightshift is, its architecture, and the canonical vocabulary.
- [`OPEN-QUESTIONS.md`](OPEN-QUESTIONS.md) — the unresolved design tensions we are working through.
- [`docs/adr/`](docs/adr/) — architecture decisions, one file per decision.
- [`docs/prior-art.md`](docs/prior-art.md) — survey of existing tools (adopt vs. build).
