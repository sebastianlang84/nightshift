# ADR 0046 — An unparsed answer gets one correction call

- Status: accepted
- Date: 2026-11-24
- Amends: [ADR 0034](0034-an-empty-answer-is-not-a-verdict.md) (an unparsed answer was left alone)
- Touches: [ADR 0030](0030-a-mismatched-closer-is-repaired-not-refused.md) (local repair of two slips)

## Context

ADR 0034 left an answer that arrived and did not parse alone. ADR 0030 repairs two slips locally:
a swapped closer and a trailing comma. Every other syntax error still discarded the whole stage.
On 2026-11-20 an Explore answer with one syntax error cost $2.73 and recorded no verdict.

Rerunning the stage would repeat the whole cost. A correction of the answer text needs neither
the repository nor tools, so its prompt is bounded by the answer's size.

The curator approved one correction attempt on 2026-11-20.

## Decision

`run_agent` makes exactly one correction call for a stage when all of these hold:

- The stage is Recon, Explore, Review, Advise or Verify, the stages whose answer is JSON.
- The CLI completed with status 0 and the extraction failed. The adapter reports this; a CLI that
  stopped at its turn limit gets no correction.
- The extraction found a complete object that does not parse. An object that never closes is a
  truncated answer, and completing it would invent its end (ADR 0030); prose without an object has
  nothing to correct. Neither is sent.
- The answer is at most `NIGHTSHIFT_JSON_REPAIR_MAX_BYTES` bytes (default 65536). A larger answer is
  not sent. `0` disables the call.
- No credential or quota verdict stands, and the stage did not count as a wall (ADR 0023).
  A second call into the same wall would end the night.

The call is the stage `repair-<stage>` on the same adapter and the stage's own model, so a review
answer is corrected by the review model. It runs in an empty temporary directory in the worktrees directory, outside `$HOME` by default,
so it loads neither the repository nor its instruction files. Claude gets no tools; Codex keeps its
read-only sandbox. The prompt is `prompts/repair.md`, the parse error from `lib/extract_json.py`
and the answer in a fence it cannot close. It asks for the same object with corrected syntax
only, and for `NO_JSON` when the answer holds no stage object, is truncated or is ambiguous.

The reply goes through the same extraction into the stage's own artifact, with one extra check:
`extract_json.py --against <stage>.out` compares the keys and scalar values of the corrected object,
in order, with those of the longest malformed object in the original answer. A lenient scan reads
the original; numbers keep their literal text, and strings also match with quotes and backslashes
removed, since the slip may be in their escaping. Any added, dropped, changed or moved key or value
rejects the correction. Codex gets `--skip-git-repo-check`, because the directory is no repository.
Validity rules do not change: the caller's checks read the
artifact as before. A failed correction leaves the stage failed with its original status. The
correction gets no retry, neither for an empty reply nor for another parse failure. A wall on the
correction call counts in the wall streak but does not mark the stage itself as walled.

## Consequences

- **Positive:** a syntax slip costs one small call instead of the whole stage.
- **Positive:** both calls are rows in `runs.jsonl`. The digest counts correction calls and how
  many parsed, so their worth can be measured.
- **Positive:** the digest no longer counts a corrected stage as lost, and counts a failed one once.
- **Negative:** the check compares keys and values, not nesting. A correction could still move a
  value into another object; the caller's checks still apply. A lenient scan can also misread an
  unusual slip and reject an honest correction, which only fails the stage as before. The artifact
  is no longer byte-for-byte what the stage model wrote; the original answer stays in `<stage>.out`.
- **Unchanged:** an empty answer, a refusing adapter, a spent quota and a bad credential behave as
  before.

Regression cover: `tests/test-json-repair-call.sh`.
