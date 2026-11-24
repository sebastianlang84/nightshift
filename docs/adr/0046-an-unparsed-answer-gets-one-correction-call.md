# ADR 0046 — An unparsed answer gets one correction call

- Status: accepted
- Date: 2026-11-24
- Amends: [ADR 0034](0034-an-empty-answer-is-not-a-verdict.md) (an unparsed answer was left alone)
- Touches: [ADR 0030](0030-a-mismatched-closer-is-repaired-not-refused.md) (local repair of two slips)

## Context

ADR 0034 left an answer that arrived and did not parse alone. ADR 0030 repairs two slips locally:
a swapped closer and a trailing comma. Every other syntax error still discarded the whole stage.
On 2026-11-20 an Explore answer with one syntax error cost $2.73 and recorded no verdict.

Rerunning the stage would repeat the whole cost. A correction of the answer text costs a fraction,
because it needs neither the repository nor tools.

The curator approved one correction attempt on 2026-11-20.

## Decision

`run_agent` makes exactly one correction call for a stage when all of these hold:

- The stage is Recon, Explore, Review, Advise or Verify, the stages whose answer is JSON.
- The CLI completed with status 0 and the extraction failed. The adapter reports this; a CLI that
  stopped at its turn limit gets no correction.
- The answer contains a `{` and is at most `NIGHTSHIFT_JSON_REPAIR_MAX_BYTES` bytes (default
  65536). A larger answer is not sent. `0` disables the call.
- No credential or quota verdict stands.

The call is the stage `repair-<stage>` on the same adapter and work model. Claude gets no tools;
Codex keeps its read-only sandbox. The prompt is `prompts/repair.md`, the parse error from
`lib/extract_json.py` and the answer in a fence it cannot close. It asks for the same object with
corrected syntax only, and for `NO_JSON` when the answer is truncated or ambiguous.

The reply goes through the same extraction into the stage's own artifact. Validity rules do not
change: the caller's checks read the artifact as before. A failed correction leaves the stage
failed with its original status. The correction gets no retry, neither for an empty reply nor for
another parse failure.

## Consequences

- **Positive:** a syntax slip costs one small call instead of the whole stage.
- **Positive:** both calls are rows in `runs.jsonl`. The digest counts correction calls and how
  many parsed, so their worth can be measured.
- **Negative:** a model can change content while correcting syntax. The prompt forbids it, and the
  caller's checks still apply, but the artifact is no longer what the stage model wrote. The
  original answer stays in `<stage>.out`.
- **Unchanged:** an empty answer, a refusing adapter, a spent quota and a bad credential behave as
  before.

Regression cover: `tests/test-json-repair-call.sh`.
