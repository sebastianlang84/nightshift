# Architecture and terminology

nightshift is a self-hosted runner for unattended review and fixes across authorized Git
repositories. It produces isolated branches or findings and keeps a ledger to avoid repeating
settled work. The operator owns configuration, credentials, and merge decisions.

## Architecture

The core is written in Bash and Python with file-based handoffs between fresh agent sessions.

| Layer | Responsibility |
| --- | --- |
| Orchestrator | Repository selection, dimension rotation, budget checks, stage transitions |
| Ledger | Append-only findings, attempts, branch outcomes, and coverage evidence |
| Rulebook | Authorized repositories, modes, models, limits, and exclusions |
| Adapter | Agent invocation, stage capabilities, usage extraction, and failure classification |
| Gate | Sandbox construction, dependency setup, repository tests, and tree-integrity checks |
| Reports | Local run artifacts, morning digests, and branch advice |

[`bin/nightshift.sh`](bin/nightshift.sh) coordinates
[`lib/adapters.sh`](lib/adapters.sh), [`lib/sandbox.sh`](lib/sandbox.sh), and
[`lib/digest.sh`](lib/digest.sh). The rulebook parser uses a restricted block-style YAML subset.
The system needs no server or database service.

## Pipeline

Recon prioritizes review dimensions from repository evidence. Explore traces a flow and checks
invariants, returning ranked findings or a valid empty result. Each finding gets its own
disposable worktree. Fix and Review iterate within configured limits, Review optionally on a
separate review model. A repository's declared test command runs in a sandbox before Finalize pushes the
reviewed tree to a `nightshift/*` branch.

`findings-only` reports without pushing. Verify can close earlier findings after their target
code changes. Harvest reconciles branch outcomes against Git and optional forge evidence;
manual verdicts outrank inferred outcomes. The ledger is the durable installation state.

The runner never merges. Human review and merging are the normal workflow. An independently
configured external merge job may consume branches only under separate operator authorization
([ADR 0040](docs/adr/0040-optional-external-merge-job.md)); that job is not shipped here.
PR creation is optional, disabled by default, and requires separate API credentials.

## Boundaries

The runner owns branch creation, commit, and push. The Claude adapter enforces its tool and write
boundary through per-stage tool profiles and a `PreToolUse` guard. The ship gate executes candidate content and uses bubblewrap without host credentials,
with network disabled unless public egress is explicitly enabled through a vetting proxy.
These boundaries do not prevent all secret reads by agents or all prompt injection; see the
[threat model](docs/design/risk-analysis.md).

## Vocabulary

- **Work item:** a repository, target, and proposed action.
- **Dimension / lens:** a review perspective such as correctness, security, or documentation.
- **Ledger:** persistent events describing work and outcomes.
- **Rulebook:** operator-authored authorization and configuration, read-only to agents.
- **Constitution:** a proposed prompt-level identity and principles layer, distinct from the
  rulebook; see [the design](docs/design/constitution-and-rulebook.md).
- **Budget window:** the time and quota envelope for a run.

## Scope

nightshift reviews and fixes code in authorized repositories. It is not a hosted service or a
general task runner. It does not guarantee defect detection, safe changes, complete secret
isolation, or a fixed monetary cost. Decisions are recorded in [docs/adr/](docs/adr/);
operational instructions are in [docs/deployment.md](docs/deployment.md).
