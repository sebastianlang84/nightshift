# ADR 0020 — the rulebook declares which model a stage runs on

- Status: accepted
- Date: 2026-08-02
- Closes the question left open by [ADR 0019](0019-stage-context-excludes-operator-config.md):
  whether nightshift must now pin a model of its own.

## Context

Stage isolation (ADR 0019) excludes the CLI's whole `user` settings scope so the operator's personal
`CLAUDE.md` cannot reach a stage and end up in a pushed commit body. The scope is the smallest unit
the CLI offers, so `~/.claude/settings.json` goes with it — and a machine-wide model pin lives
there. Verified on 2026-08-02 against claude 2.1.205: a stage-shaped call made with
`--setting-sources project,local` on a host pinned to `claude-opus-5` reports
`claude-opus-4-8[1m]` in `modelUsage`, the CLI's own default.

The consequence is not that the pin stopped working — it works exactly as scoped. The consequence is
that **a host had no place left to state which model its nights run on.** `NIGHTSHIFT_CLAUDE_MODEL`
existed, but only as an environment variable: it must be set on every manual invocation and lives
outside any file the project reads, so the natural failure is silence — the night simply runs on
something else and nobody learns of it until `runs.jsonl` is read the next morning.

Three options were on the table in `OPEN-QUESTIONS.md`: leave it to the environment variable, pin
the model in the Runner-owned `state/claude-settings.json` (which `--settings` loads regardless of
scope), or fail the run when no model is declared anywhere.

## Decision

**The rulebook declares the model, in an `agent:` block, per adapter.**

```yaml
agent:
  claude_model: claude-opus-5
  codex_model: gpt-5.6-sol
```

Precedence, most specific first: `NIGHTSHIFT_CLAUDE_MODEL` / `NIGHTSHIFT_CODEX_MODEL` **if set** —
an explicitly empty value is the escape hatch and passes no `--model` at all — then the rulebook key,
then nothing, leaving the CLI to resolve its own default.

Every run announces the model it will **request** *and where that choice came from*, before the first
stage:

```
[nightshift] claude model: claude-opus-5 (from rulebook agent.claude_model)
[nightshift] claude model: not declared — the CLI's own default applies (…)
```

That is a statement about the *selection*, not about what served: with no `--model` the CLI decides
for itself, and even a given id may be an alias that resolves to another concrete model. Which model
actually ran is `runs.jsonl` `model_id`, and only afterwards.

## Why the rulebook and not the alternatives

- **It is the file this design already reserves for human governance.** `rulebook.yaml` is untracked,
  host-owned, and read on every run — manual or scheduled. Which model does the work is a governance
  choice of exactly that kind, sitting naturally beside the caps and the lens rotation.
- **"nightshift commits no model of its own" survives intact.** The repo ships the key documented and
  commented out in `rulebook.example.yaml`. No tracked file *sets* a model — the examples here and in
  the docs name concrete ids only to illustrate the shape; the host's untracked rulebook decides.
- **`state/claude-settings.json` was the wrong home.** It is generated Runner state whose single
  purpose is registering the PreToolUse guard. Mixing a governance choice into a file the Runner
  rewrites every run hides the decision from the human who owns it, and couples the model to the
  confinement mechanism.
- **Failing the run when no model is declared was too strict.** Not every host cares; the CLI default
  is a legitimate choice. Announcing it beats forbidding it — the actual defect was silence, not the
  absence of a pin.

## Consequences

- A host that pins a model for its interactive Claude Code work and wants the same model overnight
  must state it in **both** places. That duplication is deliberate: they are different scopes with
  different lifetimes, and ADR 0019 exists precisely to keep them from bleeding into each other.
- The environment variable keeps working and still wins, so a one-off cheap night stays a one-liner —
  and `NIGHTSHIFT_CLAUDE_MODEL=` (empty) remains the way to fall back to the CLI default from a
  configured host.
- The parser gained an `agent:` section. It rejects a tab in the value, which would corrupt the TSV
  transport to bash; model ID *syntax* is deliberately not validated, since it belongs to the CLI
  vendor and any check here would go stale.
- The announcement is the safety net that makes this auditable **before** a night rather than after.
  `runs.jsonl` (`model_id`, `context_window`) remains the after-the-fact record; ADR 0019's note that
  the effective model is "auditable, but only after the fact" no longer holds.
