# What the reflection job may reach

Session reflection reads untrusted transcript text and proposes rule changes. Its separation from
the night loop is a deployment boundary, as required by
[ADR 0035](../adr/0035-a-reflection-finding-is-verified-before-it-becomes-a-rule.md).
It runs manually and never applies recommendations.

## Host-account threat

Without isolation the job would inherit every credential and privilege of the host account
running nightshift: repository push keys, forge tokens, model credentials, and any access supplied
by administrative or service-secret groups. Docker daemon access can be host-root-equivalent.
A dedicated unprivileged account is preferred. Where that cannot be provisioned, the sandbox
limits the job's visible filesystem; it does not remove the underlying account's privileges.

## Sandbox contract

The job reuses `build_test_sandbox` in [lib/sandbox.sh](../../lib/sandbox.sh), as do the ship gate
and Pi Fix. Environment variables are allowlisted, `/etc` is exposed file by file, and writable
paths are explicitly bound. Docker sockets, SSH keys, and forge credentials are absent.
Missing bubblewrap stops the run; there is no unsandboxed fallback.

### As built, 2026-09-25

`bin/reflect.sh` constructs a separate Pi agent directory for each model call. It copies only that
stage's provider credential into `auth.json`, and copies model catalogs for resolution. This
prevents a generator or judge from reading other provider credentials from the normal Pi store.
The provider defaults to `openrouter` and is configurable through `NIGHTSHIFT_REFLECT_PROVIDER`;
judge settings can be specified separately.

The read-only bind set includes:

- Claude transcript root (`~/.claude/projects`), without the surrounding credential directory.
- Codex transcript root (`~/.codex/sessions`), without the surrounding credential directory.
- Each selected rulebook, named individually.
- The runner source, runtime toolchain, and declared extension package roots needed by the call.

The generator receives transcript access. The judge receives the assembled evidence payload and
can no longer read the transcript roots or arbitrary neighboring files. An entire transcript root
is readable during generation, including extra files an operator stores there; keep unrelated
secrets out of it.

Writable mounts are the stage's scratch agent directory and output area. No target repository or
Git write credential is exposed. Extension discovery is disabled. Gateway authentication
extensions must be declared explicitly through `NIGHTSHIFT_PI_EXTENSIONS` or `agent.pi_extensions`;
only load trusted extensions, since they execute inside the job.

By default reflection reads the host's `~/.claude/CLAUDE.md` and nightshift's `AGENTS.md` if present.
`NIGHTSHIFT_REFLECT_RULEBOOKS` replaces that list with colon-separated file paths. An empty value
selects no rulebooks. Missing files are skipped. Provider and model selection are independent of
this rulebook input list.

The filesystem sandbox shares the host network to allow configured model gateways, including
private endpoints. The public-only ship-gate proxy cannot express a private endpoint exception.
A separate pinned-destination policy remains open; the current hull does not claim network isolation.

## Remaining risks

A cited quotation can still misrepresent its source through omitted context. The citation checker
rejects unsupported text; a separate judge evaluates the surviving evidence. Neither step proves
a proposed rule is correct. Reports must remain untrusted input to a human decision.

Transcript payloads leave the machine for the selected providers. The operator must authorize that
use and choose providers appropriate for the material. The sandbox narrows credential exposure
but cannot prevent disclosure of text deliberately supplied to a model.

Regression coverage: `tests/test-reflect-hull.sh` and `tests/test-reflect-runner.sh`.
