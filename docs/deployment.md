# Deployment & operations

Operator guide for running Nightshift unattended on a machine. For *what* Nightshift is and its
architecture, see [`CONTEXT.md`](../CONTEXT.md); for decisions, [`docs/adr/`](adr/).

## Model

Nightshift is a set of bash scripts plus a rulebook and local state — no server, no database. A
systemd **user** timer fires the launcher nightly; the launcher runs the orchestrator, which pushes
`nightshift/*` branches to each managed repo's `origin`. You review and merge in the morning. The
only durable state is a local append-only ledger.

**One installation owns each target repo** — never point two installations at the same repo (their
ledgers diverge silently: duplicate branches, broken caps and rotation). See
[ADR 0012](adr/0012-one-installation-per-target-repo.md).

## Bootstrap (per machine)

1. **Clone** the Nightshift repo somewhere stable — this path becomes `NIGHTSHIFT_HOME`, and the
   installed systemd unit hard-codes it. Moving the checkout later requires re-running `install`.
2. **Provide the agent CLI.** Nightly runs default to the `claude` adapter (`NIGHTSHIFT_AGENT=claude`;
   `codex` also supported). The chosen CLI must be on `PATH` — the launcher prepends
   `~/.local/bin:/usr/local/bin:/usr/bin:/bin` because systemd user services start with a minimal
   env. `git` and (optionally) `gh` must also be reachable there.
3. **Write the rulebook.** Copy `rulebook.example.yaml` to `rulebook.yaml` and list the repos this
   installation may touch, their `mode` (`branch-fix` / `findings-only`), optional `base:`,
   `dimensions:`, and the `limits:` block. The parser rejects a malformed rulebook and the run aborts
   rather than silently servicing a partial fleet.
4. **Install and enable the timer:**
   ```
   bin/schedule.sh install     # write + reload the user units
   bin/schedule.sh enable      # start the nightly timer + enable linger (fires while logged out)
   bin/schedule.sh status      # confirm; also reports any drop-in overrides
   ```
5. **Prove the wiring** without spending quota:
   ```
   bin/schedule.sh dry-run     # runs the launcher now with the mock agent
   ```

## Updating

- `git -C "$NIGHTSHIFT_HOME" pull` to update the code. The units call scripts by path, so no
  reinstall is needed unless you **move** `NIGHTSHIFT_HOME` (then re-run `bin/schedule.sh install`).
- After changing the schedule cadence, prefer editing `scheduler/nightshift.timer` in the repo and
  re-running `install`. If you use `systemctl --user edit` instead, `schedule.sh status` will flag the
  drop-in override so the effective cadence is never hidden.

## Local state (all under `NIGHTSHIFT_HOME` unless overridden)

| Path | What | Override |
|------|------|----------|
| `state/ledger.jsonl` | The memory: findings, shipped, abandoned, verdicts (append-only) | `NIGHTSHIFT_STATE_DIR` |
| `state/runs.jsonl` | Per-stage telemetry (tokens, cost, duration) | `NIGHTSHIFT_STATE_DIR` |
| `state/recon/` | Per-repo recon caches (derived, disposable) | `NIGHTSHIFT_STATE_DIR` |
| `state/dim-scans/` | Per-(repo,dim) explore markers driving rotation | `NIGHTSHIFT_STATE_DIR` |
| `runs/<date>/` | Per-item working dirs (prompts, agent output) | `NIGHTSHIFT_RUNS_DIR` |
| `digests/<date>.md` | The morning report | `NIGHTSHIFT_DIGEST_DIR` |
| `~/.local/state/nightshift/logs/<date>.log` | Launcher log (also in journald) | `NIGHTSHIFT_LOG_DIR` |
| `${TMPDIR:-/tmp}/nightshift-worktrees/` | Throwaway per-item worktrees | `NIGHTSHIFT_WORKTREES` |
| `${TMPDIR:-/tmp}/nightshift.lock` | Single-instance flock | `NIGHTSHIFT_LOCK` |

The ledger IS the installation. Back it up / move it with the installation; losing it loses dedup,
backpressure, and rotation history.

## Branch-only operation across Git hosts

The credential-free baseline is **push a branch, nothing else**: Nightshift pushes `nightshift/*`
over the repo's existing `origin` transport (usually SSH) and never touches `main`. This works on any
host (GitHub, Bitbucket, GitLab, a bare remote) because it needs no host API.

Opening a PR is **optional and off by default** (`NIGHTSHIFT_OPEN_PR=1`). A PR is a host-API object
needing a host credential the SSH transport does not provide:

- **GitHub:** requires `gh` authenticated in the run environment. The PR targets the branch's
  configured base.
- **Other hosts:** no PR is opened; the pushed branch remains the unit of review.

Confinement holds regardless: the agent only ever reads/edits inside a throwaway worktree and can
never push outside `nightshift/*` (see [`docs/design/hook-spec.md`](design/hook-spec.md)).

## Daily operation

- **Morning:** read `digests/<date>.md`; review open branches with `bin/review-branch.sh`; merge or
  delete. Deleting/merging frees the open-branch cap so the next night resumes.
- **Record verdicts** the machine can't derive with `bin/harvest.sh verdict <selector> <verdict>`;
  harvest also reconciles merged/dropped branches automatically each run.
- **Independent branch review (opt-in):** set `NIGHTSHIFT_BRANCH_REVIEW=1` to have a fresh read-only
  agent add a merge / do-not-merge second opinion for every open branch to the digest. Set
  `NIGHTSHIFT_ADVISOR_AGENT` (e.g. `codex` when the night runs on `claude`) for a different vendor's
  eyes. It never merges or pushes. Costs extra tokens, so it is off by default.
- **Logs:** `bin/schedule.sh logs [N]` or `journalctl --user -u nightshift.service`.

## Teardown

```
bin/schedule.sh uninstall   # stop the timer, remove the units AND any drop-in overrides
```

State under `NIGHTSHIFT_HOME` (ledger, runs, digests) is left in place — remove it by hand if you
want a clean slate.
