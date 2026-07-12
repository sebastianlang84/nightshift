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
wall-clock spend budget (ADR 0013), and stable finding identity + lifecycle (ADR 0014).

## Implement ADR 0015 — Recon reprioritizes, never excludes

Decision recorded ([ADR 0015](docs/adr/0015-recon-reprioritizes-never-excludes.md)); code still
emits `applicable`. Deltas:

- `prompts/recon.md` + `mock_recon`: emit `yield: high|normal|low` instead of `applicable`; drop the
  `correctness/docs/craft` always-applicable special-case.
- `select_dimension()`: replace `recon_applicable()` skip with weighted-staleness `argmax` —
  `score = (now − last_epoch) · eff_w`; weights `2.0/1.0/0.2` clamp `[0.2,2.0]`; evidence floor at
  `1.0`; cadence-relative overdue ceiling `2.5 · D · median_gap(R)` (60d bootstrap) boosts to `2.0`.
- Evidence override: derive from ledger `shipped`/human-confirmed rows newer than the recon-cache
  `generated_epoch`; write nothing to the cache.
- Empty Explore passes emit a `{dimension, scope}` ledger row (`in_scope_no_findings` |
  `out_of_scope`); confabulation guard in `explore.md` makes "nothing in scope" a first-class return.
- Digest: 3 consecutive `out_of_scope` for a (repo,dim) → suggest a rulebook exclusion; flag
  rulebook/reality contradictions.
- Extend the ADR 0010 mock test to cover recon→yield→weighted-rotation→empty-scope→digest end-to-end.

## Conditional / deferred

- **Wake from suspend:** only if catch-up-on-wake is operationally insufficient.
- **Adaptive cadence:** only if measured empty-run cost justifies more scheduler state.
- **Bitbucket/GitLab PR APIs:** only when credentials and operator demand exist; branches remain the
  credential-free baseline.
- **Full containment:** dedicated user, `bwrap`, or container if path confinement is insufficient.
- **Server branch protection:** per-host operator defense-in-depth, not a Nightshift code task.
