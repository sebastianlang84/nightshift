# ADR 0038 — every open branch gets advice from two vendors every night

- Status: accepted
- Date: 2026-10-15
- Extends: [ADR 0031](0031-the-reviewer-may-be-another-vendor.md) (a reviewer from another vendor does not share the author's blind spot)
- Touches: [ADR 0020](0020-the-rulebook-declares-the-stage-model.md) (the rulebook declares the model) · [ADR 0034](0034-an-empty-answer-is-not-a-verdict.md) (an empty answer is not a verdict)

## Context

`advise_branches` gave each open `nightshift/*` branch a merge / do-not-merge opinion in the digest.
It was opt-in through `NIGHTSHIFT_BRANCH_REVIEW=1` and ran on one adapter
(`NIGHTSHIFT_ADVISOR_AGENT`). Both switches were environment variables, so the rulebook did not show
whether a host used it.

The operator wants every open branch to have a recommendation from two models every morning. A
recommendation from one model shares that model's blind spots, which is the same author's-twin
problem ADR 0031 addresses for the Review stage. A two-valued verdict also loses the most common
answer: the branch is worth having, but it needs one correction first (a CHANGELOG entry, a test
that does not exercise the fix).

## Decision

**1. The rulebook names the advisors.** `agent.advisors` is a comma-separated list of adapters
(`advisors: claude,codex`). It is validated like `review_agent`. A repeated adapter is refused,
because it asks the same model twice. When the key is set, the branch review runs every night.
`NIGHTSHIFT_ADVISORS` overrides it, and an explicitly empty value switches it off for one run.
`NIGHTSHIFT_BRANCH_REVIEW=1` with `NIGHTSHIFT_ADVISOR_AGENT` still works as a single advisor. Each
advisor runs on its own adapter through the same rebinding of `NIGHTSHIFT_AGENT` as before. The
quota fallback stays off, for the reason ADR 0031 gives. An adapter that failed to authenticate is
skipped. The other advisors still run.

**2. The verdict has three values.** `prompts/advise.md` asks for `merge`, `fix` or `reject`, plus
`what`, `benefit`, `reason` and, for `fix`, `required_fix`. An answer that lacks one of these
fields, names another verdict, or is empty is shown as `?`. It is not a verdict (ADR 0034).

**3. Answers are cached.** The key is repo + branch tip sha + base sha + adapter + requested model.
The answer is stored in `state/advice/<key>.json`. A matching key reuses the answer without a stage
call, so an unchanged branch is reviewed once, not every night. A changed tip, base or model
changes the key. A `?` is never cached. Entries older than 90 days are deleted.

**4. The recommendations are combined.** All advisors `merge` → `merge`. Any `reject` → `reject`.
Otherwise → `fix`. A `fix` that rests on fewer answers than advisors says so
(`fix (1 advisor missing)`). No answer at all → `?`. The required-fix texts are joined and labelled
by adapter.

**5. The digest shows a table.** `| Repo | Branch | What | Benefit | <one column per advisor> |
Recommendation | Required fix |`. The advisor columns are named after the adapter (`claude` →
Claude, `codex` → GPT). `what` and `benefit` come from the first advisor that answered.

## Consequences

- The host's rulebook sets `advisors: claude,codex`, so the morning digest carries a recommendation
  from two vendors per open branch. Which model each adapter requests is still `claude_model` and
  `codex_model` (ADR 0020).
- The first night after a branch is pushed costs one advise stage per advisor. Later nights cost
  nothing until the branch or its base moves.
- An advisor that changes its model re-reviews every open branch once.
- A cached answer survives a prompt change. Delete `state/advice/` to force a fresh review.

Regression cover: `tests/test-branch-review.sh`.
