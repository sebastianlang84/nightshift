# Design note — Autonomy boundaries & self-shutoff

- Status: **idea-stage, not decided.** Captures the 2026-07-08 discussion for review.
- No implementation details on purpose.

## The idea

Consider a **dead-man's switch**: a total auto-shutoff if the user stops engaging, so the steward
does not run forever into the void burning quota.

## The tension it exposes

This pulls against the *end goal*: you should **not have to babysit** the agent at all — it should
keep the system in shape like a diligent employee. A crude switch keyed on "did the human click
today?" contradicts that: being on vacation or busy for a week would shut it down, which is the
opposite of "set it and forget it."

## The resolution: key the switch on output-health, not human-attention

An employee you don't babysit still **stops and asks when something is clearly wrong** — that is
judgment, not neediness. What you *don't* want is an agent that needs a daily "keep going" from you
(that is babysitting, inverted). So the one idea splits into three distinct mechanisms:

1. **Value-based throttle (soft, automatic).** If draft-PRs pile up *unreviewed and unmerged*, that
   is a signal the value is not landing → **back off** (slow down, do less), not shut down. This is
   the existing adaptive-backoff / trust-ramp run in reverse. Absence alone never throttles; only
   sustained non-acceptance does. Preserves "don't babysit."

2. **Safety kill-switch (hard, the real dead-man's switch).** Keyed on the *agent's own health*, not
   the human's attendance: error-rate spike, touching forbidden zones, budget anomaly, repeated
   failed verifies → **halt itself, escalate, wait for a human.** This is the catastrophe/drift brake.

3. **Courtesy heartbeat (rare, not a leash).** If the human has genuinely engaged with *nothing* for
   a long stretch (e.g. weeks), pause and send **one** "still want me running?" ping — rather than
   silently burning quota into the void forever. One ping, not a daily gate.

The unifying principle: **the switch reacts to the agent's output health and safety, not to whether
the human showed up.** That keeps both goals — mostly-autonomous employee *and* no runaway.

## Open decisions (do not resolve yet)

- Thresholds for each mechanism (how many unreviewed PRs = throttle? what anomaly = halt?).
- Is the courtesy heartbeat opt-in, and how long is "genuinely abandoned"?
- Where does escalation go (digest, ping, both)? Ties to the morning-digest question.

_Related: [self-evaluation.md](self-evaluation.md) (throttle = trust-ramp in reverse),
[execution-modes.md](execution-modes.md) (budget/governor), [constitution-and-rulebook.md](constitution-and-rulebook.md)
(safety enforcement), OPEN-QUESTIONS §5, §6, §7._
