# nightshift — agent guide

Autonomous overnight code steward (bash + first-party CLI adapters). **What & why → [`CONTEXT.md`](CONTEXT.md);
first read → [`README.md`](README.md).** This file is orientation + the operational facts that live nowhere else;
it does not repeat architecture (CONTEXT.md/ADRs) or global rules (git, secrets, sub-agents, ADR discipline).

## Where things are (router)

- **Orchestrator:** [`bin/nightshift.sh`](bin/nightshift.sh) — the night loop: harvest → verify (close open findings) → recon → explore → fix↔review↔`test_cmd` gate (a red suite loops back into Fix, ADR 0022) → finalize (push `nightshift/*`).
- **Peers:** `harvest.sh` (reconcile branches, probe findings, `todos`/`close`) · `review-branch.sh` (mechanical branch review) · `schedule.sh` (systemd timer) · `nightshift-cron.sh` (unattended launcher).
- **lib/:** `parse_rulebook.py` · `extract_json.py` · `recon_signals.sh` · `probe_findings.py` (finding freshness, ADR 0021). **prompts/** one per stage. **hooks/** `pre-push` + `pretooluse-guard.sh` (the confinement).
- **Decisions → [`docs/adr/`](docs/adr/) · Design → [`docs/design/`](docs/design/) · Open questions → [`OPEN-QUESTIONS.md`](OPEN-QUESTIONS.md) · Backlog → [`todo.md`](todo.md) · Operations → [`docs/deployment.md`](docs/deployment.md).**

## Test & verify (documented nowhere else)

- There is no test runner: `for t in tests/*.sh; do bash "$t"; done` — every test must pass before a commit.
- Tests run `NIGHTSHIFT_AGENT=mock` with isolated `NIGHTSHIFT_STATE_DIR` / `RUNS_DIR` / `DIGEST_DIR` / `WORKTREES` against a throwaway bare-remote sandbox — never the live state.
- **`systemctl --user` ignores `XDG_CONFIG_HOME`.** It talks to the operator's live session bus wherever the unit files sit, so a test that exercises `schedule.sh` must stub `systemctl` on `PATH` (`test-scheduler-overrides.sh` does) — otherwise `uninstall` disarms the real nightly timer. The ADR 0022 ship gate runs this suite in a worktree, which would make that a nightly occurrence.

## Gotchas

- `lib/parse_rulebook.py` parses a **block-style YAML subset only** — no flow `{…}` / `[…]`.
- Mock findings are triggered by **target-file content** (`teh`, `retrun`, `AMBIGUOUS`, `FROB`) — that is how tests plant deterministic defects.
- Runner functions are unit-testable via `NIGHTSHIFT_SOURCED=1 source bin/nightshift.sh` (defines functions without running the night).
- `state/findings-probe.json` is **derived** state (ADR 0021), rewritten by harvest and the verify phase — never hand-edit it; the ledger is the record. The dashboard reads it through the same read-only mount, so it must stay world-readable.
- The rulebook's per-repo `test_cmd` rides **last** on the parser's `repo` TSV row on purpose (ADR 0022): a command contains spaces and the Runner's `read` soaks the remainder into the final variable, so any new repo field must be inserted *before* it.

## Before touching confinement / safety

Editing an adapter in `bin/nightshift.sh` or anything in `hooks/`: read [`docs/design/hook-spec.md`](docs/design/hook-spec.md) and [`docs/design/risk-analysis.md`](docs/design/risk-analysis.md) first — the branch-only guarantee and the Fix-stage write confinement (R8) depend on those exact mechanisms.
