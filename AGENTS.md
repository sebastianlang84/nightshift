# nightshift — agent guide

Autonomous overnight code steward (bash + first-party CLI adapters). **What & why → [`CONTEXT.md`](CONTEXT.md);
first read → [`README.md`](README.md).** This file is orientation + the operational facts that live nowhere else;
it does not repeat architecture (CONTEXT.md/ADRs) or global rules (git, secrets, sub-agents, ADR discipline).

## Where things are (router)

- **Orchestrator:** [`bin/nightshift.sh`](bin/nightshift.sh) — the night loop: harvest → verify (close open findings) → recon → explore → fix↔review↔`test_cmd` gate (a red suite loops back into Fix, ADR 0022) → finalize (push `nightshift/*`).
- **Peers:** `harvest.sh` (reconcile branches, probe findings, `todos`/`close`) · `review-branch.sh` (mechanical branch review) · `schedule.sh` (systemd timer) · `nightshift-cron.sh` (unattended launcher).
- **lib/:** `parse_rulebook.py` · `extract_json.py` · `validate_explore.py` (ADR 0029 depth receipt) · `recon_signals.sh` · `probe_findings.py` (finding freshness, ADR 0021) · `ledger_epochs.py` (batch ISO→epoch behind the ledger indexes). **prompts/** one per stage. **hooks/** `pre-push` + `pretooluse-guard.sh` (the confinement).
- **Decisions → [`docs/adr/`](docs/adr/) · Design → [`docs/design/`](docs/design/) · Open questions → [`OPEN-QUESTIONS.md`](OPEN-QUESTIONS.md) · Backlog → [`todo.md`](todo.md) · Operations → [`docs/deployment.md`](docs/deployment.md).**

## Test & verify (documented nowhere else)

- There is no test runner — the suite IS `tests/*.sh`, and every test must pass before a commit. Run it so a red suite reaches the exit status: `(rc=0; for t in tests/*.sh; do bash "$t" || { echo "FAIL $t"; rc=1; }; done; exit $rc)`. Never judge the suite by a bare `for … done` (its status is the LAST test's, so an earlier failure reads as green) or by a `|| break` form (`break` succeeds and runs last, so *every* failure reads as green). [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs the same tests on every push to `main` and every PR, accumulating `rc` the same way — that accumulation, not the loop, is what makes a failure a failure. A `nightshift/*` branch is covered by the PR trigger, not the push one; the ship gate has already run this suite against it before the push.
- `lib/check_docs.py` refuses docs that name something absent (dead links, missing ADRs, moved files, line citations past EOF). It runs in the suite, in CI, and — activate with `git config core.hooksPath .githooks` — in [`.githooks/pre-commit`](.githooks/pre-commit) (0.05s). Not to be confused with `hooks/`, which is the agent confinement.
- Tests run `NIGHTSHIFT_AGENT=mock` with isolated `NIGHTSHIFT_STATE_DIR` / `RUNS_DIR` / `DIGEST_DIR` / `WORKTREES` against a throwaway bare-remote sandbox — never the live state.
- **`systemctl --user` ignores `XDG_CONFIG_HOME`.** It talks to the operator's live session bus wherever the unit files sit, so a test that exercises `schedule.sh` must stub `systemctl` on `PATH` (`test-scheduler-overrides.sh` does) — otherwise `uninstall` disarms the real nightly timer. The ADR 0022 ship gate runs this suite in a worktree, which would make that a nightly occurrence.

## Gotchas

- `lib/parse_rulebook.py` parses a **block-style YAML subset only** — no flow `{…}` / `[…]`. Every mapping section's key set is **closed** (`LIMIT_KEYS` / `RECON_KEYS` / `AGENT_KEYS` / `REPO_KEYS`): an unknown key aborts the parse, and the run with it, instead of the knob silently reverting to a default. So a new knob must be added to its tuple, or every rulebook that uses it is refused — including `rulebook.example.yaml`, which the suite parses for exactly that reason.
- Mock findings are triggered by **target-file content** (`teh`, `retrun`, `AMBIGUOUS`, `FROB`) — that is how tests plant deterministic defects. The mock reviewer otherwise always ships; `NIGHTSHIFT_MOCK_ABANDON_IF=<path>` makes it `abandon` once that path exists, which is how a test reaches the give-up verdict mid-loop.
- Runner functions are unit-testable via `NIGHTSHIFT_SOURCED=1 source bin/nightshift.sh` (defines functions without running the night).
- `state/findings-probe.json` is **derived** state (ADR 0021), rewritten by harvest and the verify phase — never hand-edit it; the ledger is the record. The dashboard reads it through the same read-only mount, so it must stay world-readable.
- The rulebook's per-repo `test_cmd` rides **last** on the parser's `repo` TSV row on purpose (ADR 0022): a command contains spaces and the Runner's `read` soaks the remainder into the final variable, so any new repo field must be inserted *before* it (`test_net` is).
- The ship gate runs `test_cmd` in a **bwrap sandbox** (ADR 0026), so it can write nowhere but the worktree and sees no `$HOME` — a fixture that used to park a marker outside the tree must now keep it inside and `.gitignore` it (hence `NIGHTSHIFT_MOCK_ABANDON_IF` resolving a *relative* path against the worktree). No bwrap ⇒ `run_test_gate` returns **2** ("could not run"), which the caller refuses *without* spending another fix iteration — distinct from **1** (a red suite), which loops back. `NIGHTSHIFT_TEST_SANDBOX=none` is the documented opt-out, and why the suite still passes on a host without user namespaces.

## Before touching confinement / safety

Editing an adapter in `bin/nightshift.sh` or anything in `hooks/`: read [`docs/design/hook-spec.md`](docs/design/hook-spec.md) and [`docs/design/risk-analysis.md`](docs/design/risk-analysis.md) first — the branch-only guarantee and the Fix-stage write confinement (R8) depend on those exact mechanisms.
