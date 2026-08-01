# ADR 0019 — a stage's context is repo-scoped, never operator-scoped

- Status: accepted
- Date: 2026-08-02
- Extends the "capability, not convention" principle of the confinement hooks
  ([`docs/design/hook-spec.md`](../design/hook-spec.md)) from *what an agent may do* to *what it may read*.
- Leaves open: whether nightshift must now pin its own model
  ([`OPEN-QUESTIONS.md`](../../OPEN-QUESTIONS.md)).

## Context

A stage runs the operator's own CLI on the operator's own machine, so by default it inherits the
operator's personal Claude Code configuration — `~/.claude/settings.json` and `~/.claude/CLAUDE.md`.
That configuration is **chat-scoped and person-scoped**: preferred reply language, private
annotation conventions, tripwire strings, house style for a human conversation. A stage's output is
the opposite: **repo-scoped and permanent**. `bin/nightshift.sh` commits the Fix worknote *verbatim*
as the commit body and pushes the branch.

Observed on a supervised real-model night (2026-08-01, sandbox repo, all four stages): the worknote
opened with a tripwire line from the operator's personal instructions, was written in the operator's
chat language rather than the repo's documentation language, and used an annotation convention that
the same personal file explicitly restricts to chat and forbids in commits. Blast radius is every
stage of every night across all configured repos; commit bodies are permanent, and the same ~3.8k
tokens of irrelevant personal rules were prepended to every call.

The observation was made in claude mode, but the exposure is structural — every first-party CLI reads
a personal instruction file — so codex was checked for the same class and found to leak too (below).

Prompt-level containment ("write the worknote in English") is the wrong instrument for the same
reason it is the wrong instrument for git confinement: it asks the model not to use context it can
see, and it fails silently and invisibly. The operator's file is also **not nightshift's to change** —
it legitimately governs their interactive sessions.

## Decision

**A stage loads repo context and runner context; it does not load operator context.** Enforced by
what the CLI is allowed to *load*, not by prompt instruction. The rule is adapter-independent; the
lever is not, because each CLI scopes its config differently.

### claude — verified against claude 2.1.205

1. **`--setting-sources project,local`** — the CLI's settings **scopes** are the smallest unit on
   offer. Dropping `user` drops `~/.claude/settings.json` and `~/.claude/CLAUDE.md`; keeping
   `project,local` keeps the **target repo's own** `CLAUDE.md`, which is context a stage should have.
   `--settings`, `--mcp-config` and `--tools` are unaffected, so both confinement layers stand.
   `NIGHTSHIFT_CLAUDE_SETTING_SOURCES` overrides it; empty passes no flag, for a CLI too old to know
   the option.
2. **`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`** — the per-cwd auto-memory store is not covered by setting
   scopes. A throwaway worktree has nothing to read, but its **writer** is a write path outside the
   worktree that the `PreToolUse` guard never sees; closing it keeps R8 true for the whole process.

Rejected: `--bare` and `--safe-mode` (both disable hooks — i.e. the confinement itself — and `--bare`
additionally forces API-key auth), and `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` (drops the target repo's
`CLAUDE.md` too).

### codex — verified against codex-cli 0.145.0

`codex_run` already passed `--ignore-user-config --ignore-rules --ephemeral --strict-config`, which
looks like isolation and is not: those cover `$CODEX_HOME/config.toml` and the execpolicy `.rules`
files, **not** `$CODEX_HOME/AGENTS.md`. Measured with a tripwire in that file and nightshift's exact
flags: the global instructions reached the stage verbatim.

Codex has no scope selector. The config-level knob is the wrong way round — `project_doc_max_bytes=0`
drops the **repo's** `AGENTS.md` and leaves the global one standing, the exact inverse of what a
stage needs. The one lever that separates the scopes is **the home itself**: a Runner-owned
`CODEX_HOME` (`state/codex-home`, `codex_stage_home()`) containing nothing but a symlink to the
operator's `auth.json`. No `AGENTS.md`, no `config.toml`, no skills, no memories, no history — while
the target repo's `AGENTS.md` still loads. Verified end-to-end: real API call succeeds through the
symlinked credentials, tripwire gone, repo file still seen. `NIGHTSHIFT_CODEX_STAGE_HOME` overrides
the location; empty reverts to the operator's home.

No auth file to link (API-key-in-env setups) still isolates rather than falling back: an auth failure
is loud and recoverable, a reopened leak is silent until it is in a commit body.

## Consequences

- **The `user` scope is all-or-nothing, so a machine-wide model pin is collateral.** The CLI offers no
  way to drop `~/.claude/CLAUDE.md` while keeping `~/.claude/settings.json`. A host relying on such a
  pin must set `NIGHTSHIFT_CLAUDE_MODEL`; otherwise the nightly model silently becomes the CLI
  default. `runs.jsonl` records the model that actually served each stage, so it stays auditable —
  but only after the fact. Whether nightshift should therefore pin a model of its own is the open
  decision above.
- **Location precondition.** The CLI also collects `CLAUDE.md` along the `cwd`→`/` chain, and for a
  cwd under `$HOME` that chain includes `~/.claude/CLAUDE.md`, which setting scopes do not drop.
  Worktrees default outside `$HOME` and every stage — recon included — runs in one, so isolation
  holds; `NIGHTSHIFT_WORKTREES` pointed into `$HOME` reopens the leak and the Runner warns at startup.
- **The lever is per-adapter; the contract is not.** Both adapters now satisfy it, by different
  mechanisms — a settings-scope selector for claude, a Runner-owned home for codex. A future adapter
  inherits the *rule* and must find its own lever; neither existing mechanism generalizes.
- The codex model pin is **not** affected the way claude's is: `--ignore-user-config` already
  excluded `$CODEX_HOME/config.toml` before this ADR, so `NIGHTSHIFT_CODEX_MODEL` was always the only
  model lever for a codex night. The asymmetry is in the CLIs, not in nightshift.
- `state/codex-home` is new Runner-owned local state. Codex populates it itself (model cache,
  bundled skills, an empty memory store) — nothing is copied from the operator's home, verified by
  checksum. It is disposable: deleting it costs one model-cache refetch.
- Regression cover: `tests/test-claude-context-isolation.sh`, `tests/test-codex-context-isolation.sh`.
