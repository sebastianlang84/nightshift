# Design note — The git-confinement hook (§2a)

- Status: **accepted (v1), 2026-07-08.** The single safety mechanism that makes "branch-only" a
  guarantee instead of a prompt promise.

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
- non-zero `<remote sha>` is not an ancestor of `<local sha>` → **reject** (no force update)

Because git resolves everything first, this catches every bypass at once: `+main` presents
`refs/heads/main` → reject; `:branch` presents a delete → reject; `--all`/`--mirror` present
main/develop → reject. A forced rewrite inside the allowed namespace still presents its old and new
object ids; the ancestry check rejects it.

**Installation:** the Fix stage provisions the worktree and points `core.hooksPath` at a
nightshift-owned hooks directory, so the `pre-push` hook is guaranteed present (it is not part of a
normal clone).

### Layer 2 — Claude Code `PreToolUse` hook (anti-bypass + write confinement)

The `PreToolUse` guard does two things, dispatched on the tool call it receives:

**(a) Bash — anti-bypass.** Layer 1's one loophole: `git push --no-verify` skips `pre-push` hooks. So
the guard denies any Bash command that would disable, relocate, or *widen* the hook. Plain string
checks, no ref parsing:

- deny if the command contains `--no-verify`
- deny if it sets `core.hooksPath` (e.g. `-c core.hooksPath=…` or `git config … core.hooksPath`)
- deny other `-c`/config or `GIT_CONFIG_*` overrides that turn hooks off
- deny if it sets `NIGHTSHIFT_BRANCH_PREFIX` — the env Layer 1 reads to build its allowed namespace

The hard work (which ref) is git's job via Layer 1; this part only stops the agent switching it off or
redefining what it permits.

**(b) Write/Edit — worktree confinement (R8).** The Fix stage grants `Write`/`Edit` but no `Bash`, and
those tools accept **absolute paths** — so without a check the agent could edit the runner, hooks,
`~/.claude`, systemd units, or another repo with no shell at all. The guard reads the target
(`.tool_input.file_path` / `.notebook_path`), normalises it with `realpath -m` (resolving `..` and
symlinks in existing prefixes), and denies anything not equal to or strictly beneath the worktree
root. The root is the Runner-injected `NIGHTSHIFT_WORKTREE` (primary), else the payload `.cwd`, else
`$PWD`. Containment is trailing-slash-safe (a prefix-sibling like `…/worktree-evil` is *not* inside).
The exceptions inside the root are `.claude/settings.json`, `.claude/settings.local.json`, and
`.mcp.json`. These paths can supply startup configuration, so Fix may not create or edit them.
A repository that intentionally changes those files needs human handling.

Codex Fix can write files that a later Claude stage would load. The Runner therefore checks
Claude control files after every Fix and before branch advice. Right after Fix, `worktree_control_files_clean` in
`bin/nightshift.sh` checks the worktree at the `.git`-pointer check. A worktree in which any of the
three files — or `.claude` itself, which a symlink could replace — is changed, untracked or ignored is
refused as `worktree-tampered` before Review runs. `advise_branches` asks the same of a pushed branch
against its merge base (`branch_control_files_changed`) and rejects such a branch without checking it
out for any advisor.

A pathname diff alone misses changes to scripts referenced by unchanged settings and changes to
symlink targets. `lib/check_claude_controls.py` runs before every Claude launch, after Fix, and
against the committed tree before branch advice. It checks `.claude/settings.json` when `project` is enabled and
`.claude/settings.local.json` when `local` is enabled. An empty source override enables both checks.
Under the default `local` scope, unchanged project settings are inert because their hooks never
load. The checker always inspects `.mcp.json` and rejects symlinks or non-regular entries at any
control path, with a directory expected at `.claude`. For configuration it reads, the checker allows
only string-valued `model` and `$schema` preferences and empty `hooks` or `mcpServers` objects.
Malformed or unreadable checked JSON and failed Git inspections also cause refusal.

**The denial itself is built with `jq`,** not string-interpolated: its reason quotes the resolved
target, i.e. an agent-supplied path, and a quote/backslash/control character in that path would
otherwise emit malformed JSON from the very call that is supposed to block the write. If `jq` is
unavailable the guard still denies, with a fixed reason — this path fails closed.

