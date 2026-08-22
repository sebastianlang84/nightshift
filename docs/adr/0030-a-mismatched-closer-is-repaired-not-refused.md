# ADR 0030 — a mismatched closer is repaired, a truncated answer is not

- Status: accepted
- Date: 2026-08-22
- Extends: [ADR 0023](0023-an-unusable-agent-aborts-the-night.md) (a stage that could not run is not a stage that found nothing)
- Touches: [ADR 0029](0029-a-serviced-lens-needs-depth-evidence.md) (the `coverage` receipt whose shape provokes the slip)

## Context

`lib/extract_json.py` refuses anything it cannot parse, and that refusal is load-bearing: inventing
`found:false` would advance coverage and rotation for a review the model never completed. The rule
was applied, though, to output where the model *had* completed the review — and said so in JSON that
misses parsing by one character.

Across the four nights 2026-08-19 … 08-22, **13 explore lenses were lost to one keystroke**, always
the same one:

```json
"invariants": {"config_domain": "checked: …",
               "lifecycle":     "checked: …"
],
```

`coverage` holds five members. Four are arrays; `invariants` is the single object, and it sits
between two arrays (ADR 0029). After several hundred words of evidence strings inside it, the model
closes it with the closer its neighbours use. Each of those thirteen stages had already spent 3–6
minutes and real tokens, and each carried a finding — the work was done and then discarded at the
door.

## Decision

**A closer that contradicts its own opener is repaired; anything else is still refused.**

The distinction is not "how broken is it" but *what the damage proves about the answer*:

- **Mismatched closer** — the model opened `{` and closed `]`. It closed every bracket it opened, so
  the nesting it meant is unambiguous: there is exactly one structurally valid reading, and the swap
  recovers the model's answer rather than choosing among several. At most `MAX_SWAPS = 2`; past that
  the output is garbled enough that "the model meant this" stops being a reading and becomes a guess.
- **Truncated output** — a bracket is never closed. That means the model *stopped*, and appending the
  closer would fabricate the part it did not say. Refused, and refused harder than before: the search
  now ends there rather than handing the next `{` a turn, because that next brace is nested inside
  the unfinished object and returning it answers the stage with a fragment.

The second half is a fix, not a side effect. On 2026-08-08 a recon was cut off mid-sentence
(`…procedures."}</parameter>`) and the extractor returned its nested `dimensions` object as the
recon verdict — precisely the laundering the existing nested-object rule forbids, reached by a path
that rule did not cover.

A repair is announced on stderr and logged by `materialize_stage_output`. The artifact that reaches
the ledger is not byte-for-byte what the model wrote, and a night log that hides that is the wrong
kind of quiet.

## Alternatives rejected

**Retry the stage.** 3–6 minutes and full token cost per attempt, against a slip that is systematic
rather than random — it recurred in three different repositories on the same night. A retry pays the
whole bill for a coin flip.

**Change `coverage.invariants` to an array so every member closes with `]`.** This removes the
specific trap and nothing else; the next schema with a lone object re-creates it. It also touches
ADR 0029's receipt, `validate_explore.py`, the prompts and the digest — a wide change for a narrow
benefit, while the repair covers every stage and any future shape.

**Ask the CLI for structured output.** nightshift is agent-independent by construction (ADR 0001).
A guarantee available in one vendor's CLI cannot be the thing the parser depends on.

## Consequences

- 13 of the 14 historical parse failures on this machine are recovered; the fourteenth is a genuine
  malformation inside a string and stays refused. Verified against all 226 stage outputs in `runs/`:
  212 parse identically to before, 13 are recovered, 1 changes — the truncated recon above, which
  now correctly fails instead of yielding a fragment.
- A repaired verdict is visible in the night log. If repairs become routine rather than occasional,
  that is evidence the prompt shape is wrong and should be fixed at the source.
- The refusal doctrine is unchanged where it matters: no JSON, an unfinished answer, or damage past
  the ceiling is still a failed stage, never a synthetic verdict.
