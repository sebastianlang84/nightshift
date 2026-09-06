# ADR 0032 — the pi Fix stage runs inside the gate's sandbox

- Status: accepted
- Date: 2026-09-06
- Amends: [ADR 0031](0031-the-reviewer-may-be-another-vendor.md) (pi is read-only, and `pi_allow_fix` is the deliberate hole in that)
- Extends: [ADR 0026](0026-the-ship-gate-runs-in-a-sandbox.md) (the bwrap hull this reuses)
- Touches: [ADR 0028](0028-gate-egress-goes-through-a-vetting-proxy.md) (why this stage keeps the host's network)

## Context

ADR 0031 admitted pi for read-only stages and refused it the Fix stage, because Fix may write and pi
has neither of the mechanisms the other two adapters use to bound *where*: claude's `PreToolUse`
guard rejects a Write/Edit resolving outside the worktree, codex's OS sandbox makes such a write
impossible. `agent.pi_allow_fix: true` was then added as a deliberate hole, with the cost written
down in `docs/design/hook-spec.md`: the only thing keeping a write inside the worktree is the model
choosing relative paths, and a write outside appears in no diff, so no branch review can catch it.

On 2026-09-06 that cost was paid for the first time. The night's partflow fix — a correct,
gate-passing, shipped change — also left a note at `/tmp/nightshift-install-marker.txt`, outside its
worktree. Harmless in content, and invisible to every check the night runs: it was found only
because the agent mentioned it in its own worknote. The operator then made pi the standing choice
for cost reasons, so the hole stops being an occasional exception and becomes the normal path.

## Decision

The pi Fix stage runs inside the same `bwrap` hull as the ship gate (`build_test_sandbox`,
ADR 0026), wrapped around the agent process instead of the test command (`pi_sandbox_argv`). The
writable set is the worktree and the stage's own agent directory; everything else is read-only or
absent. Credentials, model catalogs, the `-e` extension package roots and the toolchain are bound
read-only on their real paths, because `--clearenv` and an unbound `$HOME` would otherwise leave pi
without any of them.

It fails closed: no `bwrap` means the Fix stage refuses to run, rather than running unconfined.
`NIGHTSHIFT_PI_SANDBOX=none` is the documented opt-out and restores the pre-2026-09-06 behaviour,
logging that writes are not confined.

**The stage keeps the host's network namespace** (`--share-net`), and that is the one thing this ADR
does *not* narrow. ADR 0028's vetting proxy forwards to public addresses only, and this host's model
gateway is a LAN address — so an isolated namespace would not narrow the stage, it would remove the
one connection it exists to make. The stage's network reach is therefore exactly what it was before
this ADR; only its filesystem reach changed. Narrowing it needs an egress path that can carry a
private destination under an explicit host-declared pin, and that is tracked in `OPEN-QUESTIONS.md`.

## Consequences

- **Positive:** `pi_allow_fix` stops being an accepted risk and becomes a bounded one. R8 — the Fix
  stage writes only inside its worktree — is now a mechanism for all three adapters rather than a
  promise for two of them and a hope for the third.
- **Positive:** the failure this was built for is the confused absolute path, not malice, and the
  kernel now refuses it whether or not the model was trying to be careful.
- **Negative:** the Fix stage's environment is an allowlist, so a future pi feature that reads
  something new from disk fails inside the sandbox and not outside it. The symptom is a stage that
  cannot start; the fix is a named read-only bind, not widening the hull.
- **Negative:** a host without user namespaces loses the pi Fix stage entirely. That is the intended
  trade — the alternative is the unconfined writer this ADR exists to end.
- **Unchanged:** every read-only pi stage runs exactly as before. They have no write primitive to
  confine, so a sandbox would buy nothing and could only break a read.

Regression cover: `tests/test-pi-fix-sandbox.sh`.
