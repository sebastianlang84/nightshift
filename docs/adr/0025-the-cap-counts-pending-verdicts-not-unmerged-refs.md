# ADR 0025 — the open-branch cap counts pending verdicts, not unmerged refs

- Status: accepted
- Date: 2026-08-13
- Extends: [ADR 0004](0004-v1-scope-branch-isolated-steward.md) (the cap), [ADR 0016](0016-reconcile-detects-squash-merges-and-fails-closed.md) (the verdict ladder)
- Amends: [ADR 0014](0014-finding-identity-and-lifecycle.md) §"the cap counts git reality, not ledger rows"

## Context

The open-branch cap is the system's only throughput governor (ADR 0004): work continues while
fewer than `limits.max_open_branches` `nightshift/*` branches are outstanding. Its purpose is
backpressure on the *human* — nightshift must not run ahead of the operator's ability to decide.
The quantity it therefore wants is **decisions still pending**.

What it measured instead was `git branch -r --no-merged <base>`: is the branch's sha an ancestor
of base. That is the same naive merge test ADR 0016 already found insufficient and replaced inside
harvest's reconcile ladder — and re-deriving it in the cap makes the cap wrong in both directions
whenever a ref outlives the decision it belongs to:

- **A rejected branch holds a slot forever.** The operator closes the PR (a decision — often
  because they fixed it themselves) and leaves the ref on origin. Nothing ever deletes it, the
  sha never enters base, so the branch counts as "open" for the rest of time.
- **A squash- or rebase-merged branch counts as open** if its ref survives, although ADR 0016 §2
  already established the change demonstrably landed.

This is not hypothetical. On 2026-08-13 the fleet had been at `4/4` for three consecutive nights,
each logging `open-branch cap reached (4/4) — stop` and `0 shipped, 0 considered`. One of the four
was market-digest's `nightshift/correctness-bug-…-20260809-042520-2`, whose finding was real but
which the operator had rejected on 2026-08-09 in favour of a hand-written fix (PR #45). Harvest had
recorded `dropped` for it that same night. **The ledger knew the branch was settled; the cap did
not read the ledger.** Two full nights of fleet capacity were spent on a decision that had already
been made.

The asymmetry is the point: harvest owns an authoritative verdict ladder (ancestor test → patch
equivalence → PR state → ref presence, failing closed), records the result, and never overwrites a
human verdict (ADR 0007). The cap ignored all of it and asked git a weaker question.

## Decision

**The cap counts branches whose latest ledger verdict is not terminal.** A `nightshift/*` ref on
origin occupies a slot only while the ledger has no `merged` / `dropped` / `resolved` / `wontfix`
verdict for it — the same terminal set `known_work` already uses to decide a fingerprint is
cleared (ADR 0014).

- `refresh_settled_branches` builds the settled set once per pass, alongside the existing ref
  refresh; `open_branch_count` filters against it.
- Latest verdict per `(repo, branch)` wins, so a reopened PR — harvest derives `open` again from
  the PR state — re-occupies its slot on the next pass.
- Verdicts are keyed by repo *and* branch: the same branch name in another repo is a different
  decision.
- No ledger, or a ledger jq cannot read, degrades to the previous ref-only count. That over-counts,
  which pauses work — the safe direction for a backpressure signal.

Nothing here writes: the cap remains a read of state harvest already owns. The ledger is the record
(ADR 0021); the cap now reads it instead of re-deriving a worse answer from git.

## Consequences

- A rejected-but-undeleted branch stops blocking the fleet. Deleting the ref stays good hygiene,
  but is no longer load-bearing for throughput.
- Squash/rebase merges free their slot as soon as harvest sees them, whether or not GitHub deleted
  the branch.
- The cap now depends on harvest having run. It runs first in the night loop, so a stale verdict
  costs at most one pass — and staleness only ever over-counts.
- Cost: one `jq` pass over the ledger per pass boundary, next to a fleet-wide fetch that already
  dominates it.
- The reported figure changes meaning: digest and log now say "awaiting your verdict" / "undecided"
  rather than "unmerged", because those numbers can now differ.
