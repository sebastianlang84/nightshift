# ADR 0024 — the commit subject declares the change type

- Status: accepted
- Date: 2026-08-07
- Extends: [ADR 0004](0004-v1-scope-branch-isolated-steward.md) (the branch-isolated contract this commit lives under)
- Touches: [ADR 0022](0022-a-repos-own-tests-gate-the-ship.md) (the other host-repo gate the Fix stage has to satisfy in advance)

## Context

nightshift commits into repositories it does not own, with **those repositories' own hooks active**
— deliberately, so it never manufactures a commit its host would reject. The Fix stage cannot
commit, so it never sees a hook fire: an unmet convention surfaces only as `commit-failed` after the
model is gone, discarding the entire change. `stage_prompt` therefore names the gates it detects, so
the Fix stage can satisfy them as part of the change.

Both halves of that mechanism were incomplete against a real repo.

**The subject was unparseable.** Every commit was titled `nightshift: <summary>`. A `commit-msg`
gate of the common kind — pi-ext-auth runs git-workflow's `changelog-check.sh` — reads the
Conventional Commits type as a *checked claim* about user visibility: `feat|fix|perf` demand a
CHANGELOG entry, `refactor|test|chore|docs|ci|build|style|revert` are exempt by the same definition,
and an **unparseable subject is treated as user-visible** so that a malformed message never becomes
a bypass. `nightshift: …` carries no type at all, so it always landed in that last branch. Every
change touching a code-classified file (`.ts`, `.py`, `.sh`, `.yaml`, …) was read as user-visible and
blocked for a missing CHANGELOG entry.

The Fix stage could not fix this from where it stands: **it does not write the subject.** The
worknote of the 2026-08-07 `doc` finding shows the trap closing precisely. The model read the hooks,
reasoned correctly about them, and concluded:

> One caveat you should know: if the runner commits this under a `fix:` type rather than `docs:`,
> the `commit-msg` hook will block for a missing CHANGELOG entry. A `docs:`-typed subject passes
> cleanly.

It was then committed as `nightshift: …` — neither of the two subjects it had reasoned about, and
the one the hook refuses outright.

**The gate detection missed the hook.** `stage_prompt` probed `pre-commit` only. pi-ext-auth had
*moved* its CHANGELOG check to `commit-msg` — the only hook that can see the commit type — leaving
`pre-commit` as a SKILL.md lint. So the repo whose gate was about to reject the commit was the repo
reported as gating nothing more than a lint.

Cost, measured from the ledger: four findings discarded after a full explore→fix→review cycle each —
two `correctness` bugs on 2026-08-05 and two `docs` findings on 2026-08-07, all in pi-ext-auth. The
three successes in that repo were luck, not design: two touched only `package.json`/`package-lock.json`
(not code-classified), and one happened to write a CHANGELOG entry of its own accord. pi-ext-auth is
the only repo in the current rulebook with both a CHANGELOG and a `commit-msg` hook, so the blast
radius was one repo — but it was **total** there for any change to a code file.

## Decision

**The commit subject states the Conventional Commits type of the change, derived from the finding's
own `type` field**, and the Fix stage is told that subject verbatim.

- `commit_type` maps the finding vocabulary to the type that is true of it: `bug`/`typo` → `fix`
  (defects, user-visible by definition), `doc` → `docs`, `convention` → `chore`,
  `cleanup`/`smell`/`naming`/`complexity` → `refactor`.
- An **unrecognised** type yields no type at all, restoring the old `nightshift: ` subject. That is
  the fail-closed answer on purpose: a guessed internal type would let nightshift under-claim its way
  past a gate, and every such gate already reads an untyped subject as user-visible.
- The subject keeps a `nightshift` scope — `docs(nightshift): …` — so authorship stays visible in
  `git log --oneline`, which the old prefix carried and the committer identity does not show. A scope
  is optional in the grammar these gates parse, so it costs the type nothing.
- `stage_prompt` detects `commit-msg` alongside `pre-commit`, and prints the exact subject line the
  runner will use, with the note that the model does not write it. A hook that reads the subject is
  then judged against the line it will actually receive.

The type is a claim that must stay *true*, not merely permissive. A `bug` fix is still committed as
`fix:` and still owes a CHANGELOG entry where the repo keeps one — the Fix stage is already
instructed to write that companion edit, and has done so successfully.

## Consequences

- Changes classified as internal (`doc`, `convention`, `cleanup`, `smell`, `naming`, `complexity`)
  now pass a type-reading CHANGELOG gate without an entry, which is what the gate intends.
- Changes classified as defects still face the entry requirement. That is not a regression: it is the
  host repo's rule, correctly applied, and the Fix stage can satisfy it.
- The mapping is a **fixed vocabulary**, tied to `prompts/explore.md`'s `type` enum. A new finding
  type added there without an arm here degrades to the untyped subject — safe, but it forfeits the
  benefit. `commit_type` is the single place to extend.
- Repos with no message gate are unaffected in behaviour; their history simply gains a type.
- Nothing parses the subject inside nightshift — harvest keys on the `nightshift/*` branch name and
  the ledger, not on the commit message — so the change is confined to what the host repo sees.
- Regression coverage: [`tests/test-commit-subject-type.sh`](../../tests/test-commit-subject-type.sh)
  pins every arm of the mapping including the untyped fallback, asserts the Fix prompt names the
  subject verbatim and detects a `commit-msg`-only repo, and drives a full night against a host repo
  whose `commit-msg` hook refuses an untyped subject.
