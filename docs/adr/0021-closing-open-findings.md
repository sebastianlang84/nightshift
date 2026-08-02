# ADR 0021 — closing open findings: signature probe, then bounded verification

- Status: accepted
- Date: 2026-08-02
- Extends: [ADR 0014](0014-finding-identity-and-lifecycle.md) (lifecycle), [ADR 0007](0007-human-verdicts-outrank-machine-reconcile.md) (verdict authority)

## Context

A `finding` is a work item nightshift surfaced but did not fix: no branch, no sha. `harvest.sh`
reconciles a *branch* by testing its recorded sha against the base tip, so it structurally cannot
reach a finding — the only way one ever got a verdict was a human typing
`harvest.sh verdict <selector> resolved`, which nobody did. Measured on the live ledger on
2026-08-02: **22 findings, 22 without any verdict**, the oldest 23 days old.

Three surfaces carry that staleness. The morning digest repeats every finding under "Open findings
(all nights)" forever. The dashboard's Nightshift tab shows a permanent `📝 TODO` badge with an
empty verdict column. And `known_work` injects unresolved findings into every later Explore prompt
with "do not re-report these" — so findings that were quietly fixed weeks ago keep consuming
prompt budget and keep suppressing their own identity.

The system already holds an unused signal: ADR 0014 stores `code_sig` on every finding row — a hash
of its target files' blob shas at the moment it was recorded. Recomputing it costs nothing and is
decisive in one direction: an unchanged signature means the target code was never touched, so the
finding cannot have been fixed. A changed signature means only that something moved — a fix, an
unrelated edit, or a reformat.

## Decision

**1. Two layers, cheapest first, both fail closed.**

*Layer 1 — deterministic probe (`lib/probe_findings.py`).* For every open finding, recompute
`code_sig` at HEAD and classify: `untouched` (signature matches — certainly still open),
`code_changed` (signature differs — may be fixed), `unknown` (no baseline signature on pre-0014
rows, an unreadable repo, or a fingerprint with no file targets). No model, no network. It runs at
the end of every `harvest.sh`.

*Layer 2 — verify stage.* Only `code_changed` findings are handed to a read-only stage
(`prompts/verify.md`) that reads today's code and judges whether that specific defect is gone. It
receives the finding record, never a reconstruction of the old code.

**2. Probe output is a derived snapshot, not ledger events.** `state/findings-probe.json` is
rewritten in place (atomic replace, world-readable so the dashboard container can read it through
its existing read-only mount). The probe observes; it never claims a verdict. The ledger stays the
append-only record of decisions.

**3. Only a proven fix writes a verdict, and it is labelled as machine-made.** `resolved:true` AND
`confidence:"high"` appends `verdict: resolved` with `source: "auto-verify"` — distinct from a
human's `manual` and from harvest's unlabelled reconcile. Every other answer leaves the finding
open. ADR 0007 is unchanged: this phase only ever *derives* `resolved`, and a human verdict still
outranks it.

**4. A verify result is remembered per signature.** The outcome is stored in the snapshot keyed to
the signature it was made against. An unchanged finding is therefore never re-verified, and an item
re-enters the queue exactly when its code moves again. That, plus `max_verifies_per_run` (default
5, `0` disables the stage entirely), bounds what closure can cost per night.

**5. A human front door for what the machine will not decide.** `harvest.sh todos` lists open
findings numbered, with age and probe state; `harvest.sh close <n> [reason]` records the manual
`resolved`. `unknown` items — including every pre-0014 row — are closed this way or not at all.

## Consequences

- The `untouched` state is the honest, zero-cost majority answer: on the live ledger it covers 7 of
  16 signed findings, and none of those cost a model call.
- Coarse invalidation cuts both ways (ADR 0014's own trade-off): an unrelated edit to a target file
  makes a finding a verify candidate. The cap bounds that cost; the verify prompt is instructed
  that a changed file is not evidence of a fix.
- A false `resolved` deletes a real defect from the backlog. Mitigations: two independent gates
  (`resolved` + `high` confidence), an explicit "when in doubt keep it open" instruction, the
  `auto-verify` label so a human can audit machine closures, and — because ADR 0014's suppression
  keys on the content signature — a later change to the same code re-opens the identity for a fresh
  finding.
- Findings recorded before ADR 0014 have no baseline and stay `unknown` forever; they are human
  backlog, not machine work.
- Covered by `tests/test-finding-probe.sh` (classification, snapshot merge, todos/close) and
  `tests/test-finding-verify.sh` (verdict + source, negative result, untouched never verified, cap).
