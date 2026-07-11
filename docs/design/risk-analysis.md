# nightshift — Risk Analysis

- Status: **living document.** First cut 2026-07-10, during the daytime-testing phase.
- Scope: the security and safety posture of running the nightshift steward **unattended** on a
  shared host. What can go wrong, what is already in place to stop it, and what risk remains open.
- Method: derived from the actual runner (`bin/nightshift.sh`, `bin/nightshift-cron.sh`), the
  confinement hooks (`hooks/`), and the live `rulebook.yaml` — not from intent alone.
- Reviewed: independent adversarial pass by a second model (Fable, 2026-07-10) against the code.
  It found the register understated the write-primitive threat — see [R8](#r8)–[R13](#r13), which
  materially revised §2 and the §6 residual statement below.

Read alongside: [hook-spec.md](hook-spec.md) (git confinement), [autonomy-and-shutoff.md](autonomy-and-shutoff.md)
(kill-switch design, not yet built), [constitution-and-rulebook.md](constitution-and-rulebook.md),
ADR [0003](../adr/0003-subscription-safe-execution.md) (headless execution) and
[0004](../adr/0004-v1-scope-branch-isolated-steward.md) (branch-only scope).

---

## 1. Trust model — what runs, as whom, with what reach

nightshift launches a selected first-party CLI headlessly (`claude -p` or `codex exec`) per stage,
orchestrated by a "dumb" launcher fired from a systemd **user** timer with linger enabled. The
original threat analysis targeted Claude; adapter-specific differences are explicit below.

- **Identity:** runs as the interactive user `llmadmin`. That account is a member of the `docker`
  and `sudo` groups and can read the user's SSH private keys, the `gh` OAuth token
  (scopes incl. `repo`, `admin:public_key`), and any secrets its group membership grants.
- **Reach of that account (if any confinement layer failed):** `docker` group membership is
  equivalent to host root (`docker run -v /:/host …`). The host is shared with other services
  (partflow, llmstack, open-webui, dashboard). So the *theoretical* blast radius of a full
  containment failure is the entire VM — see [R2](#r2).
- **Targets** (`rulebook.yaml`): five local repos, mostly `findings-only` (report, never push);
  a few `branch-fix` (push `nightshift/*` branches). Only this repo opens a PR. Nothing is ever
  merged automatically (ADR 0004).
- **Untrusted input:** the *contents* of the target repos. Third-party code, dependencies, commit
  messages and comments the agent reads are attacker-influenceable and reach the model context.

The design intent (ADR 0003): the agent only **reads and edits files**; the **Runner owns all git**
(branch, commit, push). Containment is therefore enforced at two seams — the agent's *capabilities*
(which tools exist) and *git* (which refs a push may touch).

---

## 2. Containment in place

These are implemented and active today. Each is enforced by mechanism, not by prompt wording.

| # | Control | Mechanism | Where |
|---|---------|-----------|-------|
| C1 | **Stage capability boundary** | Claude uses a per-stage tool allowlist and never grants `Bash`. Codex uses `read-only` for Recon/Explore/Review and `workspace-write` with network disabled for Fix; Codex can execute sandboxed commands inside that worktree. | [nightshift.sh](../../bin/nightshift.sh) |
| C2 | **Repo never touched directly** | Every work item runs in a throwaway `git worktree --detach` under `$TMPDIR`, removed `--force` after. Edits land there, not in the real checkout. | [nightshift.sh:312-315](../../bin/nightshift.sh) |
| C3 | **Push confinement (Layer 1)** | `hooks/pre-push` checks git's already-**resolved** refs: rejects any ref outside `nightshift/*`, plus deletes and tag pushes. Every bypass spelling (`+main`, `:branch`, `--all`, `--mirror`) is resolved by git before the hook sees it. | [pre-push](../../hooks/pre-push) |
| C4 | **Can't disable Layer 1 (Layer 2, Claude only)** | `core.hooksPath` is injected into both adapters. Claude also has a `PreToolUse` guard denying bypass flags. Codex has no equivalent tool hook here; its sandbox is the primary agent boundary, while the Runner's final push supplies the hook independently. | [pretooluse-guard.sh](../../hooks/pretooluse-guard.sh), [nightshift.sh](../../bin/nightshift.sh) |
| C5 | **Never merges** | Output is `nightshift/*` branches (+ optional PR on this repo only). A human reviews before any merge. | ADR 0004, `rulebook.yaml` |
| C6 | **Runaway caps** | Claude has `--max-turns 25` per stage. Both adapters have fix-iteration, open-branch and per-run caps, single-instance `flock`, and the service's wall-clock timeout. Codex currently has no separate per-stage turn cap. | [nightshift.sh](../../bin/nightshift.sh), rulebook, [nightshift-cron.sh](../../bin/nightshift-cron.sh), [nightshift.service](../../scheduler/nightshift.service) |
| C7 | **Report-only for sensitive repos** | `findings-only` mode reports without ever pushing (e.g. llmstack). | `rulebook.yaml` |
| C8 | **Change-size pressure** | Soft file/line budgets injected into explore/fix prompts (15 files / 400 lines) to keep changes reviewable. | [nightshift.sh:205-207](../../bin/nightshift.sh) |

**Consequence — and its limit.** The *destructive-git* class is structurally blocked: no merge, no
push outside `nightshift/*`, no direct repo access. But "no `Bash`" was **over-read** in the first
cut as "no code execution." It is not: `Write`/`Edit` accept **absolute paths** and are unconfined
(the settings only guard `Bash`, [nightshift.sh:127-131](../../bin/nightshift.sh)), so the agent can
write anywhere `llmadmin` can — including files that later execute ([R8](#r8), [R10](#r10)). The real
risk lives in the **write primitive**, not in a shell.

**Codex adapter delta.** `--ignore-user-config` and `--ignore-rules` prevent host-global Codex
configuration and exec-policy rules from silently changing unattended behavior. Read-only stages
cannot modify the worktree; Fix is OS-sandboxed to workspace writes with network disabled, but it
can execute commands there. This is a different boundary from Claude's no-shell tool allowlist.
The shared Runner still creates the disposable worktree, owns commit/push, and applies the hook.

---

## 3. Risk register

Severity = impact × likelihood given the controls above. Status: **Open** / **Partial** / **Mitigated**.

| ID | Risk | Severity | Status |
|----|------|----------|--------|
| [R8](#r8) | Write/Edit accept **absolute paths** → code execution as `llmadmin` with no `Bash` | **High** | **Open** |
| [R1](#r1) | Secret exfiltration via prompt-injection → commit content → pushed branch | **High** | **Open** |
| [R9](#r9) | New **untracked** files bypass the review evidence chain, then get committed | **High** | **Open** |
| [R2](#r2) | All containment is application-layer, on a `docker`/`sudo` account (host-root blast radius if a layer fails) | **High** | **Partial** |
| [R10](#r10) | `~/.local/bin` first on PATH → a write primitive hijacks the Runner's own tools | Med–High | **Open** |
| [R3](#r3) | `--dangerously-skip-permissions` is the default for *all* runs (single line of defense for command exec) | Medium | **Partial** |
| [R5](#r5) | Prompt injection from untrusted repo content skews findings/fixes (persists across stages) | Medium | **Partial** |
| [R12](#r12) | `gh` token over-scope (`admin:public_key`) + PR body is an unscanned API exfil channel | Medium | **Partial** |
| [R4](#r4) | No kill-switch: no automated halt on anomaly/drift | Medium | **Open** |
| [R11](#r11) | Git-confinement layers (C3/C4) guard an agent capability that C1 already removes — effort mis-allocated | Medium | **Open** |
| [R6](#r6) | Unrestricted network egress from the agent process | Low–Medium | **Open** |
| [R13](#r13) | Predictable state paths (lock, worktrees) in world-writable `/tmp` on a shared VM | Low–Medium | **Open** |
| [R7](#r7) | Quota/cost runaway | Low | **Mitigated** |

---

## 4. Risks in detail

### R1 — Secret exfiltration via commit content <a id="r1"></a>
`Read` is unrestricted: no deny-paths in the agent settings, and no OS sandbox around the `claude`
process. As `llmadmin`, the agent can read `~/.ssh/id_ed25519`, the `gh` token, `.env` files, and
group-readable secrets. Two exposures follow:
- **Anything read enters the model context** and thus leaves the host to the LLM provider.
- **A path that bypasses the human-review backstop:** a crafted file in a target repo instructs the
  agent (fix stage, which has `Write`) to read a secret and write it into a tracked file. The Runner
  commits and pushes it to a `nightshift/*` branch. `pre-push` (C3) validates the **ref name, not the
  content** — so the secret is off-host the moment the branch is pushed, even if the branch is later
  deleted.

*Residual: unmitigated today.* This is the sharpest real risk. Addressed by [M1](#m1)/[M2](#m2)/[M3](#m3).

### R2 — Application-layer containment on a privileged account <a id="r2"></a>
C1–C4 all live at the Claude Code tool/hook layer. The account underneath is in `docker` (host-root
equivalent) and `sudo`. If any layer assumption breaks — a CLI version changes `--tools` semantics,
a bug grants `Bash`, or the `PreToolUse` I/O contract shifts (the guard itself is a prototype artifact
that should be re-verified against the installed CLI version) — the agent inherits full host reach.

*Residual: the containment is sound but single-tier and sits on an over-privileged account.* Most of
the impact is removed by running under a dedicated unprivileged account — [M1](#m1).

### R3 — `--dangerously-skip-permissions` default everywhere <a id="r3"></a>
The claude adapter defaults its flags to `--dangerously-skip-permissions --max-turns 25` for **all**
runs, not only the sandbox ([nightshift.sh:186](../../bin/nightshift.sh)); the cron path does not
override `NIGHTSHIFT_CLAUDE_FLAGS`. Defensible only because the `--tools` allowlist (C1) is the true
containment — but it means command execution has exactly one line of defense, with the permission
layer fully off.

*Residual: acceptable given C1, but reduces defense-in-depth.* Consider a non-skip permission mode
with an explicit allow/deny set once the OS sandbox ([M2](#m2)) exists.

### R4 — No kill-switch <a id="r4"></a>
[autonomy-and-shutoff.md](autonomy-and-shutoff.md) is explicitly idea-stage: no implemented
halt-on-anomaly (error-rate spike, forbidden-zone touch, budget anomaly, repeated failed verifies).
On drift, the run continues until a cap (C6) stops it.

*Residual: bounded by C6, but no early safety brake.* Tracked by [M4](#m4).

### R5 — Prompt injection steering findings/fixes (persists across stages) <a id="r5"></a>
Target-repo content is untrusted and reaches the prompt. Injection could steer what the agent flags
or how it "fixes" code. Worse, it is **second-order**: the explore stage's output — itself derived
from untrusted content — is re-embedded verbatim as `### finding.json` into the fix **and** review
prompts ([nightshift.sh:210-214](../../bin/nightshift.sh)), and the working-tree diff (also
attacker-influenced) is embedded into review ([nightshift.sh:218-219](../../bin/nightshift.sh)). So
the same adversary shapes both the instruction the fixer follows and the diff the reviewer signs off.
Backstopped by C5 (human review before merge) for correctness — but **not** for the R1 exfil variant
(damage done at push time), and R9 shows the review evidence itself is incomplete.

*Residual: human review covers merge-time correctness; the push-time secrecy risk is R1; the
evidence-completeness gap is R9.*

### R6 — Unrestricted network egress <a id="r6"></a>
Nothing at the OS level restricts where the agent process can talk. Today the allowlist grants no
fetch-capable tool (only Read/Grep/Glob/Write/Edit + read-only codemap MCP), so there is no *direct*
exfil channel from the agent. But that safety rests entirely on the allowlist staying fetch-free; a
future tool addition would open a channel with no second barrier.

*Residual: no OS-level egress control.* Closed together with [M2](#m2).

### R7 — Quota / cost runaway <a id="r7"></a>
Bounded by `--max-turns`, `max_fix_iterations`, `max_open_branches` (hard halt at 2/2),
`max_branches_per_run`, and single-instance `flock`. Per-stage token/cost are recorded to the ledger.

*Residual: low.* The value-based throttle in autonomy-and-shutoff.md would tighten it further.

### R8 — Write/Edit accept absolute paths → code execution as `llmadmin` <a id="r8"></a>
The fix stage grants `Write,Edit` ([nightshift.sh:195](../../bin/nightshift.sh)); the process only
does `cd "$wd"` ([nightshift.sh:239](../../bin/nightshift.sh)) and the agent settings guard **only**
`Bash` ([nightshift.sh:127-131](../../bin/nightshift.sh)). `Write`/`Edit` take absolute paths, so a
prompt-injected fix stage can write anywhere `llmadmin` can — `~/.bashrc`, `~/.ssh/authorized_keys`,
`~/.config/systemd/user/*.service`, `~/.claude/settings.json`, or a fake binary in `~/.local/bin/`.
That is arbitrary code execution as a `docker`+`sudo` account (→ host root, R2) reached with **no
`Bash` at all**. C1 removes only the shell; C2's worktree confines nothing against absolute paths;
C4 never inspects `Write`/`Edit`. This is broader and sharper than R1 (which framed the write only as
commit-content exfil): "no shell → no code execution" was the first cut's central error.

*Residual: unmitigated. The single highest-severity finding.* Closed by [N1](#n1) (+ [M2](#m2)).

### R9 — Untracked files bypass the review evidence chain <a id="r9"></a>
Review is shown `git -C "$wd" diff` ([nightshift.sh:219](../../bin/nightshift.sh)) — a plain diff
shows **tracked modifications only**, not new untracked files. finalize then stages everything with
`git add -A` ([nightshift.sh:374](../../bin/nightshift.sh)) and pushes. A fix stage that *creates* a
new file (a secret dump, a malicious `.github/` workflow, a planted binary) is invisible to the
reviewer yet committed and pushed to the `nightshift/*` branch.

*Residual: undermines C5 — the reviewer's own evidence omits the payload.* Closed by [N3](#n3).

### R10 — `~/.local/bin` first on PATH → write primitive hijacks the Runner <a id="r10"></a>
The launcher prepends `$HOME/.local/bin` to PATH ([nightshift-cron.sh:16](../../bin/nightshift-cron.sh))
and the Runner calls `jq`, `git`, `gh`, `python3`, `codemap` **unqualified** throughout (e.g.
[nightshift.sh:369,374,376,386](../../bin/nightshift.sh)). Chained with R8: a fix stage that writes
`~/.local/bin/jq` gets that binary executed **by the Runner** on the next `jq` call in the same run —
turning a write-only agent into RCE without the agent executing anything itself.

*Residual: unmitigated; amplifies R8.* Closed by [N4](#n4).

### R11 — Git-confinement layers guard an already-closed door <a id="r11"></a>
C3 (pre-push) and C4 (PreToolUse guard) only bite if the agent can run `git` / set `GIT_CONFIG_*` —
but no stage grants `Bash`, so it cannot. The Runner always issues `push -u origin "$branch"` with
`branch=nightshift/*` ([nightshift.sh:380](../../bin/nightshift.sh)), so even a disabled hook cannot
redirect the refspec. The two layers are therefore **latent** insurance against a future `Bash`
grant, not active containment — while the live exposure (R8/R9) has no enforcement layer at all.
Not a vulnerability; a mis-allocation of defense effort that the register originally mispresented as
core containment. C4 also carries an unverified prototype assumption (its PreToolUse I/O contract).

*Residual: re-label, don't remove.* Addressed by [N7](#n7)/[M5](#m5).

### R12 — `gh` token over-scope + PR body as unscanned exfil channel <a id="r12"></a>
The `gh` token carries `admin:public_key` and `repo` (§1). If exfiltrated (R1/R8), an attacker can
register SSH keys on the account — persistence beyond this repo. Separately, `open_pr` builds the PR
title/body from model-derived `summary`/`worknote`/`proof` and sends it via the **GitHub API**, not
`git push` ([nightshift.sh:383](../../bin/nightshift.sh)) — so a diff-content scanner (M3/N6) as
scoped to commits would never see it. Lower live risk today: `NIGHTSHIFT_OPEN_PR` defaults 0
([nightshift.sh:17](../../bin/nightshift.sh)).

*Residual: latent while PRs are off; scope + API-text gap remain.* Addressed by [N6](#n6).

### R13 — Predictable state paths in world-writable `/tmp` <a id="r13"></a>
`LOCK` and `WORKTREES_DIR` default under `/tmp` ([nightshift-cron.sh:21](../../bin/nightshift-cron.sh),
[nightshift.sh:31](../../bin/nightshift.sh)). On a shared VM a co-tenant can pre-create
`/tmp/nightshift.lock` and hold `flock`, or make it unreadable, to silently suppress every night's
run (DoS — `exec 9>` under `set -e`). Debian's `fs.protected_symlinks` blunts the classic
symlink-truncate, but isolation then rests on a kernel sysctl rather than a private `0700` dir.

*Residual: multi-tenant interference with nightshift's own state.* Closed by [N5](#n5).

---

## 5. Recommended / planned mitigations

**Priority order** (risk reduced per unit of effort), revised after the R8–R13 findings:
[N1](#n1) → [N4](#n4) → [N3](#n3) → [M1](#m1) → [M2](#m2) → [N2](#n2) → [N6](#n6) → [N5](#n5) →
[M3](#m3) → [M4](#m4) → [N7](#n7)/[M5](#m5). N1+N3+N4 together turn today's "write-only agent = RCE as
a `docker`/`sudo` account" into "a compromised fix stage is confined to the worktree and fully
visible to review" — the largest reduction available before the account (M1) and OS-sandbox (M2) work.

### M1 — Dedicated unprivileged service account <a id="m1"></a>
Run nightshift as an account that is **not** in `docker` or `sudo` and cannot read other services'
secrets. Smallest change, largest reduction: collapses the R2 blast radius at the root and shrinks
what R1 can even read. **Highest priority.**

### M2 — OS sandbox around the agent process <a id="m2"></a>
Wrap `claude` in a filesystem/network jail (bubblewrap or a systemd sandbox profile):
restrict `Read` scope to the worktree, deny network egress to everything except the Anthropic API.
Closes the R1 exfil chain and R6.

### M3 — Content secret-scanning in pre-push <a id="m3"></a>
Extend the confinement so `pre-push` (or a pre-commit step) scans **diff content** for key material,
not just the ref name. Catches whatever slips past M1/M2, and directly addresses the R1 push-time leak.

### M4 — Implement the safety kill-switch <a id="m4"></a>
Build the hard brake from autonomy-and-shutoff.md: halt and escalate on error-rate spike,
forbidden-zone access, budget anomaly, or repeated failed verifies. Addresses R4.

### M5 — Re-verify the PreToolUse contract <a id="m5"></a>
Confirm the `PreToolUse` deny I/O shape against the installed Claude Code version and pin/monitor it;
the guard (C4) currently notes it as an unverified prototype assumption. Hardens R2/R11.

### N1 — PreToolUse deny on Write/Edit outside the worktree <a id="n1"></a>
**Closes R8 — the biggest gap, and cheaper than M2.** Add a second hook in `write_claude_settings`
([nightshift.sh:127-131](../../bin/nightshift.sh)) with `matcher:"Write|Edit"` pointing at a guard
that reads `.tool_input.file_path`, `realpath`-normalises it, and denies anything not under `$wd`
(pass the worktree root via env, same pattern as `NIGHTSHIFT_BRANCH_PREFIX`). Resolve symlinks
before comparison. No new infrastructure.

### N2 — Make confinement assets unwritable by the agent <a id="n2"></a>
`chattr +i` on `hooks/pre-push`, `hooks/pretooluse-guard.sh`, and `state/claude-settings.json`, or
relocate `HOOKS_DIR` to a root-owned path. The agent has no `Bash`, so it cannot `chattr -i`; a
`Write` over an immutable file fails. Backstops R8 even if N1 is bypassed.

### N3 — Feed the reviewer the full change; refuse hidden files <a id="n3"></a>
**Closes R9.** Replace `git -C "$wd" diff` ([nightshift.sh:219](../../bin/nightshift.sh)) with
`git -C "$wd" add -A && git -C "$wd" diff --staged` so review sees exactly what finalize commits.
Better: in finalize, after `add -A`, assert the changed-file set equals the finding's declared
file(s) and abandon/flag on any extra path.

### N4 — Pin the Runner's own tool paths <a id="n4"></a>
**Closes R10.** Put system dirs before `~/.local/bin` in
[nightshift-cron.sh:16](../../bin/nightshift-cron.sh), or resolve `jq`/`git`/`gh`/`python3` to
absolute paths once at Runner start and call via those. Stops a planted binary from hijacking the
orchestrator.

### N5 — Move lock + worktrees to a private dir <a id="n5"></a>
**Closes R13.** Default `LOCK` and `WORKTREES_DIR` to `${XDG_RUNTIME_DIR:-$HOME/.local/state/nightshift}`
with `mkdir -m 700`. Removes the shared-`/tmp` DoS and symlink surface without relying on a sysctl.

### N6 — Extend secret-scanning beyond the diff; drop token scope <a id="n6"></a>
**Addresses R12.** Scope M3's content scan to the PR body / worknote / digest text, not only the
committed diff (the `gh` API path never touches pre-push). Re-issue the `gh` token without
`admin:public_key` — the PR flow needs only `repo` / pull-request scope.

### N7 — Re-label the latent defense-in-depth <a id="n7"></a>
**Addresses R11.** Document C3/C4 as latent (they activate only if a future stage gains `Bash`) and
redirect guard effort to Write/Edit (N1). Keep the Bash guard as a tripwire, but do not count it as
primary containment.

---

## 6. Residual risk statement

With C1–C8, the *destructive-git* class (repo destruction, force-push to `main`, auto-merge, push
outside `nightshift/*`) is structurally blocked. The independent review corrected the rest: **"no
`Bash`" is not "no code execution."** The material residual risk is **arbitrary code execution as the
`llmadmin` account** via the unconfined `Write`/`Edit` primitive (R8), optionally self-triggering
through the Runner's PATH (R10) — reached with no shell at all. Secret exfiltration (R1) and the
review-evidence gap (R9) sit alongside it. All of this is amplified by R2: the containment, though
individually sound, is single-tier and sits on a `docker`/`sudo` (host-root-capable) account.
For Codex, workspace sandboxing narrows the arbitrary-write exposure, while permitted in-worktree
commands and the missing per-stage turn cap are adapter-specific residuals.

Ordered response: **N1** (deny Write/Edit outside the worktree) is the cheapest, highest-leverage
step and should land first — it neutralises R8 without new infrastructure. **N3** and **N4** close the
review-evidence and PATH-hijack chains. **M1** (dedicated unprivileged account) then collapses the R2
blast radius. Until N1/N3/N4 + M1 are in place, unattended operation on the shared host carries a
real, understood **code-execution** risk — not merely an exfiltration risk — that the daytime-testing
phase is expected to keep bounded by attention, not by architecture.
