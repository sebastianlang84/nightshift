# ADR 0012 — one Nightshift installation per target repo

- Status: accepted
- Date: 2026-07-12

## Context

Nightshift's memory is a single append-only ledger (`state/ledger.jsonl`) local to the installation
(ADR 0004/0007). Everything that keeps the system honest reads that one ledger:

- **dedup** — `already_done` / `already_acted` / `already_surfaced` skip a finding whose fingerprint
  is already recorded;
- **backpressure** — the open-branch cap counts unmerged `nightshift/*` branches to decide when to
  stop;
- **fairness & rotation** — least-recently-serviced repo (ADR 0008) and per-dimension coverage
  (ADR 0010) are computed from ledger timestamps;
- **harvest** — merge/drop verdicts reconcile against the same ledger.

Nothing in the design coordinates two installations. If the same target repo is listed in the
rulebooks of two Nightshift installations (two machines, or two checkouts on one machine, each with
its own `state/`), each has a *divergent* ledger: neither sees the other's findings, branches, or
verdicts.

## Decision

**A given target repo is managed by exactly one Nightshift installation.** This is an operating
constraint, not something the code enforces — there is no cross-installation lock or shared ledger in
v1.

## Consequences

Running two installations against the same repo produces, with no error:

- **duplicate work** — both independently explore and can ship near-identical `nightshift/*` branches
  for the same defect (fingerprint dedup only works within one ledger);
- **broken backpressure** — each counts only the branches it knows about, so the real number of open
  branches exceeds either installation's cap;
- **broken rotation/fairness** — each rotates dimensions and orders repos on partial history;
- **harvest blind spots** — a branch shipped by installation A is invisible to B's harvest.

Therefore:

- Keep one rulebook as the single owner of each repo. If you must move the installation, move
  `state/` with it (the ledger is the memory) and re-point the scheduler (`bin/schedule.sh install`).
- Consolidating two installations means merging their ledgers by hand; there is no supported merge.
- A future multi-node design would need a shared/locked ledger or a partition of repos by owner —
  out of v1 scope (see `OPEN-QUESTIONS.md`).

Documented for operators in [`docs/deployment.md`](../deployment.md).
