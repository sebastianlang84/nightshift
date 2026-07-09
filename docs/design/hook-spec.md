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

## Implementation (prototype) — how the layers are actually activated

- **Layer 1 for the Runner's own push:** `finalize` pushes with `git -c core.hooksPath="$HOOKS_DIR"`.
- **Layer 1 for the *agent*:** when launching `claude -p`, the Runner injects the hook via
  environment — `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$HOOKS_DIR`
  — so *every* git the agent runs is confined. **Neither path writes to any repo's config**, so the
  user's own pushes stay unconstrained. Verified: an agent-context `push origin HEAD:main` is
  rejected, `nightshift/*` is allowed, and `.git/config` is untouched.
- **Layer 2:** the Runner writes `state/claude-settings.json` registering `pretooluse-guard.sh` as a
  `PreToolUse` hook and passes it via `--settings`. The guard denies `--no-verify`, `core.hooksPath`
  overrides, **and** any `GIT_CONFIG_*` env manipulation (`GIT_CONFIG_COUNT`/`KEY`/`VALUE`/`GLOBAL`/
  `SYSTEM`) — otherwise an agent could disable Layer 1 by overriding the very env that injects it
  (e.g. `GIT_CONFIG_COUNT=0 git push …`) without ever naming `core.hooksPath`. Benign commands pass.

**Known residual (v1):** the sandbox uses `--dangerously-skip-permissions`, and whether a PreToolUse
hook fires under that mode is not yet verified in-session. Layer 1 (git-level) holds regardless. For
real repos, two backstops close the residual: (a) enable **GitHub branch protection** on `main`
(block direct/force push + deletion) — a server-side guarantee you own; (b) move real-repo runs off
`--dangerously-skip-permissions` to a hook-respecting permission mode. Tracked as hardening.

## Out of scope (handled elsewhere)

Non-git shell that is also irreversible — `gh`, `curl`, `npm publish`, `rm -rf` outside the worktree
— is **not** covered here. That is re-review §2b (shell/worktree isolation), a separate decision. §2a
confines git only.
