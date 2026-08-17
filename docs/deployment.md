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
   | `bwrap` (`apt install bubblewrap`) | sandboxing the ship gate (ADR 0026) | every `branch-fix` repo refuses to ship |
   | `gh` | opening PRs when `NIGHTSHIFT_OPEN_PR=1` | branch still pushed, no PR |
   | `codemap` | structural index handed to explore | falls back to Read/Grep/Glob |

   Only the last two degrade — they are probed with `command -v`. `git`, `jq` and `python3` are hard
   dependencies called unqualified and unguarded: parsing the rulebook is a `python3` call on the
   first code path of every entry point, so a host missing one loses the entire night. `bwrap` fails
   in the other direction, on purpose: the gate executes repository content, so a missing sandbox
   refuses the ship rather than running it unconfined (override, loudly, with
   `NIGHTSHIFT_TEST_SANDBOX=none`). It also needs unprivileged user namespaces enabled in the kernel.
   Step 5's `dry-run` is the cheap way to find out before a real run does.
3. **Write the rulebook.** Copy `rulebook.example.yaml` to `rulebook.yaml` and list the repos this
   installation may touch, their `mode` (`branch-fix` / `findings-only`), optional `base:`,
   `dimensions:`, and the `limits:` block. The parser rejects a malformed rulebook and the run aborts
   rather than silently servicing a partial fleet. A key it does not recognise counts as malformed:
   every section takes a closed set of keys, so a typo (`max_open_branchs:`, `test-cmd:`) fails the
   parse by name instead of dropping that knob and running the night on the default you never wrote.

   **Every `branch-fix` repo needs a `test_cmd`, and the parse aborts without one**
   ([ADR 0022](adr/0022-a-repos-own-tests-gate-the-ship.md),
   [ADR 0026](adr/0026-the-ship-gate-runs-in-a-sandbox.md)). It is the repo's own suite, run in the
   worktree just before the commit and *inside* the fix↔review loop: a red suite hands the failing
   output back to the Fix stage to repair its own regression, and only an item still red after
   `max_fix_iterations` is refused (`tests-failed`, no branch). The Review stage proves the finding is
   fixed, never that nothing else broke — so a repo with no suite to declare is a repo nightshift must
   not push branches for. Say so with `mode: findings-only`, which reports without ever pushing. Keep
   the command fast: it runs once per shipped finding and up to `max_fix_iterations` times for one
   that keeps breaking, inside the night's wall-clock budget, bounded by `limits.test_timeout_seconds`
   (600).
   ```yaml
   repos:
     - path: /home/you/dev/yourrepo
       mode: branch-fix
       test_cmd: uv run pytest -q
       test_net: false           # true only if the suite installs dependencies as it runs
   ```
4. **Install and enable the timer:**
   ```
   bin/schedule.sh install     # write + reload the user units
   bin/schedule.sh enable      # start the nightly timer + enable linger (fires while logged out)
   bin/schedule.sh status      # confirm; also reports any drop-in overrides
   ```
