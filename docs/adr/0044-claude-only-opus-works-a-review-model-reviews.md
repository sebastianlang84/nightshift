# ADR 0044 — Claude only: Opus works, a review model reviews

- Status: accepted
- Date: 2026-11-19
- Supersedes: [ADR 0031](0031-the-reviewer-may-be-another-vendor.md) (the reviewer on another adapter) · [ADR 0038](0038-every-open-branch-gets-two-vendors-advice.md) in its vendor mix · [ADR 0037](0037-the-fix-stage-starts-from-a-provisioned-worktree.md) in its Codex toolchain and pnpm-store parts · [ADR 0023](0023-an-unusable-agent-aborts-the-night.md) in its quota fallback
- Touches: [ADR 0019](0019-stage-context-excludes-operator-config.md) (only the Claude half of stage isolation remains) · [ADR 0020](0020-the-rulebook-declares-the-stage-model.md) (a second rulebook model key)

## Context

The operator runs exactly two models: Claude Opus does all work and Claude Fable only reviews.
Codex is no longer called or configured on any host. Its adapter carried its own stage home, its own
argv, a Fix sandbox with a different residual risk than Claude's, a toolchain PATH, a pnpm store
setting, a quota fallback from Claude to Codex and a per-review vendor command. Every one of those
paths now runs nowhere, and an unused path in a public repository still reads as a supported one.

The one thing the Codex routing bought — a reviewer that is not the author's model — is still
wanted. It no longer needs a second vendor: a different Claude model can review.

## Decision

**nightshift has two adapters, `claude` and the deterministic `mock`. The Review stage and the
branch advice run on `agent.review_model`; every other stage runs on `agent.claude_model`.**

- **Removed:** the Codex adapter and every value, key and variable that selected or configured it
  (`codex` as an adapter, `agent.codex_model`, `agent.codex_effort`, `NIGHTSHIFT_CODEX_*`), the
  quota fallback (`NIGHTSHIFT_QUOTA_FALLBACK_AGENT`), and the reviewer routing (`agent.review_agent`,
  `NIGHTSHIFT_REVIEW_AGENT`, `review_agent: auto` with `NIGHTSHIFT_REVIEW_VENDOR_CMD` and
  `NIGHTSHIFT_REVIEW_VENDOR_TIMEOUT`). With one real adapter a routed reviewer can only name the
  night's own adapter or the mock. A rulebook that still names a removed key or `codex` fails with
  the parser's unknown-key or unknown-adapter error instead of being ignored.
- **Kept:** `agent.advisors` still switches the nightly branch advice on (`claude`, or `mock` slots
  in tests); one real adapter means at most one real advisor.
- **The review model.** `agent.review_model`, overridden by `NIGHTSHIFT_REVIEW_MODEL`, follows the
  ADR 0020 precedence. When it resolves to a value, the Review and advise stages pass it to
  `claude --model`. When it does not — the key omitted, or the variable set empty — they use the
  `claude_model` resolution like every other stage. The night announces both models at start.
- **Every review is adversarial.** The reviewer is always the author's vendor now, so the "same model
  family" brief that `review_agent: auto` added only on a same-vendor review is part of every Review
  prompt.
- **A wall is counted per model.** A spent window is per model, and Fix and Review now alternate on
  the same adapter. Counted per adapter, an Opus success between two failed reviews restarted the
  count, and the night would keep building fixes nothing could review. Two failures in a row on the
  same model abort the night (`agent_unavailable`), as ADR 0023 already did for an adapter without a
  fallback.
- **A spent quota pauses; it does not switch.** The operator's rule for unattended runs is to pause
  and say so. `NIGHTSHIFT_QUOTA_CMD` lets the launcher ask the host before the night starts, and
  `NIGHTSHIFT_NOTIFY_CMD` sends one line when the night pauses on it or stops for
  `agent_unavailable`. Both are optional and never fatal (docs/deployment.md).

## Consequences

- A night whose quota runs out stops; the work waits for the next night instead of continuing on
  another vendor.
- Review independence now rests on a different model of the same family plus the adversarial brief,
  not on a different vendor.
- `setup_cmd` (ADR 0037) still runs before every Fix stage, but a Claude Fix stage has no shell, so
  nothing in the Fix stage uses what it installs. The gate's purge of ignored files stays either way.
- History stays in the superseded ADRs; their regression-coverage lines name the removed tests as
  removed.

Regression coverage: `tests/test-review-model.sh`, `tests/test-agent-wall-reviewer.sh`,
`tests/test-agent-wall-abort.sh`, `tests/test-quota-pause.sh`, `tests/test-rulebook-validation.sh`.
