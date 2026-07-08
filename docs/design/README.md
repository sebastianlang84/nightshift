# Design notes — idea stage

Detailed capture of the 2026-07-08 brainstorming. **Ideas, not decisions.** Implementation is
explicitly out of scope for now — the goal is to collect good ideas (realistic *and* wild) and
discard clearly bad ones before thinking about how to build any of it.

- [memory-model.md](memory-model.md) — the ledger: two-tier (episodic log + semantic memory),
  hybrid format, self-authored backlog, reflect/compaction.
- [constitution-and-rulebook.md](constitution-and-rulebook.md) — three safety layers, the four
  pillars of the system prompt, `rulebook.md`, the guiding asymmetry.
- [execution-modes.md](execution-modes.md) — single / chain / parallel, and the self-chaining
  governor that keeps autonomy from becoming a fork bomb.
- [self-evaluation.md](self-evaluation.md) — pre-flight critic (short loop) + retrospective (long
  loop), the honesty caveat, escalation mode, trust-ramp.
- [autonomy-and-shutoff.md](autonomy-and-shutoff.md) — dead-man's switch vs. "don't babysit"; the
  switch keyed on output-health, not human-attention (throttle / kill-switch / courtesy heartbeat).
- [documentation-system.md](documentation-system.md) — **accepted (v1).** The one doc/state system
  every run and the human share: four invariants, two physical homes, the read/write matrix.

Open decisions are flagged inline in each note and mirrored in [../../OPEN-QUESTIONS.md](../../OPEN-QUESTIONS.md).
