# ADR 0009 — explore optimizes for value per review slot, not for smallness

- Status: accepted
- Date: 2026-07-11

## Context

The explore prompt (`prompts/explore.md`) told the agent to find "ONE **small**,
high-value, **low-risk** improvement", to attempt "no sweeping refactors", and "when in
doubt: none". It also demoted runtime findings to near-unshippable and let the agent stop
at the first candidate that cleared the bar (satisfice, not rank). The observed result:
findings skewed to doc/comment/typo drift — trivially provable, low value.

That calibration is the threat model of an agent editing an **unversioned live system**.
It does not match nightshift's actual architecture, where the safety is already carried
end to end by isolation, not by keeping each change tiny:

- every work item runs in a throwaway `git worktree`, never the repo's live checkout;
- the fix lands only on a `nightshift/*` branch — `main` is untouched;
- push confinement rejects any ref outside `nightshift/*`;
- **nothing merges without a human** (ADR 0004; PRs are opt-in and merge stays the human's click).

So the blast radius of a bad OR large finding is exactly one `nightshift/*` branch that a
human reviews in the morning and rejects at zero cost. Optimizing explore for "smallest,
safest, static-only" spends the system's one scarce resource — the model's judgment — on
avoiding a risk the architecture has already neutralized.

The change budget already reflected this: the runner injects "prefer a change under 15
files and 400 lines; larger is acceptable for one coherent improvement"
(`bin/nightshift.sh`). The prompt was contradicting the budget the config already grants.

## Decision

Explore optimizes for **value to the morning reviewer**, not for smallness. Safety is the
architecture's job (worktree + branch-only + push confinement + human merge gate); the only
constraints explore keeps are the two the architecture does NOT cover:

1. **Provability** — a finding must be a falsifiable claim with a verify recipe, so the
   morning merge is a 30-second audit. Kept verbatim; it is the review-economics enabler,
   required no matter how large the finding.
2. **Worth a review slot** — the human's morning attention is the real scarce resource, so
   the bar is expected value, not size.

Concretely, the prompt now:
- frames the isolation reality explicitly and tells the agent to optimize for value, not
  minimal risk (the branch is free to reject);
- **enumerates then ranks**: build a shortlist, rank by `impact × provability`, emit only
  the top one — killing the first-found/satisfice failure mode;
- gives an explicit impact hierarchy with pure prose/style drift as the FLOOR, raised only
  when nothing above it clears the bar;
- treats verifiability (`static` … `runtime`) as a REPORTING flag and ranking tiebreaker,
  not a filter: runtime findings ship flagged `UNVERIFIED` for the human to test, suppressed
  only when a wrong fix would itself be unsafe (rubber-stamp risk);
- drops "small / no sweeping refactors / when in doubt none"; `found:false` is for "nothing
  worth a review slot", not "everything I found is nontrivial".

Kept unchanged: the surface-vs-fix intent guard (ADR 0006), the output schema, and the
`confidence` semantics (now explicitly not a reason to drop a high-impact finding).

## Consequences

- Findings should shift from doc-drift toward correctness/latent bugs and larger coherent
  improvements — the change the operator asked for.
- Review burden per finding rises. This is the intended trade: fewer, more valuable branches
  beat many trivial ones. The open-branch cap (ADR 0004/0005) and the least-recently-serviced
  ordering (ADR 0008) still bound how many land per night and keep coverage fair.
- More runtime/lower-confidence findings will ship flagged `UNVERIFIED`. The morning reviewer
  must actually test those before merge — the flag and the human gate are the safeguard, and a
  rubber-stamp is now a more expensive mistake. The "unsafe-when-wrong ⇒ drop" carve-out limits
  the worst case.
- `prompts/fix.md` is unchanged: its "minimal, single-concern" means "no scope creep beyond the
  chosen finding", tempered by the same injected change budget. Revisit only if fix gold-plates.
- Watch the merge-rate signal in the digest. If it falls (humans rejecting bolder findings),
  retune the value bar rather than reverting to smallness.
