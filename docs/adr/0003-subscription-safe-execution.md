# ADR 0003 — Subscription-safe execution

- Status: accepted (design phase)
- Date: 2026-07-08

## Context

A core goal (requirement #7) is to run on the user's own coding subscription (Claude Code / Codex),
not a separate metered API bill. The prior-art survey surfaced a hard reality: in 2026 Anthropic
actively shut down third-party tools that tapped the subscription quota *outside* Claude Code.
Routing a subscription token through a custom API client is the move that gets broken — and is a
terms-of-service risk.

## Decision

Execute agent work only through the **first-party CLI, headless**: `claude -p` (and, per harness,
the equivalent first-party CLI). **Never** put the subscription token into a custom API wrapper.

- Budget/window awareness is done by observing usage (e.g. `ccusage`, `claude-token-lens`) and
  respecting the 5h / weekly windows — not by metering a custom API client.
- `budget_remaining()` lives in the runner adapter (ADR 0001), because only the harness/subscription
  knows its own window.
- If a user explicitly opts into a pay-per-token API key instead of a subscription, that is a
  separate adapter configuration — the default and the subscription path stay first-party CLI.

## Consequences

- Requirement #7 stays clean and ToS-safe.
- The budget model is "run until the window is spent, then stop," detected via usage, rather than a
  hard dollar cap (a dollar cap still applies naturally on the API-key path).
- We depend on the first-party CLI's headless interface and its flags (already the case in ADR 0001).
