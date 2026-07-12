# ADR 0015 — Recon reprioritizes, never excludes

- Status: accepted
- Date: 2026-07-12
- Resolves: [OPEN-QUESTIONS.md §3 "Recon exclusion policy"](../../OPEN-QUESTIONS.md)
- Refines the dimension-selection half of [ADR 0010](0010-recon-dimensions-and-coverage-rotation.md)
  (recon/dimensions/rotation); the recon *stage* and the ledger-as-memory model are unchanged.

## Context

ADR 0010 let Recon mark a review dimension `applicable:false`, and `select_dimension` skipped any
non-applicable dimension. So `applicable:false` was **full exclusion**: that lens dropped out of the
rotation and was never reviewed for that repo until a HEAD change or TTL forced a fresh recon.

That is the wrong default for an unattended system, on a cost-asymmetry argument:

- A wrongly *included* lens costs one wasted pass per rotation cycle — bounded, cheap, and visible
  in the digest.
- A wrongly *excluded* lens costs an **unbounded, silent absence** in exactly the dimension where
  absence is most expensive (e.g. `security` switched off on a repo that does handle untrusted
  input). Silent-and-unbounded must never beat cheap-and-visible.

Two further points seal it. First, a "low-yield" lens that is still run occasionally and *finds
something* is the only signal that Recon is miscalibrated for that repo — hard exclusion destroys
its own error detector. Second, the deterministic floor (`lib/recon_signals.sh`) is a static probe;
`prompts/recon.md` can compensate for a gap within a run but cannot extend the probe, so every
exclusion ultimately rests on a known-incomplete signal set or a fallible per-run model judgment —
no basis for "never look here again."

## Decision

**Machines reprioritize; only humans exclude.** Recon steers *attention and ordering*; it can never
remove a dimension from the rotation. The only exclusion authority is the human `rulebook.yaml`
(per-repo `dimensions:` already lists the applicable set — omitting a lens is a human assertion).

1. **Recon emits a yield label, not applicability.** `prompts/recon.md` returns, per dimension,
   `yield: high | normal | low` (replacing `applicable`), plus the existing `hint`/`notes`. The
   `correctness/docs/craft` "always-applicable" whitelist is retired — with no exclusion path it is
   unnecessary; they are simply judged like any other lens (typically `normal`/`high`).

2. **Weighted-staleness selection with a finite weight floor.** Selection stays wall-clock-based
   (ADR 0008/0010): `score(repo,dim) = (now − last_epoch) · eff_w(repo,dim)`, pick `argmax(score)`.

   ```
   weight(yield)      = {high: 2.0, normal: 1.0, low: 0.2}     # clamp [0.2, 2.0]
   eff_w(R,dim)       = weight(recon_yield)
                        |> floor at 1.0 if evidence_override(R,dim)     # step 4
                        |> raise to 2.0 if (now − last_epoch) > ceiling(R)   # step 3
   ```

   The **finite floor (0.2) is the real anti-starvation guarantee**, not the ceiling: in steady
   state a lens is picked when its weighted staleness reaches a common threshold, so a `low` lens's
   service interval is exactly `w_high / w_low = 10×` a `high` lens's — bounded, never infinite. A
   low-yield lens recurs ~10× less often than a high-yield one on the same repo; it never vanishes.
   Recon emits only the three labels; there is no per-dimension numeric tuning surface.

3. **Cadence-relative ceiling as a legibility backstop.** A dimension is *overdue* when
   `(now − last_epoch) > ceiling(R)`, with

   ```
   ceiling(R) = 2.5 · D · median_gap(R)      # D = # dims for R; ≈ 2.5 realized rotations
                                              # bootstrap: absolute 60 days until R has ≥ D services
   ```

   `median_gap(R)` is the median inter-service interval for that repo, from the ledger. Overdue
   **boosts the weight to 2.0** (it competes through the same `argmax`), it does not jump to the
   front. Relative — not absolute — is deliberate: a slow-cadence repo would trip an absolute 60–90d
   ceiling on *every* dimension every run, neutralizing the weights into plain by-recency rotation.
   Under the relative ceiling that same "fires for everything" event is **correct by design**: if
   every dim is overdue relative to the repo's own norm, the repo simply lacks the service capacity
   to spend on yield-steering, and flat even coverage is exactly what you want there. At these
   weights the ceiling only ever bites for `low` dims — its whole job.

