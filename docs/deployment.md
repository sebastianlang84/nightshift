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
2. **Provide the binaries a run shells out to.** Nightly runs use the `claude` adapter
   (`NIGHTSHIFT_AGENT=claude`); the only other adapter is the deterministic `mock`
   ([ADR 0044](adr/0044-claude-only-opus-works-a-review-model-reviews.md)). The launcher looks for
   these binaries on its `PATH`, which is
   `/usr/local/bin:/usr/bin:/bin:~/.local/bin` — systemd user services start with a minimal env, so
   the launcher sets that list explicitly (system dirs first, deliberately: see
   [`docs/design/risk-analysis.md`](design/risk-analysis.md) R10). "It works in my login shell" is not
   the test.

   | Binary | Used for | Missing |
   |--------|----------|---------|
   | `claude` | every stage that thinks | every stage fails; nothing ships |
   | `git` | worktrees, commits, branch pushes | run aborts |
   | `jq` | telemetry and JSON handling, the ledger reads not yet in `lib/ledger.py` | run aborts |
   | `python3` (stdlib only — nothing to install) | ledger writes, harvest's and the digest's ledger reads, rulebook parsing, JSON extraction, finding probes | run aborts |
   | `bwrap` (`apt install bubblewrap`; on Debian 11 from bullseye-backports, because 0.4.1 lacks `--clearenv` and `--size`) | sandboxing the ship gate (ADR 0026) | every `branch-fix` repo refuses to ship |
   | `gh` | opening PRs when `NIGHTSHIFT_OPEN_PR=1` | branch still pushed, no PR |

   A run started by hand from an interactive shell already has nvm on PATH and needs nothing.

   `bwrap` and `gh` are probed with `command -v`; only a missing `gh` lets the run continue unchanged. `git`, `jq` and `python3` are hard
   dependencies called unqualified and unguarded: parsing the rulebook is a `python3` call on the
   first code path of every entry point, so a host missing one loses the entire night. `bwrap` fails
   in the other direction, on purpose: the gate executes repository content, so a missing sandbox
   refuses the ship rather than running it unconfined (override, loudly, with
   `NIGHTSHIFT_TEST_SANDBOX=none`). It also needs unprivileged user namespaces enabled in the kernel.
   Step 5's `dry-run` is the cheap way to find out before a real run does.
3. **Write the rulebook.** Copy `rulebook.example.yaml` to `rulebook.yaml` and list the repos this
   installation may touch, their `mode` (`branch-fix` / `findings-only`), optional `base:`,
   `dimensions:`, and the `limits:` block. Change-size guidance limits (`max_files_per_change` and
   `max_lines_per_change`) must be positive integers. The parser rejects a malformed rulebook and
   the run aborts rather than silently servicing a partial fleet. A key it does not recognise counts as malformed:
   every section takes a closed set of keys, so a typo (`max_open_branchs:`, `test-cmd:`) fails the
   parse by name instead of dropping that knob and running the night on the default you never wrote.
   `repos:` must contain at least one entry with an absolute, non-empty `path`; an empty fleet aborts
   instead of producing a false-clean no-op night. List each checkout once. The runner aborts during
   rulebook loading if two paths refer to the same checkout, including through a symlink or bind mount.

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
   `enable` after a pause starts a real night at once, because the timer has `Persistent=true`;
   stop it with `systemctl --user stop nightshift.service` if that is unwanted.
