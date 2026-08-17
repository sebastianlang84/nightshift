# ADR 0022 — a repo's own tests gate the ship

- Status: accepted; **§4 superseded by [ADR 0026](0026-the-ship-gate-runs-in-a-sandbox.md)**, which
  also confines the gate described in §1 to a sandbox
- Date: 2026-08-04
- Extends: [ADR 0011](0011-multi-finding-explore-one-branch-per-finding.md) (the per-finding branch this gate terminates)

## Context

The Fix↔Review loop proves one thing: that **the finding** is fixed. `prompts/review.md` asks the
reviewer to run *the finding's verification recipe* — a targeted proof about a targeted claim. That
is the right question for the claim and the wrong question for the repository: a change that fixes
its finding perfectly can still break something the reviewer never looked at.

Nothing downstream caught that. `finalize()` gated on the host repo's commit hooks
(`commit-failed`) and on the push (`push-failed`), so a branch could only be blocked by a repo that
happened to run a hook. Regressions were caught by CI, and CI existed in **one of four** fleet
repos:

| repo | CI |
|---|---|
| macrolens | `.github/workflows/ci.yml` |
| nightshift | — |
| market-digest | — |
| valuelens | — |

The failure is not hypothetical. On 2026-08-04 nightshift shipped
[market-digest#10](https://github.com/sebastianlang84/market-digest/pull/10), which removed
`fastapi` from a dev dependency group after correctly establishing that nothing under `src/`
imports it. The reviewer's recipe passed. But that repo's `services/transcript-miner/tests/test_wrapper_*.py`
import `mcp/transcript-miner/app/main.py` **across a service boundary**, and that module is a FastAPI app:
three tests broke. `main` had 160 passing tests, the branch had 157. Nothing in the pipeline
noticed, and the PR sat merge-ready with a green human summary until a human ran the suite by hand.

That is the general shape — a claim that is locally true and globally wrong — and no amount of
prompt engineering on the Review stage fixes it, because the reviewer is being asked about the
finding, not about the repo. The repo already knows how to answer: it has a test suite.

## Decision

**1. A repo may declare `test_cmd`, and it gates the ship.**

Per-repo, in the rulebook, alongside `mode`/`base`/`findings`/`dimensions`:

```yaml
repos:
  - path: /home/wasti/dev/market-digest
    mode: branch-fix
    test_cmd: cd services/transcript-miner && uv run pytest -q
```

`run_test_gate()` runs it under `bash -c` **in the worktree**, with the fix applied, **before the
branch is created** — since [ADR 0026](0026-the-ship-gate-runs-in-a-sandbox.md) inside a disposable
bubblewrap sandbox, because that `bash -c` executes code the Fix stage just wrote. Running it in the worktree and not the repo is the whole point — the worktree
is what carries the change and what is about to be committed. Running it before branch creation
means a failure costs nothing to clean up, unlike `commit-failed`, which has to delete a branch it
already made.

**2. The gate sits INSIDE the fix↔review loop. A red suite is a revision request, not a verdict.**

When the reviewer returns `ship`, the gate asks the other question — is the repo still whole? — and
it overrules a `ship`. But it does not end the item. Discarding the whole change on the first red
suite would throw away a fix that is *mostly right* and leave the finding unfixed, and it would
punish the one actor best placed to repair the damage: the Fix stage caused the regression, is
still in the loop, and has iterations left.

So a failed gate loops back. `stage_prompt` hands the Fix stage the last 100 lines of the failing
output with an explicit instruction that this is its own regression to repair, that reverting to
green is not a solution, and that a genuinely wrong test must be corrected deliberately and named
in the worknote. `run_test_gate` deletes `tests.log` the moment the suite is green, so the file's
*presence* is the signal — a stale log can never ask the Fix stage to repair something already
repaired.

Only an item that leaves the loop still broken is refused.

**3. A refusal is recorded, not swallowed.**

The ledger gets an outcome row `tests-failed`, in the same family as `commit-failed` and
`push-failed`: recorded with the finding's summary and identity, with `branch` and `sha` null
because neither ever existed. It is distinct from `abandoned` on purpose — the reviewer *wanted* to
ship and the suite said no, every time, which is a different signal from a fix the reviewer gave up
on. The digest lists both under "Considered but not shipped".

Crucially the finding is **not** latched as an open finding. `tests-failed` is a fact about one
night's attempts, not a verdict about the defect — a later night may find the same thing and fix it
properly.

**4. Absent `test_cmd` means ungated, and the run says so.** — *superseded by
[ADR 0026](0026-the-ship-gate-runs-in-a-sandbox.md) §5: a `branch-fix` repo without a `test_cmd` now
aborts the parse. The reasoning below still holds for the half that survives — there is no
fleet-wide default and none is invented — but "ships exactly as before" turned out to be the last
silent path to a merge-ready branch with no regression check, and a log line at 04:00 is not a gate.
A repo with no suite belongs in `findings-only`.*

There is no fleet-wide default test command. A test command is repo-specific by nature; inheriting
one would run the wrong suite, and inventing one (guessing `pytest`, `npm test`) would produce
confident nonsense. A repo without the key ships exactly as it did before, and the run logs
`shipping UNGATED` — so the gap is visible in the night's log rather than silently assumed away.

**5. The gate always runs under a timeout.**

`limits.test_timeout_seconds` (default 600, env override `NIGHTSHIFT_TEST_TIMEOUT`) bounds a single
`test_cmd`. A suite that hangs — waiting on a port, a prompt, a network call — must not consume the
night. A timeout is a failure: `timeout` exits 124, the run logs `test gate TIMED OUT`, and the item
takes the `tests-failed` path like any other failure.

**Amended by [ADR 0027](0027-the-reviewed-tree-is-what-ships.md).** The gate still runs here, in
the loop, and a red suite is still a revision request. What changed is that the gate no longer
contributes *content*: `finalize` commits the tree object review was shown, so anything the suite
writes to the worktree is discarded rather than staged.

## Consequences

**A green nightshift branch now means two things instead of one:** the finding is fixed *and* the
repo's own suite still passes. That is the claim a reviewer actually wants when deciding to merge.

**The gate is only as good as the declared command.** `test_cmd: true` gates nothing while looking
gated, and a suite that is already red on `main` blocks every ship in that repo until it is green.
Both are host decisions the rulebook makes explicit rather than problems nightshift can solve — the
rulebook is host-owned, and the log names the outcome either way.

**It costs one suite run per shipped finding**, and up to `max_fix_iterations` runs for one that
keeps breaking — all inside the night's wall-clock budget (ADR 0013). Keep `test_cmd` fast; it is a
regression gate, not a release pipeline. A repo whose suite takes twenty minutes should declare a
fast subset, not the whole thing.

**A repo can be gated without having CI**, which is the case that motivated this: three of four
fleet repos have no CI at all, and now three of four can still gate.

## Alternatives considered

**Refuse on the first red suite instead of looping back.** This is what the gate did for its first
few hours, and it was wrong: a fix that breaks one test is usually a fix that is nearly right, and
throwing it away costs the whole night's work on that finding *and* leaves the defect unfixed. It
also aims the consequence at the wrong actor — the Fix stage caused the regression and is the only
thing in the loop that can undo it. Retrying costs at most `max_fix_iterations` suite runs, which
is bounded and cheap next to re-finding the same defect on a later night.

**Ship anyway and only warn in the digest.** Rejected. The digest is read in the morning; the branch
is open all night with a PR attached and a summary that reads as verified. A warning that arrives
after the artifact has been presented as trustworthy is not a gate.

**Require CI on every repo instead.** A better world, and not one nightshift can legislate. It
already runs on the host machine with the repo checked out — asking a repo to name its own test
command is a far smaller thing to ask than asking it to adopt a CI provider.

**Detect the test command automatically** (find `pytest.ini`, `package.json` scripts, a `Makefile`).
Rejected on the same ground as the fleet-wide default: a wrong guess produces a *passing* gate on
the wrong suite, which is worse than no gate, because it reads as proof.
