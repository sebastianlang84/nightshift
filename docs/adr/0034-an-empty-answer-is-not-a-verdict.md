# ADR 0034 — an empty answer is retried, not recorded as a verdict

- Status: accepted
- Date: 2026-09-11
- Extends: [ADR 0023](0023-an-unusable-agent-aborts-the-night.md) (a stage that could not run says nothing about the code)
- Touches: [ADR 0030](0030-a-mismatched-closer-is-repaired-not-refused.md) (the other half of "the model's text is not the model's meaning")

## Context

ADR 0023 established the rule this extends: a stage that never reached a model must not be recorded
as one that ran and found nothing. It covered the cases where the *call* fails — bad credentials, a
rejected quota window — and both are detected from the adapter's own output.

A third shape was not covered, because it does not look like a failure anywhere in the stack. The
provider accepts the turn, bills it, and returns a stopped assistant message whose content array is
empty. Every adapter dutifully extracts the answer, gets the empty string, and hands it to
`lib/extract_json.py`, which says `no parseable JSON from stage` and exits 1. The stage is then
correctly reported as FAILED — but it is a failure with no diagnosis, and nothing retries it.

On 2026-09-11 that was the night's **first** explore lens. The item recorded no verdict, the
rotation did not advance, the Runner saw a pass that produced no new work, and the night ended
31 seconds after it started with its entire findings budget untouched. One dropped turn cost a whole
night — the same class of loss ADR 0023 exists to prevent, arriving through the one door it left
open.

Retrying everything was the alternative, and it is worse. A stage that returns prose instead of JSON
has told us something about the repository and about the prompt; calling it again spends a second
lens to be told the same thing, and hides the prompt problem behind a retry counter.

## Decision

`run_agent` retries a stage **once** when all of the following hold: it failed with status 1, no
fatal condition is set, and the answer file exists and holds no non-whitespace text.

Each clause excludes a case that must not be retried:

- **Status 1 only.** Status 2 is an adapter *refusing to run* — an unpermitted tool in a pi profile,
  a missing `bwrap` for the Fix stage sandbox. That is a deterministic configuration verdict, and a
  second identical call can only repeat it.
- **No fatal condition.** The credential and quota checks run first and keep their verdicts. A spent
  quota window also produces an empty answer, and retrying into the same wall is what ADR 0023's
  abort already refuses.
- **Exists and is empty.** Emptiness is the whole signal: an answer that *arrived* and did not parse
  is the model's verdict on the repo and is left alone (ADR 0030 already repairs it where it can).
  Existence is the other half — every real adapter writes this file unconditionally, the mock agent
  writes none, so an absent file means "this adapter reports no answer here" and must not be read as
  an empty one.

Both attempts are appended to `runs.jsonl` and the first attempt's stream, stderr and usage sidecar
are preserved as `.<name>.empty-answer-1`, so the empty turn stays visible and its cost stays
countable. `NIGHTSHIFT_EMPTY_ANSWER_RETRIES` sets the number of extra attempts; `0` disables the
retry entirely.

## Consequences

- **Positive:** a dropped turn costs one extra call instead of a night. The blip that motivated this
  hit the first lens of the night, which is the most expensive place for it to land.
- **Positive:** the empty turn is not swallowed. It is a row in `runs.jsonl` with its own token
  count, so a provider returning nothing *often* shows up as spend rather than as silence.
- **Negative:** a provider that is durably returning nothing now costs two calls per stage instead
  of one. Bounded, and the night still ends on the second empty answer rather than looping.
- **Unchanged:** every other failure path. A refusing adapter, a spent quota, a bad credential and
  an unparseable answer all behave exactly as before.

Regression cover: `tests/test-empty-answer-retry.sh`.
