# nightshift — active backlog

Only active, actionable work belongs here. Items are ordered by priority.

- Durable decisions: [`docs/adr/`](docs/adr/)
- Unresolved architectural choices: [`OPEN-QUESTIONS.md`](OPEN-QUESTIONS.md)
- Implemented behavior: `README.md`, `CONTEXT.md`, and `docs/design/`
- Completed work: remove it; Git history and ADRs are the record

Last triaged: 2026-08-26 against `main`. The Fable v2 review findings and the earlier P1/P2 backlog are
resolved and removed: fail-closed rulebook parsing, configured-base PRs, recon never on the live
checkout, collision-safe recon caches and work-item IDs, empty-Explore rotation, Fix-stage write
confinement (R8), the `surface` route + bounded findings-only loops, hardened recon cache writes,
digest merge-rate breakdowns, the deployment guide (ADR 0012), independent branch review, the
wall-clock spend budget (ADR 0013), stable finding identity + lifecycle (ADR 0014), and recon
yield-weighting / never-exclude with the empty-scope feedback loop (ADR 0015).

## Active security work

- **PR API credential:** automatic PR opening stays disabled. Before re-enabling it, scan the
  model-derived PR title/body for secrets and re-issue the machine's `gh` credential without
  `admin:public_key` (risk-analysis R12/N6). Credential rotation is an operator action.

## Runner behavior

- **`max_branches_per_run` overshoots by up to one pass.** The `MAX_RUN_BRANCHES` check sits at the
  top of the pass loop in `run_night` ([`bin/nightshift.sh`](bin/nightshift.sh)), while the
  open-branch cap is re-checked per item inside the pass. A pass therefore runs every repo to
  completion before the ceiling is consulted again: observed 2026-08-28 with `max_branches_per_run: 3`,
  where pass 1 shipped 5 branches (two repos at a findings budget of 2, plus one) and what actually
  stopped the run was `max_open_branches: 5`. Nothing is unsafe about this — the open-branch cap is
  the real bound and it held — but the knob does not mean what its name says, which matters for an
  operator throttling a run deliberately. Either move the check next to the per-item cap check, or
  rename it and say in [`rulebook.example.yaml`](rulebook.example.yaml) that it is a per-pass floor.

## `ideas` lens — operator-supplied work items

- **Add an `ideas` lens fed by a per-repo `ideas_cmd`.** Today the steward only self-selects findings; CONTEXT.md lists "general task runner" as a non-goal, and this stays true: the lens must not know any repo's schema or tooling. Contract, modelled on `test_cmd` and on the read-only structure report of the `knowledge` lens: the rulebook gains an optional per-repo `ideas_cmd`; the runner executes it outside the sandbox before Explore, expects JSONL on stdout (one object per idea: `id`, `title`, `text`, `source`), and passes the file to Explore as lens input. Repos without the key are not applicable for the lens and recon skips it. Explore needs a lens-specific prompt (`prompts/dimensions/`): an idea is a feature request, not a falsifiable defect, so the finding contract changes to "one idea → one bounded, reversible change proposal with a verify recipe", and ideas the model judges out of scope are reported as such, never silently dropped. Record the decision as an ADR before implementing. First consumer: partflow (feedback rows of type `IDEA`, exporter lives in that repo).

## Session reflection — the PDCA job

Design and rationale: [ADR 0035](docs/adr/0035-a-reflection-finding-is-verified-before-it-becomes-a-rule.md).
That ADR is the authority on the pipeline and the reviewer policy; this section lists what has to be
built and what has to be settled first.

**Prerequisites — both answered 2026-09-16, so building can continue to the model stages.**

- ~~Where the payload may be sent.~~ The day's material may go to the proxied third-party models,
  GLM included — the same path the prototype used. This is what keeps a nightly run affordable, and
  it means a third vendor sees material that only Anthropic and OpenAI saw before.
