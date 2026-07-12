# ADR 0010 — review dimensions, recon, and coverage rotation

- Status: accepted (dimension-selection semantics superseded by [ADR 0015](0015-recon-reprioritizes-never-excludes.md))
- Date: 2026-07-11

> **Note (ADR 0015):** the `applicable:true/false` recon output and the `argmin`-over-applicable
> selection described below are superseded — recon now emits `yield` weights and never excludes; the
> "should recon only ever raise priority?" open question at the end is resolved (yes). The recon
> *stage*, caching, dimensions, and ledger-as-memory are unchanged.

## Context

Explore had no notion of *what kind* of review was due. It scanned generically, so findings
skewed to whatever was easiest to prove — doc/comment drift — and nightshift kept re-reviewing
the same shallow surface of whatever repo sorted first. The operator wants (1) the full range of
review — real bugs, security, infra/docker, UI/UX, perf, tests, deps, docs — not just docs; and
(2) intelligent rotation: "repo A had security yesterday → today docs on A, security on B, because
B never had it"; and (3) reconnaissance: nightshift should look at a repo and infer which reviews
make sense ("there's a compose file → check it; there's a frontend → UX").

The safety architecture already absorbs boldness and volume (see ADR 0009/0011): everything runs
in throwaway worktrees, lands only on `nightshift/*`, and merges only by a human. So this is an
*aim* upgrade, not a safety question.

## Decision

Introduce **review dimensions** (lenses), a **recon** stage, and **coverage rotation** — all with
the ledger as the single source of memory (ADR 0004/0007) and all policy in the Runner (ADR 0001).

**Dimensions.** A closed-but-extensible set (`correctness, security, infra, docs, tests, perf,
ui-ux, deps, craft`), declared in `rulebook.yaml` under `dimensions:` (ORDER = cold-start/tie
priority). Adding a dimension = drop a `prompts/dimensions/<id>.md` lens file + add one rulebook
line; no code change. A lens is appended to the shared `explore.md` (which still owns the output
schema, the falsifiable-claim contract, and the surface/fix guard) — it only aims attention and
states dimension-specific proof standards. The selected dimension is stamped onto every finding
(ledger `dimension` field, nullable/additive) and leads the branch slug.

**Recon.** A read-only stage, run per repo and **cached** in `state/recon/<repo>.json`
(derived, disposable state — NOT the ledger), invalidated when the repo HEAD changes or after
`recon.ttl_days`. Two layers: `lib/recon_signals.sh` emits deterministic filesystem signals
(docs/compose/frontend/tests/CI/lockfiles/…) — harness-independent and what mock mode runs on —
and the model (`prompts/recon.md`) refines them into per-dimension `{applicable, hint}` plus a
one-paragraph `notes` map that orients explore. Recon **narrows** the candidate dimensions and
never starves: a missing cache or an unknown dimension is treated as applicable, and
`correctness/docs/craft` are applicable to any repo.

**Coverage rotation.** `last_dim_epoch(repo, dim)` is a ledger query (max ts over work-item rows
— finding/shipped/abandoned — for that repo+dimension; verdict rows excluded, as in ADR 0008).
`select_dimension(repo)` = argmin of `last_dim_epoch` over the recon-applicable configured set,
ties broken by rulebook order. This reproduces the operator's rotation mechanically with zero new
stored state, and composes with the existing two other selectors: repo order stays
least-recently-serviced (ADR 0008), throughput stays open-branch-capped (ADR 0004/0005). The
digest gains a coverage matrix (days since each repo×dimension was serviced) and a per-dimension
merge-rate (ADR 0009's tuning signal), so rotation and lens-yield are observable.

## Consequences

- Findings span the full range and rotate across repos and nights; a long-overdue lens surfaces
  in the coverage matrix as a large number or `—`.
- One extra read-only recon stage per repo when its cache is stale (HEAD change / TTL); zero cost
  otherwise. Recon telemetry lands in `runs.jsonl` via the normal stage path.
- The ledger gains one nullable `dimension` field; pre-v2 rows read as dimension-null and count
  for no dimension (an honest cold start). Downstream readers ignore unknown/absent fields.
- Recon can wrongly exclude a dimension. Mitigations: per-repo `dimensions:` overrides recon; the
  fallback never fully starves a repo; the digest shows `—` so absence is visible. Open question
  (I.7 in the design): should recon only ever *raise* priority, never *exclude*? Deferred; revisit
  if a real exclusion bites.
- `mock_recon` maps signals to applicability deterministically, so the whole recon→dimension→
  rotation→multi-finding→cap→merge-rate path is testable end-to-end in mock mode (verified).
- Bridged an isolation leak found while testing: `nightshift.sh` now passes `STATE_DIR/LEDGER/
  RULEBOOK` to `harvest.sh` (which honours those names, not the `NIGHTSHIFT_*` ones), so an
  isolated run no longer reconciles the live ledger.
- See `docs/design/nightshift-v2.md` for the full design and the phased plan; multi-finding and
  one-branch-per-finding are ADR 0011.
