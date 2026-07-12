# nightshift — active backlog

Only active, actionable work belongs here. Items are ordered by priority.

- Durable decisions: [`docs/adr/`](docs/adr/)
- Unresolved architectural choices: [`OPEN-QUESTIONS.md`](OPEN-QUESTIONS.md)
- Implemented behavior: `README.md`, `CONTEXT.md`, and `docs/design/`
- Completed work: remove it; Git history and ADRs are the record

Last triaged: 2026-07-12 against `main` after the Fable v2 review. Resolved that pass: rulebook
parse errors now fail closed (no more silent fleet truncation); `open_pr` targets the configured
base; recon never falls back to the live checkout; recon caches and work-item IDs are collision-safe;
dimension rotation advances after an empty Explore; the dead `deferred` outcome is gone.

## Next — P1 identity, scheduling, and deterministic coverage

### Repair finding identity and lifecycle across runs

Equivalent defects can receive different prose/line-derived fingerprints. Surfaced work can then be
rediscovered, while a repeatedly selected known item can crowd out new work. Resolve
[Open Question 1](OPEN-QUESTIONS.md#1-finding-identity-and-lifecycle) and record the contract in an ADR.

Acceptance criteria:

- identity survives rewording, line movement, and multi-file ordering;
- unresolved findings and open branches are supplied to Explore as known work;
- Explore continues searching instead of returning a known item;
- unresolved findings remain visible in later digests;
- human verdicts clear or permanently dismiss findings;
- merged and dropped branches both release backpressure;
- deterministic tests cover identity, starvation, carry-forward, and clearing.

### Make scheduler overrides visible and removable

`bin/schedule.sh install|enable|status` must report active files under
`~/.config/systemd/user/nightshift.timer.d/` and show that effective cadence may differ from the
committed timer. `uninstall` must remove the directory or explicitly warn that it remains.

### Cover the `surface` route end to end

Add a deterministic mock result with `disposition:"surface"`. Verify the latch, ledger row,
worktree removal, absence of a push, digest rendering, and unknown dispositions failing closed.

## Later — P2 robustness and operator experience

### Bound findings-only progress loops

Findings set `progress=1` but do not consume the open-branch or branch-per-run caps. A nondeterministic
Findings-only repo can therefore generate unbounded passes. Decide whether findings consume a
per-run cap or do not keep the pass loop alive; always retain an explicit stop reason.

### Harden recon cache writes

- Write caches atomically so a failed `jq` cannot truncate the prior cache.
- Add negative caching/backoff for empty or failed Recon results.
- Validate `ttl_days` instead of silently turning malformed values into constant refreshes.

### Improve harvest visibility

- Show the latest verdict per item in the llmstack dashboard.
- Add merge-rate breakdowns by `verifiability`, `proof`, and finding `type` after enough data exists.
- Keep automatic finding resolution deferred until identity is stable; manual verdicts remain truth.

### Document deployment

Create one operator document for per-machine bootstrap/updates, local state, branch-only operation
across Git hosts, and optional PR credentials. Record the v1 constraint "one Nightshift installation
per target repo" in an ADR because duplicate installations have divergent ledgers.

### Add an independent branch review mode

Review open `nightshift/*` branches in fresh contexts and write read-only merge/do-not-merge
recommendations to the digest. Never merge or push. Prefer a different model/vendor when configured.

### Add an explicit spend control

Resolve [Open Question 2](OPEN-QUESTIONS.md#2-spend-control). Existing branch/run caps constrain
output and review load, not monetary or token spend.

## Conditional / deferred

- **Wake from suspend:** only if catch-up-on-wake is operationally insufficient.
- **Adaptive cadence:** only if measured empty-run cost justifies more scheduler state.
- **Bitbucket/GitLab PR APIs:** only when credentials and operator demand exist; branches remain the
  credential-free baseline.
- **Full containment:** dedicated user, `bwrap`, or container if path confinement is insufficient.
- **Server branch protection:** per-host operator defense-in-depth, not a Nightshift code task.
