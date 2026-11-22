# ADR 0045 — The host rulebook selects the agent

- Status: accepted
- Date: 2026-11-22
- Amends [ADR 0044](0044-claude-only-opus-works-a-review-model-reviews.md).

## Context

Quota windows reset at different times. On 2026-11-22 the curator decided that each
machine should select its overnight harness just as it sets its open-branch cap.

## Decision

Each host selects Claude Code or Codex through `agent.primary` in its untracked
`rulebook.yaml`. The adapter's model and effort apply across stages. Review and
branch advice on the primary adapter may use `agent.review_model`. An advisor from
the other vendor uses its own configured model and effort. The deterministic mock
remains available for tests and dry runs.

The operator can change adapters between nights. The launcher retains its quota
pause, and the runner counts consecutive failures per adapter and model.
[The example rulebook](../../rulebook.example.yaml) gives both configurations.

## Consequences

Codex stages use a fresh home and the CLI sandbox. Fix receives workspace write
access with command network access disabled. All other stages use read-only access.
[The hook specification](../design/hook-spec.md) documents stage isolation and the
[threat model](../design/risk-analysis.md#r15) describes the shell's residual read access.