4. **Evidence overrides Recon, derived from the ledger (no new state).** A confirmed finding under a
   lens proves Recon's low verdict stale:

   ```
   evidence_override(R,dim) = ∃ ledger row (R,dim) with outcome ∈ {shipped, human-confirmed}
                              AND row.epoch > recon_cache(R).generated_epoch
   ```

   It **floors the weight at normal (1.0)** — evidence contradicts "low," so the neutral correction
   is normal; a single finding must not over-rotate to high. Anchoring to the recon-cache generation
   time makes it self-clearing: once Recon re-runs (new generation) with that finding in the repo's
   history and still says low, the override lifts on its own. It is derived at selection time (the
   ledger is already scanned for `last_epoch`, so it is free) and **never written into the recon
   cache** — writing it there would lose the evidence exactly when Recon regenerates and repeats its
   mistake, and would break the cache's "pure function of (HEAD, recon model)" contract. Only
   `shipped`/`human-confirmed` count, so a later-dismissed false positive cannot pin the weight up.

5. **"Nothing in scope" is a first-class, logged outcome.** The confabulation guard requires the
   Explore model to explicitly return "nothing in scope for this lens here" instead of manufacturing
   a finding. That declaration is logged: an empty Explore pass emits a lightweight ledger row
   `{dimension, scope}` with `scope ∈ {in_scope_no_findings, out_of_scope}` (in addition to touching
   the rotation scan marker, which already advances rotation on empty passes). This is the only new
   ledger surface — a field on a row added for the guard, not a new event kind. Driving the signal
   off Explore's *actual conclusion* (a full review through the lens) rather than off Recon's own
   repeated low verdict avoids a doom loop that could exclude a genuinely-relevant lens Recon is
   simply blind to.

6. **Digest visibility.** The coverage matrix stays. Additionally: **3 consecutive `out_of_scope`
   rows for a (repo,dim) → the digest suggests a human `rulebook.yaml` exclusion** (the human, the
   only actor entitled to exclude, decides). And Recon flags rulebook/reality contradictions —
   e.g. "rulebook excludes `ui-ux` but I see frontend signals" — since a hand-exclusion in the
   rulebook, unlike Recon, never re-evaluates on its own.

## Consequences

- `recon.md` and `mock_recon` emit `yield` (`high|normal|low`) instead of `applicable`; the
  deterministic mock mapping updates signals→yield. `recon_applicable()` is replaced by a weight
  lookup; `select_dimension()` becomes the weighted-staleness `argmax` above. The
  `correctness/docs/craft` always-applicable special-case is removed.
- One new ledger surface: empty Explore passes write a `{dimension, scope}` row. Downstream readers
  ignore unknown fields (ADR 0010), so pre-0015 rows read as scope-null and count as ordinary empty
  passes.
- No new *stored* state: weights come from the recon cache, staleness and the evidence override are
  derived from the ledger, `median_gap` is a ledger query. The recon cache stays a pure function of
  (HEAD, recon model).
- Selection composes cleanly with the two other selectors: repo order stays least-recently-serviced
  (ADR 0008), throughput stays open-branch-capped (ADR 0004/0005). This ADR only changes *which lens*
  within the chosen repo — orthogonal to *which repo*.
- The whole recon→yield→weighted-rotation→empty-scope→digest path stays deterministic in mock mode
  and must be covered end-to-end before this ships (extends the ADR 0010 mock test).
- Tunable defaults (weights `2.0/1.0/0.2`, ceiling `K=2.5`, bootstrap `60d`, suggest-exclusion
  `N=3`) live in the Runner / rulebook; they are chosen aggressively on purpose because the finite
  floor and the cadence-relative ceiling make aggression safe.
