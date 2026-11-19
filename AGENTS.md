# Contributor guide

Read [README.md](README.md) for setup and [CONTEXT.md](CONTEXT.md) for architecture.
Operations are documented in [docs/deployment.md](docs/deployment.md).

## Navigation

- `bin/nightshift.sh`: orchestration; `lib/adapters.sh`: agent adapters.
- `lib/sandbox.sh`: test execution and worktree safety; `lib/digest.sh`: reporting.
- `prompts/`: stage and dimension prompts.
- `docs/adr/`: decisions; `docs/design/`: implemented and explicitly labeled proposed designs.

## Verification

Run `python3 lib/check_docs.py .` and the shell tests from the repository root:

```bash
for t in tests/*.sh; do env -u GIT_CONFIG_COUNT bash "$t"; done
```

Use mock agents and throwaway remotes. Keep test state separate from real state with
`NIGHTSHIFT_STATE_DIR`, `NIGHTSHIFT_RUNS_DIR`, `NIGHTSHIFT_DIGEST_DIR`, and `NIGHTSHIFT_WORKTREES`.
Tests involving `bin/schedule.sh` must stub `systemctl` on PATH: changing `XDG_CONFIG_HOME`
does not isolate the systemd user bus. `.githooks/` contains contributor hooks; `hooks/`
contains the agent confinement hooks.

## Parser and state contracts

- `lib/parse_rulebook.py` accepts a block-style YAML subset. Register keys in the allowed-key
  tuples; keep `test_cmd` last in each emitted repository TSV row.
- `state/findings-probe.json` is derived from the ledger. Do not edit it by hand.
- `.nightshift-note` reports harness problems through `state/agent-notes.md` and the digest.
  The runner removes notes before committing and never feeds collected notes into later stages.

## Safety contracts

Read [hook-spec.md](docs/design/hook-spec.md) and the
[threat model](docs/design/risk-analysis.md) before changing adapters or confinement hooks.

Claude uses a tool guard; it is the only real adapter. The ship gate runs candidate code in
bubblewrap with an allowlisted environment and no host home. Missing bubblewrap blocks shipping.
`NIGHTSHIFT_TEST_SANDBOX=none` explicitly opts out of the gate sandbox. Preserve the fail-closed default.

The gate removes ignored files before each run and refuses hidden worktree changes.
Finalize commits the reviewed tree. The runner only pushes `nightshift/*` and never merges.
