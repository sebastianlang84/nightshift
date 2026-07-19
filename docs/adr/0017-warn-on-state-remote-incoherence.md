# ADR 0017 — abort when a non-canonical ledger pushes to a network remote

- Status: accepted
- Date: 2026-07-19
- Supersedes the initial warning-only draft of this ADR (Fable adversarial review, 2026-07-19).

## Context

`finalize()` pushes a `nightshift/*` branch to origin, then records a `shipped` row in the ledger
at `$STATE_DIR` (default `$NIGHTSHIFT_HOME/state`). `harvest.sh` later reconciles those `shipped`
rows against git reality to derive `merged`/`dropped`/`open` verdicts — the only ground-truth
signal in the system.

The state dir is overridable via `NIGHTSHIFT_STATE_DIR`, intended for isolated e2e runs, which
point BOTH the ledger AND the remote at a throwaway sandbox (`bin/setup-sandbox.sh` builds a local
**bare** remote — a filesystem path, not a network host).

The failure mode: a run whose ledger is **not** the canonical `$NIGHTSHIFT_HOME/state` while origin
still points at the **real** forge (`git@github.com:…`). The branch lands on the real origin; the
`shipped` row lands in the isolated ledger and is discarded when that dir is cleaned up. The
canonical ledger `harvest` reads never learns the branch exists. It resurfaces only via the orphan
sweep (ADR 0016).

Observed 2026-07-19: two real `nightshift/*` branches on origin with zero ledger rows on the only
checkout on the host. The host evidence (frozen ledger mtime, reflog gap, git-ignored `state/`, no
second checkout, disabled/never-journaled timer, **and** untouched default `/tmp/nightshift-worktrees`
+ `/tmp/nightshift.lock`) establishes only that the run was **fully divorced** from this environment
— a foreign `NIGHTSHIFT_HOME`, ephemeral clone, or another host. The exact vector (a set
`NIGHTSHIFT_STATE_DIR` vs. an entirely separate home) is **not** determinable and is not claimed.

This matters for the fix: a run-start guard in *this* checkout can only see runs that execute here.
The complete repair is downstream — orphan **adoption** in harvest (ADR 0018), which acts on what is
really on origin regardless of where the run happened. This ADR is the cheap run-start half.

## Decision

Add a once-per-run preflight, `guard_state_remote_incoherence`, called from `main()` after
`load_rulebook`. It **aborts the run** (exit 1) when **both** hold:

1. `NIGHTSHIFT_STATE_DIR` is set and its resolved path is **not** the canonical
   `$NIGHTSHIFT_HOME/state` (a `realpath -m` comparison — a non-canonical ledger, not merely one
   "outside `NIGHTSHIFT_HOME`"; `$NIGHTSHIFT_HOME/sandbox/state` is non-canonical and would drop rows
   identically), and
2. at least one configured repo's `origin` is a **network** remote. Classification follows git's own
   rule — a scheme (`scheme://host`) or a colon before the first slash (`host:path`, including
   ssh-config aliases with no `user@`) is network; a bare filesystem path or `file://` is local.

**Hard stop, with an explicit `NIGHTSHIFT_ALLOW_SPLIT_STATE=1` override** (which downgrades to a
loud warning). Rationale (revised after the Fable review): a legitimate isolated e2e run pushes to a
local bare remote, so condition 2 is false and it never trips — the abort has ~zero legitimate-blocking
cost. The earlier warning-only design emitted onto the stderr of precisely the run whose output is
ephemeral and unread (the observed incident had the timer disabled and no journal), so the warning
would land in the void it was meant to illuminate. A false block is recoverable in seconds via the
override; a missed drop is permanently-lost ground truth.

## Consequences

- The dangerous mix (non-canonical ledger + real forge) cannot run silently from this checkout.
- No behavior change for production runs (default canonical ledger) or sandbox e2e runs (local bare
  remote). Deliberately-split deployments set `NIGHTSHIFT_ALLOW_SPLIT_STATE=1` once.
- The guard is blind to runs that execute in a foreign environment; ADR 0018 (adoption) is the
  backstop that covers those. See `docs/design/risk-analysis.md` R14.
