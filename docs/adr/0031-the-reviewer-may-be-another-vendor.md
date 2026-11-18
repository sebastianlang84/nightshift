# ADR 0031 — the reviewer may run on another adapter

- Status: accepted
- Date: 2026-08-30
- 2026-11-18 — the pi adapter was removed entirely (never used): neither Review nor Fix can run on pi; everything below about pi is history.
- Related: [ADR 0019](0019-stage-context-excludes-operator-config.md),
  [ADR 0020](0020-the-rulebook-declares-the-stage-model.md), and
  [ADR 0032](0032-the-pi-fix-stage-is-sandboxed.md)

## Context

An author and reviewer using the same model can share blind spots. Advisory review after shipping
is useful but does not replace an independent review at the ship boundary. A separate adapter
also permits a different cost or quota policy for Review.

## Decision

1. `agent.review_agent`, overridden by `NIGHTSHIFT_REVIEW_AGENT`, selects the Review adapter.
   Omitted, Review uses the primary adapter. The routed call records the actual reviewer in
   telemetry and uses its failure classification. The primary adapter's quota fallback is not
   carried into a routed reviewer, which could silently reintroduce the author's vendor.
2. Pi is an additional adapter. Read-only stages withhold write, edit, and Bash tools.
   Fix requires `agent.pi_allow_fix: true` or `NIGHTSHIFT_PI_ALLOW_FIX=1`, and the bubblewrap
   write boundary defined by ADR 0032. Pi's tool allowlist alone cannot confine absolute paths.
3. `PI_CODING_AGENT_DIR` points to a runner-owned stage home containing credentials and catalogs,
   excluding global operator instructions. Target-repository context remains available.
4. Pi stage success is determined from its event stream. A provider may emit
   `stopReason: "error"` and `errorMessage` while the process exits zero. Treating that as success
   would forge a clean result. Only the provider's error message is used for credential diagnosis;
   tool results and prompt text must not trigger an authentication abort.
5. Hosts using Pi get a daily best-effort `pi update --all` followed by `pi update --models`.
   Catalog freshness matters for resolving configured model IDs. `NIGHTSHIFT_PI_UPDATE=0`
   disables refresh. Updates can reset Pi-managed Git clones; keep local edits out of them.
6. Extension discovery stays disabled. Providers requiring authentication extensions must declare
   trusted paths through `agent.pi_extensions` or `NIGHTSHIFT_PI_EXTENSIONS`. Explicit loading
   allows required gateway authentication without loading unrelated operator extensions.
   Missing declared paths are logged and dropped. Configure `agent.pi_provider` and
   `agent.pi_model` for the provider you use; no private gateway is assumed.
7. `NIGHTSHIFT_PI_PATH` prepends a compatible runtime only for the Pi subprocess. It does not
   put a user-writable runtime directory ahead of the runner's system tools.
8. `agent.codex_effort` follows the same precedence as model selection: explicit environment
   setting, then rulebook, then CLI default. An explicitly empty environment value passes none.

## Dynamic reviewer selection

`agent.review_agent: auto` asks `NIGHTSHIFT_REVIEW_VENDOR_CMD` before each Review stage. The
command must print `claude` or `codex`; errors, timeouts, or invalid output select `codex`.
Configuring `auto` without a command refuses startup. An explicitly set
`NIGHTSHIFT_REVIEW_AGENT` still wins. A same-adapter reviewer receives an adversarial brief.
This lets a host implement its own quota policy without embedding account usage in nightshift.

## Consequences

Independent review is configurable at the stage that decides shipping. It reduces correlated
errors but does not prove correctness. The run log and telemetry state which adapter judged the
fix. Pi Fix remains an explicit, sandboxed option; unconfined writes are never implied by a
provider choice. See [the threat model](../design/risk-analysis.md) for read and network limits.

Regression coverage: test-pi-adapter.sh (removed 2026-11-18), test-pi-stage-failure.sh (removed 2026-11-18),
`tests/test-rulebook-validation.sh`, and `tests/test-review-vendor.sh`.
