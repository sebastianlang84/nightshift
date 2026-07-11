# ADR 0008 — repo selection is fairness-first (least-recently-serviced), not commit-recency

- Status: accepted
- Date: 2026-07-11

## Context

`select_order()` decides the order in which repos are explored each pass. It sorted by the
repo's most-recent **human commit** timestamp, descending — "work the hottest code first."

That key is self-reinforcing toward one repo: nightshift's own repo. nightshift commits to
itself nightly (it ships `nightshift/*` branches; the human merges them each morning), so it
almost always carries the freshest commit and sorted **first every night**. Ordering only
matters at the throughput boundary — the inner loop explores repos in order and `break`s the
moment the open-branch cap is hit (ADR 0004/0005), skipping the rest of that pass. So the
repos that sort last (pi-authenticator, partflow) are the ones systematically starved when
the cap bites. Observed on the 2026-07-11 run: nightshift got 2 shipped branches while each
other branch-fix repo got 1 — the head-of-list repo compounding its own lead.

The operator's intent is the opposite: nightshift should preferentially work repos it has
attended to **least**, so coverage rotates across the fleet.

## Decision

Order repos by **when nightshift last serviced them, ascending** — the longest-neglected repo
first. Human commit-recency is demoted to a **tiebreaker** (descending), so among equally- or
never-serviced repos the hotter code still wins.

- "Last serviced" = the timestamp of the most recent **work-item** ledger entry for the repo:
  outcome `finding`, `shipped`, or `abandoned`. Harvest `verdict` reconcile rows are excluded —
  they are bookkeeping, not attention spent, and would otherwise make a just-merged repo look
  freshly serviced and unfairly sink it. Implemented by `last_serviced_epoch()`.
- Never-serviced repo → epoch `0` → sorts first (cold-start priority).
- Cold start (empty ledger): every repo ties at `0`, so night one orders purely by
  commit-recency — identical to the prior behavior.

After nightshift ships or records a finding for a repo, that repo's last-serviced time becomes
the newest, so it sinks to the bottom of the next pass and the previously-neglected repos rise.
The order self-balances instead of fixating.

## Consequences

- The self-bias is gone: the most-active repo (nightshift) now sorts **last** once it has been
  serviced, and the tail repos get first crack at the cap's free slots.
- Verified against the live ledger at decision time: order flipped from
  `nightshift → …` to `pi-authenticator → partflow → llmstack → nightshift`.
- "Review hottest code first" survives only as a tiebreaker, not the primary policy. This is a
  deliberate trade of recency-relevance for fleet coverage; the operator asked for coverage.
- Signal gap (accepted): an explore that finds **nothing** writes no ledger row, so a repo that
  keeps yielding no findings does not advance its last-serviced time and keeps sorting first —
  it re-consumes the first explore slot each pass until it finally produces something. Bounded
  in practice (every repo is explored once per pass regardless of order; a no-finding explore is
  cheap) and arguably correct (a never-productive repo should keep getting first look). If it
  ever bites, the fix is to persist a `last_explored` marker rather than derive from the ledger.
- `select_order()` now runs one small `jq` slurp of the ledger per repo per pass (via
  `last_serviced_epoch`). The ledger is a short append-only file; cost is negligible.
- Does not touch the shallow "one-finding-per-repo, first-found-wins" exploration behavior —
  that is a separate concern (exploration depth), tracked for its own change.
