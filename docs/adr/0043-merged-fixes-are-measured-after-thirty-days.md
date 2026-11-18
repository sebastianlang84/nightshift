# ADR 0043 — merged fixes are measured thirty days later

- Status: accepted
- Date: 2026-11-18
- Touches: [ADR 0040](0040-optional-external-merge-job.md) (optional external merge job) · [ADR 0021](0021-closing-open-findings.md) (derived snapshots beside the ledger)

## Context

The merge rate counts what reviewers accepted. Once an external job merges automatically, the
reviewers are models as well, so the rate no longer says whether the fixes were right, and
nothing recorded what happened to a fix after its merge.

## Decision

1. Harvest refreshes `state/fix-survival.json` with `lib/probe_survival.py`, without a model, the
   network or a ledger write. For every item whose latest verdict is `merged`, it measures the
   base as it stood 30 days after the verdict:
   - **reverted**: a later commit names the fix's sha and says it reverts it;
   - **kept**: lines the fix added that `git blame -M` still attributes to it;
   - **removed**: most added lines sat in files deleted later. The code is gone, which says
     nothing about the fix, so it counts neither way;
   - **held**: not reverted, and at least half of the added lines in surviving files kept.
2. A fix younger than 30 days is `pending`. A fix whose commit is gone or not in the base is
   `unknown`. A measured fix is cached, because its cutoff commit no longer changes.
3. The digest shows held/measured per repo; `bin/harvest.sh survival` prints the table.

## Consequences

The measure is a proxy. A later refactor that rewrites a fixed line counts against the fix, and a
fix that is wrong without anyone touching it again counts as held. It still separates fixes that
stayed from fixes that were undone or redone within a month, which the merge rate cannot.

Fixes merged before a repository's history was replaced are `unknown`.
