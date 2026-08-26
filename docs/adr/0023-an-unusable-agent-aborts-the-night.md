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
- A nonzero exit and an unusable result are separate facts. Explore, Fix, Review and Verify may keep
  a complete artifact returned before a turn ceiling. Without a complete artifact, Fix/Review append
  retryable `stage-failed`; Verify writes no negative snapshot result. Neither path enters the
  suppression sets. If the failure set `AGENT_FATAL`, no ledger or Verify state is written at all.

The detector is deliberately broad *within the CLI's own account of the run*. A false negative costs
a forged record of a clean fleet, which nobody sees.

### Amendment 2026-08-27 — an explicit second adapter may absorb quota exhaustion

A structured rejected quota event still proves that the current adapter produced no evidence, but
it no longer has to cost the whole night. When `NIGHTSHIFT_QUOTA_FALLBACK_AGENT` names a different
adapter, Nightshift records and preserves the rejected attempt, retries the same stage once through
that adapter, and keeps later stages on it. If the fallback fails, the existing fatal path still
aborts before derived repo state is written. Credential failures and ordinary stage failures never
switch vendors. This is host opt-in; unset keeps the original abort behavior.
Regression coverage: [`tests/test-agent-quota-fallback.sh`](../../tests/test-agent-quota-fallback.sh).

### Amendment 2026-08-24 — the signatures read the CLI, not the repo

The asymmetry above held; the channel it was applied to did not. `AGENT_AUTH_RE` is prose, and it was
matched against the stage's entire raw stdout — which carries the model's work, i.e. the words of the
repository under review. On 2026-08-24 an explore lens serviced nightshift's own infra dimension and
read [`bin/nightshift.sh`](../../bin/nightshift.sh) — including the comment about self-healing a
stale symlink after `codex login`. The signature matched the repo's source code, and the night
aborted after one stage with "no usable credentials" while `.usage_explore` recorded 29,600 output
tokens, 2.4M cache reads and $3.32 spent. The signature sits latent in **33 of 197** archived raw
streams on this machine and arms itself whenever a stage fails to parse for any other reason — which
is exactly what happened that night, one layer below (ADR 0030).

A false positive is not the cheap half of the trade after all. It costs a night *and* points the
morning at a repair that changes nothing: the credentials were never the problem, so
re-authenticating and re-running reproduces it.

So the classifier no longer searches the raw stream whole. `agent_diagnosis` extracts what the CLI
said **about itself** and only that reaches the signatures:

- **claude** emits a JSON event array. Its own verdict is the `result` event; `assistant`, `user` and
  `system` events are the model's work. A `result` with `is_error: false` is the CLI's receipt that
  it ran the session, so there is nothing to diagnose — and the `.result` text there is the model's
  answer, which may discuss credentials as a matter of code. Only a failed result is read, and then
  its text is the CLI's.
- **codex** has no verified shape here — no codex night has ever run on this machine — so its raw
  passes through unfiltered rather than through a guess, the same standard the quota detector was
  held to. It reports auth failures on stderr regardless.
- A raw stream that is not a parseable event array is not model output either, and passes through
  whole. That is the shape of the 2026-08-05 outage: one line of plain text on stdout.

A second, adapter-independent riddle-out runs first and is the only cover codex has:
`agent_reached_the_api` reads `.usage_<stage>`, which both adapters write from the CLI's own
counters. **A stage that spent tokens reached the API, so whatever else went wrong, authentication
did not.** It is a receipt rather than a heuristic, but it is not sufficient alone — a CLI that dies
before writing the counters leaves nothing to read — so both riddle-outs stand.

Rejected: **narrowing the regex** (dropping `codex login`, say) fixes the one match and not the
class — `unauthorized`, `not logged in` and `/login` are commoner still in source code, and every
repo nightshift services is a repo that might discuss authentication. **Matching stderr only** is
what the raw capture was added to fix: on 2026-08-05 stderr was empty and the CLI reported the
failure on stdout.

Verified against the archive: of the 33 raw streams the signatures hit, the amended classifier
aborts on **0**, while a structured `is_error: true` result and the plain-text 2026-08-05 shape are
both still caught. Regression coverage:
[`tests/test-agent-auth-false-positive.sh`](../../tests/test-agent-auth-false-positive.sh).

## Consequences

- A credential outage is now loud in all four places an operator might look: the night log, the
  morning digest, the process exit code, and `systemctl --user status`.
- Three of those four are **per-run**, and the fourth reports only the *last* run. Nothing here
  survives the next night that completes. Observed 2026-08-08..11: four consecutive nights aborted
  exactly as designed, and the healthy night of 08-12 turned the unit green again — the outage
  remained only in the journal and in four digests nobody re-reads. `aborted_streak()` closes that
  gap by carrying the count into the digest, so the first night to finish after an outage still
  names how many were lost and when the fleet was last actually serviced. It counts only nights
  that produced a digest: a missing date is a night that never started, not a failure.
- The rest of the fleet is *not* serviced once the agent is known dead. That is intended — those
  stages would fail identically, and each one would write another false record.
- A configured quota fallback is the exception: the rejected attempt is recorded separately, the
  same stage is retried once, and later stages do not probe the spent provider window again.
- The classification is a **heuristic over CLI output**, not a contract. Both CLIs are free to
  reword their errors; a reword degrades this to the pre-ADR behaviour for that message, minus the
  silence, since the stage failure itself is now logged either way. `AGENT_AUTH_RE` is the single
  place to extend — but extending it is only safe because `agent_diagnosis` now bounds what it may
  read. A signature added to match the CLI will otherwise match the fleet's source code as well.
- Credential failures abort. A structured rejected quota event either switches to the configured
  fallback or aborts; timeouts and transient API errors remain per-stage best-effort because they
  are local and retryable.
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
