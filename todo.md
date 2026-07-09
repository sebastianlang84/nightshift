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

## codemap structural index — fully autonomous (2026-07-10)

**Shipped.** explore/review can use `codemap_search`/`codemap_context` (an MCP tool — no Bash needed,
fits the capability model) to navigate structure instead of reading files blindly. **nightshift keeps
the index current itself**: before explore, the Runner runs `codemap index --approve --repo <repo>` —
local + incremental (seconds), so every run the index reflects tonight's code. No manual step, no
per-repo config, no staleness. `--approve` makes first-time indexing automatic because the rulebook is
already the human consent surface (you listed these repos). The agent runs in a throwaway worktree
(no index of its own), so the prompt tells it to query the stable real repo via `repoPath`. codemap
absent or an index failure → plain Read/Grep/Glob, no change. Kill switch: `NIGHTSHIFT_CODEMAP=0`.

Verified: MCP tool callable in the locked-down subprocess (`--tools` + `--dangerously-skip-permissions`);
full e2e where nightshift auto-indexed a sandbox and shipped a fix. Biggest payoff on large repos
(market-digest, 291 files) where blind reading is weakest and explore cost highest.

## Review = verify the claim, not judge the diff (2026-07-10)

**Shipped.** Reframed the pipeline around Sebastian's point (a review verifies a proposition against
truth — "is 2x = 4x/2" needs no diff/history) and the cold, first-contact reality (nightshift meets
most repos for the first time, with no privileged access to intent or history). Fable (cross-model)
hardened it into a policy:
- **explore** emits every finding as a FALSIFIABLE `claim` + a `verify` recipe + a `verifiability`
  class (`static` | `convention` | `runtime`); `confidence` redefined as "how completely provable
  statically", not vibes. Prefers correctness over craft. Craft is only raised if it cites THIS repo's
  own standard (else it's generic dogma → dropped).
- **review** runs the verification recipe against the RESULTING worktree (cwd = post-fix code; Grep is
  truth), and separates `proof: verified` from `proof: unproven`. Key guard: absence of a grep hit is
  not proof of absence when dynamic/string references (reflection, registries, CLI dispatch, entry
  points) are possible — so a clean grep is not blind trust. Unfalsifiable taste → abandon.
- **runtime findings** can't be statically proven (no Bash/execution) → ship only if safe-when-wrong,
  as `proof: unproven`, and the Runner stamps **[unverified]** on the PR title + digest so the morning
  human knows *this one needs tests before merge*. `proof`/`verifiability` now recorded in the ledger.
- Fixed the latent bug where review.md referenced a `worknote` the Runner never injected (the rewrite
  drops it — not seeing the producer's self-justification is the point: kills anchoring).
- **codemap role clarified:** `repoPath` indexes the REAL repo (no fix) → stale for "still unused
  after the edit"; verification uses Grep/Read over cwd (the worktree). codemap = locate, not verify.

Verified: live static e2e (`verifiability:static` → `proof:verified`, no stamp) + unproven-path
plumbing (digest + PR title stamped `[unverified]`).

## Craft / best-practice review — always on (2026-07-10)

**Shipped.** explore + review now cover **craft**, not just correctness: code smells, dead/unused
code, poor naming, needless complexity, inconsistency with the surrounding style. Grounded in the
repo's OWN standard (linter/formatter config, CONVENTIONS.md, CONTRIBUTING, surrounding code) — not
generic dogma — and held to the same smallness/reversibility/single-concern bar (no sweeping refactors,
no subjective restyle = churn). Finding types widened to
`bug|typo|doc|cleanup|smell|naming|convention|complexity`. Prompt-only change (explore.md, review.md);
always on. Verified with a claude e2e that found + fixed a pure-craft issue (unused `import os`, no
typo/bug present), shipped a correct 1-line diff.

## NEXT: verdict / harvest recording — the first human feedback loop

**This is the designated next build (Fable's ordering, 2026-07-10).** Today the ledger records
`shipped` and then goes deaf: it never learns whether the human **merged, closed, or deleted** the
branch/PR. That human verdict is the only real ground-truth signal in the whole system — and per Fable
it is worth more than any additional machine reviewer, because each same-vendor reviewer decorrelates
less than the last while the human verdict decorrelates completely. It is also the instrument that
finally *validates or refutes* craft-always-on: if craft PRs are mostly closed/deleted, craft mode is
a churn generator; if merged, it earns its keep.

Build sketch (do BEFORE any second-reviewer / merge-recommendation layer below):
- A harvest step (run at start of each night, and/or a `bin/harvest` command) that, for every ledger
  row with `outcome:"shipped"` and an open branch/PR, reconciles against reality: is the branch merged
  (`git branch --merged`, or the PR state via `gh pr view --json state,mergedAt`)? closed unmerged?
  deleted? still open? Write the result back as a `verdict` (merged | closed | deleted | open) + a
  timestamp — append a new ledger event rather than mutating the shipped row (keep it append-only).
- Surface it: a small stats line in the digest (merge rate, and merge rate split by `verifiability` /
  `proof` and by finding `type`) so the churn question is answered by data, not opinion.
- This is also what feeds the open-branch backpressure a truer signal (a closed/deleted branch frees a
  slot just like a merge). Builds on the review=verify work above (proof / verifiability per row).

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
- **Verify Layer 2 under `--dangerously-skip-permissions`** — DONE (2026-07-09). Adversarial test:
  registered `hooks/pretooluse-guard.sh` as a PreToolUse hook exactly as the Runner does, launched
  `claude 2.1.197` with the production env+flags, had it attempt `git ... commit --no-verify ...`. The
  guard **fired** — verbatim deny "nightshift: git --no-verify would bypass the pre-push confinement
  hook"; a control command ran, the `--no-verify` one did not. So Layer 1 (git hook) + Layer 2 (guard)
  both hold in the unattended mode. Residual closed.
- **Server-side branch restrictions** — now defense-in-depth, not the sole backstop (Layer 2 proven).
  Still worth adding GitHub branch protection on `main` (with `enforce_admins`, else the agent's own
  admin creds bypass it) per target repo. Per-repo, per-host.
- **Graduate a repo to `branch-fix`** only with explicit human OK — it is the first real `nightshift/*`
  push to a shared remote. (The 4 live repos are already branch-fix in rulebook.yaml — human-approved.)
- **Enable the scheduler** — DONE; timer armed, first live fire Fri 2026-07-10 03:00.

_Also 2026-07-09:_ caught + fixed a latent parser bug — `claude -p --output-format json` returns an
ARRAY on 2.1.197 (result object as an element, when a rate_limit_event is present), but the Runner
parsed object-only (`.result`) → every explore would have reported `found:false` (silent no-op, no
branches). Now normalises both shapes (commit f0e1898); proven with a real-claude e2e that found+fixed
4 README typos and pushed a `nightshift/*` branch, with zero live-state pollution (commit e833979).
