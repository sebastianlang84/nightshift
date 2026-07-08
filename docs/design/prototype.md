# Prototype — how to run it

- Status: **runnable prototype, 2026-07-08.** Proves the v1 mechanics end-to-end with zero risk to
  real repos. Both agent paths are verified against the sandbox: `mock` (deterministic) and `claude`
  (real Explore/Fix/Review via the first-party CLI).

## Run it

```sh
bin/setup-sandbox.sh                    # throwaway target repo + local bare remote + a planted typo
bin/nightshift.sh                       # one night, mock agent (default)
NIGHTSHIFT_AGENT=claude bin/nightshift.sh   # one night, real claude -p stages
```

Then look at `digests/<date>.md`, `state/ledger.jsonl`, `state/runs.jsonl`, and the pushed
`nightshift/*` branch in the sandbox remote.

## What the prototype demonstrates (verified)

- **The outer loop:** select repo (cold-start = most-recent-commit churn) → Explore → Fix⟷Review
  (capped) → Finalize (push a `nightshift/*` branch) → append ledger + telemetry → digest.
- **Branch isolation:** the fix lands on `nightshift/*`; `main` is untouched.
- **The git-confinement hook (§2a, `hook-spec.md`):** `hooks/pre-push` rejects pushes to `main`,
  `+main` (force), `:branch` (delete), and tags — while allowing `nightshift/*`. It checks git's
  *resolved* refs, so the bypass spellings are caught.
- **Dedup (§1.7):** a finding already in the ledger (by `file:type:line-window` fingerprint) is
  skipped on the next night — the anti-nag mechanism.
- **Caps:** `max_branches_per_night` and the global `max_open_branches` backpressure (counted from
  real remote branches, reconciling against reality, §3e).

## The `run_agent` seam (ADR 0001)

Stages are invoked through `run_agent(stage, workdir, item_dir)`, which dispatches to:

- `NIGHTSHIFT_AGENT=mock` — deterministic fake stages (fixes a planted typo). The tested path.
- `NIGHTSHIFT_AGENT=claude` — calls the first-party CLI headless (`claude -p --output-format json`,
  ADR 0003), **verified**: a real run found the planted typo (pinning the line window more precisely
  than the mock), fixed exactly it, reviewed it independently, and shipped — `main` untouched.
  The agent only reads/edits; the Runner owns all git. `runs.jsonl` captured real tokens **and cost**
  (~$0.37 for the trivial fix across 3 Opus calls — telemetry immediately surfaces that a smaller
  model for Explore/Review is the obvious cost lever). Still to harden: sub-agents for Explore
  (context control, §3b), the PreToolUse guard wired into settings, and non-sandbox permission mode.

## Files

| Path | Role |
|------|------|
| `bin/nightshift.sh` | the Brain/Runner (outer loop, caps, finalize, digest) |
| `bin/setup-sandbox.sh` | builds the throwaway sandbox |
| `hooks/pre-push` | Layer 1 git-confinement (resolved-ref check) |
| `hooks/pretooluse-guard.sh` | Layer 2 anti-bypass (Claude PreToolUse; for the claude path) |
| `lib/parse_rulebook.py` | minimal rulebook YAML-subset parser |
| `prompts/{explore,fix,review}.md` | stage prompts (for the claude path) |
| `rulebook.example.yaml` | the governance template |

Runtime state (`state/`, `runs/`, `digests/`, `sandbox/`, `rulebook.yaml`) is gitignored.
