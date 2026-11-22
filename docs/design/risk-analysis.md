# Threat model

Scope: unattended nightshift runs as **the host account running nightshift**. This document
models capabilities and failure modes, not any particular machine. Target repository content,
dependencies, commit messages, and agent output are untrusted. The operator's rulebook, runner,
adapter configuration, and confinement assets form the trusted control plane.

Read alongside [hook-spec.md](hook-spec.md) and
[autonomy-and-shutoff.md](autonomy-and-shutoff.md) (proposed anomaly shutoff).

## 1. Trust model

A systemd user timer or manual invocation launches the runner and selected agent CLI. The runner
owns Git worktrees, commits, pushes, ledger writes, and repository test execution. Agents receive
stage-specific capabilities; prompts alone are not a security boundary.

The host account may have SSH keys, forge API credentials, model credentials, environment files,
and access to other services. If it belongs to `docker`, access to the daemon is effectively host
root. Administrative groups and service-secret groups can further widen the blast radius.
These are deployment risks to assess, not requirements for running nightshift. Prefer a dedicated
unprivileged account with access only to the authorized repositories and required model services.

Repositories may be `branch-fix` or `findings-only`. The runner pushes only `nightshift/*`, never
merges, and creates PRs only when explicitly enabled. Human merge control is the default.
An optional external merge job is a separate authorization decision ([ADR 0040](../adr/0040-optional-external-merge-job.md)).

## 2. Containment in place

