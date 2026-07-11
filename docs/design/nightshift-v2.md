# nightshift v2 — dimension-rotating, multi-finding steward

Design reference for the v2 evolution. Decisions are recorded in ADR 0008 (repo ordering),
0009 (value over smallness), 0010 (recon + dimensions + rotation), 0011 (multi-finding, one
branch per finding). This document is the map; the ADRs are the law.

## Why

v1 explored each repo generically and took ONE finding per repo per pass, so output skewed to
trivial doc drift and one mini branch a night. v2 is an **aim + throughput** upgrade, not a
safety change: the safety architecture (throwaway worktree per item · fixes only on
`nightshift/*` · push-confinement hook · **human merge gate, no auto-merge/deploy** · everything
in git · findings-only repos never push) means the blast radius of a bad, bold, or large finding
is exactly one branch a human rejects at zero cost. The only scarce resource is the human's
morning review budget — governed by the open-branch cap.

## The loop (v2)

```
per repo (order: least-recently-serviced first — ADR 0008):
  ensure_recon(repo)            # cached survey → which dimensions apply (state/recon/<repo>.json)
  dim = select_dimension(repo)  # least-recently-serviced APPLICABLE dimension (ADR 0010)
  explore ONCE (read-only, lens=dim, recon notes injected) → up to N ranked findings
  per finding (best first, cap-checked between each):
    dedup (fingerprint) · surface-vs-fix guard (ADR 0006)
    fix disposition → FRESH worktree from base → fix ⟷ review → finalize → own branch
```

Three orthogonal selectors compose: **repo** (LRU, ADR 0008) × **dimension** (LRU over applicable,
ADR 0010) × **throughput** (open-branch cap, ADR 0004/0005). All derive from the ledger; no new
persistent state except the disposable recon cache.

## Components

- **Dimensions (lenses).** `correctness, security, infra, docs, tests, perf, ui-ux, deps, craft`.
  Each = `prompts/dimensions/<id>.md` (appended to `explore.md`) + one `dimensions:` line in the
  rulebook. Extensible with no code change. Stamped onto findings (ledger `dimension` field) and
  the branch slug. Fingerprint stays dimension-free so the same defect never double-ships.
- **Recon.** Read-only, per-repo, cached; HEAD/TTL-invalidated. `lib/recon_signals.sh`
  (deterministic filesystem signals) + `prompts/recon.md` (model refines to per-dimension
  applicability + orientation notes). Narrows the candidate dimensions; never starves.
- **Rotation.** `last_dim_epoch(repo,dim)` (ledger query) + `select_dimension` (argmin, rulebook
  order breaks ties). Reproduces "security yesterday on A → docs today on A, security on B".
- **Multi-finding.** `limits.max_findings_per_item` (per-repo `findings:` override); explore emits
  a ranked `findings[]`; each ships on its own branch from its own fresh worktree (ADR 0011).
- **Observability.** Digest gains a coverage matrix (days since each repo×dimension serviced) and
  a per-dimension merge-rate (the ADR 0009 tuning signal).

## Config (rulebook.yaml)

```yaml
limits:
  max_open_branches: 5          # sole throughput governor — size to morning review appetite
  max_findings_per_item: 2      # N ranked findings per repo/pass (per-repo `findings:` overrides)
recon:
  enabled: true
  ttl_days: 7
dimensions:                     # ORDER = cold-start / tie priority
  - correctness
  - security
  - infra
  - docs
  - tests
  - perf
  - ui-ux
  - deps
  - craft
repos:
  - path: …
    mode: branch-fix | findings-only
    base: <ref>                 # optional
    findings: <N>               # optional per-repo override
    dimensions: a,b,c           # optional per-repo override (comma scalar; beats the global set)
```

All new keys are optional with backward-compatible defaults in `lib/parse_rulebook.py`
(`max_findings_per_item` defaults to 1 = pre-v2 behavior when the key is absent).

## Adapter seam (ADR 0001)

Policy lives in the Runner (dimension list, `select_dimension`, `last_dim_epoch`, recon cache/TTL,
`recon_signals.sh`, per-finding loop and worktrees, ledger fields, digest). Judgment lives behind
`run_agent()` (recon refinement, dimension-aimed explore). Mock adapters (`mock_recon`,
`mock_explore`, `mock_fix`) exercise every path deterministically, so the whole system is testable
without a model.

## Phased build (all four landed together this cycle)

1. **Multi-finding** — array schema + per-finding fresh worktrees + cap-per-finding (ADR 0011).
2. **Dimensions + rotation** — lens files, ledger `dimension`, `select_dimension`, coverage matrix.
3. **Recon** — signals probe + recon prompt + cache + applicability narrowing.
4. **Tuning** — per-dimension merge-rate in the digest.

Each phase was verified end-to-end in an isolated mock sandbox.

## Risks & open questions

1. **Cap sizing.** N × branch-fix repos can exceed the cap in one pass; the cap truncates
   (backpressure), so it stays the honest governor. Current: cap 5, N 2.
2. **Merge-conflict clustering.** Two same-night branches touching one file conflict at the second
   merge; accepted for v2 (sequential morning merges; harvest still detects the merge).
3. **UNVERIFIED volume.** `ui-ux`/`perf` ship mostly flagged-unproven; at N/night this is a stream.
   Watch the per-dimension merge-rate; option: per-dimension findings-only semantics.
4. **Budget.** More stages/findings grow subscription-window use; `runs.jsonl` meters per stage.
   Lever: a `--model` downgrade for recon (a cheap survey).
5. **Cold-start dimension priority.** The `dimensions:` list order decides the first lens every
   repo gets; currently `correctness` then `security`.
6. **Recon exclusion trust.** A wrong `applicable:false` silently starves a dimension; mitigated by
   per-repo overrides, the never-starve fallback, and `—` visibility in the matrix. Open: should
   recon only ever raise priority, never exclude?
