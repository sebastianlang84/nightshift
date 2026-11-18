# ADR 0041 — a red base skips the repo before Explore

- Status: accepted
- Date: 2026-11-18
- Touches: [ADR 0022](0022-a-repos-own-tests-gate-the-ship.md) (a repo's own tests gate the ship)

## Context

The ship gate ran on the unchanged base only before the first fix of a repo. A red base still got
one fix attempt per night, in case the fix repaired the suite, and the repo's other findings ended
`gate-blocked`. From 2026-11-12 to 2026-11-16 twenty findings in three repos ended that way. Explore
and the one attempt were paid every night, nothing shipped there, the night's work went to the one
repo whose suite was green, and nobody whose job it was to repair the suite was told.

## Decision

1. Before Explore, the Runner runs the gate once per repo and base commit on the unchanged base. A
   red suite, or a gate that cannot run, skips the repo for the rest of the run, even if a later
   pass finds its base moved to a green commit. Findings-only repos are not checked.
2. The digest names each skipped repo at the top with the log of the base run.
3. `NIGHTSHIFT_BLOCKED_BASE_CMD`, when set, is run once per red spell with the repo, base commit,
   state and log path. The spell ends at the first green pre-check. `state/blocked-bases.tsv`
   records the reported repos under a lock, so overlapping runs send one report; a failed command
   is tried again the next night.
4. The red-base attempt rotation (`state/base-red-attempts.tsv`) is removed.

## Consequences

A fix that would have repaired a red suite is no longer attempted. The owner of the repo repairs
it instead, which the report asks for. A red base now costs one suite run per night and no model
tokens.
