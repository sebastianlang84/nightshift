# ADR 0023 — an unusable agent aborts the night

- Status: accepted
- Date: 2026-08-06
- Extends: [ADR 0001](0001-ports-and-adapters-runner.md) (the adapter seam this failure classification sits on)
- Touches: [ADR 0010](0010-recon-dimensions-and-coverage-rotation.md) (the negative recon cache it must not poison) ·
  [ADR 0015](0015-recon-reprioritizes-never-excludes.md) (the `empty` ledger row it must not forge)

## Context

nightshift's stages are best-effort by design. Every call site says so:

```sh
run_agent recon "$wt" "$id" || true
run_agent explore "$wt" "$id" || true
```

That is right for a stage that *ran and produced nothing* — one lens turning up clean is the normal
case, and a single hiccup must never take down a night that has three other repos to service. It
was applied, though, to a stage that **could not run at all**, and those are not the same event.

On the night of **2026-08-05** all eight stage invocations died after 1–3 seconds. The reason was in
the CLI's own transcript:

```json
{"error": "authentication_failed",
 "content": [{"type": "text", "text": "Not logged in · Please run /login"}]}
```

Not one layer above reported it. The night log recorded a quiet, healthy fleet:

```
[nightshift]   valuelens: recon produced no result — negative-cached (backoff 21600s)
[nightshift]   valuelens [branch-fix]: nothing worth doing (scope=in_scope_no_findings)
…
[nightshift] night done: 0 shipped this run, 4 considered, 0 now open (cap 4).
=== nightshift done rc=0 ===
```

The outage was invisible because three separate mechanisms each did something locally reasonable:

1. **The claude adapter discarded the diagnosis twice.** `out="$(… 2>/dev/null)" || return 1` sent
   stderr to `/dev/null`, and the non-zero exit dropped the captured *stdout* along with it — and
   stdout is where `claude -p --output-format json` reports exactly this failure. The item dirs from
   that night contain no `.out` file and no error file: nothing at all.
2. **`run_agent` recorded the exit code and no one read it.** `runs.jsonl` had `"exit": 1` on all
   eight rows the whole time. Nothing ever surfaced it, so a stage that could not start was
   indistinguishable — in the log, in the digest, in the exit status — from one that ran and had
   nothing to say.
3. **The failure then wrote itself into state.** Each dead recon produced a `recon_failed` negative
   cache carrying a 6h backoff, and each dead explore produced an `outcome:"empty"` ledger row. Both
   are *claims about the repositories*: "recon found nothing here", "this lens was clean on this
   night". Neither was true, and the ledger is append-only — the four `empty` rows of 2026-08-05 are
   permanent fiction in the record the digest's coverage matrix reads.

The 6h backoff made it worse than a one-night loss: it is longer than the gap between the operator
noticing in the morning and any re-run, so the fix would not have taken effect on the retry either.

An infrastructure outage forging the record of a clean fleet is the worst available outcome. A night
that fails loudly costs one night. A night that fails silently costs the trustworthiness of every
night's record, because a clean digest no longer distinguishes "nothing to fix" from "nothing ran".

## Decision

**A stage failure that means the agent itself is unusable ends the night, and nothing derived from
it is recorded.** Concretely:

- Both adapters capture stdout (`.raw_<stage>`) and stderr (`<stage>.err`) into the item dir
  unconditionally, and the exit code is inspected afterwards rather than short-circuiting the
  capture. The CLI's own words are always on disk.
- `run_agent` reports any non-zero stage as a **failure** in the night log, with its exit code and
  the last line of its stderr, instead of letting the `|| true` at the call site absorb it.
- It then matches the captured output against credential-failure signatures (`AGENT_AUTH_RE`). A hit
  sets `AGENT_FATAL`, which `main()` treats as a stop reason: no recon cache is written, no `empty`
  row is appended, the dimension rotation does not advance, and the night ends at the **first**
  failing stage rather than walking the rest of the fleet into the same wall.
- The digest announces the abort, and the process exits **3** — so `bin/nightshift-cron.sh` logs a
  verdict and the systemd unit is marked failed.

The detector is deliberately broad. A false positive costs one aborted night, which the operator
sees and can re-run. A false negative costs a forged record of a clean fleet, which nobody sees.

## Consequences

- A credential outage is now loud in all four places an operator might look: the night log, the
  morning digest, the process exit code, and `systemctl --user status`.
- The rest of the fleet is *not* serviced once the agent is known dead. That is intended — those
  stages would fail identically, and each one would write another false record.
- The classification is a **heuristic over CLI output**, not a contract. Both CLIs are free to
  reword their errors; a reword degrades this to the pre-ADR behaviour for that message, minus the
  silence, since the stage failure itself is now logged either way. `AGENT_AUTH_RE` is the single
  place to extend.
- Only credential failures abort. A stage that dies of a timeout, a rate limit, or a transient API
  error is still per-stage best-effort — those are genuinely local and genuinely retryable, and
  ending a night on one would trade a rare silent failure for a frequent noisy one.
- `NIGHTSHIFT_ADVISOR_AGENT` is gated on *which* adapter died, not on the fact that one did: an
  advisor on a different vendor is unaffected by the outage and still gives a usable second opinion
  on already-pushed branches.
- **The rows already written stay written.** This ADR stops the forgery; it does not undo the four
  `empty` rows of 2026-08-05, and the ledger is append-only by design (ADR 0007). They are withdrawn
  instead: `bin/harvest.sh retract <night> [reason]` appends one `outcome:"retracted"` row per
  affected item, and the two readers that treat an `empty` row as evidence skip any item so named —
  `service_cadence` (which a phantom service makes look busier than it is) and ADR 0015's
  exclusion-suggestion window (where a phantom row occupies a slot and *masks* a real signal). The
  original rows remain visible, so the record shows both what was claimed and that it was withdrawn.
  Applied to 2026-08-05 on 2026-08-06; covered by
  [`tests/test-retract-empty-night.sh`](../../tests/test-retract-empty-night.sh).
- Regression coverage: [`tests/test-agent-auth-abort.sh`](../../tests/test-agent-auth-abort.sh)
  drives a stubbed `claude` that fails the way the real one did, and asserts the exit code, the
  captured reason, the early stop, and the *absence* of every artifact that made 2026-08-05 look
  clean.