- ~~The execution identity.~~ The `build_test_sandbox` hull rather than a dedicated account, which is
  not reachable without IT, and no request opened with IT for one. Specified in
  [`docs/design/reflection-confinement.md`](docs/design/reflection-confinement.md).

**Order of work.** The two prerequisites block *enabling* the job, not building it. The first two
deliverables run no model and send nothing anywhere, so they are built and tested first.

1. ~~Extractor and citation checker.~~ Done: `lib/extract_session.py` and
   `lib/check_citations.py`, covered by `tests/test-session-extract.sh` and
   `tests/test-citation-check.sh`. Both tests were mutation-checked — breaking the origin filter,
   the id derivation or the quote matcher turns them red.
2. ~~Settle the citation format.~~ Done, and recorded in the two modules' docstrings: a turn id is
   `<session>:<native>` derived from the source; a quote resolves on whitespace- and
   typography-normalised substring match with case significant; elision is allowed, must keep its
   fragments in order, and is flagged for the judge; an ordering claim resolves on recorded order
   within a session and on timestamps across sessions; one unresolved quote drops its finding.
3. ~~Draft the execution identity.~~ Done:
   [`docs/design/reflection-confinement.md`](docs/design/reflection-confinement.md). It ends in three
   questions for the operator, and nothing is deployed until they are answered. Short version: a
   dedicated account is not reachable from this side, so the draft proposes the `build_test_sandbox`
   hull instead, failing closed without bwrap.
4. ~~Generate prompt and judge stage.~~ Done, now that the payload destination is settled.
5. **The runner and its unit.** What remains. It wires the five steps together, applies the hull, and
   is the first piece that runs unattended — so it is also where the fail-closed rule lives: no
   bwrap, no run.

The severity taxonomy and the tool-result question stay open through all of this. Neither blocks
step 1: findings come out unranked, and the extractor's first version drops tool results exactly as
the prototype did.

**Deliverables.**

- ~~Extractor~~ — `lib/extract_session.py`.
- ~~Citation checker~~ — `lib/check_citations.py`.
- ~~Generate prompt~~ — `prompts/reflection/generate.md`.
- ~~Judge stage input~~ — `lib/build_judge_input.py` plus `prompts/reflection/judge.md`.
- **Entry point and unit.** The one piece still missing: a runner that walks a day's transcripts
  through extract, generate, check, build and judge, inside the hull
  ([`docs/design/reflection-confinement.md`](docs/design/reflection-confinement.md)), and writes the
  report. Nothing runs on a schedule until it exists.

**Open decisions inside the design.**

- **The severity taxonomy.** ADR 0035 assigns severity from the finding's type rather than asking the
  model. The types, the mapping, and who classifies do not exist yet; until they do the pipeline
  reports findings unranked.
- **What the extractor keeps of tool results.** Dropping them all makes any finding about what a
  command returned unsupportable, which both prototype reviewers flagged. Keeping them all
  reintroduces the size and the secrets problem.
- **Whether the elided flag is enough.** The checker allows an elided quote and flags it, because an
  exact quote can still reverse its source by dropping a clause — the prototype did exactly that.
  Whether the judge stage acts on that flag reliably is unmeasured.

## Conditional / deferred

- **Wake from suspend:** only if catch-up-on-wake is operationally insufficient.
- **Adaptive cadence:** only if measured empty-run cost justifies more scheduler state.
- **Bitbucket/GitLab PR APIs:** only when credentials and operator demand exist; branches remain the
  credential-free baseline.
- **Full containment:** the *ship gate* is done — `bwrap`, network off by default, no credential
  reach ([ADR 0026](docs/adr/0026-the-ship-gate-runs-in-a-sandbox.md)). Still open, and now the head
  of the queue: a dedicated unprivileged account (risk-analysis M1) and the same sandbox around the
  **agent** process itself (M2), where path confinement is still the only boundary.
- **Server branch protection:** per-host operator defense-in-depth, not a Nightshift code task.
