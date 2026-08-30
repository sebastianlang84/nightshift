# ADR 0031 — the reviewer may run on another adapter, and pi is read-only

- Status: accepted
- Date: 2026-08-30
- Extends: [ADR 0001](0001-ports-and-adapters-runner.md) (the adapter seam), [ADR 0019](0019-stage-context-excludes-operator-config.md) (a stage does not inherit the operator's config), [ADR 0020](0020-the-rulebook-declares-the-stage-model.md) (the host declares the model in the rulebook)
- Touches: [ADR 0023](0023-an-unusable-agent-aborts-the-night.md) (a stage that could not run is not a stage that found nothing)

## Context

Fix and Review have always run on the same adapter, therefore on the same model. That makes the
reviewer the author's twin: it shares the author's blind spots by construction, and a fix built on a
misreading is reviewed by the same misreading. The Runner already recognises the problem elsewhere —
`advise_branches` exists precisely so a *different* vendor gives the second opinion on a pushed
branch (`NIGHTSHIFT_ADVISOR_AGENT`) — but that runs after the fact, on branches already shipped. The
gate that decides whether a fix ships at all had no such lever.

Separately, the host wanted a third adapter: `pi`, so a cheap, fast model can serve the review while
the night's expensive model does the work.

## Decision

**1. The Review stage may be routed to a different adapter than the rest of the night.**
`agent.review_agent` in the rulebook (env override `NIGHTSHIFT_REVIEW_AGENT`) names it; omitted, the
Review stage runs on the night's own adapter exactly as before. The mechanism is the dynamic-scope
rebinding `advise_branches` already uses — `run_review_stage` rebinds `NIGHTSHIFT_AGENT` for that one
call — so every helper that reads it (the diagnosis filter, the quota detector, the adapter name in
`runs.jsonl`) sees the adapter that actually ran.

The quota fallback is deliberately *not* carried into a routed reviewer. That route is `claude ->
codex` and belongs to the night's adapter; applying it to a reviewer chosen to differ from the author
would silently swap in the very vendor the routing exists to avoid.

**2. The `pi` adapter serves read-only stages only, and refuses `fix`.**

This is a safety boundary, not a limitation waiting to be lifted. The Fix stage's write confinement
(R8, [hook-spec.md](../design/hook-spec.md)) is enforced *per adapter* by a mechanism that adapter
provides: claude by a `PreToolUse` guard that rejects a `Write`/`Edit` resolving outside the worktree,
codex by an OS-level `--sandbox workspace-write`. pi offers neither. Its tool allowlist can withhold
`write`/`edit`/`bash` entirely — which is what makes a read-only stage safe, since no write primitive
exists to confine — but nothing in pi could bound an absolute path once `write` were granted. So
`pi_run` refuses the fix stage outright rather than shipping an unconfined writer.

**3. pi's stage isolation is a Runner-owned agent directory.** pi resolves `~/.pi/agent` from
`$PI_CODING_AGENT_DIR`, and that directory holds the operator's global `AGENTS.md`, which pi injects
into every stage. Verified 2026-08-30 against pi 0.84.2: a stage launched with
`--no-extensions --no-skills --no-prompt-templates` and a cwd outside `$HOME` still named
`~/.pi/agent/AGENTS.md` as an injected instruction file. `--no-context-files` is the wrong lever —
all-or-nothing, so it would drop the *target repo's* `AGENTS.md` too, which a stage legitimately
needs. `pi_stage_home()` therefore builds `state/pi-home` holding nothing but symlinks to
`auth.json` and the model catalogs: credentials and model resolution in, personal config out, repo
context unaffected. Same shape, same reasoning as `codex_stage_home()` (ADR 0019). Verified with the
same probe — the isolated stage answered `NONE`.

**4. A pi stage's success is decided by the stream, not the exit code.** pi reports a provider or
transport failure *inside* its event stream (`stopReason: "error"` plus `errorMessage`) and still
exits 0. Verified 2026-08-30, where a 403 from the model gateway produced `rc=0` and an empty answer.
Absorbed as success that is exactly the forged clean night ADR 0023 exists to prevent, so the adapter
reads the stream's verdict and fails the stage itself.

**5. Only pi's own words are offered for diagnosis.** pi's stream carries the prompt and every tool
result verbatim — i.e. the reviewed repo's words. Matching credential prose against that whole stream
is the mistake that aborted a healthy night on 2026-08-24, when an explore lens read a line about
`codex login`. `agent_diagnosis` therefore extracts only `errorMessage` from a message whose
`stopReason` is `error`, the same narrowing the claude branch applies to its `result` event.

**6. A host that runs any stage on pi refreshes pi once a day.** pi resolves `--model` against a
catalog cached on disk, and a stale catalog refuses a model the provider already serves: verified
2026-08-30, where `z-ai/glm-5.3-flash` was rejected as unknown by a 13-day-old store and accepted
immediately after a refresh. `pi_daily_update` runs `pi update --all` followed by `pi update
--models` — the second is not covered by `--all` and is the half model resolution depends on — once
per calendar day, stamped in `state/.pi-update-day`. A failure is logged and never fatal: an update
that cannot reach the network is not a reason to skip a night, and the previous catalog is still on
disk. `NIGHTSHIFT_PI_UPDATE=0` opts out.

**Corollary — extension discovery cannot simply be switched off.** The natural reading of stage
isolation is "no extensions", and that is wrong on a gateway host: pi's authentication is itself an
extension, which stamps the caller's device header. Verified 2026-08-30 — with `--no-extensions` the
gateway answered `403 ... this token is bound to a different device; run /pidso-auth neu on this
machine to enroll it`, which reads like a revoked credential and is nothing of the sort; the same
call with the auth extension loaded succeeded. Worse, the fallback catalog reached without the
extension exposes the same credential under a DIFFERENT provider name (`openrouter` rather than
`pidso-proxy`), so the misconfiguration looks like a working provider right up to the 403. So
discovery stays off and `agent.pi_extensions` names the auth extension by path (`-e` loads a path
even under `-ne`); a declared path that does not exist is logged and dropped rather than passed on.

**7. pi's own toolchain is prepended for the pi subprocess only.** pi is an npm-global under nvm and
its `env node` shebang takes the first node on PATH; under the unattended launcher's PATH that is a
node too old to run it (verified: pi requires >= 22.19, the system node is 18). The launcher exports
`NIGHTSHIFT_PI_PATH` and `pi_path_prefix()` prepends it for the pi call alone — merging it into the
Runner's own PATH would put a `$HOME` directory ahead of the system dirs, which is the R10/N4 hole
[risk-analysis.md](../design/risk-analysis.md) warns about.

## Amendment, 2026-08-30 — the host may take the Fix risk deliberately

Decision 2 above refuses the Fix stage outright. That refusal now has an explicit opt-in:
`agent.pi_allow_fix: true` (env `NIGHTSHIFT_PI_ALLOW_FIX=1`), together with `agent.primary`, which
lets the rulebook name the adapter for the whole night rather than only `$NIGHTSHIFT_AGENT`.

The operator's reasoning, recorded because it is the part a future reader will want to weigh: the
Fix stage writes into a throwaway worktree, its output reaches a human as a `nightshift/*` branch,
and no branch is merged without that review. On that view the code the stage produces is already
gated, and paying Opus prices for it buys little — this night cost 26,34 $, of which 23,52 $ were
Explore and Fix, against 0,04 $ for six reviews on glm-5.3-flash.

**What the opt-in trades away is not the branch content, and that distinction is the whole point.**
The confinement bounds where the PROCESS may write, not what the diff contains. A write outside the
worktree — into `~/partflow` rather than the worktree also named `partflow`, into `~/.claude`, into
nightshift's own hooks — appears in no diff, so the morning branch review structurally cannot catch
it. The realistic failure is a confused absolute path, not malice, and it is precisely the case
Layer 2(b) was built and adversarially tested for on 2026-07-12.

Bounded as far as it can be without a mechanism: `bash` is refused on every pi profile including the
opted-in Fix one, so such a stage may edit files but never execute anything; the write tools are
granted only on the Fix stage, never on a read-only one; the rulebook key takes only the literal
`true`; and the run announces the adapter it uses. What remains unbounded is the write path itself.

The proper fix is a mechanism rather than a policy: wrapping the agent process in the bwrap sandbox
`build_test_sandbox` already provides for the ship gate (ADR 0026 / hook-spec.md, "when M2 wraps the
agent process too"). Until that exists, `pi_allow_fix` is the host accepting a known, named risk.

## Consequences

- A fix can now be judged by a model that did not write it, on the gate that decides shipping.
- The morning log states the split explicitly (`review stage: <adapter>`), because "who judged this"
  is a governance fact, not something to reconstruct from `runs.jsonl`.
- `pi update --all` hard-resets pi-managed git clones under `~/.pi/agent/git/` (`git reset --hard` +
  `git clean -fdx`). Nightshift runs it because the host declared it; local edits parked in those
  clones do not survive it.
- pi cannot become the night's primary adapter for a `branch-fix` repo — its fix refusal would fail
  every item. That is intended: promoting it needs a write-confinement mechanism first, which is the
  same gap M2 (sandboxing the agent process) would close for every adapter at once.
- Regression cover: `tests/test-pi-adapter.sh` (flags, isolation, routing, telemetry, the fix
  refusal, the daily refresh), `tests/test-pi-stage-failure.sh` (the rc=0 rejection, the diagnosis
  narrowing), `tests/test-rulebook-validation.sh` (the new keys).
