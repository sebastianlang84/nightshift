# ADR 0042 — protected paths wait for a human merge

- Status: accepted
- Date: 2026-11-18
- Touches: [ADR 0040](0040-optional-external-merge-job.md) (optional external merge job)

## Context

An external merge job can merge reviewed `nightshift/*` branches without a human (ADR 0040). For
nightshift's own repository that includes the code that confines the agents: the hooks, the sandbox
and the rulebook parser. A wrong automatic merge there weakens the checks for every later night,
including the checks on the next change to the same files. Other repositories have files of the
same kind, such as credential handling or deployment.

## Decision

1. A repository entry may declare `protected_paths`: comma-separated paths relative to the repo
   root; an entry that ends in `/` covers a directory. The parser rejects absolute paths and `..`.
2. The parser emits the list with the repository entry. The Runner does not act on it; a merge job
   that merges automatically leaves any branch that touches a protected path for a human.
3. The rule is the same for every repository; nightshift's own entry is only the first to use it.

## Consequences

Changes to protected files still get found, fixed, reviewed and pushed at night. Only the merge
waits for a human.
