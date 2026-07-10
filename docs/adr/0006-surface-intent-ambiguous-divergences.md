# ADR 0006 — surface intent-ambiguous value conflicts instead of auto-fixing

- Status: accepted (design phase)
- Date: 2026-07-11

## Context

A real run had the EXPLORE stage find a genuine divergence: `bin/schedule.sh` documented the
timer as firing at 03:00, while the committed `scheduler/nightshift.timer` fired at 18:20. The
agent "fixed" it by rewriting the comment to 18:20 — the wrong direction. 18:20 was a *throwaway
test cadence* (the unit's own `Description` even said "daytime test cadence"); 03:00 is the design
intent. The fix also deleted a comment that stated the rationale ("the whole point at 03:00").

The behaviour was locally defensible: the reviewer applied the usual "code is authoritative, the
comment is stale" heuristic. It failed because *which side is authoritative was not determinable
from the repo* — it was a fact about intent that lived outside the code (a pending "reset to 03:00
before prod" task). The repo actually lied about its own intent by committing a temporary value
into the canonical unit file. See the sibling fix for that root cause: the test cadence now lives
in an uncommitted local systemd drop-in, and `scheduler/nightshift.timer` stays at 03:00.

EXPLORE is framed as a *cold, first-contact reviewer with no privileged knowledge of intent*. That
framing already forbids guessing intent — but nothing operationalised it for value conflicts, and
in a `branch-fix` repo the only two outcomes were `ship` or `abandon`, with no way to hand a real
divergence to a human without either rewriting it or dropping it silently.

## Decision

EXPLORE emits a `disposition` field: `fix` (default) or `surface`.

Set `surface` when reconciling a proven divergence would require picking an authoritative side that
the repo does not settle — specifically when the fix would side with a value labelled
temporary/test/WIP/placeholder/example, delete or invert a stated design rationale, or side with a
value that contradicts the component's own documented name or purpose. When unsure, prefer
`surface` over guessing a direction.

The runner routes `disposition: surface` into the findings path even in `branch-fix` repos: it is
recorded as a `finding` ledger event (a human-owned TODO), deduped by fingerprint like any finding,
and never enters the Fix↔Review loop. `fix` keeps the existing behaviour.

## Consequences

- A wrong-direction auto-fix that blesses a throwaway value is replaced by a flagged TODO the human
  resolves in the authoritative direction.
- `branch-fix` repos gain a third outcome (surface) alongside ship/abandon; the morning digest
  "Findings" section is no longer exclusive to `findings-only` repos (heading updated accordingly).
- The judgment still lives in the model. If EXPLORE misclassifies a `surface` case as `fix`, the
  Fix↔Review `abandon` verdict remains the backstop (dropping it, without a TODO). This is accepted
  for v1; a stronger backstop can move the check into REVIEW later.
- Related root-cause hygiene: never commit a temporary operational value into a canonical config
  file — use a local, uncommitted override so the repo never misrepresents its own intent.
