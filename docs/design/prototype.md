# Prototype — how to run it

- Status: **runnable prototype, 2026-07-11.** Proves the v2 mechanics end-to-end with zero risk to
  real repos. Adapter paths are `mock` (deterministic), `claude`, and `codex`; the real adapters
  invoke their first-party CLIs headlessly.

## Run it

```sh
bin/setup-sandbox.sh                    # throwaway target repo + local bare remote + a planted typo
bin/nightshift.sh                       # one night, mock agent (default)
NIGHTSHIFT_AGENT=claude bin/nightshift.sh   # one night, real claude -p stages
NIGHTSHIFT_AGENT=codex NIGHTSHIFT_CODEX_MODEL=<model> NIGHTSHIFT_CODEX_REASONING_EFFORT=high bin/nightshift.sh
```

Per-repo `mode` (rulebook.yaml): **`branch-fix`** does the full loop and pushes a `nightshift/*`
branch; **`findings-only`** runs Explore only and just reports (no fix, no branch) — the safe
trust-ramp entry, and the first mode to point at a real repo. Worktrees are created *outside* the
control repo (default `${TMPDIR}/nightshift-worktrees`) so nightshift can even target its own repo.

Then look at `digests/<date>.md`, `state/ledger.jsonl`, `state/runs.jsonl`, and the pushed
`nightshift/*` branch in the sandbox remote.

## What the prototype demonstrates (verified)

- **The outer loop:** select repo (least-recently-serviced first, ADR 0008; cold-start falls back to
  most-recent-commit churn) → Explore → Fix⟷Review
  (capped) → Finalize (push a `nightshift/*` branch) → append ledger + telemetry → digest.
- **Branch isolation:** the fix lands on `nightshift/*`; `main` is untouched.
- **Push truthfulness:** `shipped` is written only after the remote accepts the branch. Failure
  records a retryable `push-failed` outcome, cleans the local branch, and appears in the digest.
- **Worktree isolation:** each item runs in a throwaway `git worktree`, never the repo's live
  checkout — so nightshift never touches your branch/state, and any misstep (incl. non-git shell,
  §2b) is confined to a dir deleted afterwards. The confinement hook is activated per-push via
  `-c core.hooksPath` — **zero writes** to the target repo's config (your own pushes stay unconstrained).
- **The git-confinement hook (§2a, `hook-spec.md`):** `hooks/pre-push` rejects pushes to `main`,
  `+main` (force), `:branch` (delete), and tags — while allowing `nightshift/*`. It checks git's
  *resolved* refs, so the bypass spellings are caught.
- **Dedup (§1.7):** a finding already in the ledger (by `file:type:line-window` fingerprint) is
  skipped on the next night — the anti-nag mechanism.
- **Caps:** the global `max_open_branches` backpressure (counted from real remote branches,
  reconciling against reality, §3e) is the sole throughput governor (ADR 0004). Two hard backstops
  sit under it, both rulebook-configurable (ADR 0005): `max_branches_per_run` (per-run runaway
  ceiling) and `max_fix_iterations` (Fix↔Review round-trips per finding).

## The `run_agent` seam (ADR 0001)

Stages are invoked through `run_agent(stage, workdir, item_dir)`, which dispatches to:

- `NIGHTSHIFT_AGENT=mock` — deterministic fake stages (fixes a planted typo). The tested path.
- `NIGHTSHIFT_AGENT=claude` — calls the first-party CLI headless (`claude -p --output-format json`,
  ADR 0003), **verified**: a real run found the planted typo (pinning the line window more precisely
  than the mock), fixed exactly it, reviewed it independently, and shipped — `main` untouched.
  The agent only reads/edits; the Runner owns all git. `runs.jsonl` captures real tokens **and
  cost**, plus the `model_id` and `context_window` that actually served each stage — so a night is
  attributable to a model after the fact, not just to an adapter. A supervised night (2026-08-01,
  four stages, sandbox repo) cost ~$2.16 across 4 Opus-5 calls — recon $0.57 · explore $0.65 ·
  fix $0.61 · review $0.33, 163s wall clock — which keeps a smaller model for Recon/Explore/Review
  the obvious cost lever. `NIGHTSHIFT_CLAUDE_MODEL` is that lever — run-wide, empty by default, so
  no model is committed as the default. The PreToolUse guard is wired through the generated settings
  and confines Fix-stage `Write`/`Edit` paths to the worktree. Still to harden: sub-agents for
  Explore (context control, §3b) and non-sandbox permission mode.
- `NIGHTSHIFT_AGENT=codex` — calls `codex exec` ephemerally. Recon/Explore/Review use Codex's
  `read-only` sandbox; Fix uses `workspace-write` in the disposable worktree with network disabled.
  `NIGHTSHIFT_CODEX_MODEL` and `NIGHTSHIFT_CODEX_REASONING_EFFORT` are optional host configuration;
  no model is committed as the default. Codex can execute sandboxed commands during Fix, unlike the
  Claude adapter's no-Bash profile. The Runner still owns branch, commit, and push.

**Verification debt — real-model prompt behavior (partly closed).** The Runner logic (recon
caching, yield-weighted dimension selection, the empty-scope ledger row and its digest suggestions
— ADR 0010/0015) is covered end-to-end in **mock** mode, which drives the real
branch/worktree/git/ledger path but fakes the model boundary.

A supervised real-model night on **2026-08-01** against a throwaway sandbox repo closed part of the
prompt-level gap. A live Recon calibrated `yield` across all nine dimensions with file- and
line-grounded hints — it rated `correctness` high and pointed at the exact zero-argument division
Explore then found. Explore produced that finding, Fix made a minimal guarded change, and Review
shipped it on independently gathered evidence; both Fix and Review stated plainly that they could
not execute the code instead of claiming verification they had not done.

Two things that night did **not** exercise, and they stay open. The rulebook pinned a single
dimension, so yield-weighted *selection* never had to choose. And the sandbox contained a genuine
defect, so the confabulation guard is still untested: whether a real Explore honestly returns
`out_of_scope`/`in_scope_no_findings` on a repo with nothing to find, rather than manufacturing a
finding, needs a night against a clean repo.

## Files

| Path | Role |
|------|------|
| `bin/nightshift.sh` | the Brain/Runner (outer loop, caps, finalize, digest) |
| `bin/harvest.sh` | reconciles shipped branches into verdicts; `todos`/`close`/`probe` for open findings |
| `bin/review-branch.sh` | mechanical branch review (the opt-in second opinion) |
| `bin/schedule.sh` | installs/updates the systemd timer |
| `bin/nightshift-cron.sh` | unattended launcher the timer invokes |
| `bin/setup-sandbox.sh` | builds the throwaway sandbox |
| `hooks/pre-push` | Layer 1 git-confinement (resolved-ref check) |
| `hooks/pretooluse-guard.sh` | Layer 2 anti-bypass (Claude PreToolUse; for the claude path) |
| `lib/parse_rulebook.py` | minimal rulebook YAML-subset parser |
| `lib/extract_json.py` | pulls the JSON artifact out of a stage model's output |
| `lib/recon_signals.sh` | collects the per-repo signals recon ranks dimensions on |
| `lib/probe_findings.py` | finding freshness probe (ADR 0021), writes `state/findings-probe.json` |
| `prompts/{recon,explore,fix,review,verify,advise}.md` | provider-neutral stage prompts |
| `prompts/dimensions/*.md` | one lens per review dimension, selected by recon |
| `rulebook.example.yaml` | the governance template |

Runtime state (`state/`, `runs/`, `digests/`, `sandbox/`, `rulebook.yaml`) is gitignored.
