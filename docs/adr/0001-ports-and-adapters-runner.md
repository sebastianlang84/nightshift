# ADR 0001 — Runner behind a ports-and-adapters boundary

- Status: accepted (design phase)
- Date: 2026-07-08

## Context

nightshift should be usable primarily on Claude Code now, and be portable to other harnesses
(OpenAI Codex, Pi, …) later without a rewrite. The parts that differ between harnesses are narrow:
how the LLM agent is invoked headless, how permissions are expressed, and how remaining budget is
queried. Everything else — selecting work, remembering it, evaluating rules — is generic.

## Decision

Introduce a **runner adapter boundary from day one**, even though only the Claude Code adapter is
implemented first. The core (Brain, Memory, Policy) calls a single interface:

```
run_agent(prompt, cwd, permission, budget) -> result
```

Harness-specific concerns live only in adapters:
- `adapters/claude-code.*` (first; `claude -p --permission-mode …`)
- `adapters/codex.*`, `adapters/pi.*` (later)

A neutral permission vocabulary (`read-only` | `edit-in-worktree` | `none`) is mapped to each
harness's flags inside its adapter. A `budget_remaining()` call also lives in the adapter, because
only the harness/subscription knows its own quota window.

## Consequences

- Going harness-agnostic later is "add a file," not "refactor the core."
- Small upfront cost now: one function with a single case.
- The core must not leak harness assumptions (no `claude`-specific flags outside adapters).
- Prompts stay in the neutral core; per-harness prompt tweaks, if unavoidable, are the exception.
