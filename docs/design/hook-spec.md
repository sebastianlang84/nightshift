# Design note — The git-confinement hook (§2a)

- Status: **accepted (v1), 2026-07-08.** The single safety mechanism that makes "branch-only" a
  guarantee instead of a prompt promise. Resolves re-review §2a
  ([`fable-rereview-2026-07-08.md`](fable-rereview-2026-07-08.md)).

## What it must guarantee

nightshift can only ever create or update its own `nightshift/*` branches. It can **never** push to
`main`/`develop`/any other ref, **never** delete a ref, **never** push a tag, and therefore **never**
merge (a merge would require pushing `main`). This is enforced mechanically, not by the system prompt.

## Why not parse the command

`git push` has many spellings for the same dangerous action — `+main` (force), `:branch` (delete),
`HEAD:main`, `--all`, `--mirror`, config-driven pushes. Matching the *command text* against bad
patterns is leaky: a spelling we didn't anticipate slips through. So we do not inspect the typed
command. We let git resolve what the command *actually does*, then check the resolved result.

## Two layers

### Layer 1 — git `pre-push` hook (does the real work)

A `pre-push` hook receives, on stdin, the **already-resolved** refs git is about to send:
`<local ref> <local sha> <remote ref> <remote sha>`, one line per ref, *after* git has processed
config, `HEAD`, refspecs, and the `+`/`:` syntaxes. The rule is then trivial and airtight — for every
line:

- `<remote ref>` must match `refs/heads/<branch_prefix>*` (default `refs/heads/nightshift/*`) → else **reject**
- `<local sha>` all-zeros (a delete) → **reject**
- `<remote ref>` under `refs/tags/*` → **reject** (no releases)

Because git resolves everything first, this catches every bypass at once: `+main` presents
`refs/heads/main` → reject; `:branch` presents a delete → reject; `--all`/`--mirror` present
main/develop → reject.

**Installation:** the Fix stage provisions the worktree and points `core.hooksPath` at a
nightshift-owned hooks directory, so the `pre-push` hook is guaranteed present (it is not part of a
normal clone).

### Layer 2 — Claude Code `PreToolUse` hook (thin anti-bypass only)

Layer 1's one loophole: `git push --no-verify` skips `pre-push` hooks. So the PreToolUse hook does
*one simple thing* — deny any Bash command that would disable or relocate the hook. Plain string
checks, no ref parsing:

- deny if the command contains `--no-verify`
- deny if it sets `core.hooksPath` (e.g. `-c core.hooksPath=…` or `git config … core.hooksPath`)
- deny other `-c`/config overrides that turn hooks off

The hard work (which ref) is git's job via Layer 1; this layer only stops the agent from switching
Layer 1 off.

## Out of scope (handled elsewhere)

Non-git shell that is also irreversible — `gh`, `curl`, `npm publish`, `rm -rf` outside the worktree
— is **not** covered here. That is re-review §2b (shell/worktree isolation), a separate decision. §2a
confines git only.
