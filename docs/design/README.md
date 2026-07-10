# Design notes — idea stage

Detailed capture of the 2026-07-08 brainstorming. **Ideas, not decisions.** Implementation is
explicitly out of scope for now — the goal is to collect good ideas (realistic *and* wild) and
discard clearly bad ones before thinking about how to build any of it.

- [memory-model.md](memory-model.md) — the ledger: two-tier (episodic log + semantic memory),
  hybrid format, self-authored backlog, reflect/compaction. **Superseded for v1** by
  [documentation-system.md](documentation-system.md) + [ADR 0004](../adr/0004-v1-scope-branch-isolated-steward.md) (see banner).
- [constitution-and-rulebook.md](constitution-and-rulebook.md) — three safety layers, the four
  pillars of the system prompt, `rulebook.md`, the guiding asymmetry. **Stakes framing swept** to the
  branch-only world (see the note's rewritten problem/stakes sections).
- [execution-modes.md](execution-modes.md) — single / chain / parallel, and the self-chaining
  governor that keeps autonomy from becoming a fork bomb. **Superseded for v1** by
  [ADR 0004](../adr/0004-v1-scope-branch-isolated-steward.md) (see banner).
- [self-evaluation.md](self-evaluation.md) — pre-flight critic (short loop) + retrospective (long
  loop), the honesty caveat, escalation mode, trust-ramp. **Superseded for v1** by
  [ADR 0004](../adr/0004-v1-scope-branch-isolated-steward.md) (see banner).
- [autonomy-and-shutoff.md](autonomy-and-shutoff.md) — dead-man's switch vs. "don't babysit"; the
  switch keyed on output-health, not human-attention (throttle / kill-switch / courtesy heartbeat).
- [documentation-system.md](documentation-system.md) — **accepted (v1).** The one doc/state system
  every run and the human share: four invariants, two physical homes, the read/write matrix.
- [hook-spec.md](hook-spec.md) — **accepted (v1).** The git-confinement hook (§2a): two layers that
  make "branch-only" a mechanical guarantee via resolved-ref checking, not command parsing.
- [risk-analysis.md](risk-analysis.md) — **living document (not idea-stage).** Security/safety
  posture of unattended operation: trust model, controls in place (mapped to code), the open risk
  register, and recommended mitigations. R1 (secret exfiltration) is the material residual risk.

Open decisions are flagged inline in each note and mirrored in [../../OPEN-QUESTIONS.md](../../OPEN-QUESTIONS.md).
