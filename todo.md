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

## Deployment topology — the tool vs. the repos it tends (2026-07-09)

nightshift-the-tool lives in ONE git repo (github.com/sebastianlang84/nightshift), but is meant to
run on **several machines**, each tending that machine's **local** repos — which live on different
hosts (GitHub, Bitbucket e.g. `~/partflow`, GitLab, or bare/local). The control repo's host has
nothing to do with the target repos' hosts.

**Already handled (verified 2026-07-09):**
- Everything machine-specific is git-ignored — `rulebook.yaml`, `state/` (ledger/runs), `digests/`,
  `worktrees/`, `sandbox/`. So `git pull` to update the tool never clobbers local config/state.
- `NIGHTSHIFT_HOME` is self-derived from the script path — no hardcoded location; clone anywhere.
- The core loop is host-agnostic (pure git over SSH: fetch/branch/push `nightshift/*`). The pre-push
  confinement is pure git and works against any remote.

**Still to handle:**
- **Document the deployment model** (README or `docs/design/deployment.md`) + graduate to an ADR:
  per-machine bootstrap = install `claude`+`jq` (+PR CLI) → clone → write `rulebook.yaml` → `schedule.sh
  install/enable`. Tool updates = `git pull` per machine.
- **One machine per target repo (v1 constraint).** The ledger is local per install; if the same repo
  is tended from two machines, ledgers diverge → duplicate findings/branches. State the constraint;
  a shared/remote ledger is out of v1 scope (memory-model.md).
- **Host-aware PR automation** — see next item; today PRs are GitHub-only, so Bitbucket/GitLab targets
  get bare branches regardless of where the control repo lives.

## Multi-host PR automation (Lücke 1, 2026-07-09)

`open_pr` only recognises `*github.com*` and shells out to `gh pr create`. On Bitbucket/GitLab remotes
it logs "no GitHub remote — PR skipped" and pushes a bare `nightshift/*` branch. So on `~/partflow`
(Bitbucket) the morning triage is branch-based, not PR-based.
- Decision needed: implement Bitbucket (REST API / `bb`) and/or GitLab PR creation, dispatched by the
  remote host — or accept bare branches and set `NIGHTSHIFT_OPEN_PR=0` to drop the misleading log.
- If implemented: keep it best-effort (branch is already pushed; a PR-API failure must not fail the run),
  mirroring the current GitHub path.

## Cost ceiling (2026-07-09)

No dollar/turn budget cap exists — the only caps are open-branch backpressure + per-run branch count
(ADR 0005). Observed: one findings-only explore on the real partflow codebase cost **~$4.60 / 357s**
(vs $0.18 on the toy sandbox) because explore reads many files under `--max-turns 25`. branch-fix over
several repos/night could run to tens of dollars.
- Consider a rulebook knob: per-stage `max_turns`, and/or a `ccusage`/`claude-token-lens` spend stop
  (ADR 0003 already names usage-window observation as the budget backstop — wire it in).

## Pre-go-live checklist (open from the 2026-07-09 readiness review)

The claude production path is now proven end-to-end (findings-only on partflow, accurate finding, zero
remote writes). Before enabling the live nightly timer on a real repo:
- **Verify Layer 2 under `--dangerously-skip-permissions`** — whether the PreToolUse guard fires in that
  mode is unconfirmed (hook-spec.md "Known residual"). Layer 1 (git-level) held in testing. Either run an
  adversarial test (agent instructed to attempt `git push origin HEAD:main`, observe the guard) or rely on
  Layer 1 + server-side branch restrictions and document that choice.
- **Server-side branch restrictions** on each target repo/host (Bitbucket branch permissions / GitHub
  branch protection) — the backstop that does not depend on agent behaviour. Per-repo, per-host.
- **Graduate a repo to `branch-fix`** only with explicit human OK — it is the first real `nightshift/*`
  push to a shared remote.
- **Enable the scheduler** (`schedule.sh install && enable` + linger) once the above are green.
