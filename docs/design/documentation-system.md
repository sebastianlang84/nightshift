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
                           #   + finding fingerprint = sorted(files):type:symbol, ADR 0014 — line
                           #   numbers excluded), all nights — SINGLE TRUTH
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
| **Finalize** (Brain) | `review.md` | successful push → `shipped`; failed push → retryable `push-failed`; rejected work → `abandoned\|deferred` |
| **Digest** (end of night) | tonight's `ledger.jsonl` entries · all `review.md` | `digests/<date>.md` |
| **Human** (morning) | `digests/<date>.md`, then the branches | `rulebook.yaml` (governance only) |

Reads flow strictly downstream. The human touches exactly two things: the digest (read) and the
rulebook (write).

Orthogonal to the stages, the **Runner** wraps every stage invocation and appends one
`state/runs.jsonl` line of operational telemetry. The Runner is its single writer; the agents do not
self-report. Every field below is optional in the sense that it degrades to `null` when the CLI does
not report it (mock agent, older CLI output shapes) — telemetry can never fail a stage.

| field | meaning |
|-------|---------|
| `night` · `item` · `stage` · `start` · `duration_s` · `exit` | which invocation this was, and how it ended |
| `model` | the **adapter** name: `claude` \| `codex` \| `mock`. Stable identifier — harvest/digest code reads it |
| `model_id` | the model that **actually served** the stage, as reported by the CLI: `claude-opus-5`, `claude-opus-4-8[1m]`, `gpt-5-codex`, … — never the requested model |
| `tokens` | **output** tokens (name kept for backwards compatibility) |
| `input_tokens` · `cache_read_tokens` · `cache_creation_tokens` | input-side counters, i.e. how much context the stage consumed |
| `context_window` | the window the served model **actually ran with** (`200000`, `1000000`, …), as reported by the CLI — claude only; codex reports none |
| `cost_usd` | cost of the whole stage invocation — claude only (`total_cost_usd`); codex reports no cost |
| `model_cost_usd` | the slice of that cost attributed to `model_id`; differs from `cost_usd` only when a stage touched more than one model |

Where the numbers come from, and how to read them:

- **claude** — the `--output-format json` result object. `model_id` comes from `modelUsage`, whose
  keys *are* the real model IDs; a stage that touched several models is attributed to the heaviest
  consumer, and `context_window` / `model_cost_usd` are read from *that same* entry, so the three
  always describe one model. Note the casing asymmetry the CLI emits: `usage.*` is snake_case,
  `modelUsage.<id>.*` is camelCase. Token counters come from `usage.*`, where `input_tokens`
  **excludes** cache reads.
- **codex** — the `--json` event stream: counters from the last `turn.completed` (`token_count` in
  older shapes), `model_id` from the session/thread event. Codex's `input_tokens` **includes**
  `cached_input_tokens`, and it reports no cache-creation count — so do not compare the two adapters'
  `input_tokens` directly without accounting for that. It reports neither cost nor a context window;
  both stay `null` rather than being inferred.
- **Context-window sizing (200k vs `[1m]`).** `context_window` answers this directly: it is the
  window the model ran with, recorded as a fact, so no inference from token sums is needed. The
  token counters cannot answer it on their own — they are *cumulative per stage over every request
  the stage made*, not the peak context of a single request, so
  `input_tokens + cache_read_tokens + cache_creation_tokens` is only an upper **bound** on that peak.
  Use the two together: `context_window` says which variant was available, the cumulative sum still
  bounds how much of it any single request could have used. On a stage where `context_window` is
  `null` (codex, mock, older CLI shapes) the bound is all there is.

Statistics are derived from this file on demand and summarised in the digest; v1 records but does not
auto-act on them (distinct from the deferred §5 value-learning).

## Consequences / resolved questions

- **OPEN-QUESTIONS §2 (central vs per-repo memory): resolved → central.** There is one
  `ledger.jsonl`; per-repo views are *derived* from it by filtering, never kept as separate files
  (invariants 1 & 2). Format is JSONL append-only; the semantic/notes tier is **not** in v1.
- **`backlog.md` is cut for v1 (re-review §4): decided.** It was the semantic tier's last remnant —
  agent-authored free-prose with no provenance. Deferred ideas are instead `ledger.jsonl` rows with
  `outcome: deferred` (+ fingerprint), surfaced in a digest section. Same need, no confabulation
  surface, no hand-maintained parallel file.
- **A push is shipped only after remote success.** A failed push records `outcome: push-failed`
  with the attempted branch and commit SHA, appears in the digest, and remains eligible for retry;
  it never enters the shipped/dedup set.
- **`runs/` is ephemeral working state**, archived (not pruned) after the night for audit value;
  it is never a source of truth — `ledger.jsonl` is.
- **This mirrors the project's own doc philosophy** — `CONTEXT.md` = canonical current state,
  `docs/adr/` = decisions, append-only log = history — so there is *one* documentation mindset for
  both the meta layer (designing nightshift) and the runtime layer (nightshift at work).

_Related: [memory-model.md](memory-model.md) (this supersedes its two-tier proposal for v1),
[constitution-and-rulebook.md](constitution-and-rulebook.md) (rulebook.yaml), OPEN-QUESTIONS §2, §3, §6._
