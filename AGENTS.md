# nightshift — agent guide

Autonomous overnight code steward (bash + first-party CLI adapters). **What & why → [`CONTEXT.md`](CONTEXT.md);
first read → [`README.md`](README.md).** This file is orientation + the operational facts that live nowhere else;
it does not repeat architecture (CONTEXT.md/ADRs) or global rules (git, secrets, sub-agents, ADR discipline).

## Where things are (router)

- **Orchestrator:** [`bin/nightshift.sh`](bin/nightshift.sh) — the night loop: recon → explore → fix↔review → finalize (push `nightshift/*`).
- **Peers:** `harvest.sh` (reconcile/record verdicts) · `review-branch.sh` (mechanical branch review) · `schedule.sh` (systemd timer) · `nightshift-cron.sh` (unattended launcher).
- **lib/:** `parse_rulebook.py` · `extract_json.py` · `recon_signals.sh`. **prompts/** one per stage. **hooks/** `pre-push` + `pretooluse-guard.sh` (the confinement).
- **Decisions → [`docs/adr/`](docs/adr/) · Design → [`docs/design/`](docs/design/) · Open questions → [`OPEN-QUESTIONS.md`](OPEN-QUESTIONS.md) · Backlog → [`todo.md`](todo.md) · Operations → [`docs/deployment.md`](docs/deployment.md).**

## Test & verify (documented nowhere else)

- There is no test runner: `for t in tests/*.sh; do bash "$t"; done` — every test must pass before a commit.
- Tests run `NIGHTSHIFT_AGENT=mock` with isolated `NIGHTSHIFT_STATE_DIR` / `RUNS_DIR` / `DIGEST_DIR` / `WORKTREES` against a throwaway bare-remote sandbox — never the live state.

## Gotchas

- `lib/parse_rulebook.py` parses a **block-style YAML subset only** — no flow `{…}` / `[…]`.
- Mock findings are triggered by **target-file content** (`teh`, `retrun`, `AMBIGUOUS`, `FROB`) — that is how tests plant deterministic defects.
- Runner functions are unit-testable via `NIGHTSHIFT_SOURCED=1 source bin/nightshift.sh` (defines functions without running the night).

## Before touching confinement / safety

Editing an adapter in `bin/nightshift.sh` or anything in `hooks/`: read [`docs/design/hook-spec.md`](docs/design/hook-spec.md) and [`docs/design/risk-analysis.md`](docs/design/risk-analysis.md) first — the branch-only guarantee and the Fix-stage write confinement (R8) depend on those exact mechanisms.
