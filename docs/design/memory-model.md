# Design note — Memory (the ledger)

> **⚠️ Superseded by [documentation-system.md](documentation-system.md) + [ADR 0004](../adr/0004-v1-scope-branch-isolated-steward.md).**
> The two-tier split (episodic + semantic/working memory), reflect/compaction, and the self-authored
> backlog below are **cut from v1**. v1 memory is a single central append-only `ledger.jsonl` (per-repo
> views *derived*, never stored); the "abandoned" set is folded into the ledger as `outcome: abandoned`
> rows carrying a finding fingerprint (file + issue-type + line-window), not a separate `abandoned.jsonl`.
> Kept for history.

- Status: **idea-stage, not decided.** Captures the 2026-07-08 discussion for review.
- No implementation details on purpose. Open decisions are flagged inline.

## Why memory is the core

nightshift's novelty (ADR 0002) is that it makes progress *across nights* instead of
repeating work. That only exists if the steward remembers. Memory is not a side feature;
it is half of the thing we are building (Brain + **Memory**).

## Idea: two kinds of memory, not one

The discussion converged on splitting memory by *nature*, because they want different formats
and different lifecycles.

### a) Episodic log — immutable "what / when / outcome"
- Every action recorded: `(repo, target, action, lens, outcome, branch/PR, file-SHA, tokens/time, timestamp)`.
- **Dedup / don't-repeat:** a finding-hash, so the same thing is not re-raised nightly. An entry
  goes *stale* when the underlying file's SHA changes (the finding may be real again).
- **Abandoned set:** recognised false-positives that must **not** be reopened every night.
- **Budget receipts:** spend per night → feeds budget-awareness and the morning digest.

### b) Semantic / working memory — curated, agent-writable
- **Self-authored backlog (yes, explicitly wanted):** things the agent *saw but deliberately
  deferred* ("saw X, out of budget", "Y needs a human decision"). The agent creates its own TODOs.
- **Per-repo understanding:** running notes — "tests here are flaky", "owner dislikes dependency
  bumps", "this module is hot". The distilled character of each repo.
- **Selection state:** repo score, last-touched, backoff/cadence counters.

### The bridge: reflect / compaction
A periodic step (Aeon's reflect/flush pattern) compresses the episodic log into the semantic
memory, so the working notes stay small enough to fit in an agent's context. This is what lets a
modern LLM actually *use* the memory instead of drowning in a raw log.

## Idea: hybrid format, git-tracked

Not "just a DB" and not "just Markdown". Each kind gets the format it deserves:

- **JSONL** for the log — append-only, diff-friendly, `jq`-queryable, dedup by hash, no DB server.
- **Markdown** for anything the agent reads *and writes* — LLMs handle it natively, it is
  git-diffable and human-readable.
- **git itself is part of the memory** — history, blame, rollback for free (the Ralph-loop insight
  from prior-art). 
- **SQLite only if a query genuinely needs it** — not pre-emptively.

Illustrative shape (sketch, not a schema):

```
.nightshift/                     # central steward state — NOT scattered into target repos
  ledger.jsonl                   # append-only events — machine truth
  repos/<slug>/
    notes.md                     # curated repo understanding (agent rewrites/compacts)
    backlog.md                   # self-authored, deferred TODOs
    abandoned.jsonl              # don't-retry, keyed by finding-hash
    state.json                   # score, last_run, backoff
  digests/2026-07-08.md          # morning summary
```

## What memory can do — capability list

1. Log what / when / outcome / cost (episodic).
2. Dedup & don't-repeat (finding-hash + file-SHA staleness).
3. Remember false-positives (abandoned set).
4. Hold the agent's own deferred TODOs (self-authored backlog).
5. Carry a per-repo understanding that improves over time.
6. Hold selection state (score, cadence, backoff).
7. Feed the morning digest.
8. Feed budget-awareness (receipts).

## Open decisions (do not resolve yet)

- **Central vs per-repo `notes.md`.** Recommendation: **central & repo-external**, because writing
  extra files *into* third-party/enterprise repos pollutes them and may be forbidden. Writing
  findings *into* a repo's task file is the job of the "hands" (`nightly-review-pipeline`), not the
  brain. — *user to confirm.*
- Log format lock-in: JSONL now, SQLite later only on query pressure. Confirm the trigger.
- Staleness rule: file-SHA vs repo-SHA vs time-based expiry.

_Related: [constitution-and-rulebook.md](constitution-and-rulebook.md),
[self-evaluation.md](self-evaluation.md) (retrospective writes into semantic memory),
OPEN-QUESTIONS §2._
