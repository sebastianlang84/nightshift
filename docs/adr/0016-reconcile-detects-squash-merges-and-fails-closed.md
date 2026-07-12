# ADR 0016 — reconcile detects non-ancestor merges and fails closed on probe error

- Status: accepted
- Date: 2026-07-13

## Context

`bin/harvest.sh` `reconcile()` derives a branch's verdict from git reality. Until now it
recognised a merge only via `git merge-base --is-ancestor <sha> <base>` — true only for
merge-commit and fast-forward merges, where the branch's recorded sha literally becomes an
ancestor of base.

GitHub's default for these repos is **squash merge** (also rebase merge). Both replay the
branch's change as a *new* commit on base; the recorded sha never becomes an ancestor. GitHub
then auto-deletes the merged branch, so `ls-remote` is empty and reconcile derives `dropped`.
Worse, ADR 0007's self-heal exception ("an objective merge always wins") is gated on the same
`sha contained in base` test, which a squash merge never satisfies — so the false `dropped` is
**permanent**: no later run can flip it back to `merged`.

This is live corruption, not a hypothetical. On 2026-07-13 three shipped branches carried a
machine `dropped` verdict while their PRs were in fact merged:

| ledger verdict | GitHub reality |
|---|---|
| valuelens PR #1 → `dropped` | MERGED 2026-07-10 (squash) |
| market-digest PR #2 → `dropped` | MERGED 2026-07-10 (squash) |
| market-digest PR #3 → `dropped` | MERGED 2026-07-11 (squash) |

`digests/2026-07-13.md` therefore reported "Merge-rate by proof: verified … rate 0%" when the
true verified rate was 3/4. The merge-rate scoreboard (by dimension / verifiability / proof /
type) is the single ground-truth signal the tuning loop (ADR 0010 Phase 4) runs on, and it was
inverted. ADR 0014 suppression also treated these fingerprints as terminally cleared via a
false verdict value.

A second, related defect: reconcile could not distinguish "branch deleted from origin" from
"the probe failed". `ls-remote`/fetch errors (network down, auth failure, a moved/removed repo
path) produce empty output, which reconcile read as "ref gone" → `dropped`. One offline nightly
run could stamp every open branch `dropped` fleet-wide. The prefetch already swallowed fetch
failures (`|| true`) and reconciled against a stale view. This fails *open* — the opposite of
the fail-closed contract `load_rulebook` already honours for a broken rulebook.

## Decision

Reconcile derives a verdict from an authoritative **ladder**, and **never writes a terminal
verdict from an errored or blind probe** (fail closed).

For a shipped branch with a recorded sha, evaluate in order:

1. **sha is an ancestor of base** (`merge-base --is-ancestor`) → `merged`. Unchanged; the
   cheapest definitive local test, covers merge-commit / fast-forward.
2. **the branch's patch is present in base** (`git cherry <base> <sha>` prints `- <sha>`) →
   `merged`. Patch-id equivalence catches squash and rebase merges. nightshift ships exactly
   one commit per branch (ADR 0011), so the squashed commit on base is patch-equal to the
   branch tip — this is objective (the change demonstrably landed), not a guess.
3. **`pr_url` is set and `gh` is available** → `gh pr view <url> --json state,mergedAt` is
   authoritative: `MERGED`→`merged`, `CLOSED`→`dropped`, `OPEN`→`open`. Covers branches whose
   sha object was garbage-collected locally after deletion, where the local patch test cannot run.
4. **ref still on origin** → `open`.
5. **ref gone, none of the above** → `dropped`.

Fail-closed guards, applied before deriving anything:
- If the repo path is missing or its prefetch `fetch` failed, **skip** every branch in that
  repo (leave its last verdict untouched) — do not reconcile against a stale/absent view.
- Capture each probe's exit status separately from its output; an errored `ls-remote` or
  `cherry` is "unknown", never "deleted"/"unmerged".
- If the sha object is not present locally (`git cat-file -e <sha>^{commit}` fails) and no PR
  evidence resolves it, skip rather than derive `dropped`.

ADR 0007's "objective merge always wins" self-heal is **extended**: patch-equivalence (rung 2)
and an authoritative `gh` MERGED (rung 3) both count as objective merges and may supersede a
held or previously-recorded false verdict, exactly as `sha-in-base` does. This is what lets the
three false `dropped` rows above heal to `merged` on the next harvest.

## Consequences

- The three false `dropped` verdicts self-heal to `merged` on the next reconcile; the merge-rate
  scoreboard becomes trustworthy without hand-editing the append-only ledger.
- `gh` is an *optional* enhancement, not a dependency: rung 2 (`git cherry`) detects the fleet's
  squash merges with no network and no `gh`. Rung 3 only adds coverage for the gc'd-object edge
  case and is skipped gracefully when `gh` is absent or unauthenticated.
- A transient outage no longer writes false terminal verdicts: an unreachable repo or failed
  fetch is skipped, and harvest reports it rather than silently mislabelling.
- Schema is unchanged (still version 2); the ladder only changes how the existing
  `merged|open|dropped` value is derived. Manual `resolved`/`wontfix` holds (ADR 0007) are
  unaffected — only a machine-owned or false verdict is superseded by an objective merge.
- Cost: reconcile now runs up to one `git cherry` per unmerged branch and, for branches with a
  `pr_url` that the local tests leave unresolved, one `gh` call. Both are bounded by the
  open-branch cap and only fire when the cheap ancestor test misses.
