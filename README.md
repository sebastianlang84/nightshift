# nightshift

Autonomous overnight code review and fixes on isolated Git branches, with budgets and a sandboxed test gate.

Repositories accumulate bugs, outdated documentation, and maintenance work that rarely reaches the
front of a work queue. nightshift surveys repositories you allow, chooses a review dimension,
and proposes bounded changes for you to inspect and merge.

> **Agent-maintained.** All code, documentation, commits and pushes in this repository come from AI coding agents
> (Claude Code and Codex). I contribute ideas, set the direction and review the output; I don't write code, commit or push.

## How it works

The Bash runner coordinates fresh agent sessions through file-based handoffs:

1. **Recon** surveys each repository and helps prioritize review dimensions.
2. **Explore** traces code and reports ranked findings, or reports that nothing needs changing.
3. **Fix and Review** iterate in a disposable worktree, within configured limits.
4. **The ship gate** runs the repository's tests inside a bubblewrap sandbox.
5. **Finalize** commits the reviewed tree and pushes a `nightshift/*` branch. A local digest
   records shipped branches, findings, failures, and usage.

An append-only ledger tracks finding identity, branch outcomes, and coverage across runs.
The runner never merges. You control merges; an optional external merge job requires separate
operator authorization and is not included in this repository.

Each host selects Claude Code or Codex in its rulebook. Review and branch advice on that
adapter can use a separate model. A deterministic mock serves tests and dry runs.

## Install

Use a Linux host with Bash, Git, Python 3 (standard library only), `jq`, `timeout`, `flock`,
and bubblewrap (`bwrap`). Bubblewrap must support `--clearenv` and `--size`, and the host must
permit its user namespaces. Scheduling also requires a systemd user session.
Install and authenticate your chosen agent CLI separately before a real run.

On a Debian-based host, the system dependencies can be installed with:

```bash
sudo apt-get install bash git python3 jq coreutils util-linux bubblewrap ripgrep
```

`ripgrep` is needed only by the test suite.

Download or clone this repository to a stable directory, then run commands below from its root.
No Python package installation or build step is required.

## Quickstart with a local demo

This creates a throwaway target and local bare remote under `sandbox/`. Repeating setup rebuilds
that demo directory. The mock adapter makes no model calls; the ship gate still needs bubblewrap.

```bash
bash bin/setup-sandbox.sh
NIGHTSHIFT_AGENT=mock RULEBOOK="$PWD/sandbox/rulebook.yaml" \
  NIGHTSHIFT_STATE_DIR="$PWD/sandbox/state" \
  NIGHTSHIFT_RUNS_DIR="$PWD/sandbox/runs" \
  NIGHTSHIFT_DIGEST_DIR="$PWD/sandbox/digests" \
  NIGHTSHIFT_WORKTREES="$PWD/sandbox/wt" \
  bash bin/nightshift.sh
```

Inspect `sandbox/digests/` and the branches in `sandbox/remote.git`.

## Configure a real run

```bash
cp rulebook.example.yaml rulebook.yaml
# Uncomment one agent block and configure your repositories in rulebook.yaml.
bash bin/nightshift.sh
```

Replace the example repository path with an absolute path to a repository you own or are
authorized to modify. Configure an existing base branch and working Git push transport.
A minimal repository entry is:

```yaml
repos:
  - path: /path/to/project
    mode: branch-fix
    base: main
    test_cmd: python3 -m unittest discover
```

Use the project's actual test command. `branch-fix` refuses to run without a declared gate;
`findings-only` reports findings without pushing. Set `test_net: true` only when the gate needs
public dependency downloads: its proxy refuses private and loopback destinations.

[rulebook.example.yaml](rulebook.example.yaml) documents budgets, review dimensions, model
selection, per-repository setup, and test sandbox limits. Environment variables override selected
settings; see the [deployment guide](docs/deployment.md) for precedence and the full list.
Common settings include:

| Setting | Purpose |
| --- | --- |
| `NIGHTSHIFT_AGENT` | `claude`, `codex`, or `mock`. Manual runs require this setting or `agent.primary` in the rulebook. The scheduler falls back to `claude`. |
| `agent.review_model` | Model for Review and advice on the primary adapter (defaults to its work model) |
| `limits.max_open_branches` | Maximum branches awaiting a verdict across repositories |
| `limits.max_run_minutes` | Optional run budget; an in-flight stage may finish |
| `NIGHTSHIFT_STATE_DIR` | Ledger and derived state location |
| `NIGHTSHIFT_OPEN_PR=1` | Optional GitHub PR creation through authenticated `gh`; default off |

To schedule real runs after checking a manual run:

```bash
bash bin/schedule.sh install
bash bin/schedule.sh status
```

The [deployment guide](docs/deployment.md) covers timer configuration, state backup, updates,
branch review, and teardown. One installation must own each target repository.

## Status and limitations

The review/fix pipeline, mock adapter, ledger, scheduler, and sandboxed gate are implemented.
Models can miss defects or introduce regressions. Review the branch and its evidence before merging.

The gate sandbox executes candidate code without the host home or credentials and fails closed
when bubblewrap is unavailable. Agent reads can reach files accessible to the host account. Branch confinement does not
scan pushed content for secrets. Use a dedicated unprivileged account and read the
[threat model](docs/design/risk-analysis.md) before unattended operation.

The rulebook parser supports a documented block-style YAML subset, not arbitrary YAML.
Budgets include wall-clock and branch limits; they do not guarantee a monetary spending ceiling.
The optional historical replay evaluation needs pre-fix Git objects that are absent from this
source export; its deterministic scorer remains testable.

## Development

```bash
python3 lib/check_docs.py .
(rc=0; for t in tests/*.sh; do env -u GIT_CONFIG_COUNT bash "$t" || { echo "FAIL $t"; rc=1; }; done; exit "$rc")
```

Tests use local fixtures and mock agents. Sandbox tests report skips if the host cannot create
the required namespaces. Live public egress checks require `NIGHTSHIFT_TEST_LIVE_NETWORK=1`.
See [CONTEXT.md](CONTEXT.md) for architecture, [AGENTS.md](AGENTS.md) for contributor guidance,
and [ADRs](docs/adr/) for design decisions.

## License

[MIT](LICENSE).
