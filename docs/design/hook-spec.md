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
`.mcp.json`: Claude loads them as executable hook or MCP-server configuration for the next stage, so
Fix may not create or edit them. A repository that intentionally changes those files needs human
handling.

**The denial itself is built with `jq`,** not string-interpolated: its reason quotes the resolved
target, i.e. an agent-supplied path, and a quote/backslash/control character in that path would
otherwise emit malformed JSON from the very call that is supposed to block the write. If `jq` is
unavailable the guard still denies, with a fixed reason — this path fails closed.

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
section is the mechanism.

A stage runs on the operator's machine but must **not** inherit the operator's personal Claude Code
configuration. That config is chat-scoped and person-scoped (preferred reply language, private
conventions, tripwire strings); a stage's output is repo-scoped and permanent — `bin/nightshift.sh`
commits the Fix worknote **verbatim** as the commit body and pushes it. Observed on a supervised
real-model night (2026-08-01): a worknote opened with a tripwire line from the operator's
`~/.claude/CLAUDE.md`, was written in the operator's chat language rather than the repo's, and used a
chat-only annotation convention the same file forbids in commits. Same class as the confinement
hooks — enforce it by what the CLI *loads*, not by asking the prompt nicely.

**claude — mechanism (verified against claude 2.1.205, 2026-08-02).**

- **`--setting-sources project,local`** — selects which settings **scopes** the CLI loads. Dropping
  `user` drops `~/.claude/settings.json` *and* `~/.claude/CLAUDE.md`; keeping `project,local` keeps
  the **target repo's own** `CLAUDE.md`, which is exactly the context a stage should have. Measured:
  ~3.8k tokens of personal rules removed per stage call. `--settings`, `--mcp-config` and `--tools`
  are unaffected — Layer 2 was re-verified firing under the flag, so the confinement is untouched.
  Override with `NIGHTSHIFT_CLAUDE_SETTING_SOURCES`; **empty disables the flag** (escape hatch for a
  CLI too old to know the option — the leak returns).
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

**codex — mechanism (verified against codex-cli 0.145.0, 2026-08-02).** The flags that look like
isolation are not: `--ignore-user-config` covers `$CODEX_HOME/config.toml` and `--ignore-rules` the
execpolicy files, while `$CODEX_HOME/AGENTS.md` reaches the stage verbatim. Codex offers no scope
selector, and `project_doc_max_bytes=0` is inverted (it drops the *repo's* `AGENTS.md` and keeps the
global one). So `codex_stage_home()` builds a Runner-owned `CODEX_HOME` at `state/codex-home` that
contains **only** a symlink to the operator's `auth.json` — credentials in, personal config out, repo
`AGENTS.md` unaffected. `NIGHTSHIFT_CODEX_STAGE_HOME` overrides it; empty reverts to the operator's
home. With no `auth.json` to link, the stage still runs isolated: an auth failure is loud, a reopened
leak is not.

**pi — mechanism (verified against pi 0.84.2, 2026-08-30).** Same shape as codex, for the same
reason. `--no-extensions`, `--no-skills` and `--no-prompt-templates` switch off every discovery
source pi documents, and none of them covers `~/.pi/agent/AGENTS.md`: a stage launched with all three,
from a cwd outside `$HOME`, still named that file as an injected instruction file when asked.
`--no-context-files` is all-or-nothing and would drop the *target repo's* `AGENTS.md` with it. pi
resolves its agent directory from `$PI_CODING_AGENT_DIR`, so `pi_stage_home()` builds
`state/pi-home` containing nothing but symlinks to `auth.json` and the model catalogs
(`models.json`, `models-store.json` — without them a declared model id does not resolve at all).
Verified with the same probe: the isolated stage answered `NONE`. `NIGHTSHIFT_PI_STAGE_HOME`
overrides it; empty reverts to the operator's own directory.

**pi is read-only, and that is a confinement decision (ADR 0031).** Layer 2(b) above is a Claude
Code `PreToolUse` hook, and codex's equivalent is its OS-level `workspace-write` sandbox. pi has
neither: it can withhold `write`/`edit`/`bash` from a stage entirely — which is what makes its
read-only profile safe, since no write primitive exists to confine — but nothing in it could bound an
absolute path once `write` were granted. So `pi_run` refuses the `fix` stage rather than run an
unconfined writer, and pi serves review/explore/recon/verify/advise only.

**Rejected alternatives.** `--bare` and `--safe-mode` both remove the personal config, but they also
disable hooks — that is Layer 2, i.e. the confinement itself — and `--bare` additionally forces
API-key auth. `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` would also drop the *target repo's* `CLAUDE.md`,
which a stage legitimately needs. Not tested: `deny`-style permission rules, which do not govern
context loading at all.

Regression cover: `tests/test-claude-context-isolation.sh` (flag default, escape hatch, verbatim
pass-through, memory env).

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

**The seam none of this covers: what the *Runner* executes.** Every boundary in this document
governs the agent's capabilities. The ship gate (ADR 0022) is the Runner taking the file the agent
wrote and running it — `npm ci` executing a `package.json` lifecycle script — which no tool
allowlist and no `PreToolUse` hook can see, because the agent never invokes it. That is
[ADR 0026](../adr/0026-the-ship-gate-runs-in-a-sandbox.md) / [R15](risk-analysis.md#r15), and it is
where the "strongest tier" above actually got built: `build_test_sandbox` in
[`bin/nightshift.sh`](../../bin/nightshift.sh). When M2 wraps the *agent* process too, that is the
mechanism to reuse.

**Verified end-to-end (2026-07-12).** Beyond the deterministic unit tests
(`tests/test-fix-write-confinement.sh`), a live adversarial run confirmed the integration path: real
`claude` (2.1.205) launched exactly as the Runner does — Fix tool set, the guard registered with the
production matcher, `NIGHTSHIFT_WORKTREE` injected — was told to write two files, one inside the
worktree and one just outside. The inside write succeeded; the outside write was denied by the guard,
which emitted `nightshift: Write/Edit outside the worktree is not allowed (resolved: …)` and left no
file. This proves the matcher fires on a `Write` and that `NIGHTSHIFT_WORKTREE` reaches the hook
process (mirrors the Layer 2(a) verification of 2026-07-09).