5. **Prove the wiring** without spending quota — and without touching the installation:
   ```
   bin/schedule.sh dry-run     # the real launcher + orchestrator, mock agent, throwaway sandbox
   ```
   It builds a disposable sandbox (`bin/setup-sandbox.sh` — a target repo whose `origin` is a local
   bare remote) under `$TMPDIR` and runs the night against *that*: its own rulebook, state, runs,
   digests, worktrees, launcher log and flock. So it exercises the whole path, push included, while
   writing nothing under `NIGHTSHIFT_HOME` — no ledger rows, no `empty` rows that the cadence and the
   [ADR 0015](adr/0015-recon-reprioritizes-never-excludes.md) exclusion window would later read as a
   lens having been reviewed, no overwritten digest, and no mock-authored branch on a real `origin`.
   Your own `rulebook.yaml` is not read by the run; it is parsed read-only first, so a malformed one
   still fails the dry-run rather than waiting for 04:00. The sandbox path is printed — inspect its
   digest, then `rm -rf` it.

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
| `NIGHTSHIFT_CLAUDE_FLAGS` | claude | `--dangerously-skip-permissions --max-turns 60` |
| `NIGHTSHIFT_CLAUDE_SETTING_SOURCES` | claude | `--setting-sources project,local` (stage isolation) |
| `NIGHTSHIFT_CODEX_MODEL` | codex | the rulebook's `agent.codex_model`, else no `--model` |
| `NIGHTSHIFT_CODEX_REASONING_EFFORT` | codex | the CLI default effort applies |
| `NIGHTSHIFT_CODEX_STAGE_HOME` | codex | `state/codex-home` (stage isolation); empty = your own `CODEX_HOME` |
| `NIGHTSHIFT_TEST_TIMEOUT` | all | the rulebook's `limits.test_timeout_seconds`, else 600s per `test_cmd` |
| `NIGHTSHIFT_TEST_PATH` | all | nothing is prepended, so a `test_cmd` sees only `/usr/local/bin:/usr/bin:/bin` |
| `NIGHTSHIFT_TEST_SANDBOX` | all | `bwrap` — the gate is sandboxed (ADR 0026); `none` disables it, loudly, per gate |
| `NIGHTSHIFT_TEST_SANDBOX_ROBIND` | all | nothing extra is bound; `:`-separated paths mounted read-only in the gate |
| `NIGHTSHIFT_TEST_SANDBOX_HOME` | all | the gate's `$HOME` is disposable; set a path to keep dependency caches warm |
| `NIGHTSHIFT_TEST_ENV_PASS` | all | the gate's environment is an 8-variable allowlist; names listed here are added |
| `NIGHTSHIFT_TEST_MEMORY_MB` | all | the rulebook's `limits.test_memory_mb`, else 4096 (`RLIMIT_DATA`) |
| `NIGHTSHIFT_TEST_FSIZE_MB` | all | the rulebook's `limits.test_fsize_mb`, else 2048 (`RLIMIT_FSIZE`) |
| `NIGHTSHIFT_TEST_MAX_PROCS` | all | the rulebook's `limits.test_max_procs`, else 2048 (`RLIMIT_NPROC`) |

### The ship gate runs in a sandbox — and refuses to run without one

The gate **executes candidate-controlled repository content**: `npm ci` alone runs `preinstall`,
`prepare` and `pretest` out of a `package.json` the Fix stage may just have written. So it does not
run as this account. [ADR 0026](adr/0026-the-ship-gate-runs-in-a-sandbox.md) has the full reasoning;
operationally:

- **Install bubblewrap** (`apt install bubblewrap`). Without it every `branch-fix` repo refuses to
  ship — no gate, no branch — which is the intended direction of failure, not a bug to work around.
- Inside the sandbox there is **no `$HOME`**, so no `~/.ssh`, no `gh` token, no `~/.claude`; no
  `/etc` beyond a named allowlist; no docker socket; and **no network** unless the repo sets
  `test_net: true`. The environment is an allowlist, so `SSH_AUTH_SOCK`/`GH_TOKEN`/`ANTHROPIC_API_KEY`
  are absent by construction. Writable: the worktree and a disposable `HOME`.
- **A suite that needs something from outside `/usr` must have it bound in.** Every entry of
  `NIGHTSHIFT_TEST_PATH` is bound read-only *and* put on the gate's `PATH` — it is a `:`-separated
  list, so the fleet's `node` (nvm) and `uv` (`~/.local/bin`) travel together. Anything a suite needs
  but does not execute from `PATH` goes in `NIGHTSHIFT_TEST_SANDBOX_ROBIND`. A bind that would
  re-expose `$HOME` is refused with a log line.
- **`test_net: true` does not open this host's network** (ADR 0028). The sandbox always has its own
  network namespace; a `test_net` repo reaches the outside through a proxy that refuses anything
  resolving to a loopback, private, link-local or metadata address, on ports 80/443, HTTPS CONNECT
  only. Every decision is logged to `<runs>/<night>/<item>/egress.log`. A suite that ignores
  `HTTPS_PROXY` simply has no network. Grant it only to repos whose suite installs dependencies as
  it runs.
- **Git works inside the gate.** The worktree is a linked one, so its `.git` is a file pointing into
  the repo; the repo's git dir is bound **read-only** for that reason. A suite may read git history;
  it cannot plant a hook or move a ref in the real repository.
- **A suite that needs one more variable** names it in `NIGHTSHIFT_TEST_ENV_PASS` (e.g.
  `UV_CACHE_DIR,CARGO_HOME`) rather than the gate inheriting the session.
- A gate that fails only under the sandbox is almost always one of three things: a dependency
  outside `/usr` that is not bound, a suite that reaches the network without `test_net: true`, or a
  cold cache running into `limits.test_timeout_seconds`. The suite's own output is in
  `<runs>/<night>/<item>/tests.log`; bubblewrap's own startup failures land there too, and the run
  log distinguishes them (`could not START its sandbox`) from a red suite.

### The ship gate needs a toolchain the service does not have

