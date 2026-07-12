# nightshift — active backlog

Only active, actionable work belongs here. Items are ordered by priority.

- Durable decisions: [`docs/adr/`](docs/adr/)
- Unresolved architectural choices: [`OPEN-QUESTIONS.md`](OPEN-QUESTIONS.md)
- Implemented behavior: `README.md`, `CONTEXT.md`, and `docs/design/`
- Completed work: remove it; Git history and ADRs are the record

Last triaged: 2026-07-12 against `main`. The Fable v2 review findings and the whole P1/P2 backlog are
resolved and removed: fail-closed rulebook parsing, configured-base PRs, recon never on the live
checkout, collision-safe recon caches and work-item IDs, empty-Explore rotation, Fix-stage write
confinement (R8), the `surface` route + bounded findings-only loops, hardened recon cache writes,
digest merge-rate breakdowns, the deployment guide (ADR 0012), independent branch review, the
wall-clock spend budget (ADR 0013), stable finding identity + lifecycle (ADR 0014), and recon
yield-weighting / never-exclude with the empty-scope feedback loop (ADR 0015).

_No active implementation work at present._

## Conditional / deferred

- **Wake from suspend:** only if catch-up-on-wake is operationally insufficient.
- **Adaptive cadence:** only if measured empty-run cost justifies more scheduler state.
- **Bitbucket/GitLab PR APIs:** only when credentials and operator demand exist; branches remain the
  credential-free baseline.
- **Full containment:** dedicated user, `bwrap`, or container if path confinement is insufficient.
- **Server branch protection:** per-host operator defense-in-depth, not a Nightshift code task.
