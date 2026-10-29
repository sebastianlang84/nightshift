# nightshift — agent guide

Read [README.md](README.md) first.
Architecture and terminology: [CONTEXT.md](CONTEXT.md).
Operations: [docs/deployment.md](docs/deployment.md).

## Navigation

1. Runner: `bin/nightshift.sh`; supporting commands: `bin/`.
2. Stage prompts: `prompts/`; reflection prompts: `prompts/reflection/`.
3. Decisions: `docs/adr/`; designs: `docs/design/`.
4. Backlog: `todo.md`; unresolved design choices: `OPEN-QUESTIONS.md`.

## Verification

1. Before committing, run every shell test from the repo root:

   `(rc=0; for t in tests/*.sh; do bash "$t" || { echo "FAIL $t"; rc=1; }; done; exit $rc)`

2. The suite checks documentation references; `python3 lib/check_docs.py .` runs this check alone.
   Development hook setup: [Working on nightshift itself](docs/deployment.md#working-on-nightshift-itself).
   `.githooks/` contains development hooks; `hooks/` confines agents.
3. Keep test state separate from live state.
   Integration fixtures use `NIGHTSHIFT_AGENT=mock` and throwaway remotes.
   For these runs, override `NIGHTSHIFT_STATE_DIR`, `NIGHTSHIFT_RUNS_DIR`, `NIGHTSHIFT_DIGEST_DIR` and `NIGHTSHIFT_WORKTREES`.
4. Start shell tests with `unset GIT_CONFIG_COUNT` to remove inherited Git confinement settings.
5. Tests exercising `bin/schedule.sh` must stub `systemctl` on `PATH`.
   `XDG_CONFIG_HOME` isolates unit files, not the live user session bus.
   See `tests/test-scheduler-overrides.sh`.

## Parser and state

1. `lib/parse_rulebook.py` accepts a block-style YAML subset; flow mappings and lists are unsupported.
   Register new keys in the corresponding allowed-key tuple.
   Keep `test_cmd` last in the emitted repo TSV row; insert new fields before it.
2. `state/findings-probe.json` is derived from the ledger; never edit it manually.
   Keep it world-readable for the dashboard.
3. `.nightshift-note` reports harness problems through `state/agent-notes.md` and the digest.
   The runner removes notes before committing; never feed collected notes into later stages.

## Ship gate and confinement

1. Before changing adapters in `bin/nightshift.sh` or files in `hooks/`, read
   [hook-spec.md](docs/design/hook-spec.md) and [risk-analysis.md](docs/design/risk-analysis.md).
2. Fix confinement differs by adapter: Claude uses `hooks/pretooluse-guard.sh`,
   Codex uses `--sandbox workspace-write`, and Pi uses a bwrap filesystem sandbox.
   Pi's sandbox shares the host network; see [ADR 0032](docs/adr/0032-the-pi-fix-stage-is-sandboxed.md).
3. The ship gate normally runs `test_cmd` in bwrap without the operator's home.
   The worktree, sandbox home and temporary filesystems are writable.
   Missing bwrap blocks shipping without a Fix retry.
   `NIGHTSHIFT_TEST_SANDBOX=none` disables the gate sandbox.
   `NIGHTSHIFT_PI_SANDBOX=none` disables Pi's Fix sandbox; otherwise missing bwrap blocks Pi Fix.
4. The gate removes ignored files with `git clean -ffdX` before each run.
   Sandbox details: `docs/deployment.md`.

## Operations

1. Never propose a notification or alerting channel for nightshift runs; the digest file is the report.
2. Run `bin/reflect.sh` manually, never on a timer; see ADR 0035.
3. Identify the timer's checkout with `systemctl --user cat nightshift.service`.
   After pushing `main` from another checkout, update the timer's checkout on `main`:
   `git -C <checkout> fetch origin main`
   `git -C <checkout> merge --ff-only origin/main`
4. An operator-side job handles automatic branch review and merging:
   [ADR 0040](docs/adr/0040-reviewed-branches-merge-without-a-human.md).
   The runner itself only pushes `nightshift/*`.
   Handle tasks for this repo labelled `nightshift-merge` in this session; do not pass them on.
