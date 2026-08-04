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
2. **Provide the binaries a run shells out to.** Nightly runs default to the `claude` adapter
   (`NIGHTSHIFT_AGENT=claude`; `codex` also supported), but the agent CLI is only one of the tools the
   Runner invokes. All of these must be reachable from the launcher's `PATH`, which is
   `/usr/local/bin:/usr/bin:/bin:~/.local/bin` — systemd user services start with a minimal env, so
   the launcher sets that list explicitly (system dirs first, deliberately: see
   [`docs/design/risk-analysis.md`](design/risk-analysis.md) R10). "It works in my login shell" is not
   the test.

   | Binary | Used for | Missing |
   |--------|----------|---------|
   | `claude` or `codex` | every stage that thinks | every stage fails; nothing ships |
   | `git` | worktrees, commits, branch pushes | run aborts |
   | `jq` | every ledger and telemetry read/write | run aborts |
   | `python3` (stdlib only — nothing to install) | rulebook parsing, JSON extraction, finding probes | run aborts |
   | `gh` | opening PRs when `NIGHTSHIFT_OPEN_PR=1` | branch still pushed, no PR |
   | `codemap` | structural index handed to explore | falls back to Read/Grep/Glob |

   Only the last two degrade — they are probed with `command -v`. `git`, `jq` and `python3` are hard
   dependencies called unqualified and unguarded: parsing the rulebook is a `python3` call on the
   first code path of every entry point, so a host missing one loses the entire night. Step 5's
   `dry-run` is the cheap way to find out before a real run does.
3. **Write the rulebook.** Copy `rulebook.example.yaml` to `rulebook.yaml` and list the repos this
   installation may touch, their `mode` (`branch-fix` / `findings-only`), optional `base:`,
   `dimensions:`, and the `limits:` block. The parser rejects a malformed rulebook and the run aborts
   rather than silently servicing a partial fleet.

   **Give every `branch-fix` repo a `test_cmd`** ([ADR 0022](adr/0022-a-repos-own-tests-gate-the-ship.md)).
   It is the repo's own suite, run in the worktree just before the commit; a nonzero exit means no
   branch is created and the ledger records `tests-failed`. Without it the repo ships **ungated** —
   the Review stage proves the finding is fixed, never that nothing else broke, so a regression only
   surfaces if that repo happens to have CI. Keep the command fast: it runs once per shipped finding,
   inside the night's wall-clock budget, and is bounded by `limits.test_timeout_seconds` (default 600).
   ```yaml
   repos:
     - path: /home/you/dev/yourrepo
       mode: branch-fix
       test_cmd: uv run pytest -q
   ```
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

### Model and flags (optional, per host)

Nightshift **commits no model of its own**. A host declares the model it wants in its own
`rulebook.yaml` (untracked) under `agent:` — see below; the variables here override that per run,
e.g. a smaller/cheaper model for one night.

```yaml
agent:
  claude_model: claude-opus-5
  codex_model: gpt-5.6-sol
```

| Variable | Adapter | Effect when unset |
|----------|---------|-------------------|
| `NIGHTSHIFT_CLAUDE_MODEL` | claude | the rulebook's `agent.claude_model`, else no `--model` |
| `NIGHTSHIFT_CLAUDE_FLAGS` | claude | `--dangerously-skip-permissions --max-turns 25` |
| `NIGHTSHIFT_CLAUDE_SETTING_SOURCES` | claude | `--setting-sources project,local` (stage isolation) |
| `NIGHTSHIFT_CODEX_MODEL` | codex | the rulebook's `agent.codex_model`, else no `--model` |
| `NIGHTSHIFT_CODEX_REASONING_EFFORT` | codex | the CLI default effort applies |
| `NIGHTSHIFT_CODEX_STAGE_HOME` | codex | `state/codex-home` (stage isolation); empty = your own `CODEX_HOME` |
| `NIGHTSHIFT_TEST_TIMEOUT` | all | the rulebook's `limits.test_timeout_seconds`, else 600s per `test_cmd` |