| ID | Control | Mechanism |
| --- | --- | --- |
| C1 | Stage capabilities | Claude receives a tool allowlist without Bash. Codex uses its read-only sandbox except during Fix, which uses workspace-write with command networking disabled. |
| C2 | Disposable worktrees | Each work item runs in a detached worktree; the target checkout is not the edit destination. |
| C3 | Push confinement | `hooks/pre-push` checks Git's resolved refs, refusing destinations outside `nightshift/*`, deletion, tag pushes, and non-fast-forward updates. |
| C4 | Adapter write boundaries | Claude's tool guard confines write paths and rejects hook bypasses. Codex confines writes through its OS sandbox. |
| C5 | Separate merge authority | The runner never merges; review and merge authority stay with the operator or a separately authorized external job. |
| C6 | Runaway bounds | Iteration, pending-branch, per-run branch, and optional wall-clock caps; launcher flock; scheduler hard timeout. Claude also has a turn cap. |
| C7 | Report-only mode | `findings-only` reports without pushing. |
| C8 | Reviewable changes | Soft file and line budgets guide Explore and Fix; these are not hard reject limits. |
| C9 | Sandboxed execution | Ship gates and repository setup run in bubblewrap with an allowlisted environment, no host home or Docker socket, limited writable paths, and resource limits. Network is off unless public egress is explicitly proxied. |
| C10 | Startup control checks | The default `--setting-sources local` leaves unchanged project settings inert because project hooks never load ([measured on 2026-11-20 with Claude Code 2.1.329](hook-spec.md#stage-isolation--the-operators-personal-config-is-not-stage-context)). `--strict-mcp-config` prevents implicit MCP loading. Checks reject unsafe settings in enabled scopes, unsafe `.mcp.json` content, and symlink or non-regular control paths. Post-Fix and branch checks reject control-file changes for every adapter. |

Implementation: [adapters.sh](../../lib/adapters.sh), [sandbox.sh](../../lib/sandbox.sh),
[nightshift.sh](../../bin/nightshift.sh), [pre-push](../../hooks/pre-push),
[pretooluse-guard.sh](../../hooks/pretooluse-guard.sh), and
[check_claude_controls.py](../../lib/check_claude_controls.py).

Codex stages start with a fresh home that excludes the operator's instructions and CLI settings.
Claude's tool restrictions do not provide an OS filesystem read boundary.
Disabling a sandbox through an explicit environment override removes that control.

## 3. Risk register

“Mitigated” means the described path has a mechanism; it does not mean all related attacks are
impossible. Severity depends on credentials, group memberships, and remote CI behavior.

| ID | Risk | Severity | Status |
| --- | --- | --- | --- |
| [R1](#r1) | Secret reads and exfiltration through model context or pushed content | High | Open |
| [R2](#r2) | Privileged host account widens a containment failure to the whole host | High | Partial |
| [R3](#r3) | Unattended permission bypass reduces defense in depth | Medium | Partial |
| [R4](#r4) | No general anomaly-triggered kill switch | Medium | Open |
| [R5](#r5) | Prompt injection persists through findings, fixes, and review | Medium | Partial |
| [R6](#r6) | Agent network reach exceeds necessary model endpoints | Low–Medium | Open |
| [R7](#r7) | Quota, cost, or runtime runaway | Low | Mitigated |
| [R8](#r8) | Absolute write paths enable out-of-worktree persistence | High | Mitigated |
| [R9](#r9) | New files omitted from review but included in the commit | High | Mitigated |
| [R10](#r10) | User-writable PATH entries can hijack runner tools | Medium–High | Partial |
| [R11](#r11) | Git safeguards mistaken for complete agent confinement | Medium | Open |
| [R12](#r12) | Over-scoped forge credentials and unscanned PR text | Medium | Partial |
| [R13](#r13) | Predictable lock and worktree paths in shared temporary storage | Low–Medium | Open |
| [R14](#r14) | Alternate state plus a real remote splits the ledger from shipped work | Low–Medium | Mitigated |
| [R15](#r15) | Candidate-controlled tests or setup execute with host authority | High | Partial |

## 4. Risks in detail

### R1 — Secret exfiltration <a id="r1"></a>

Claude's reads can reach credentials and environment files readable by the host account. Anything
read may enter the model provider's context. A malicious finding can also persuade Fix to copy a
secret into a tracked file. The runner then pushes it before a human reviews the branch. The
pre-push hook validates refs, not content; branch deletion cannot undo disclosure. See M1–M3.

### R2 — Privileged account <a id="r2"></a>

Tool guards do not remove underlying account privileges. A CLI change or guard bypass can expose
host-root-equivalent Docker access, administrative capabilities, or other services' secrets if
those capabilities belong to the account. Gate sandboxing limits some of that exposure.
Use M1 and M2.

### R3 — Unattended permission bypass <a id="r3"></a>

The Claude adapter defaults to `--dangerously-skip-permissions` with a turn cap. The tool allowlist
and guard carry the boundary while interactive permission checks are bypassed. Review this
assumption against the installed CLI; consider a restrictive permission policy as defense in depth.

### R4 — No anomaly shutoff <a id="r4"></a>

Runtime and branch caps stop a run eventually, but no general automatic brake detects semantic
drift, forbidden-zone attempts, or repeated verification failures. The shutoff design is proposed,
not implemented. See M4.

### R5 — Persistent prompt injection <a id="r5"></a>

Repository text shapes Explore output, which is then embedded in Fix and Review prompts. A hostile
finding and diff can influence both author and reviewer. A separate review model and full diff evidence
help, but do not prove correctness. Merge review cannot prevent R1's push-time disclosure.

### R6 — Agent egress <a id="r6"></a>

Claude runs without a general OS egress policy. Codex disables network access for Fix commands. The gate's public-only proxy applies only to repository setup and tests. See M2.

### R7 — Runaway usage <a id="r7"></a>

Iteration, pending-verdict, per-run branch, time, and scheduler limits bound work. Usage is recorded
in the ledger. A model that cannot be reached two stages in a row stops the night instead of
switching to another one. A wall-clock budget may let an in-flight stage finish; no cap guarantees a dollar ceiling.

### R8 — Absolute write paths <a id="r8"></a>

Changing cwd does not confine Write/Edit. An out-of-tree write could alter shell startup, SSH
configuration, user services, CLI hooks, or a binary in a user-writable PATH directory without any
shell tool. Claude's guard resolves paths and confines writes to the injected worktree. Codex uses its workspace sandbox. See N1 and N2.

### R9 — Untracked review gap <a id="r9"></a>

A plain diff omits new files while `git add -A` includes them. Review now sees the staged candidate
tree, including new files; Finalize commits the reviewed tree. Tests may not silently change that
tree. A reviewer can still overlook an extra path; comparing paths with a finding's declared file
set would add another check. See N3 and [ADR 0027](../adr/0027-the-reviewed-tree-is-what-ships.md).

### R10 — PATH hijacking <a id="r10"></a>

The runner calls tools such as Git, jq, Python, and gh by name. System directories precede
`~/.local/bin`, so a planted user-local binary cannot shadow a system copy. Tools installed only
in user-writable directories remain exposed to a write-boundary failure. Adapter-specific
runtime paths are prepended only for the relevant subprocess. See N4.

### R11 — Scope of Git controls <a id="r11"></a>

Push hooks guard Git ref updates, not arbitrary file reads, writes, or candidate-code execution.
Claude's Bash bypass guard is latent protection while Bash is withheld; an operator who grants Bash
changes the capability assumptions. Codex can run sandboxed shell commands. Keep Git safeguards but avoid
counting them as a complete sandbox. See N7 and M5.

### R12 — Forge credentials and PR text <a id="r12"></a>

An over-scoped forge token can grant persistence or access beyond the intended repositories.
For example, permission to register public SSH keys is unnecessary for PR creation. PR titles
and bodies are model-derived text sent through an API, bypassing any future diff-only scanner.
PR creation is disabled by default, leaving that API channel inactive until enabled. Audit scopes
and scan outbound text before enabling it. See N6; no host token history is assumed.

### R13 — Shared temporary paths <a id="r13"></a>

A co-tenant can pre-create a predictable lock or worktree path under `/tmp`, hold a lock, or cause
a denial of service through permissions. Kernel symlink protections do not replace private state
directories. Configure account-private paths and use restrictive permissions. See N5.

### R14 — Split state <a id="r14"></a>

Using an alternate state directory with real target remotes can leave shipped work outside the
ledger a later harvest reads. A state/remote guard blocks incoherent combinations by default;
explicitly permitted alternate state still needs consistent runner and harvest configuration.
Use the same state environment for every operational command.

### R15 — Candidate code execution <a id="r15"></a>

Tests, dependency lifecycle scripts, and setup commands execute candidate-controlled code. They
run in the gate sandbox, with no host home, credential files, or daemon sockets. The runner checks
worktree Git metadata and refuses test-induced changes before committing the reviewed tree.
Setup must not change files that would become part of the candidate commit.

Codex Fix can run repository commands inside its workspace-write sandbox before the ship gate.
Those commands can read host files accessible to the sandbox and copy their contents into the
candidate tree. A later push can disclose them even when command networking is disabled (R1).
Use a dedicated unprivileged account (M1).

An allowed public network destination can still receive worktree content. Remote CI can execute
pushed workflow changes with forge-side secrets before merge. Kernel namespaces, bubblewrap,
trusted runner code, and configured read-only binds remain in the trust base. See N8.

## 5. Mitigations and remaining work

| ID | Mitigation | Status |
| --- | --- | --- |
| <a id="m1"></a>M1 | Dedicated unprivileged service account without Docker, administrative groups, or unrelated service secrets | Deployment recommendation; highest priority |
| <a id="m2"></a>M2 | OS filesystem and endpoint-restricted network sandbox around every agent, exposing only required inputs and model credentials | Partial. The gate and Codex have filesystem confinement. Full agent isolation remains open. |
| <a id="m3"></a>M3 | Scan pushed diff content for secrets before disclosure | Open |
| <a id="m4"></a>M4 | Halt on anomalies and repeated unsafe behavior | Proposed in [autonomy-and-shutoff.md](autonomy-and-shutoff.md) |
| <a id="m5"></a>M5 | Re-verify tool-hook contracts against supported CLI versions | Ongoing compatibility responsibility |
| <a id="n1"></a>N1 | Deny writes outside the worktree after resolving traversal, symlinks, and prefix siblings | Implemented Claude guard; adapter equivalents described above |
| <a id="n2"></a>N2 | Make confinement assets unwritable to agents, for example through trusted ownership or immutable files | Additional defense in depth |
| <a id="n3"></a>N3 | Stage all candidate files for review and preserve reviewed-tree identity through Finalize | Implemented; stronger declared-file-set check remains open |
| <a id="n4"></a>N4 | Prefer system tool directories; resolve runner tools to trusted absolute paths | System-first PATH implemented; full absolute-path pinning remains open |
| <a id="n5"></a>N5 | Put lock and worktrees in account-private directories, with mode 0700 | Recommended; shared temporary defaults remain |
| <a id="n6"></a>N6 | Minimize forge scopes and extend secret scanning to PR text, worknotes, and digests | Operator scope audit required; content scanning remains open |
| <a id="n7"></a>N7 | Describe Git safeguards as ref confinement and defense in depth | Documented here |
| <a id="n8"></a>N8 | Sandbox tests and setup; fail closed without a usable sandbox; require a gate for branch-fix | Implemented in [ADR 0026](../adr/0026-the-ship-gate-runs-in-a-sandbox.md) and [ADR 0037](../adr/0037-the-fix-stage-starts-from-a-provisioned-worktree.md) |

A private model gateway needs an explicit endpoint policy that the public-only gate proxy cannot
currently express. A destination pin or dedicated forwarder could restrict that connection without
opening the surrounding LAN.

## 6. Residual risk

Ref confinement, write guards, tree identity, startup-control checks, and gate sandboxing address
distinct failure paths. They do not make unattended operation safe under an arbitrary privileged
host account. Secret reads and push-time exfiltration remain material risks; independent review
helps correctness but cannot retract disclosed data. Restrict the account first, then narrow
agent filesystem and network reach, and retain human control of merge authorization.
