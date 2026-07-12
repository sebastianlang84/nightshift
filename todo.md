# nightshift — active backlog

Only active, actionable work belongs here. Items are ordered by priority.

- Durable decisions: [`docs/adr/`](docs/adr/)
- Unresolved architectural choices: [`OPEN-QUESTIONS.md`](OPEN-QUESTIONS.md)
- Implemented behavior: `README.md`, `CONTEXT.md`, and `docs/design/`
- Completed work: remove it; Git history and ADRs are the record

Last triaged: 2026-07-11 against `origin/main` at `556e996`.

## Now — P0 correctness and containment

### Confine Claude Fix-stage writes to its worktree

**Observed:** Claude Fix has `Write`/`Edit`, whose absolute paths are not guarded. It can alter the
Nightshift runner, hooks, user shell files, or another repository and weaken a future run.

**Done when:**

- the existing `PreToolUse` guard denies `Write` and `Edit` outside the current worktree;
- adversarial tests cover the Nightshift checkout and another user-owned path;
- normal worktree edits still succeed;
- hook spec and risk analysis describe the enforced boundary.

Codex Fix already uses an OS `workspace-write` sandbox; full dedicated-user/container isolation
remains defense-in-depth.

## Next — P1 identity, scheduling, and deterministic coverage

### Restore globally unique work-item IDs

v2 currently records per-finding directory basenames such as `f0` and `f1` in ledger and telemetry.
Use `<parent-item>-f<N>` so `harvest.sh verdict <item>` and runs-to-item joins remain unambiguous.
Test multiple repos and multiple findings in one run.

### Make recon caches collision-safe

`state/recon/$(basename "$repo").json` collides for different repositories with the same basename.
Derive the cache name from a stable hash of the canonical repository path while keeping the repo path
inside the cache for inspection. Test two same-named repositories.

### Rotate dimensions after an empty Explore

Rotation currently advances only when a finding/ship/abandon ledger row exists. A clean lens remains
at epoch zero and is selected forever. Record a lightweight serviced event (or equivalent state)
after every completed Explore, including `found:false`, without treating it as a finding. Verify that
two empty passes select two different applicable dimensions.

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

### Harden recon fallback and cache writes

- Avoid running Recon in the live checkout when worktree setup fails, or document and test the
  accepted read-only fallback.
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
