# ADR 0040 — a reviewed branch merges without a human

- Status: accepted
- Date: 2026-10-29
- Supersedes in part: [ADR 0004](0004-v1-scope-branch-isolated-steward.md) ("never merge", the human merge gate)
- Touches: [ADR 0038](0038-every-open-branch-gets-two-vendors-advice.md) (the nightly advisors stay read-only)

## Context

From 2026-10-23 to 2026-10-29 nightshift stood still: ten branches waited for a merge, the limit
`max_open_branches` was reached, and every night ended without work. The flow of 2026-10-27
(reviewed here, one kb task per repo, the repo's session merges) needed a session to pick the task
up; the brain task stayed untouched for more than a day. A gate that waits on a session that may
not come is not a review step but a stop.

## Decision

The operator (Sebastian, 2026-10-29) authorised that every open `nightshift/*` branch is reviewed
and merged without a human. An **operator-side** job does it, outside nightshift: the chief of
staff's `nightshift-merge` job on beelink (`~/chief/nightshift-merge`, hourly user timer). For
each branch it

1. probes the merge for a conflict;
2. has the branch read by the vendor that did **not** write the fix (`runs.jsonl` names the fix
   stage's adapter), through the `using-harnesses` review script;
3. on a merge recommendation only, runs the rulebook's `test_cmd` on the merge result;
4. green: merges as a merge commit, pushes without force, deletes the branch, fast-forwards the
   deployed checkout. Anything else: one kb task to the repo, no merge.

nightshift itself is unchanged: the Runner and every stage still push only to `nightshift/*`, the
pre-push hook still refuses everything else, and the ADR 0038 advisors still never merge. What
changes is only who closes the branch: the job instead of a human.

## Consequences

- A bad change no longer costs one rejected branch; it lands in `main` unless the cross-vendor
  review or the tests catch it. The review is the one gate, so the Explore and Fix prompts now say
  that a reviewer of another vendor, not a human, reads the branch.
- The risk analysis's condition "no autonomous landing while R1/R2 stand" is lifted by the
  operator's decision, not by closing R1/R2. They stand; a merged change that exfiltrates on the
  next `test_cmd` or deployment is the residual the review has to catch.
- The job runs `test_cmd` on the merge result unsandboxed, as the operator account, after the
  review and before the merge. A hostile test the review misses runs there with that account's
  reach even when it then fails and nothing merges; a red suite or a refused merge does not show
  that the run was harmless. The branch already ran the same command inside the ship gate's
  sandbox (ADR 0026), which the job does not repeat.
- Branches the ledger already settled stay where they are: deleting an unmerged branch remains a
  curator approval.
- Reversal: disable the timer (`systemctl --user disable --now nightshift-merge.timer`); branches
  then wait for a human again.
