# nightshift — todo / future ideas

Running list of enhancements to build later. Not design tensions (those live in OPEN-QUESTIONS.md)
and not the ratified v1 scope (ADR 0004) — just good ideas parked with enough context to act on.

## Scheduler — nightly 03:00 (requested, soon)

**Concrete first target (user, 2026-07-09):** a systemd timer (or cron) that fires **every night at
03:00 local** and runs nightshift across all rulebook repos, unattended. This is what makes the
"runs all night" behaviour real (the open-branch cap already governs throughput; the scheduler
governs *when* + re-invocation).

_Resolved 2026-07-09:_ auto-PR is **done** — the Runner now opens a **normal (non-draft) PR** per
shipped branch (`gh pr create`, `NIGHTSHIFT_OPEN_PR=1` default; ADR 0004 amendment). Chosen over
draft so CI runs overnight and the morning triage sees a green/red check with the merge button live.

## Schedule management — templates / scripts (create / edit / delete)

Convenience tooling to manage nightshift's schedule(s) efficiently instead of hand-editing timers.
Small scripts (or templates) to **create / edit / delete** scheduled runs — wrap the systemd-timer
(or cron) setup that will drive the nightly loop: install/enable/disable/list, sane defaults
(when to run, adaptive backoff), and a `--dry-run`. Pairs with the eventual scheduler that makes the
"runs all night" behaviour real (the open-branch cap already handles throughput; the scheduler
handles *when* and re-invocation between merges).

## PR / branch review mode — merge-recommendation layer

A separate mode that reviews **all open `nightshift/*` branches (or PRs)** and gives a
**merge / don't-merge recommendation** per branch — an extra review layer *on top* of the pipeline,
run with an **independent, empty context** (not the thread that produced the change).

**Value:**
- *Convenience / harvest:* turns the morning triage from "fetch + diff + judge each branch" into a
  ranked recommendation list — directly attacks the harvest-friction weak spot (re-review §2d/§5).
- *Extra safety:* a second, independent judgment before the human merges.

**Design notes for later:**
- Read-only + advisory: it recommends, never merges or pushes (consistent with "human merges").
- Fresh/empty context per branch reduces transcript-sycophancy — but same-model review still shares
  the producer's blind spots (re-review §2, fable wild-idea #8). For true decorrelation, run this
  layer on a *different model / vendor* (the opt-in API-key path, ADR 0003 allows it).
- Natural output: append recommendations to the morning digest (or a `reviews/<date>.md`).
- Could reconcile with the ledger: record the recommendation + (later) the human's actual verdict —
  the first place a real merge/verdict signal could re-enter the system (re-review §5).