A systemd user service starts with a minimal environment, and
[`bin/nightshift-cron.sh`](../bin/nightshift-cron.sh) deliberately keeps the system directories at
the front of `PATH` so nothing planted under `$HOME` can shadow the Runner's own `jq`/`git`/`python3`
calls (R10/N4 in [`docs/design/risk-analysis.md`](design/risk-analysis.md)). A repo's `test_cmd`,
however, needs the *developer* toolchain — under nvm, `/usr/bin/node` is typically several major
versions behind, and `pnpm`/`corepack` are not in a system directory at all.

So the launcher resolves the nvm bin directory of the default (else newest) installed Node into
`NIGHTSHIFT_TEST_PATH`, and the Runner prepends **only that variable, only for the `test_cmd`
subprocess** — which already executes the repo's own package scripts, so its `PATH` is not a
boundary. Set the variable yourself to pick a specific toolchain; set it empty to opt out. Since
ADR 0026 those directories are also what gets **bound into the sandbox**, where `$HOME` does not
exist at all — so the variable is now how the toolchain is *reachable*, not merely how it is found
first.

It is read as a **`:`-separated PATH fragment**, because one directory is not enough: this fleet
needs `node` from nvm and `uv` from `~/.local/bin` in the same gate, and a directory that is bound
but not on `PATH` (or on `PATH` but not bound) leaves the tool exactly as unreachable as before.

```bash
NIGHTSHIFT_TEST_PATH="$HOME/.nvm/versions/node/v24.13.0/bin:$HOME/.local/bin"
```

A **self-contained node install** also gets its prefix bound (node resolves its own libraries via
`..`). That is deliberately narrow: it requires both a `node` binary in the listed directory *and* a
node-modules tree under the prefix. Binding the parent of any bin directory — or of any directory
that merely has a node-modules tree beside it — would mount `~/.local`, npm's global prefix on this
host, and with it `~/.local/share`, into a sandbox whose entire purpose is that `$HOME` is not in it.

