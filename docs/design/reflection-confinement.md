# What the reflection job may reach

[ADR 0035](../adr/0035-a-reflection-finding-is-verified-before-it-becomes-a-rule.md) keeps the
reflection job out of the night loop and says its separation "has to be a property of the deployment,
not of the code's intentions". This is the specification that turns that sentence into a mechanism.

It was written as a draft with three open questions. The operator answered all three on 2026-09-16,
and the answers are recorded at the end; the body below now describes what is decided rather than
what is proposed.

## What the job would inherit by default

The night loop runs as a systemd **user** unit and the reflection job is started by hand, so both
run as the operator's own account. Either way the job inherits that account whole. On this host (2026-09-16) that
account is `llmadmin`, and `id` reports it in three groups that matter:

- **`docker`.** Membership is root-equivalent on the host: anyone who can talk to the daemon socket
  can start a container that bind-mounts `/` and writes as root. Nothing else in this document
  outweighs that one.
- **`partflow-secrets`.** Read access to `/etc/partflow/secrets`, which is where a production
  database password lives.
- **`sudo`.** It prompts for a password, so it is not a direct path, but it is a membership the job
  has no use for.

Beyond groups, the account reaches an SSH key that can push to the repositories, a `gh` credential,
and the credentials of every model CLI on the machine.

The job reads session transcripts, and a transcript is text that other people's repositories put
there. Handing that material an account with these capabilities is the thing the separation is
supposed to prevent, and keeping the job off the timer does not prevent it — a manual start runs
under the same account as a scheduled one.

## Why a dedicated account is not available here

The obvious answer is a second, unprivileged system account. It is not reachable from this side:
creating one needs `sudo`, `sudo` prompts for a password here, and the machine's administration is
IT's. So this job does not get one. It gets the confinement that **is** reachable, and the operator
decided against opening a request with IT for the better answer — see the decisions at the end.

## What is reachable: the hull that already exists

Nightshift already confines two things this way — the ship gate ([ADR
0026](../adr/0026-the-ship-gate-runs-in-a-sandbox.md)) and the pi Fix stage ([ADR
0032](../adr/0032-the-pi-fix-stage-is-sandboxed.md)) — with `build_test_sandbox` in
[`bin/nightshift.sh`](../../bin/nightshift.sh). That function already does the work: `--clearenv`, an
`/etc` allowlist rather than a directory bind, its own user, IPC, PID, UTS and cgroup namespaces, and
a writable set that is nothing but what is bound writable.

Reusing it costs almost nothing and changes what "separate job" means from a promise into a
mechanism. Inside such a hull the group memberships above stop mattering, because the docker socket,
`/etc/partflow/secrets`, the SSH key and the `gh` credential are simply not present unless something
binds them, and this job binds none of them.

### The bind set

Read-only, and nothing wider:

| Path | Why, and why not the directory above it |
|---|---|
| `~/.claude/projects` | the Claude Code transcripts. **Not** `~/.claude`, which holds that CLI's own credentials and settings beside them. |
| `~/.codex/sessions` | the Codex rollouts. **Not** `~/.codex`, which holds `auth.json` in the same directory. |
| each rulebook and skill the run reads | named individually, the way the `/etc` allowlist is |
| the model credential the reflection calls with | one, named, and only the one that stage needs |

Writable: one output directory for the report, and nothing else. No repository is bound at all —
the job has no reason to see a working tree, and a report is not a commit.

Network: the reflection calls a model, so it needs egress. The same question ADR 0032 left open for
the pi Fix stage applies unchanged here, and this file does not reopen it: the vetting proxy of
[ADR 0028](../adr/0028-gate-egress-goes-through-a-vetting-proxy.md) forwards to public addresses
only, while the host's model gateway is a LAN address. Whichever way that is settled, it is settled
once for both.

Failure mode: **closed**. No `bwrap` means the job does not run, matching what ADR 0032 decided for
the pi Fix stage. A reflection that silently ran unconfined would be worse than no reflection.

## What this does not protect

Confinement bounds what the job can *reach*. It does nothing about what the job can *say*, and the
job's whole output is text a human will act on:

- The generating and judging models read untrusted repository text, and their report proposes changes
  to rulebooks. A recommendation to weaken a rule arrives through the operator, who has every
  permission the job was denied. That is why ADR 0035 makes the citation the thing a human checks,
  and why the report is not treated as an authority.
- Sending the payload to a model discloses it, whatever the filesystem allows. That was a separate
  operator decision, settled the same day in favour of the proxied third-party models, and no
  confinement substitutes for it.
- The transcripts stay readable by the account that owns them. This bounds the job, not the machine.

## What the operator decided, 2026-09-16

1. **The hull stands in for the account.** Accepted as the confinement, because a dedicated account
   is not reachable without IT and the hull removes the capabilities that make the account dangerous
   here.
2. **No account requested from IT.** The hull is the answer, not an interim. If that changes, this
   file is where the change belongs.
3. **The model credential is bound read-only inside the hull,** one named credential and no other.
   Holding it outside would mean a broker process this repository does not have, and the same
   decision was already made for the pi Fix stage.

One thing follows from the payload destination the operator settled the same day — the day's
material may go to the proxied third-party models, GLM included. That widens what a disclosure costs
and changes nothing about what this hull does: confinement never bounded what the job may send, only
what it may read.
