# nightshift — Risk Analysis

- Status: **living document.** First cut 2026-07-10, during the daytime-testing phase.
- Scope: the security and safety posture of running the nightshift steward **unattended** on a
  shared host. What can go wrong, what is already in place to stop it, and what risk remains open.
- Method: derived from the actual runner (`bin/nightshift.sh`, `bin/nightshift-cron.sh`), the
  confinement hooks (`hooks/`), and the live `rulebook.yaml` — not from intent alone.
- Reviewed: independent adversarial pass by a second model (Fable, 2026-07-10) against the code.
  It found the register understated the write-primitive threat — see [R8](#r8)–[R13](#r13), which
  materially revised §2 and the §6 residual statement below.
- Re-statused 2026-08-06 against the runner: [N3](#n3) and [N4](#n4) had landed in code while the
  register still carried [R9](#r9)/[R10](#r10) as **Open** and both mitigations as future work.
- Second independent adversarial pass, cross-vendor (gpt-5.6-sol, 2026-08-14). Its top finding was
  [R15](#r15): the register tracked what the *agent* may execute and never asked what the **Runner**
  executes on its behalf — the ADR 0022 ship gate ran candidate-authored `package.json` lifecycle
  scripts unconfined. Closed by [N8](#n8)/[C9](#2-containment-in-place).

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
| C3 | **Push confinement (Layer 1)** | `hooks/pre-push` checks git's already-**resolved** refs: rejects any ref outside `nightshift/*`, deletes, tag pushes, and non-fast-forward updates. Every bypass spelling (`+main`, `:branch`, `--all`, `--mirror`, `--force`) is resolved by git before the hook sees it. | [pre-push](../../hooks/pre-push) |
| C4 | **Can't disable Layer 1 (Layer 2, Claude only)** | `core.hooksPath` is injected into both adapters. Claude also has a `PreToolUse` guard denying bypass flags and writes to project settings that a later stage would execute as hooks. Codex has no equivalent tool hook here; its sandbox is the primary agent boundary, while the Runner's final push supplies the hook independently. | [pretooluse-guard.sh](../../hooks/pretooluse-guard.sh), [nightshift.sh](../../bin/nightshift.sh) |
| C5 | **Never merges** | Output is `nightshift/*` branches (+ optional PR on this repo only). A human reviews before any merge. | ADR 0004, `rulebook.yaml` |
| C6 | **Runaway caps** | Claude has `--max-turns 60` per stage. Both adapters have fix-iteration, open-branch and per-run caps, single-instance `flock`, and the service's wall-clock timeout. Codex currently has no separate per-stage turn cap. | [nightshift.sh](../../bin/nightshift.sh), rulebook, [nightshift-cron.sh](../../bin/nightshift-cron.sh), [nightshift.service](../../scheduler/nightshift.service) |
| C7 | **Report-only for sensitive repos** | `findings-only` mode reports without ever pushing (e.g. llmstack). | `rulebook.yaml` |
| C8 | **Change-size pressure** | Soft file/line budgets injected into explore/fix prompts (15 files / 400 lines) to keep changes reviewable. | [nightshift.sh:205-207](../../bin/nightshift.sh) |
| C9 | **Ship-gate sandbox** | The one component that deliberately *executes* candidate content runs under `bwrap`: no `$HOME`, `/etc` by allowlist, no docker socket, no network unless the repo opts in, allowlisted environment, writable only the worktree + a throwaway HOME, rlimits. No sandbox ⇒ no ship. | `build_test_sandbox`/`run_test_gate` in [nightshift.sh](../../bin/nightshift.sh), ADR 0026 |

**Consequence — and its limit.** The *destructive-git* class is structurally blocked: no merge, no
push outside `nightshift/*`, no direct repo access. But "no `Bash`" was **over-read** in the first
cut as "no code execution." `Write`/`Edit` accept **absolute paths**, so they required their own
boundary: the implemented PreToolUse guard now confines them to the Runner-injected worktree
([R8](#r8), [N1](#n1)). The historical lesson remains that the risk lived in the **write primitive**,
not in a shell; the no-`Bash` allowlist alone was insufficient.

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
| [R15](#r15) | The **ship gate executes** candidate-controlled repo content (`npm ci` lifecycle scripts) as `llmadmin` | **High** | **Mitigated** |
| [R8](#r8) | Write/Edit accept **absolute paths** → code execution as `llmadmin` with no `Bash` | **High** | **Mitigated** |
| [R1](#r1) | Secret exfiltration via prompt-injection → commit content → pushed branch | **High** | **Open** |
| [R9](#r9) | New **untracked** files bypass the review evidence chain, then get committed | **High** | **Mitigated** |
| [R2](#r2) | All containment is application-layer, on a `docker`/`sudo` account (host-root blast radius if a layer fails) | **High** | **Partial** |
| [R10](#r10) | `~/.local/bin` on PATH → a write primitive hijacks the Runner's own tools | Med–High | **Partial** |
| [R3](#r3) | `--dangerously-skip-permissions` is the default for *all* runs (single line of defense for command exec) | Medium | **Partial** |
| [R5](#r5) | Prompt injection from untrusted repo content skews findings/fixes (persists across stages) | Medium | **Partial** |
| [R12](#r12) | `gh` token over-scope (`admin:public_key`) + PR body is an unscanned API exfil channel | Medium | **Partial** |
| [R4](#r4) | No kill-switch: no automated halt on anomaly/drift | Medium | **Open** |
| [R11](#r11) | Git-confinement layers (C3/C4) guard an agent capability that C1 already removes — effort mis-allocated | Medium | **Open** |
| [R6](#r6) | Unrestricted network egress from the agent process | Low–Medium | **Open** |
| [R13](#r13) | Predictable state paths (lock, worktrees) in world-writable `/tmp` on a shared VM | Low–Medium | **Open** |
| [R7](#r7) | Quota/cost runaway | Low | **Mitigated** |
| [R14](#r14) | Non-canonical ledger + real origin → shipped rows silently dropped from the ledger harvest reads | Low–Medium | **Mitigated** |

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
The claude adapter defaults its flags to `--dangerously-skip-permissions --max-turns 60` for **all**
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
prompts (`stage_prompt` in [nightshift.sh](../../bin/nightshift.sh)), and the staged diff (also
attacker-influenced) is embedded into review there. So
the same adversary shapes both the instruction the fixer follows and the diff the reviewer signs off.
Backstopped by C5 (human review before merge) for correctness — but **not** for the R1 exfil variant
(damage done at push time). R9's evidence gap is closed, so what the reviewer sees is now complete;
whether it is *read* adversarially is not something the mechanism can guarantee.

*Residual: human review covers merge-time correctness; the push-time secrecy risk is R1.*

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
The fix stage grants `Write,Edit`, and `Write`/`Edit` take absolute paths. Before N1, merely doing
`cd "$wd"` did not confine them: a prompt-injected fix stage could write anywhere `llmadmin` could —
`~/.bashrc`, `~/.ssh/authorized_keys`, `~/.config/systemd/user/*.service`,
`~/.claude/settings.json`, or a fake binary in `~/.local/bin/`. That exposed arbitrary code
execution as a `docker`+`sudo` account (→ host root, R2) with **no `Bash` at all**. C1 removed only
the shell, while C2's worktree did not by itself constrain absolute tool paths. This was broader and
sharper than R1 (which framed the write only as commit-content exfil): "no shell → no code
execution" was the first cut's central error.

*Mitigated by [N1](#n1) (implemented): the PreToolUse guard confines `Write`/`Edit`/`MultiEdit`/
`NotebookEdit` to the worktree, and `write_claude_settings` registers it for those tools (not just
`Bash`). Verified end-to-end under real `claude` on 2026-07-12 (guard denied an out-of-tree `Write`;
see hook-spec.md), in addition to the deterministic unit tests. [M2](#m2) (OS sandbox) remains
defense-in-depth.*

### R9 — Untracked files bypass the review evidence chain <a id="r9"></a>
Review was shown a plain `git -C "$wd" diff`, which reports **tracked modifications only**, not new
untracked files, while finalize stages everything with `git add -A`
(`finalize` in [nightshift.sh](../../bin/nightshift.sh)) and pushes. A fix stage that *creates* a new file (a
secret dump, a malicious `.github/` workflow, a planted binary) was invisible to the reviewer yet
committed and pushed to the `nightshift/*` branch.

*Mitigated by [N3](#n3) (implemented): the review path stages all candidate content and embeds
`git diff --staged` (`stage_prompt` in [nightshift.sh](../../bin/nightshift.sh)), so the reviewer's
evidence is by construction the same index finalize commits — new files included. Both stagings
honour the target repo's `.gitignore` identically, so an ignored file is absent from review **and**
from the commit; the evidence chain stays complete.*

*Residual: the set of changed files is shown, not constrained — N3's stronger half (assert in
finalize that the committed paths equal the finding's declared `files`) is not implemented, so an
extra path still ships if the reviewer reads past it. That is a review-attention gap, not an
evidence gap.*

### R10 — `~/.local/bin` on PATH → write primitive hijacks the Runner <a id="r10"></a>
The Runner calls `jq`, `git`, `gh`, `python3`, `codemap` **unqualified** throughout (e.g.
[nightshift.sh:1184,1199,1220](../../bin/nightshift.sh)), and the launcher must put `$HOME/.local/bin`
on PATH because the agent CLIs live there. Chained with R8: a fix stage that writes `~/.local/bin/jq`
would get that binary executed **by the Runner** on the next `jq` call in the same run — turning a
write-only agent into RCE without the agent executing anything itself.

*Partially mitigated by [N4](#n4) (implemented): the launcher now exports
`PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH`
([nightshift-cron.sh:20](../../bin/nightshift-cron.sh)), so a planted `~/.local/bin/jq` — or `git`,
`python3` — is shadowed by the system copy and never reached.*

*Residual: the reorder protects only tools that also exist in a system dir. Anything resolved solely
from `~/.local/bin` is still hijackable by a plant of the same name — `gh` is called unqualified
([nightshift.sh:1107,1139](../../bin/nightshift.sh)) and is named in the launcher as one of the
tools that may live only there. N4's stronger half (resolve the Runner's tools to absolute paths
once at start) would close that remainder; [N1](#n1) is what currently keeps the write primitive out
of `~/.local/bin` in the first place, so this is defense-in-depth behind N1, not the front line.*

### R11 — Git-confinement layers guard an already-closed door <a id="r11"></a>
C3 (pre-push) and C4 (PreToolUse guard) only bite if the agent can run `git` / set `GIT_CONFIG_*` —
but no stage grants `Bash`, so it cannot. The Runner always issues `push -u origin "$branch"` with
`branch=nightshift/*` ([nightshift.sh:380](../../bin/nightshift.sh)), so even a disabled hook cannot
redirect the refspec. The two layers are therefore **latent** insurance against a future `Bash`
grant, not active containment — the live exposure (R8/R9) was left without one until N1 and N3
supplied it.
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

### R14 — Non-canonical ledger + real origin silently drops ground-truth signal <a id="r14"></a>
The ledger location (`NIGHTSHIFT_STATE_DIR`) and origin are independent. A run whose ledger is not
the canonical `$NIGHTSHIFT_HOME/state` while origin stays on the real forge pushes a `nightshift/*`
branch to the real origin while its `shipped` row lands in the isolated ledger — discarded when that
dir is cleaned up. The canonical ledger `harvest` reads never learns the branch exists; it resurfaces
only as an orphan (ADR 0016) holding a cap slot. Observed 2026-07-19: two real branches on origin,
zero ledger rows on the only checkout. Host evidence shows the run was **fully divorced** from this
environment (foreign home / other host); the precise vector is not determinable. **Not a security
exposure** — a data-integrity/observability gap in the ground-truth loop.

Two-layer mitigation:
- **Prevention** — `guard_state_remote_incoherence` ([nightshift.sh](../../bin/nightshift.sh), ADR
  [0017](../adr/0017-warn-on-state-remote-incoherence.md)): a run-start **abort** (override
  `NIGHTSHIFT_ALLOW_SPLIT_STATE=1`) when the ledger is non-canonical and origin is a network remote.
  Covers only runs that execute in this checkout.
- **Repair** — harvest **adopts** orphans ([harvest.sh](../../bin/harvest.sh), ADR
  [0018](../adr/0018-harvest-adopts-orphan-branches.md)): synthesizes the lost `shipped` row so the
  verdict becomes recordable. Acts on what is really on origin, so it covers orphans from **any**
  source, including the foreign-run vector the guard cannot see.

*Residual: adopted rows carry no dimension/type/proof provenance (genuinely unknown), so they are
uncategorized in merge-rate breakdowns; and the guard is bypassable with the override flag.*

### R15 — the ship gate executes candidate-controlled repository content <a id="r15"></a>
Named the single highest-priority finding by an independent cross-vendor architecture review
(gpt-5.6-sol, 2026-08-14). `run_test_gate` (ADR 0022) exists to run the target repo's **own** suite
against the worktree the Fix stage just wrote, and it did so through an unsandboxed `bash -c` as
`llmadmin`. For a JS repo the declared command is `npm ci && npm test`, which executes `preinstall`
/ `prepare` / `pretest` lifecycle scripts out of a `package.json` the agent may have modified.

That inverted the whole containment story. C1 removes `Bash` from every stage; N1 confines
`Write`/`Edit` to the worktree — and then the Runner itself took the file the agent wrote and
executed it, with the account's full ambient authority: `~/.ssh`, the `gh` token, `~/.claude` /
`~/.codex`, `/etc` secrets, the docker socket (host root), `sudo`. A `pretest` that exfiltrates a
key and exits 0 is reported by the night as **a passing gate**. Live every night since 2026-08-04,
independent of any auto-merge plan, and reached before a human ever sees the branch.

*Mitigated by [N8](#n8) (implemented, ADR [0026](../adr/0026-the-ship-gate-runs-in-a-sandbox.md)):
the gate runs in a disposable bubblewrap sandbox — `$HOME` unbound, `/etc` reduced to a named
allowlist, no docker socket, network denied unless the repo opts in with `test_net: true`, the
environment an allowlist rather than an inheritance, writable only the worktree and a throwaway
HOME, plus `RLIMIT_NPROC`/`RLIMIT_DATA`/`RLIMIT_CPU` and a size-capped `/tmp`. A missing or
unconstructable sandbox refuses the ship instead of running unconfined. Covered by
`tests/test-gate-sandbox.sh`.*

*A second, sharper leg of the same risk was found while verifying the fix against the real fleet,
and is closed by the same ADR: confining the gate **while it runs** is not enough, because
`$wt/.git` is a plain pointer file in the writable worktree and `finalize` then runs `checkout -b`,
`add -A` and `commit` in that worktree **outside** the sandbox as `llmadmin`. A `pretest` that
repoints it at a gitdir it built inside the worktree gets `core.fsmonitor` (arbitrary command) or
a `pre-commit` hook executed by the Runner seconds later — a complete bypass that leaves the sandbox
looking intact. Verified firing, then closed twice over: the pointer is re-bound read-only inside
the sandbox (after the worktree's read-write bind, or it is simply covered again), and it is
validated against the repo's own git dir before the gate reports success. A mismatch refuses the
item with the "could not run" status, which does not loop back into Fix — retrying would only run
the hostile command again. The expected pointer is **read** from the repo side (`<admin>/gitdir`,
which git maintains outside the worktree) rather than derived from the worktree's basename: git
suffixes the admin directory when that name is already registered, so the derived form accused a
sound worktree of tampering and refused the item until someone pruned the stale entry. Note this also covers a pointer the **Fix stage** wrote: N1 confines that
stage to the worktree, and this file is inside the worktree.*

*Residual: closed by ADR [0027](../adr/0027-the-reviewed-tree-is-what-ships.md). The worktree stays
writable, but it is no longer what `finalize` commits: the Runner records the tree object review was
shown and commits that, so a `pretest`'s edits are discarded rather than staged. The C5 backstop
named here did NOT cover it — a rewritten `.github/workflows/ci.yml` is executed by GitHub with the
repository's secrets before a human opens the PR. `test_net: true` was a real hole and is closed by ADR
[0028](../adr/0028-gate-egress-goes-through-a-vetting-proxy.md) — it shared the HOST's network
namespace, i.e. loopback and the LAN, not merely the internet; egress now leaves through a proxy
that refuses every non-public destination. What remains of it is that worktree content can still
leave through an ALLOWED destination, though
credential-free. `RLIMIT_AS` bounds address space, not RSS. Kernel unprivileged user namespaces and
bubblewrap are now in the trust base.*

---

## 5. Recommended / planned mitigations

**Priority order** (risk reduced per unit of effort), revised after the R8–R13 findings and again
after R15: ~~[N1](#n1) → [N4](#n4) → [N3](#n3) → [N8](#n8)~~ (all four landed) → [M1](#m1) →
[M2](#m2) → [N2](#n2) → [N6](#n6) → [N5](#n5) → [M3](#m3) → [M4](#m4) → [N7](#n7)/[M5](#m5).
N1+N3+N4 together turned "write-only agent = RCE as a `docker`/`sudo` account" into "a compromised
fix stage is confined to the worktree and fully visible to review". N8 then closed the remaining
execution path — the Runner's own ship gate, which took what the agent wrote and ran it. What is
left at the head of the queue is the account (M1) and the sandbox around the *agent* process (M2).

### M1 — Dedicated unprivileged service account <a id="m1"></a>
Run nightshift as an account that is **not** in `docker` or `sudo` and cannot read other services'
secrets. Smallest change, largest reduction: collapses the R2 blast radius at the root and shrinks
what R1 can even read. **Highest priority.**

### M2 — OS sandbox around the agent process <a id="m2"></a>
Wrap `claude` in a filesystem/network jail (bubblewrap or a systemd sandbox profile):
restrict `Read` scope to the worktree, deny network egress to everything except the Anthropic API.
Closes the R1 exfil chain and R6. **Half-done:** [N8](#n8) applies exactly this treatment to the
ship gate, which was the more urgent target because it executes rather than reads. The agent
process itself is still unconfined, so M2 remains open — and N8's `build_test_sandbox` is the
mechanism to reuse when it is taken on.

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
**Closes R8 — the biggest gap, and cheaper than M2. Implemented.** `write_claude_settings` registers
the guard with `matcher:"Bash|Write|Edit|MultiEdit|NotebookEdit"`, and `pretooluse-guard.sh` reads
`.tool_input.file_path` (or `.notebook_path`), `realpath -m`-normalises it (resolving `..` and
symlinks in existing prefixes), and denies any target not equal to or strictly beneath the worktree
root. The root is the Runner-injected `NIGHTSHIFT_WORKTREE` (primary), the hook payload's `.cwd`, then
`$PWD` (fallbacks). Containment is trailing-slash-safe, so a prefix-sibling (`…/worktree-evil`) is not
treated as inside. Adversarial coverage: `tests/test-fix-write-confinement.sh` (worktree writes allowed;
the runner, `~/.claude`, `/etc`, `..`-traversal, and prefix-siblings denied; Bash anti-bypass intact).

### N2 — Make confinement assets unwritable by the agent <a id="n2"></a>
`chattr +i` on `hooks/pre-push`, `hooks/pretooluse-guard.sh`, and `state/claude-settings.json`, or
relocate `HOOKS_DIR` to a root-owned path. The agent has no `Bash`, so it cannot `chattr -i`; a
`Write` over an immutable file fails. Backstops R8 even if N1 is bypassed.

### N3 — Feed the reviewer the full change; refuse hidden files <a id="n3"></a>
**Closes R9. Implemented.** The review prompt stages the worktree (`git -C "$wd" add -A`) and embeds
`git -C "$wd" diff --staged` ([nightshift.sh:470-478](../../bin/nightshift.sh)), so review sees
exactly the index finalize commits ([nightshift.sh:1199](../../bin/nightshift.sh)) — untracked files
included. *Still open, the stronger half:* in finalize, after `add -A`, assert the changed-file set
equals the finding's declared file(s) and abandon/flag on any extra path.

### N4 — Pin the Runner's own tool paths <a id="n4"></a>
**Addresses R10. Partially implemented.** The launcher puts the system dirs ahead of `~/.local/bin`
([nightshift-cron.sh:20](../../bin/nightshift-cron.sh)), so a plant cannot shadow a Runner tool that
also exists in `/usr/bin`. *Still open, the remainder:* resolve `jq`/`git`/`gh`/`python3`/`codemap`
to absolute paths once at Runner start and call via those — the only form that also covers a tool
resolved solely from `~/.local/bin` (today: `gh`).

### N5 — Move lock + worktrees to a private dir <a id="n5"></a>
**Closes R13.** Default `LOCK` and `WORKTREES_DIR` to `${XDG_RUNTIME_DIR:-$HOME/.local/state/nightshift}`
with `mkdir -m 700`. Removes the shared-`/tmp` DoS and symlink surface without relying on a sysctl.

### N6 — Extend secret-scanning beyond the diff; drop token scope <a id="n6"></a>
**Addresses R12.** Scope M3's content scan to the PR body / worknote / digest text, not only the
committed diff (the `gh` API path never touches pre-push). Re-issue the `gh` token without
`admin:public_key` — the PR flow needs only `repo` / pull-request scope.

### N8 — Sandbox the ship gate <a id="n8"></a>
**Closes R15. Implemented** — ADR [0026](../adr/0026-the-ship-gate-runs-in-a-sandbox.md).
`build_test_sandbox` / `run_test_gate` ([nightshift.sh](../../bin/nightshift.sh)) run the repo's
`test_cmd` under `bwrap` with isolated user/IPC/PID/UTS/cgroup/network namespaces. Network is never
re-shared; `test_net: true` exposes only a host-side vetting proxy over a bound Unix socket.
`--clearenv` plus an explicit allowlist, `/usr` read-only, a file-by-file `/etc` allowlist,
size-capped tmpfs on `/tmp` and `/run`, and exactly two writable paths: the
worktree and a disposable HOME. `NIGHTSHIFT_TEST_SANDBOX_ROBIND` is the host's escape hatch for a
dependency outside `/usr`, and a bind that would re-expose `$HOME` is refused with a log line.
Absent or unconstructable sandbox → the gate returns "could not run", the item is refused without
consuming fix iterations, and nothing ships. The same ADR closes the ungated ship path: a
`branch-fix` repo without a `test_cmd` now aborts the parse instead of shipping with
`shipping UNGATED` in the log. **This is the gate-shaped half of [M2](#m2)**; the agent process
itself is still unsandboxed, so M2 stays open for `claude`/`codex`.

### N7 — Re-label the latent defense-in-depth <a id="n7"></a>
**Addresses R11.** Document C3/C4 as latent (they activate only if a future stage gains `Bash`) and
redirect guard effort to Write/Edit (N1). Keep the Bash guard as a tripwire, but do not count it as
primary containment.

---

## 6. Residual risk statement

With C1–C9, the *destructive-git* class (repo destruction, force-push to `main`, auto-merge, push
outside `nightshift/*`) is structurally blocked. The two independent reviews each corrected the same
kind of error, one level apart. The first: **"no `Bash`" is not "no code execution"** — answered by
**N1** (Claude's `Write`/`Edit` confined to the worktree, R8), **N3** (the reviewer's diff is the
staged index finalize commits, R9) and **N4** (system dirs ahead of `~/.local/bin`, R10 partially —
a tool resolved only from `~/.local/bin` is still hijackable). The second: **confining what the
agent may execute says nothing about what the Runner executes on its behalf** — the ship gate ran
candidate-authored lifecycle scripts as this account, answered by **N8** (R15).

The material residuals are therefore secret exfiltration by the *agent* (R1) and single-tier
containment on a `docker`/`sudo` (host-root-capable) account (R2). For Codex, workspace sandboxing
narrows arbitrary-write exposure, while permitted in-worktree commands and the missing per-stage turn
cap are adapter-specific residuals.

Ordered response after the implemented **N1/N3/N4/N8**: **M1** (dedicated unprivileged account)
collapses the R2 blast radius, then **M2** (OS sandbox around the agent process) closes the R1 exfil
chain and R6 — now half-built, since N8 supplies the mechanism. Until M1 + M2 are in place,
unattended operation on the shared host still carries an understood exfiltration gap and single-tier
containment on an over-privileged account — kept bounded, in the daytime-testing phase, by attention
rather than by architecture. **No autonomous landing** (auto-merge of any kind) may be enabled while
R1/R2 stand.