**Matcher.** The guard is registered for `Bash|Write|Edit|MultiEdit|NotebookEdit` — a `matcher:"Bash"`
alone would never fire on a `Write`, leaving (b) dead. The guard denies malformed input and calls
missing the command or write path required by the matched tool.

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
- **The mirror image of that hole:** Layer 1 reads its *allowed* namespace from process env too
  (`refs/heads/${NIGHTSHIFT_BRANCH_PREFIX:-nightshift/}`, exported by the Runner from the rulebook's
  `branch_prefix`), and any non-empty value only ever widens it — `NIGHTSHIFT_BRANCH_PREFIX=m git push
  origin HEAD:main` makes `refs/heads/main` match the prefix with the hook still installed and
  running. So the guard denies that name as well. Both denials rest on the same fact: the Runner
  supplies this env to the agent process, never as a command string, so no legitimate agent command
  contains it.

**Residual — now verified (2026-07-09):** the sandbox uses `--dangerously-skip-permissions`, and the
open question was whether a PreToolUse hook fires under that mode. **It does** — an adversarial test
registered the guard exactly as the Runner does, launched `claude 2.1.197` with the production env +
flags, and had it attempt a `--no-verify` push; the guard denied it verbatim (`nightshift: git
--no-verify would bypass the pre-push confinement hook`) while a control command ran. So Layer 1 + 2
both hold in unattended mode. Optional defense-in-depth remains: **GitHub branch protection** on `main`
(with `enforce_admins`, else the agent's own admin creds bypass it) as a server-side backstop.

## Stage isolation — the operator's personal config is not stage context

Decision and rationale: [ADR 0019](../adr/0019-stage-context-excludes-operator-config.md). This
section is the mechanism; the agent adapters live in
[`lib/adapters.sh`](../../lib/adapters.sh).

A stage runs on the operator's machine but must exclude the operator's personal CLI
configuration. That config is chat-scoped and person-scoped (preferred reply language, private
conventions, tripwire strings); a stage's output is repo-scoped and permanent — `bin/nightshift.sh`
commits the Fix worknote **verbatim** as the commit body and pushes it. Observed on a supervised
real-model night (2026-08-01): a worknote opened with a tripwire line from the operator's
`~/.claude/CLAUDE.md`, was written in the operator's chat language rather than the repo's, and used a
chat-only annotation convention the same file forbids in commits. Same class as the confinement
hooks — enforce it by what the CLI *loads*, not by asking the prompt nicely.

**Claude Code CLI flags and environment**

- **`--setting-sources local`** selects local settings by default and excludes the user and project
  settings scopes. A throwaway repo test on 2026-11-20 with Claude Code 2.1.329 confirmed that the
  repo's `CLAUDE.md` still loads and its project `SessionStart` hook is skipped with `local`. The
  same test with `project,local` loaded `CLAUDE.md` and ran the hook. The Runner passes its own guard
  via `--settings`. `NIGHTSHIFT_CLAUDE_SETTING_SOURCES` accepts a comma-separated list of the
  lowercase names `user`, `project`, and `local`. The Runner trims whitespace around each name.
  An exactly empty value omits `--setting-sources` and lets Claude load all scopes. Empty elements,
  unknown names, and case variants cause the Runner to log the invalid value and refuse startup,
  reject the Fix during its control check, or reject the branch before advice.
- **`--strict-mcp-config`** applies with every source selection. The Runner supplies no
  `--mcp-config`, so there are no MCP servers to load. The Runner reserves `--mcp-config`,
  `--setting-sources`, and `--settings` for its own control of startup. Including any of these
  flags in `NIGHTSHIFT_CLAUDE_FLAGS`, including as `--flag=value`, refuses the stage with status 2.
- **`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`** — the auto-memory store is keyed by cwd under
  `~/.claude/projects/` and is *not* covered by setting sources. A throwaway worktree has nothing to
  read, but the memory **writer** is a write path outside the worktree that the PreToolUse guard
  never sees. Closing it keeps R8 ("Fix writes only inside the worktree") true for the whole process.

**Precondition — worktrees must live outside `$HOME`.** Independently of setting scopes, the CLI also
collects `CLAUDE.md` along the `cwd`→`/` directory chain, and for a cwd under `$HOME` that chain
includes `~/.claude/CLAUDE.md`; `--setting-sources` does not drop it (measured: no token drop, the
tripwire still fired). Worktrees default to `${TMPDIR:-/tmp}/nightshift-worktrees`, outside `$HOME`,
where isolation holds; every stage — recon included — runs in such a worktree, never in the live
checkout. Pointing `NIGHTSHIFT_WORKTREES` into `$HOME` silently reopens the leak, so the Runner logs
a warning at startup instead of failing the run.

**Rejected alternatives.** `--bare` and `--safe-mode` both remove the personal config, but they also
disable hooks — that is Layer 2, i.e. the confinement itself — and `--bare` additionally forces
API-key auth. `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` would also drop the *target repo's* `CLAUDE.md`,
which a stage legitimately needs. Not tested: `deny`-style permission rules, which do not govern
context loading at all.

`tests/test-claude-context-isolation.sh` covers source overrides, reserved flags, strict MCP
configuration, and the memory environment variable. `tests/test-claude-control-files.sh` covers
malformed source selections at startup, after Fix, and before branch advice.

### Codex stage isolation

The Runner invokes `codex exec` with `--ephemeral --ignore-user-config --ignore-rules
--strict-config` and approval policy `never`. Each invocation gets a fresh private directory
under its item directory as both `HOME` and `CODEX_HOME`. Its XDG configuration, data, cache
and state directories point inside that home. The only operator file linked into it is
`auth.json`, when present. The target repository's instructions remain available.
A failure to prepare the home refuses the stage. The Runner removes the home after the call.

Recon, Explore, Review, Advise and Verify use `--sandbox read-only`. Fix uses
`--sandbox workspace-write` with command network access disabled and the shared temporary
directories excluded from writable roots. The Runner injects the Git pre-push hook through
the environment. Codex relies on its OS sandbox for command confinement. The ship gate still
runs separately in bubblewrap. See [R15](risk-analysis.md#r15) for the Fix shell's read access.

## Out of scope for §2a — narrowed by capability profiles

§2a confines **git** only. Non-git irreversible shell — `gh`, `curl`, `npm publish`, `rm -rf` outside
the worktree — requires shell/worktree isolation. But the per-stage **capability profiles**
(`claude_run`, ADR-tracked) now narrow it mechanically: explore/review run with `--tools
"Read,Grep,Glob"` (no Bash at all) and fix with `Read,Grep,Glob,Write,Edit` (Write/Edit but **no
Bash**). With no Bash tool in any stage, the agent cannot invoke `rm`/`curl`/`gh`/`git` regardless of
prompt — the same "capability, not convention" principle as the hook. Verified: a claude run granted
only read tools could not create a file even under `--dangerously-skip-permissions`. The one residual
write primitive — Fix's `Write`/`Edit` reaching absolute paths outside the worktree — is now closed by
Layer 2(b) above. Full OS-level sandboxing (read-only FS / no network) stays the strongest tier if
ever needed.

**The seam none of this covers: what the *Runner* executes.** Every boundary in this document
governs the agent's capabilities. The ship gate (ADR 0022) is the Runner taking the file the agent
wrote and running it — `npm ci` executing a `package.json` lifecycle script — which no tool
allowlist and no `PreToolUse` hook can see, because the agent never invokes it. That is
[ADR 0026](../adr/0026-the-ship-gate-runs-in-a-sandbox.md) / [R15](risk-analysis.md#r15), and it is
where the "strongest tier" above actually got built: `build_test_sandbox` in
[`lib/sandbox.sh`](../../lib/sandbox.sh). When M2 wraps the *agent* process too, that is the
mechanism to reuse.

**Verified end-to-end (2026-07-12).** Beyond the deterministic unit tests
(`tests/test-fix-write-confinement.sh`), a live adversarial run confirmed the integration path: real
`claude` (2.1.205) launched exactly as the Runner does — Fix tool set, the guard registered with the
production matcher, `NIGHTSHIFT_WORKTREE` injected — was told to write two files, one inside the
worktree and one just outside. The inside write succeeded; the outside write was denied by the guard,
which emitted `nightshift: Write/Edit outside the worktree is not allowed (resolved: …)` and left no
file. This proves the matcher fires on a `Write` and that `NIGHTSHIFT_WORKTREE` reaches the hook
process (mirrors the Layer 2(a) verification of 2026-07-09).
