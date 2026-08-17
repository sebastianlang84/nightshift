# ADR 0027 — the reviewed tree is what ships

- Status: accepted
- Date: 2026-08-17
- Amends: [ADR 0022](0022-a-repos-own-tests-gate-the-ship.md) — the gate still runs inside the
  fix↔review loop, but it no longer contributes content to the commit
- Follows: [ADR 0026](0026-the-ship-gate-runs-in-a-sandbox.md), which confined the gate's *process*;
  this confines what the gate's *output* can reach

## Context

ADR 0026 put the ship gate in a sandbox with no credentials. A cross-vendor review of that work
pointed out that confining the gate while it runs is only half the question, because the gate is not
the last thing to touch the worktree:

1. Review is shown `git diff --staged` and approves it (N3, R9).
2. The gate runs the repo's own suite over that same worktree, and the suite can write to it — the
   worktree is the one thing ADR 0026 deliberately leaves writable, since the suite has to build.
3. `finalize` then ran `git add -A` and committed **whatever the worktree held at that moment**.

So every file the suite touched between (1) and (3) shipped without a reviewer ever seeing it. The
sharp case is not a stray build artifact. It is `.github/workflows/ci.yml`: a suite that rewrites
the workflow and exits 0 gets that workflow committed and pushed, and GitHub executes it — with the
repository's secrets, as a same-repo push/PR rather than the restricted fork case — **before** a
human opens the pull request.

That matters because "a human reviews before merge" (C5) is the backstop the whole branch-only
design rests on. Here the remote automation runs first, so the backstop is behind the exposure. The
ADR 0026 residual list said this risk was "bounded by human review of the branch before merge". That
was wrong, and this ADR is the correction.

The same hole also swallows honest work quietly: nothing distinguished "the suite refreshed a
lockfile" from "the suite rewrote a workflow" — both simply appeared in the commit.

## Decision

**The tree object the reviewer was shown is the tree that gets committed.**

- When the Runner stages the worktree for review (`git add -A`), it records `git write-tree` to
  `<item>/reviewed-tree`. That object is the reviewer's evidence, frozen.
- `finalize` no longer runs `git add -A`. It restores the worktree and index to the recorded tree
  (`git read-tree --reset -u`) and commits the index as it stands. Nothing the suite created can
  enter it, because nothing is added.
- The restore happens *before* the commit, so the target repo's own hooks still run and still see
  exactly what the reviewer approved — ADR 0022's reason for letting those hooks run is unchanged.
- Recording happens in the fix↔review loop, not in `stage_prompt`, because the mock adapter never
  builds a prompt and would otherwise skip it.
- **Missing recording means no commit.** `finalize` refuses rather than falling back to `add -A` —
  that fallback is precisely the behaviour being removed, and a silent revert to it would look
  identical to a healthy night.
- **Discarding is announced.** When the worktree diverges from the reviewed tree, the run logs that
  the gate's changes are being dropped. Compared against the reviewed tree, not against `HEAD`:
  `status --porcelain` reports the staged fix itself, so an honest night would otherwise claim the
  gate had meddled every time.

Each iteration of the loop re-records, so the tree that ships is the one the *last* review approved.

## Consequences

**"The reviewer saw what shipped" stops being a timing property and becomes a structural one.** It
previously held only as long as nothing wrote to the worktree between review and commit — and the
gate, by design, does exactly that.

**A suite that legitimately modifies tracked files no longer has those modifications shipped.** The
real case is a lockfile refreshed by a test run. That change is now dropped and logged. This is a
genuine cost, and it is the right trade: a lockfile edit nobody reviewed is still a lockfile edit
nobody reviewed. Getting it into a branch needs another fix↔review pass, which is the mechanism the
project already has for "a change a human should look at".

**The gate keeps its full write access to the worktree**, so nothing about how suites build changes.
It just no longer has a path from that write access into a commit.

**`finalize` is now index-based.** Anyone adding a step there must not reintroduce `add -A`; the
regression test asserts the pushed workflow is the reviewed one and fails immediately if they do.

## Residual risk

- **The gate can still make the worktree unusable** — deleting files, exhausting the disk — which
  costs the item, not the review property. Bounded by ADR 0026's rlimits.
- **The reviewed tree is only as good as the review.** This ADR guarantees that what shipped is what
  was shown; it does not guarantee anyone read it adversarially. That is R5, unchanged.
- **`.gitignore` still decides what `add -A` captured in the first place**, so a fix-created file
  the repo ignores is absent from both the review and the commit — consistent, and unchanged
  from N3.

## Alternatives considered

**Run the suite on a separate disposable checkout of the reviewed tree.** Strictly the cleanest: the
candidate worktree is never exposed to the suite at all, so there is nothing to discard afterwards.
Rejected for now on cost and blast radius — it needs a second checkout per gate iteration (a real
copy for a large repo, several times per finding), and a synthetic commit for `git worktree add` to
detach from. The property this ADR needs is obtained without it, because the commit is built from a
recorded object rather than from the directory. Worth revisiting if the worktree ever stops being
the only thing the gate may write.

**Compare the committed path set against the finding's declared files and refuse on any extra**
(N3's unimplemented stronger half). Narrower and noisier: it turns a legitimate multi-file fix into
a refusal, and it still permits the gate to *modify* a declared file. It answers "did the change
stay in scope", which is a different and weaker question than "is this the reviewed content".

**Let the gate's changes ship but flag them in the digest.** Rejected for the same reason ADR 0022
rejected it for a red suite: the digest is read in the morning, the branch is open all night with a
PR attached, and on GitHub the workflow has already run. A warning that arrives after the artifact
has been presented as trustworthy is not a gate.

**Commit the tree directly with `git commit-tree`.** Sidesteps the worktree entirely and is the
smallest possible change — but it bypasses the target repo's hooks, which ADR 0022 deliberately
lets run so nightshift cannot manufacture a commit the host repo would reject. `read-tree --reset -u`
keeps both properties.
