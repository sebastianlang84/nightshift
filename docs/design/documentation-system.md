# Design note — Documentation & state system

- Status: **accepted (v1), 2026-07-08.** The one system every run and the human use for their docs.
- Should be ratified as an ADR alongside the v1-scope ADR; captured here first so it is concrete.

## Why

The pipeline is a sequence of **separated single-job runs** (Explore → Fix → Review → …), each a
fresh headless process. State survives *only* as files on disk and in git — so the artifacts **are**
the memory and the audit trail. If every run invents its own file, that trail rots. This note fixes
one coherent scheme so it is always clear **what is stored where** and **who reads/writes it when.**

## The four invariants

These are what make the system "logical in itself" — hold them and the structure follows:

1. **One home per fact.** Every piece of information has exactly one canonical location. Nothing is
   maintained in two places.
2. **Human-facing docs are *derived*, never maintained in parallel.** The morning digest and the
   per-repo "what have I already done here" view are *generated* from the log — never hand-kept.
   This is the primary defence against drift.
3. **One writer per artifact.** Each document has exactly one stage that writes it; every other
   stage only reads. No concurrent-write ambiguity (also future-proofs against parallelism, which
   v1 does not do).
4. **Format follows audience.** Machine hand-off and memory are structured (`.jsonl` / `.yaml`);
   the two human touchpoints are Markdown.

## Two physical homes

Output lands in the **target repos**; the record and governance live in the **control repo** (this
one). Clean split: target repos carry *output*, the control repo carries *record + governance*.

### Control repo (this repo) — record & governance

```
rulebook.yaml              # governance: allowed repos, per-repo mode, limits — HUMAN writes
state/
  ledger.jsonl             # append-only: every work-item outcome (incl. outcome: abandoned|deferred
                           #   + finding fingerprint = file+type+line-window), all nights — SINGLE TRUTH
  runs.jsonl               # append-only telemetry: one line per stage invocation — RUNNER writes
runs/<date>/<item-id>/     # ephemeral per-night hand-off (archived after the night)
  finding.json             #   Explore writes
  worknote.md              #   Fix writes
  review.md                #   Review writes
digests/<date>.md          # derived morning digest — HUMAN reads
CONVENTIONS.md             # branch naming, item-id scheme, finding-hash rule
```

### Target repo — minimal footprint, output only

```
nightshift/<…> branch + commits    # the actual work; the commit message is the per-change doc
NIGHTSHIFT.md (optional)           # local "don't touch" rules, robots.txt-style — Explore reads
```

## Who reads/writes what, when (the matrix)

| Stage | reads | writes |
|-------|-------|--------|
| **Select** (Brain) | rulebook · ledger (distilled, incl. `outcome: abandoned\|deferred` rows) | — (picks a repo) |
| **Explore** | target repo · NIGHTSHIFT.md · "already done here" (derived from ledger) | `finding.json` |
| **Fix** | `finding.json` · target files | branch + commits · `worknote.md` |
| **Review** | `finding.json` · `worknote.md` · the diff | `review.md` |
| **Finalize** (Brain) | `review.md` | push **or** append `ledger.jsonl` with `outcome: abandoned\|deferred` + fingerprint |
| **Digest** (end of night) | tonight's `ledger.jsonl` entries · all `review.md` | `digests/<date>.md` |
| **Human** (morning) | `digests/<date>.md`, then the branches | `rulebook.yaml` (governance only) |

Reads flow strictly downstream. The human touches exactly two things: the digest (read) and the
rulebook (write).

Orthogonal to the stages, the **Runner** wraps every stage invocation and appends one
`state/runs.jsonl` line — operational telemetry: stage, model, start, duration, tokens **and cost**
(from the CLI's `--output-format json` usage/`total_cost_usd`), exit. The Runner is its single writer; the
agents do not self-report. Statistics are derived from it on demand and summarised in the digest;
v1 records but does not auto-act on them (distinct from the deferred §5 value-learning).

## Consequences / resolved questions

- **OPEN-QUESTIONS §2 (central vs per-repo memory): resolved → central.** There is one
  `ledger.jsonl`; per-repo views are *derived* from it by filtering, never kept as separate files
  (invariants 1 & 2). Format is JSONL append-only; the semantic/notes tier is **not** in v1.
- **`backlog.md` is cut for v1 (re-review §4): decided.** It was the semantic tier's last remnant —
  agent-authored free-prose with no provenance. Deferred ideas are instead `ledger.jsonl` rows with
  `outcome: deferred` (+ fingerprint), surfaced in a digest section. Same need, no confabulation
  surface, no hand-maintained parallel file.
- **`runs/` is ephemeral working state**, archived (not pruned) after the night for audit value;
  it is never a source of truth — `ledger.jsonl` is.
- **This mirrors the project's own doc philosophy** — `CONTEXT.md` = canonical current state,
  `docs/adr/` = decisions, append-only log = history — so there is *one* documentation mindset for
  both the meta layer (designing nightshift) and the runtime layer (nightshift at work).

_Related: [memory-model.md](memory-model.md) (this supersedes its two-tier proposal for v1),
[constitution-and-rulebook.md](constitution-and-rulebook.md) (rulebook.yaml), OPEN-QUESTIONS §2, §3, §6._
