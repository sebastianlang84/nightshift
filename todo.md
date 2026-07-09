# nightshift — todo / future ideas

Running list of enhancements to build later. Not design tensions (those live in OPEN-QUESTIONS.md)
and not the ratified v1 scope (ADR 0004) — just good ideas parked with enough context to act on.

## Scheduler — nightly 03:00 — DONE (2026-07-09)

**Shipped.** A systemd *user* timer fires `bin/nightshift-cron.sh` every night at 03:00 local
(`scheduler/nightshift.{service,timer}`, `Persistent=true` so a missed night runs at next wake,
`RandomizedDelaySec=120`). The launcher adds the three unattended-run essentials: a single-instance
`flock`, an explicit PATH (systemd's minimal env can't see `~/.local/bin/{claude,gh}`), and a
timestamped log under `~/.local/state/nightshift/logs/` (plus journald). Enabled + linger on; first
live fire Fri 2026-07-10 03:00. Manage with `bin/schedule.sh {install|enable|disable|status|logs|
dry-run|uninstall}` — this also subsumes the old "schedule management templates/scripts" item.

_Also resolved 2026-07-09:_ auto-PR — the Runner now opens a **normal (non-draft) PR** per shipped
branch (`gh pr create`, `NIGHTSHIFT_OPEN_PR=1` default; ADR 0004 amendment). Chosen over draft so CI
runs overnight and the morning triage sees a green/red check with the merge button live.

Open follow-ups on the scheduler (not blocking):
- **Sleep/suspend:** if the workstation suspends overnight the 03:00 fire is missed; `Persistent=true`
  catches it at next wake, but a true "wake to run" needs an RTC wake alarm — revisit if it matters.
- **Adaptive cadence / backoff** (from the nightly-review-pipeline skill): skip repos with no new
  commits, back off after empty runs. nightshift's open-branch cap already self-throttles, so this is
  a cost optimisation, not a correctness need.

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