5. **Smoke-test the launcher** without spending quota or touching the installation:
   ```
   bin/schedule.sh dry-run     # the real launcher + orchestrator, mock agent, throwaway sandbox
   ```
   It builds a disposable sandbox (`bin/setup-sandbox.sh` — a target repo whose `origin` is a local
   bare remote) under `$TMPDIR` and runs the night against *that*: its own rulebook, state, runs,
   digests, worktrees, launcher log and flock. It uses mock for every stage and disables
   branch advisors, the quota check and the notify command, even if the invoking shell configured
   them. It exercises
   the whole path, push included, while writing nothing under `NIGHTSHIFT_HOME` — no ledger rows,
   no `empty` rows that the cadence and the
   [ADR 0015](adr/0015-recon-reprioritizes-never-excludes.md) exclusion window would later read as a
   lens having been reviewed, no overwritten digest, and no mock-authored branch on a real `origin`.
   Your own `rulebook.yaml` is not read by the run; it is parsed read-only first, so a malformed one
   still fails the dry-run rather than waiting for 04:00. The sandbox path is printed — inspect its
   digest, then `rm -rf` it. To validate a managed repository's `test_cmd`, follow
   [Check a target repository's gate](#check-a-target-repositorys-gate).

### Model and flags (optional, per host)

Nightshift **commits no model of its own**. A host declares the model it wants in its own
`rulebook.yaml` (untracked) under `agent:` — see below; the variables here override that per run,
e.g. a smaller/cheaper model for one night.

```yaml
agent:
  claude_model: claude-opus-5-5
  review_model: claude-fable-5-2
```

`review_model` is the model the Review stage and the branch advice run on; every other stage runs on
`claude_model`. Omitted, they all run on `claude_model`
([ADR 0044](adr/0044-claude-only-opus-works-a-review-model-reviews.md)).

| Variable | Adapter | Effect when unset |
|----------|---------|-------------------|
| `NIGHTSHIFT_CLAUDE_MODEL` | claude | the rulebook's `agent.claude_model`, else no `--model` |
| `NIGHTSHIFT_REVIEW_MODEL` | claude | the rulebook's `agent.review_model`, else the claude model; set empty to review on the claude model for one run |
| `NIGHTSHIFT_CLAUDE_FLAGS` | claude | `--dangerously-skip-permissions --max-turns 60` |
| `NIGHTSHIFT_CLAUDE_SETTING_SOURCES` | claude | `--setting-sources local` keeps the repo's `CLAUDE.md` and skips project hooks. Supply a comma-separated list of `user`, `project`, and `local`, or an exactly empty value to omit the flag and load all scopes. See the [validation rules](design/hook-spec.md#stage-isolation--the-operators-personal-config-is-not-stage-context). |
| `NIGHTSHIFT_EMPTY_ANSWER_RETRIES` | all | `1` — a stage whose model returned nothing is retried once (ADR 0034); `0` disables it |
| `NIGHTSHIFT_TEST_TIMEOUT` | all | the rulebook's `limits.test_timeout_seconds`, else 600s per `test_cmd` |
| `NIGHTSHIFT_TEST_PATH` | all | nothing is prepended, so a `test_cmd` sees only `/usr/local/bin:/usr/bin:/bin` |
| `NIGHTSHIFT_TEST_SANDBOX` | all | `bwrap` — the gate is sandboxed (ADR 0026); `none` disables it, loudly, per gate |
| `NIGHTSHIFT_TEST_SANDBOX_ROBIND` | all | nothing extra is bound; `:`-separated paths mounted read-only in the gate |
| `NIGHTSHIFT_TEST_SANDBOX_HOME` | all | the gate's `$HOME` is disposable; set a path to keep dependency caches warm |
| `NIGHTSHIFT_TEST_ENV_PASS` | all | the gate's environment is an 8-variable allowlist; names listed here are added |
| `NIGHTSHIFT_TEST_MEMORY_MB` | all | the rulebook's `limits.test_memory_mb`, else 4096 (`RLIMIT_DATA`) |
| `NIGHTSHIFT_TEST_FSIZE_MB` | all | the rulebook's `limits.test_fsize_mb`, else 2048 (`RLIMIT_FSIZE`) |
| `NIGHTSHIFT_TEST_MAX_PROCS` | all | the rulebook's `limits.test_max_procs`, else 2048 (`RLIMIT_NPROC`) |
| `NIGHTSHIFT_BLOCKED_BASE_CMD` | all | unset; a shell command run once per red spell with the repo, base commit, `red` or `unavailable` and the log path as `$1`..`$4`, to tell the repo's owner (ADR 0041) |
| `NIGHTSHIFT_QUOTA_CMD` | launcher | unset = every night starts; a shell command `bin/nightshift-cron.sh` runs once before the night (stdin closed, `NIGHTSHIFT_QUOTA_TIMEOUT` seconds, default 60). Exit 75 = pause: the night does not start, the day's digest gets a `PAUSED` entry with the first line of the command's stdout as the reason, the notify command is called, and the launcher exits 0. Any other exit, a command that cannot run, or a timeout means go, logged (ADR 0044) |
| `NIGHTSHIFT_NOTIFY_CMD` | all | unset = nobody is told; a shell command called with one line as `$1` (stdin closed, `NIGHTSHIFT_NOTIFY_TIMEOUT` seconds, default 60) when the quota check pauses a night and when a running night stops for `agent_unavailable` — usually a quota spent mid-night. A failure is logged and changes nothing else (ADR 0044) |

A model that cannot be reached two stages in a row — each failed within 30 s with no tokens counted,
which is how a spent quota or an outage looks from the CLI — stops the night (ADR 0023). The count is
kept per model, so a spent review model stops the night even while the claude model still answers
the Fix stages in between. No other adapter or model takes over
([ADR 0044](adr/0044-claude-only-opus-works-a-review-model-reviews.md)): the digest says `ABORTED`
and `NIGHTSHIFT_NOTIFY_CMD`, if set, gets one line. To avoid starting a night on a nearly spent week
at all, point `NIGHTSHIFT_QUOTA_CMD` at a check that exits 75 when the night should pause.

A provider sometimes accepts a turn, bills it, and returns an empty answer. That is not a verdict
about the repository, so `run_agent` calls the stage again — once, and only when the answer file is
empty, the stage failed with status 1, and no credential or quota verdict already stands
([ADR 0034](adr/0034-an-empty-answer-is-not-a-verdict.md)). An answer that arrived and merely did
not parse is left alone, as is an adapter that refused to run (status 2). Both attempts become
`runs.jsonl` rows and the empty attempt's stream is kept in the item directory as
`.raw_<stage>.empty-answer-1`.

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
  list, so a suite can use tools from multiple installation directories. Anything a suite needs
  but does not execute from `PATH` goes in `NIGHTSHIFT_TEST_SANDBOX_ROBIND` — or, when only one repo
  needs it, in that repo's rulebook `test_robind`, so no other repo's gate sees it. The usual case
  is a local checkout named as `git+file:///…` in a lockfile: bind its `.git` directory only, which
  is all `git fetch` reads and keeps untracked files such as a `.env` out. A bind that would
  re-expose `$HOME` is refused with a log line, and so is a declared path that does not exist —
  check the night log for `does not exist — not bound` before treating a red gate as a regression.
  `nightshift-cron.sh` fills that variable with the
  operator's **python user site-packages** (`python3 -m site --user-site`) when it exists, because a
  `pip install --user` package is otherwise invisible in a gate; the bind is read-only and adds
  nothing to any import path. A suite that needs those packages sets `PYTHONPATH` in its own
  `test_cmd`, which keeps them out of every other repo's gate. Set the variable yourself to override,
  empty to opt out.
- **`test_net: true` does not open this host's network** (ADR 0028). The sandbox always has its own
  network namespace; a `test_net` repo reaches the outside through a proxy that refuses anything
  resolving to a loopback, private, link-local or metadata address, on ports 80/443, HTTPS CONNECT
  only. Every decision is logged to `<runs>/<night>/<item>/egress.log`. A suite that ignores
  `HTTPS_PROXY` simply has no network. The host proxy admits 64 active connections and gives a
  client five seconds to complete its CONNECT header. Grant it only to repos whose suite installs
  dependencies as it runs.
- **Git works inside the gate.** The worktree is a linked one, so its `.git` is a file pointing into
  the repo; the repo's git dir is bound **read-only** for that reason. A suite may read git history;
  it cannot plant a hook or move a ref in the real repository.
- **A suite that needs one more variable** names it in `NIGHTSHIFT_TEST_ENV_PASS` (e.g.
  `UV_CACHE_DIR,CARGO_HOME`) rather than the gate inheriting the session.
- A gate that fails only under the sandbox is almost always one of four things: a dependency
  outside `/usr` that is not bound, a suite that reaches the network without `test_net: true`, a
  cold cache running into `limits.test_timeout_seconds`, or an install step whose peak heap exceeds
  `limits.test_memory_mb` — the gate's `HOME` is disposable, so every package cache starts cold and
  a `pnpm`/`npm` install extracts the whole dependency tree on every run. The suite's own output is in
  `<runs>/<night>/<item>/tests.log`; bubblewrap's own startup failures land there too, and the run
  log distinguishes them (`could not START its sandbox`) from a red suite.

### The ship gate needs a toolchain the service does not have

A systemd user service starts with a minimal environment, and
[`bin/nightshift-cron.sh`](../bin/nightshift-cron.sh) deliberately keeps the system directories at
the front of `PATH` so nothing planted under `$HOME` can shadow the Runner's own `jq`/`git`/`python3`
calls (R10/N4 in [`docs/design/risk-analysis.md`](design/risk-analysis.md)). A repo's `test_cmd`,
however, needs the *developer* toolchain — under nvm, `/usr/bin/node` is typically several major
versions behind, and `pnpm`/`corepack` are not in a system directory at all.

By default, the launcher puts the nvm `bin` directory named by a concrete default version in
`NIGHTSHIFT_TEST_PATH`, or uses the newest installed nvm version. It also includes `$HOME/.local/bin`
when that directory exists. The runner mounts these directories read-only in the gate sandbox and
prepends them to the gate subprocess's `PATH`. Set the variable to choose your toolchain, or set it
empty to opt out.

It is read as a **`:`-separated PATH fragment**. List each directory whose tools the suite needs,
such as a Node installation and a separate directory for user-installed tools. Replace the example
paths with the absolute paths for your installation.

```bash
export NIGHTSHIFT_TEST_PATH="/opt/node/bin:$HOME/.local/bin"
```

A **self-contained Node install** also gets its prefix bound read-only so Node can resolve its
libraries relative to `bin`. The gate binds the prefix only when the listed directory contains an
executable `node` and `<node-prefix>/lib/node_modules` exists, where `<node-prefix>` is the parent of
the listed directory. This keeps unrelated directories under shared installation prefixes outside
the sandbox.

A missing or incompatible tool can leave work marked `tests-failed` and retried in later nights
(ADR 0022).

#### Check a target repository's gate

`bin/schedule.sh dry-run` smoke-tests the launcher with its disposable repo and rulebook. To check
a managed repo, call the runner's base-gate function from the Nightshift checkout. Use the service's
effective rulebook and gate environment. The launcher log shows the values it supplies for
`NIGHTSHIFT_TEST_PATH` and `NIGHTSHIFT_TEST_SANDBOX_ROBIND`. Replace the rulebook and target paths in
the example.

```bash
(
  set -e
  export RULEBOOK=/path/to/rulebook.yaml
  [ -f "$RULEBOOK" ] || { echo "Rulebook not found at $RULEBOOK" >&2; exit 1; }
  scratch=$(mktemp -d)
  export NIGHTSHIFT_STATE_DIR="$scratch/state" NIGHTSHIFT_RUNS_DIR="$scratch/runs"
  export NIGHTSHIFT_DIGEST_DIR="$scratch/digests" NIGHTSHIFT_WORKTREES="$scratch/wt"
  # Use the same sandbox setting as the service (default: bwrap).
  export NIGHTSHIFT_TEST_SANDBOX="${NIGHTSHIFT_TEST_SANDBOX:-bwrap}"
  NIGHTSHIFT_SOURCED=1 source bin/nightshift.sh
  load_rulebook
  repo=$(repo_id /path/to/target-repo)
  if ! test_cmd=$(repo_test_cmd "$repo") || [ -z "$test_cmd" ]; then
    echo "No test_cmd configured for $repo" >&2
    exit 1
  fi
  base=$(base_for_repo_strict "$repo")
  printf 'Gate logs in %s\n' "$scratch"
  base_gate_status "$repo" "$base" "$scratch" "$test_cmd" "base pre-check" "gate check failed"
)
```

The check runs the configured `test_cmd` on Nightshift's resolved base in a disposable worktree,
using the repo's gate binds, egress policy and resource limits, without model calls or branch pushes.
Inspect `base-tests.log` and, for `test_net: true`, `egress.log` in the printed directory. The check
returns 0 for a passing suite, 1 for a failed suite and 2 when the worktree or sandbox is unavailable.

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
[nightshift] claude model: claude-opus-5-5 (from rulebook agent.claude_model)
[nightshift] claude review model: claude-fable-5-2 (from rulebook agent.review_model)
[nightshift] claude model: not declared — the CLI's own default applies (runs.jsonl model_id records what served)
[nightshift] claude review model: not declared — Review and branch advice use the claude model
```

and `runs.jsonl` records the model that actually served each stage (`model_id`, `context_window`). The
two answer different questions: the log says what was asked for, the ledger what arrived.

These are per-process, so a whole run shares one model. Per-*stage* cost control (a cheap model for
the recon survey, the full model for fix/review) means one run per model setting today.

`NIGHTSHIFT_CLAUDE_FLAGS` replaces the default extra Claude arguments with whitespace-separated
arguments. The Runner refuses to start the stage if the override includes `--mcp-config`,
`--setting-sources`, or `--settings`, including their `--flag=value` forms.
Use `NIGHTSHIFT_CLAUDE_SETTING_SOURCES` to select the settings scopes.

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
  [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs the same tests on every push to
  `main` and every PR, with the same per-test `rc=1` accumulation and a final `exit $rc`. The push
  trigger is filtered to `main`: a `nightshift/*` branch was already put through this suite by the
  ship gate before it was pushed, and the PR you open in the morning triggers CI with no branch
  filter, so the third run an unfiltered push trigger would add decides nothing.
- **Turn the doc guard on once per clone:** `git config core.hooksPath .githooks`. The
  [`pre-commit`](../.githooks/pre-commit) hook runs `lib/check_docs.py` (0.05s) and refuses a commit
  whose docs name something that is not there: a dead relative link, an `ADR 00NN` with no file, a
  backticked `bin/…`/`lib/…` path that moved, or a `file.sh:123` citation past the end of that file.
  It is the class of rot nightshift itself kept reporting as findings. `--no-verify` bypasses it.
  `core.hooksPath` replaces `.git/hooks` entirely. If the clone already has hooks there,
  call `.githooks/pre-commit` from the existing `.git/hooks/pre-commit` instead.
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
| `state/fix-survival.json` | Whether each merged fix held 30 days after its verdict (`measured` / `removed` / `pending` / `unknown`), per item and per repo — derived by harvest, cached once measured, read by the digest ([ADR 0043](adr/0043-merged-fixes-are-measured-after-thirty-days.md)). `bin/harvest.sh survival` prints it | `NIGHTSHIFT_STATE_DIR` |
| `state/blocked-bases.tsv` | Repos whose red base was reported through `NIGHTSHIFT_BLOCKED_BASE_CMD` and not green since ([ADR 0041](adr/0041-a-red-base-skips-the-repo.md)) | `NIGHTSHIFT_STATE_DIR` |
| `state/recon/` | Per-repo recon caches (derived, disposable) | `NIGHTSHIFT_STATE_DIR` |
| `state/dim-scans/` | Per-(repo,dim) explore markers driving rotation | `NIGHTSHIFT_STATE_DIR` |
| `state/.ledger-epoch.idx` | Cached per-(repo,dim) ledger aggregates the rotation reads (last service epoch, last shipped epoch) — derived, disposable, rebuilt from the ledger whenever it changes; safe to delete | `NIGHTSHIFT_STATE_DIR` |
| `state/.ledger-gap.idx` | Cached per-repo service cadence the overdue ceiling reads (service count, median inter-service interval) — derived, disposable, rebuilt from the ledger whenever it changes; safe to delete | `NIGHTSHIFT_STATE_DIR` |
| `runs/<date>/` | Per-item working dirs (prompts, agent output) | `NIGHTSHIFT_RUNS_DIR` |
| `digests/<date>.md` | The morning report | `NIGHTSHIFT_DIGEST_DIR` |
| `~/.local/state/nightshift/logs/<date>.log` | Launcher log (also in journald) | `NIGHTSHIFT_LOG_DIR` |
| `${TMPDIR:-/tmp}/nightshift-worktrees/` | Throwaway per-item worktrees. Where `/tmp` is a RAM-backed tmpfs (the Debian 13 default), a Fix stage's dependency install can exhaust it — point this at disk outside `$HOME`, e.g. `/var/tmp/nightshift-worktrees`. Keep the path short: `test_net` fails with `AF_UNIX path too long` | `NIGHTSHIFT_WORKTREES` |
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
host (GitHub, GitLab, a bare remote) because it needs no host API.

Opening a PR is **optional and off by default** (`NIGHTSHIFT_OPEN_PR=1`). A PR is a host-API object
needing a host credential the SSH transport does not provide:

- **GitHub:** requires `gh` authenticated in the run environment. The PR targets the branch's
  configured base.
- **Other hosts:** no PR is opened; the pushed branch remains the unit of review.

Agent capabilities depend on the adapter and stage.

- **Claude** can read files accessible to the host account, including paths outside the worktree.
  The default profiles grant write tools only to Fix. The `PreToolUse` guard confines file-writing
  tools to the disposable worktree. The default profiles omit Bash, so agents have no shell to run
  `git push`. If the operator enables Bash, the guard rejects commands that try to bypass or widen
  the injected `pre-push` hook.

The runner performs the branch push. Its `pre-push` hook allows new branches and fast-forward updates
under the configured `branch_prefix` (`nightshift/` by default) and rejects deletions, tags and other
destinations. See the [hook specification](design/hook-spec.md) and [risk analysis](design/risk-analysis.md).

## Daily operation

- **Morning:** read `digests/<date>.md`; `bin/status.sh` shows each recent item's state and leftover clutter; review open branches with `bin/review-branch.sh`; merge or
  delete. Deleting/merging frees the open-branch cap so the next night resumes. The `next: merge`
  command deletes the branch as its last step: nothing else does, and a merged-but-undeleted
  `nightshift/*` ref lingers on origin indefinitely.
  These checks refresh the managed branch namespace and configured base even in a single-branch
  checkout. They fetch full history in shallow clones before classifying branches. If the refresh
  fails or history remains shallow, review and status report an unknown state and the runner
  stops at the cap check.
  With `bin/status.sh --no-fetch`, ancestry checks require a configured base and complete local
  history. A managed branch missing from the local tracking refs is reported as unknown.
- **Record verdicts** the machine can't derive with `bin/harvest.sh verdict <selector> <verdict>`.
  When multiple rows match, copy the item ID or the `--adopted` argument from the ambiguity message.
  The same command works for both older and newer adoptions.
  ```bash
  bin/harvest.sh verdict --adopted 'orphan-adopt:<ledger repo path>:<branch>' <verdict>
  ```
  If the adopted item ID also matches a fingerprint, pass `--fingerprint` to select the fingerprint.
  Harvest reconciles merged and dropped branches automatically on each run.
- **Clear open findings** — the work items nightshift reported but did not fix. A finding has **no
  branch**, so the merge/delete flow above structurally cannot reach it; it is closed from the
  numbered list instead:
  ```
  bin/harvest.sh todos                 # open findings, oldest first, with stable ITEM and freshness
  bin/harvest.sh close <item> [reason] # record `resolved` (quote a multi-word reason)
  ```
  The `STATE` column comes from the freshness probe that runs at the end of every harvest — it
  recomputes each finding's content signature on its configured base (or the auto-detected base),
  independently of the operator checkout's HEAD, and never invents a verdict. Repositories removed
  from the rulebook stay visible as `unknown` and are skipped by automatic Verify: their base is
  never guessed. Relisting a repository resumes probing against its configured base.

  | State | Means | What to do |
  |-------|-------|------------|
  | `untouched` | the target code has not changed since the finding was recorded, so it cannot have been fixed | fix it, then `close` it — or, if you disagree with the finding, record `verdict <sel> wontfix` (`close` always records `resolved`) |
  | `recheck` | the target code moved — a fix, or an unrelated edit | the verify stage judges it; a `recheck/resolved` closure is machine-made and appears with source `auto-verify` |
  | `unknown` | repo absent from the current rulebook, no baseline signature (pre-[ADR 0014](adr/0014-finding-identity-and-lifecycle.md) rows), or the repo is unreadable | restore the repo configuration or readability to resume checks, or record a manual verdict |

  Left open, a finding repeats in every digest and keeps consuming Explore prompt budget, so this is
  the routine that keeps the backlog honest. `bin/harvest.sh probe` refreshes the snapshot on demand
  and prints it by state and fingerprint, reconciling nothing. Numeric selectors are refused because
  another harvest can reorder them between commands; copy the stable `ITEM` from `todos`. Your verdict outranks the
  machine's ([ADR 0007](adr/0007-human-verdicts-outrank-machine-reconcile.md),
  [ADR 0021](adr/0021-closing-open-findings.md)).
- **Independent branch review:** set `agent.advisors: claude` in the rulebook and every open branch
  gets a merge / fix / reject recommendation every night, on the review model. The
  digest shows them as one table with a combined recommendation and the required fix
  ([ADR 0038](adr/0038-every-open-branch-gets-two-vendors-advice.md)). Answers are cached in
  `state/advice/` per branch tip, base, adapter and model, so an unchanged branch is not reviewed
  again; delete that directory to force a fresh review. `NIGHTSHIFT_ADVISORS` overrides the list
  (empty = off for one run). The older `NIGHTSHIFT_BRANCH_REVIEW=1` still turns it on as well. It never merges or pushes.
- **Logs:** `bin/schedule.sh logs [N]` or `journalctl --user -u nightshift.service`.
- **Time limits:** keep `limits.max_run_minutes` below the scheduler's hard timeout (the shipped
  unit uses five hours). The application checks its budget between work items, so an in-flight
  stage can overrun it. For example, 270 minutes leaves 30 minutes for completion. SIGTERM/SIGINT
  write an `ABORTED` digest from recorded ledger outcomes and exit with 143/130; this records
  partial progress without claiming the interrupted stage completed. SIGKILL cannot be handled.
  Keep dependency-install errors visible in `test_cmd`: use `npm ci --no-audit --no-fund`, without
  `--silent`, so a failed install leaves a useful `tests.log` for the next Fix iteration.
- **An aborted night (exit 3):** the night stopped because an agent CLI could not authenticate or
  could not reach its model two stages in a row — usually a spent quota
  ([ADR 0023](adr/0023-an-unusable-agent-aborts-the-night.md)). The digest says
  `ABORTED`, names the adapter that died, the model when it was the one that could not be
  reached, and the cause, the day's log carries a `FATAL:` line naming the stage, and the systemd unit
  is marked failed. Nothing was recorded — no recon caches, no `empty` ledger rows — so there is no
  state to clean up. For a credentials abort, log in to the `claude` CLI again;
  otherwise the `FATAL:` line names the stage's raw output, where the CLI says why — for a spent
  quota, wait until the reset it gives. Then re-run:
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
  complete partial result is still used. Without one, Fix/Review record retryable `stage-failed` and
  Verify records no negative result; unchanged code is eligible again. A one-off failure is not
  fatal — the night carries on and the repo is picked up on the next pass.

The optional external merge-state input for `bin/status.sh` is selected with
`NIGHTSHIFT_MERGE_STATE`. Imported task references retain their legacy `kb` field for
compatibility and display as “issue” by default. `NIGHTSHIFT_MERGE_ISSUE_LABEL` changes that
label for a host's issue tracker.

## Teardown

```
bin/schedule.sh uninstall   # stop the timer, remove the units AND any drop-in overrides
```

State under `NIGHTSHIFT_HOME` (ledger, runs, digests) is left in place — remove it by hand if you
want a clean slate.


## Free-search dimension

Set a repo's `dimensions: general` to search freely across improvement categories. For the
whole fleet, replace the global dimension list with just `general`; per-repo overrides still
win. The example defaults remain unchanged. General search tries at least three distinct
areas before an empty verdict, or all available areas in a smaller repo. A missing surface
is a reason to look elsewhere. The normal evidence, review, sandbox, test, and time gates apply.

Explore receives bounded history: the five latest validated scans and twenty recent terminal
decisions, alongside open work. Treat earlier checks and decisions as navigation hints, not
proof about current code; changed code may justify a fresh investigation. General scans count
as general coverage, not as completed security or UI reviews.

[ADR 0033](adr/0033-free-search-is-an-opt-in-dimension.md) records the decision.
