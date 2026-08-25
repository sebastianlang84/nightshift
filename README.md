# nightshift

Autonomous overnight steward for code repositories. Given a set of repos it is allowed to
touch, nightshift reviews and fixes code while you sleep — self-selecting what to work on,
remembering what it already did, and staying inside configurable rules and a time/quota budget.

**Status: operational, human-gated.** The scheduler runs the implemented v1/v2 pipeline, but output
remains isolated on `nightshift/*` branches and is never auto-merged. A deterministic **mock** mode
exercises the full loop end-to-end against a throwaway sandbox — see
[`docs/design/prototype.md`](docs/design/prototype.md). Run `bin/setup-sandbox.sh` and then the isolated
`RULEBOOK=… NIGHTSHIFT_STATE_DIR=… bash bin/nightshift.sh` command it prints (it no longer overwrites your
live `rulebook.yaml`). First-party `claude -p` and `codex exec` adapters run the real
Recon/Explore/Fix/Review stages plus the read-only Verify stage that closes out old findings
([ADR 0021](docs/adr/0021-closing-open-findings.md)); adapter and model selection are environment
configuration.

**v2 (dimension-rotating, multi-finding):** explore now emits several ranked findings per repo — each on
its own branch — aimed by a rotating review *dimension* (correctness, security, infra, ui-ux,
dead-code/code-bloat, …) chosen per repo from a reconnaissance survey and least-recently-serviced coverage. See
[`docs/design/nightshift-v2.md`](docs/design/nightshift-v2.md) and ADRs 0008–0011.

**Deep-review contract:** a lens counts as serviced only after Explore proves breadth with tracked
files, a traced flow, concrete checks, and five lens-specific invariant classes. The opt-in
`knowledge` lens also receives a deterministic, read-only OKF-v0.2/Markdown structure report. Invalid
or shallow answers do not advance rotation or become clean ledger evidence. The historical replay in
[`evals/deep-review/`](evals/deep-review/) measures `hit@1`, `hit@3`, and cost (ADR 0029).

Start here:
- [`CONTEXT.md`](CONTEXT.md) — what nightshift is, its architecture, and the canonical vocabulary.
- [`docs/deployment.md`](docs/deployment.md) — operator guide: bootstrap, updates, state, branch-only operation.
- [`todo.md`](todo.md) — active work, ordered by priority.
- [`OPEN-QUESTIONS.md`](OPEN-QUESTIONS.md) — unresolved architectural choices only.
- [`docs/adr/`](docs/adr/) — architecture decisions, one file per decision.
- [`docs/prior-art.md`](docs/prior-art.md) — survey of existing tools (adopt vs. build).
