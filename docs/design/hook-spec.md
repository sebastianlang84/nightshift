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

### Layer 2 — Claude Code `PreToolUse` hook (anti-bypass + write confinement)

The `PreToolUse` guard does two things, dispatched on the tool call it receives:

**(a) Bash — anti-bypass.** Layer 1's one loophole: `git push --no-verify` skips `pre-push` hooks. So
the guard denies any Bash command that would disable or relocate the hook. Plain string checks, no ref
parsing:

- deny if the command contains `--no-verify`
- deny if it sets `core.hooksPath` (e.g. `-c core.hooksPath=…` or `git config … core.hooksPath`)
- deny other `-c`/config or `GIT_CONFIG_*` overrides that turn hooks off

The hard work (which ref) is git's job via Layer 1; this part only stops the agent switching it off.

**(b) Write/Edit — worktree confinement (R8).** The Fix stage grants `Write`/`Edit` but no `Bash`, and
those tools accept **absolute paths** — so without a check the agent could edit the runner, hooks,
`~/.claude`, systemd units, or another repo with no shell at all. The guard reads the target
(`.tool_input.file_path` / `.notebook_path`), normalises it with `realpath -m` (resolving `..` and
symlinks in existing prefixes), and denies anything not equal to or strictly beneath the worktree
root. The root is the Runner-injected `NIGHTSHIFT_WORKTREE` (primary), else the payload `.cwd`, else
`$PWD`. Containment is trailing-slash-safe (a prefix-sibling like `…/worktree-evil` is *not* inside).

**Matcher.** The guard is registered for `Bash|Write|Edit|MultiEdit|NotebookEdit` — a `matcher:"Bash"`
alone would never fire on a `Write`, leaving (b) dead.

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

**Residual — now verified (2026-07-09):** the sandbox uses `--dangerously-skip-permissions`, and the
open question was whether a PreToolUse hook fires under that mode. **It does** — an adversarial test
registered the guard exactly as the Runner does, launched `claude 2.1.197` with the production env +
flags, and had it attempt a `--no-verify` push; the guard denied it verbatim (`nightshift: git
--no-verify would bypass the pre-push confinement hook`) while a control command ran. So Layer 1 + 2
both hold in unattended mode. Optional defense-in-depth remains: **GitHub branch protection** on `main`
(with `enforce_admins`, else the agent's own admin creds bypass it) as a server-side backstop.

## Out of scope for §2a — narrowed by capability profiles

§2a confines **git** only. Non-git irreversible shell — `gh`, `curl`, `npm publish`, `rm -rf` outside
the worktree — is re-review §2b (shell/worktree isolation). But the per-stage **capability profiles**
(`claude_run`, ADR-tracked) now narrow it mechanically: explore/review run with `--tools
"Read,Grep,Glob"` (no Bash at all) and fix with `Read,Grep,Glob,Write,Edit` (Write/Edit but **no
Bash**). With no Bash tool in any stage, the agent cannot invoke `rm`/`curl`/`gh`/`git` regardless of
prompt — the same "capability, not convention" principle as the hook. Verified: a claude run granted
only read tools could not create a file even under `--dangerously-skip-permissions`. The one residual
write primitive — Fix's `Write`/`Edit` reaching absolute paths outside the worktree — is now closed by
Layer 2(b) above. Full OS-level sandboxing (read-only FS / no network) stays the strongest tier if
ever needed.

**Verified end-to-end (2026-07-12).** Beyond the deterministic unit tests
(`tests/test-fix-write-confinement.sh`), a live adversarial run confirmed the integration path: real
`claude` (2.1.205) launched exactly as the Runner does — Fix tool set, the guard registered with the
production matcher, `NIGHTSHIFT_WORKTREE` injected — was told to write two files, one inside the
worktree and one just outside. The inside write succeeded; the outside write was denied by the guard,
which emitted `nightshift: Write/Edit outside the worktree is not allowed (resolved: …)` and left no
file. This proves the matcher fires on a `Write` and that `NIGHTSHIFT_WORKTREE` reaches the hook
process (mirrors the Layer 2(a) verification of 2026-07-09).
