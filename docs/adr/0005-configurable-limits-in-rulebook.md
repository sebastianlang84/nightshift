# ADR 0005 — all operational limits live in the rulebook

- Status: accepted (design phase)
- Date: 2026-07-09

## Context

[ADR 0004](0004-v1-scope-branch-isolated-steward.md) removed the per-night branch count and made
`max_open_branches` (the open-branch backpressure) the **sole throughput governor**. That decision
stands. But the cleanup left the enforcement surface inconsistent:

- `max_open_branches`, `max_files_per_change`, `max_lines_per_change` — configurable in the rulebook.
- The per-run runaway ceiling — env-only (`NIGHTSHIFT_MAX_RUN_BRANCHES`, default 50), invisible to
  the human-owned governance file.
- The Fix↔Review round-trip cap — fully hardcoded (`while [ "$iter" -lt 3 ]`), no knob at all.
- `max_branches_per_night` — still parsed and assigned (`MAX_BRANCHES`) but read nowhere: dead config
  left over from the ADR 0004 revert, and `prototype.md` still advertised it as an active cap.

So two real limits governed behaviour without appearing where an operator looks, and one dead knob
lingered with contradicting docs.

## Decision

The rulebook `limits:` map is the single surface for every operational limit. It gains two knobs and
loses the dead one:

- `max_branches_per_run` (default 50) — HARD per-run runaway ceiling. A **backstop, not policy**:
  backpressure (`max_open_branches`) remains the real governor per ADR 0004. This does **not**
  reintroduce the per-night cap ADR 0004 removed — it bounds a single run, not a night.
- `max_fix_iterations` (default 3) — HARD cap on Fix↔Review round-trips per finding before abandon.
- `max_branches_per_night` — removed from the parser and the Runner.

**Precedence for `max_branches_per_run`:** rulebook → `NIGHTSHIFT_MAX_RUN_BRANCHES` env → default.
The rulebook is authoritative; the pre-existing env var is retained as an ops override for when the
rulebook does not set it (non-breaking). The other limits have no env counterpart — the parser owns
their defaults. To make "rulebook → env" work, `parse_rulebook.py` emits an empty value for
`max_branches_per_run` when absent, so the Runner can distinguish "unset" from a parser default.

## Consequences

- One place to reason about limits; no hidden hardcoded values in the loop.
- The per-run ceiling being in the rulebook could read as a throughput policy. Mitigated by the
  `HARD safety ceiling … NOT policy` comment in `rulebook.example.yaml` and this ADR: backpressure is
  the governor; this is only a runaway backstop.
- `NIGHTSHIFT_MAX_RUN_BRANCHES` semantics change slightly — it now loses to a rulebook value instead
  of always winning. Acceptable: nothing in-repo sets it, and the rulebook is the intended surface.