Get this wrong and the failure is silent rather than loud: a gate that exits `9`
(`node: bad option`) or `127` (`pnpm: command not found`) is indistinguishable from a fix that broke
the suite, so the night discards finished work and reports it as `tests-failed`. Because
`tests-failed` is deliberately not latched (ADR 0022), the same items are re-attempted and
re-discarded every night. Verify a new repo's gate the way the night runs it — `bin/schedule.sh
dry-run`, then read the gate lines in its log. That exercises the service environment, the sandbox
construction, the binds and the timeout together, which is what actually breaks; a command that
passes in a login shell says nothing about any of them.

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

## Working on nightshift itself

- The suite IS `tests/*.sh` — there is no runner. Run it in a subshell that accumulates the status,
  so a failing test is visible in `$?` and can gate a `&&`:

  ```sh
  (rc=0; for t in tests/*.sh; do bash "$t" || { echo "FAIL $t"; rc=1; }; done; exit $rc)
  ```

  The accumulator is the point. A bare `for t in tests/*.sh; do bash "$t"; done` exits with the
  status of the LAST test only, and a `|| break` variant exits 0 for every outcome (`break` itself
  succeeds and is the last command run) — both report a red suite as green.
  [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs the same tests on every push and
  PR, with the same per-test `rc=1` accumulation and a final `exit $rc`.
- **Turn the doc guard on once per clone:** `git config core.hooksPath .githooks`. The
  [`pre-commit`](../.githooks/pre-commit) hook runs `lib/check_docs.py` (0.05s) and refuses a commit
  whose docs name something that is not there: a dead relative link, an `ADR 00NN` with no file, a
  backticked `bin/…`/`lib/…` path that moved, or a `file.sh:123` citation past the end of that file.
  It is the class of rot nightshift itself kept reporting as findings. `--no-verify` bypasses it.
  This is unrelated to `hooks/`, which is the agent confinement and is never installed into a clone.
- The hook applies to the runner's own commits too, when nightshift services this repo — and the Fix
  stage is told about it up front (`stage_prompt`), so a doc-breaking fix is corrected before the
  commit rather than discarded after it.

## Local state (all under `NIGHTSHIFT_HOME` unless overridden)

| Path | What | Override |
|------|------|----------|
| `state/ledger.jsonl` | The memory: findings, shipped, abandoned, verdicts, retractions (append-only) | `NIGHTSHIFT_STATE_DIR` |
| `state/runs.jsonl` | Per-stage telemetry (real `model_id`, `context_window`, input/output/cache tokens, cost, duration) | `NIGHTSHIFT_STATE_DIR` |
| `state/findings-probe.json` | Freshness snapshot of every open finding (`untouched` / `code_changed` / `unknown` plus verify results) — derived, disposable, rewritten in place by harvest; world-readable for the dashboard. Never hand-edit it: the ledger is the record ([ADR 0021](adr/0021-closing-open-findings.md)) | `NIGHTSHIFT_STATE_DIR` |
| `state/recon/` | Per-repo recon caches (derived, disposable) | `NIGHTSHIFT_STATE_DIR` |
| `state/dim-scans/` | Per-(repo,dim) explore markers driving rotation | `NIGHTSHIFT_STATE_DIR` |
| `state/.ledger-epoch.idx` | Cached per-(repo,dim) ledger aggregates the rotation reads (last service epoch, last shipped epoch) — derived, disposable, rebuilt from the ledger whenever it changes; safe to delete | `NIGHTSHIFT_STATE_DIR` |
| `state/codex-home/` | `CODEX_HOME` a codex stage runs under: a symlink to your `auth.json` plus codex's own caches, and deliberately no `AGENTS.md`/`config.toml` (derived, disposable) | `NIGHTSHIFT_CODEX_STAGE_HOME` |
| `runs/<date>/` | Per-item working dirs (prompts, agent output) | `NIGHTSHIFT_RUNS_DIR` |
| `digests/<date>.md` | The morning report | `NIGHTSHIFT_DIGEST_DIR` |
| `~/.local/state/nightshift/logs/<date>.log` | Launcher log (also in journald) | `NIGHTSHIFT_LOG_DIR` |
| `${TMPDIR:-/tmp}/nightshift-worktrees/` | Throwaway per-item worktrees | `NIGHTSHIFT_WORKTREES` |
| `${TMPDIR:-/tmp}/nightshift.lock` | Single-instance flock | `NIGHTSHIFT_LOCK` |

The ledger IS the installation. Back it up / move it with the installation; losing it loses dedup,
backpressure, and rotation history.

If you redirect state, **export `NIGHTSHIFT_STATE_DIR` in the shell you run the daily commands from
too** — [`bin/harvest.sh`](../bin/harvest.sh) reads it as well, so `todos`/`close`/`verdict` reach
the same ledger the night wrote. (It also still accepts a bare `STATE_DIR`, which wins when both are
set; that is how `bin/nightshift.sh` hands its own run's state dir to the harvest it invokes.)

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
  delete. Deleting/merging frees the open-branch cap so the next night resumes. The `next: merge`
  command deletes the branch as its last step: nothing else does, and a merged-but-undeleted
  `nightshift/*` ref lingers on origin indefinitely.
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
- **An aborted night (exit 3):** the night stopped because the agent CLI could not authenticate
  ([ADR 0023](adr/0023-an-unusable-agent-aborts-the-night.md)). The digest says `ABORTED` instead of
  reporting a clean fleet, the day's log carries a `FATAL:` line naming the stage, and the systemd
  unit is marked failed. Nothing was recorded — no recon caches, no `empty` ledger rows — so there is
  no state to clean up. Log in to the agent CLI again (`claude` / `codex login`), then re-run:
  ```
  bin/nightshift-cron.sh          # same launcher the timer uses (honours the single-instance lock)
  ```
- **Withdrawing a night that lied:** a night that ran *before* the abort path existed (or one whose
  stages failed some other way) may have left `empty` rows claiming a lens was reviewed and clean.
  The ledger is append-only, so the claim is withdrawn rather than deleted:
  ```
  bin/harvest.sh retract 2026-08-05 "agent credentials dead — no stage ran"
  ```
  One `retracted` row is appended per affected item. The original rows stay visible, and the readers
  that treat an `empty` row as evidence — the service cadence and the ADR 0015 exclusion window —
  skip them. Idempotent, and scoped to the single night you name.
- **A single failed stage:** any stage exiting non-zero is logged as `stage <name> FAILED (exit N)`
  with the last line of its stderr. The full output is kept in the run's item directory:
  `runs/<date>/<item>/<stage>.err` (stderr) and `.raw_<stage>` (the CLI's unparsed stdout). A
  one-off failure is not fatal — the night carries on and the repo is picked up on the next pass.

## Teardown

```
bin/schedule.sh uninstall   # stop the timer, remove the units AND any drop-in overrides
```

State under `NIGHTSHIFT_HOME` (ledger, runs, digests) is left in place — remove it by hand if you
want a clean slate.
