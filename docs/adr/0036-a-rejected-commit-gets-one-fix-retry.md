# ADR 0036 — a rejected commit gets one Fix retry

- Status: accepted
- Date: 2026-09-25
- Extends: [ADR 0024](0024-the-commit-subject-declares-the-change-type.md) (the Fix stage is told the gates in advance; this handles the case where it did not listen)
- Touches: [ADR 0022](0022-a-repos-own-tests-gate-the-ship.md) (the fix↔review↔gate loop the retry reuses) · [ADR 0027](0027-the-reviewed-tree-is-what-ships.md) (the retry's tree is reviewed again before it can ship)

## Context

nightshift commits with the host repository's own hooks active, so it never manufactures a commit
its host would reject. The Fix stage cannot commit and never sees a hook fire. ADR 0024 therefore
names every detected gate in the Fix prompt, together with the exact subject line the runner will
use. A rejection still ended the item on the spot: finalize recorded `commit-failed` and the whole
change was discarded, after a full explore→fix→review→gate cycle had been paid for.

The prompt warning is not enough on its own. The model sometimes reads the gate section and still
leaves the tree without the companion edit the hook demands — most often a CHANGELOG entry for a
`fix:`-typed change. Counted from the ledger on 2026-09-25: 7 `commit-failed` rows against 136
`shipped`. Four predate ADR 0024 and were caused by the unparseable subject it fixed. The three
since then are all `bug` findings, committed as `fix:`, and none of their worknotes mentions a
CHANGELOG. What the hook said about them is not on record: its output went only to the night's log.

The discarded work is the most expensive kind nightshift produces. The reviewer had already accepted
the fix and the repo's suite had already passed it. The only thing missing was usually one file the
hook names in its refusal, and that refusal went to the night's log, where no stage could read it.

## Decision

**A commit the repo's own hooks reject reruns the Fix stage once, in the same worktree, with the
hook's output in the prompt. The revision then goes through the normal loop again — Review, the
test gate, then one more commit attempt.**

- **Captured, not guessed.** finalize captures the commit's stdout and stderr into
  `commit-rejected.log` in the item directory, and still copies it to the night's log. The Fix
  prompt shows its last 100 lines, capped at 6000 bytes, under its own heading, and says so when the
  hook printed nothing. Any failed commit with a staged change takes this path; in practice that is
  a hook, and the prompt says the output may instead show git itself failing.
- **Redacted, because hooks run on the host.** The suite output ADR 0022 feeds back comes from the
  ship gate's sandbox, which has no `$HOME` and no credential reach (ADR 0026). A commit hook has
  both: it runs on the host with the operator's environment. So the hook output passes a
  best-effort filter (`redact_hook_output`: private-key blocks, secret-named `key=value` pairs,
  bearer tokens, `Authorization` header values, JWTs, common token prefixes, URL passwords) before it
  enters the prompt, and every run of three or more backticks in it is broken up (`fence_safe`) so
  the quoted output cannot close its code fence and read as prompt text. The suite output ADR 0022
  quotes gets the same fence treatment. The filter is a
  pattern list, not a guarantee. It is not the agent-note channel either, which carries model output
  and is never read back.
- **The same checks, not a shortcut.** The retry is one more Fix run, followed by the same staging,
  reviewed-tree record, Review stage and `test_cmd` gate a first attempt gets. Nothing about the
  retry lets a tree reach a commit that the reviewer and the gate have not both seen, beyond what a
  passing hook itself adds (see *Not addressed*). It does not
  loop: a `revise` verdict or a red suite on the revision ends it, where a first attempt would go
  back into Fix.
- **The same budget.** The retry spends a turn of the item's existing `max_fix_iterations` counter;
  it does not get a budget of its own. An item that shipped on its last iteration gets no retry. The
  night's time budget is checked after the rejection, since a slow hook may have spent it. Both
  refusals are logged with the reason and recorded as `commit-failed`.
- **Exactly once.** A second rejection is final. So is a retry that ends without a commit — the Fix
  or Review stage failing, the reviewer not shipping the revision, the suite refusing it, or the
  revision removing the whole change. All of these record `commit-failed`, as a rejection did
  before, because that is what the item is: a fix the host repo's gate refused. Recording the
  reverted case as `abandoned` would latch a finding whose first fix the reviewer accepted. The one
  exception is a tampered worktree, which keeps its own `worktree-tampered` outcome as a safety
  event.
- **No new outcome.** The ledger keeps the outcome values the digest and harvest already read. A
  retried item writes one row: `shipped` if the retry passed the hook, `commit-failed` if not. The
  retry is visible in the night's log (`commit retry: …` lines) and in `runs.jsonl`, which shows the
  extra fix and review runs. A new outcome would split one fact across two names in every consumer
  and buy no decision anyone makes from the ledger.
- **The runner never bypasses the gate.** No `--no-verify`, no trailer, no file written on the Fix
  stage's behalf. The revision has to satisfy the hook through the files, the way a human
  contributor would.

## Rejected alternatives

- **Let the Review stage judge the CHANGELOG requirement.** The reviewer would have to reimplement
  each host repo's gate from its prose, and its judgment would be a second opinion on a rule the
  hook already enforces. The two could disagree, and the hook would still have the last word at
  commit time. The retry asks the authority that actually decides.
- **Have the runner write a `Changelog-None` trailer (or a CHANGELOG entry) itself.** Such a
  trailer is the gate's escape hatch for a change its author has judged not user-visible. Written by
  the runner, it would be a claim nobody made. It would pass the gate on every rejection, including
  the `fix:`-typed changes whose entry the gate exists to demand. That under-claims past the gate,
  the failure ADR 0024 already refused when it chose the untyped subject as the fail-closed default.
  An entry written by the runner would say nothing true about the change either.
- **Retry until the hook accepts.** Unbounded, and a gate the model cannot satisfy — one that wants
  a human sign-off, say — would spend the item's whole iteration budget on it. One retry covers the
  observed case, a missing companion edit the hook names; a second rejection says the model cannot
  meet that gate.

## Consequences

- **Positive:** a fix that the reviewer and the suite accepted is no longer lost to a missing
  companion edit the hook names in its refusal. The model gets the refusal verbatim instead of a
  warning in advance.
- **Positive:** the revision passes the same checks a first attempt does, so "the reviewer saw what
  shipped" (ADR 0027) holds for the retry by the same construction.
- **Negative:** a rejected item costs up to one more Fix run, one more Review run and one more suite
  run. That cost is bounded by the existing iteration budget, and it falls only on the rare
  rejection — 7 in 143 finished commits so far.
- **Negative:** the Fix prompt now carries text from the host repo's hooks, which run on the host.
  It is bounded in size and filtered for credential shapes, but a secret in a shape the filter does
  not know reaches the model. A hook that executes files from the worktree already runs the Fix
  stage's code on the host before this change; feeding its output back does not create that
  exposure, but it does give it a return path into the prompt.
- **Unchanged:** a first attempt that leaves no change is still `abandoned`.
- **Not addressed:** finalize still pushes whatever a *passing* hook adds to the commit — a
  formatter that edits and stages files — without comparing the commit's tree to the reviewed one.
  That predates this decision and is independent of it.
- Regression cover: [`tests/test-finalize-commit-rejected.sh`](../../tests/test-finalize-commit-rejected.sh)
  drives a rejection that the retry satisfies (shipped, with the hook's demand in the pushed tree), a
  second rejection, no retry once the iteration budget is spent, a revision the test gate or the
  reviewer refuses, and a revision that reverts the change. The time-budget refusal has no test:
  the mock night cannot exhaust the budget between a commit and the retry. [`tests/test-fix-prompt-repo-gates.sh`](../../tests/test-fix-prompt-repo-gates.sh)
  pins the prompt text and the trimmed hook output.