**A machine-wide model pin in `~/.claude/settings.json` does not reach a stage.** Stage isolation
excludes the whole `user` settings scope (see
[`docs/design/hook-spec.md`](design/hook-spec.md) — it is what keeps the operator's personal
`CLAUDE.md` out of pushed commit bodies), and the pin lives in that scope. That is precisely why the
model belongs in the rulebook: it is the one host-owned file every run already reads (ADR 0020). A
host that pins a model for its interactive work and wants the same model overnight must say so in
both places — they are deliberately separate scopes.

Nothing about the choice is silent. Each run announces the model it will request and where that
choice came from — which model actually served is a separate, after-the-fact question answered by
`runs.jsonl`:

```
[nightshift] claude model: claude-opus-5 (from rulebook agent.claude_model)
[nightshift] claude model: not declared — the CLI's own default applies (runs.jsonl model_id records what served)
```

and `runs.jsonl` records the model that actually served each stage (`model_id`, `context_window`). The
two answer different questions: the log says what was asked for, the ledger what arrived.

These are per-process, so a whole run shares one model. Per-*stage* cost control (a cheap model for
the recon survey, the full model for fix/review) means one run per model setting today.

`NIGHTSHIFT_CLAUDE_FLAGS` replaces the sandbox defaults wholesale — the `--tools` allowlist, not
these flags, is what confines the agent (see [`docs/design/risk-analysis.md`](design/risk-analysis.md)).

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
| `state/runs.jsonl` | Per-stage telemetry (real `model_id`, `context_window`, input/output/cache tokens, cost, duration) | `NIGHTSHIFT_STATE_DIR` |
| `state/findings-probe.json` | Freshness snapshot of every open finding (`untouched` / `code_changed` / `unknown` plus verify results) — derived, disposable, rewritten in place by harvest; world-readable for the dashboard. Never hand-edit it: the ledger is the record ([ADR 0021](adr/0021-closing-open-findings.md)) | `NIGHTSHIFT_STATE_DIR` |
| `state/recon/` | Per-repo recon caches (derived, disposable) | `NIGHTSHIFT_STATE_DIR` |
| `state/dim-scans/` | Per-(repo,dim) explore markers driving rotation | `NIGHTSHIFT_STATE_DIR` |
| `state/codex-home/` | `CODEX_HOME` a codex stage runs under: a symlink to your `auth.json` plus codex's own caches, and deliberately no `AGENTS.md`/`config.toml` (derived, disposable) | `NIGHTSHIFT_CODEX_STAGE_HOME` |
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
- **Clear open findings** — the work items nightshift reported but did not fix. A finding has **no
  branch**, so the merge/delete flow above structurally cannot reach it; it is closed from the
  numbered list instead:
  ```
  bin/harvest.sh todos              # open findings, oldest first, numbered, with freshness state
  bin/harvest.sh close <#> [reason] # record `resolved` for one of them (quote a multi-word reason)
  ```
  The `STATE` column comes from the freshness probe that runs at the end of every harvest — it
  recomputes each finding's content signature and never invents a verdict:

  | State | Means | What to do |
  |-------|-------|------------|
  | `untouched` | the target code has not changed since the finding was recorded, so it cannot have been fixed | fix it, then `close` it — or, if you disagree with the finding, record `verdict <sel> wontfix` (`close` always records `resolved`) |
  | `recheck` | the target code moved — a fix, or an unrelated edit | the verify stage judges it; a `recheck/resolved` closure is machine-made and appears with source `auto-verify` |
  | `unknown` | no baseline signature (pre-[ADR 0014](adr/0014-finding-identity-and-lifecycle.md) rows), or the repo is unreadable | human backlog: `close` is the only thing that ever clears it |

  Left open, a finding repeats in every digest and keeps consuming Explore prompt budget, so this is
  the routine that keeps the backlog honest. `bin/harvest.sh probe` refreshes the snapshot on demand
  and prints it by state and fingerprint, reconciling nothing — but `close <#>` always counts against
  the numbering `todos` prints, so run `todos` when you mean to act. Your verdict outranks the
  machine's ([ADR 0007](adr/0007-human-verdicts-outrank-machine-reconcile.md),
  [ADR 0021](adr/0021-closing-open-findings.md)).
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
