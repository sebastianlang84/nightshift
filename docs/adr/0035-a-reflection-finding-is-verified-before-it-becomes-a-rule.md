# ADR 0035 — a reflection finding is verified before it becomes a rule

- Status: accepted (design phase)
- Date: 2026-09-16
- Touches: [ADR 0031](0031-the-reviewer-may-be-another-vendor.md) (the cross-vendor reviewer this reuses)

## Context

The operator wants a PDCA loop — plan, do, check, act — over their own working day: read the day's
Claude Code and Codex session transcripts together with the AGENTS.md rulebooks and the skills that
were invoked, find where the collaboration produced friction, and propose changes to those rulebooks
and skills. The output is meant to be acted on: a finding becomes an edit to a real rulebook.

A prototype ran on 2026-09-16 against the previous day: eight compacted transcripts, five AGENTS.md
files and four SKILL.md files, 504 KB of payload, reflected on by one model in one pass. It produced
seven findings, each with a quote and a concrete rule change. The report read well.

One adversarial review of that report (`gpt-6-astra`, an OpenAI model reached through the codex CLI,
so a different vendor from the Anthropic model that orchestrated the run) objected to all seven
findings. Eight of its 24 objections were spot-checked against the transcripts and all eight held.
Two of those, both of which would otherwise have become rules:

- The report quoted an agent as having said "Otto fetcht nicht" — *Otto does not fetch*. The
  transcript says the opposite: "Otto hat vor 6 Tagen gepusht … **fetcht also**" — *pushed six days
  ago, so it does fetch*. The report's arrow chain also reversed the order of two turns.
- For a set of unreachable sessions the report recommended addressing them by their `ListAgents`
  reference — `ListAgents` being the harness tool that lists addressable agent sessions. The very
  quote it cited says that path fails too; the report had elided that clause.

The underlying friction was usually real. What was wrong was the evidence, the diagnosis, or the
proposed rule.

A second run measured who could verify. The same review brief and the same payload went to the cheap
model that had written the report (`z-ai/glm-5.3-flash`, reached through pi). As a *reviewer* it
quoted accurately: six spot-checked quotes, all verbatim and correctly attributed. Against the other
reviewer's 24 objections it matched 10 in full and 2 in part, did not raise 12, and contributed 3 of
its own — including a session the report had ignored entirely, which the expensive reviewer also
missed. It graded nothing as a blocker, including the two cases the other reviewer did.

**What that does and does not establish.** These are two runs over one day's material, so the counts
are observations, not a measurement of either reviewer. The agreement counts in particular measure
overlap with one incompletely verified review, not detection rate: an objection counted as "not
raised" may have been one worth not raising. What *is* directly established is narrower and enough
to decide on: a generating model produced quotes that contradict their own source, and the same
model asked to check quotes against a source did so accurately in every case examined.

Why the two differ is a hypothesis this experiment did not isolate — one generator, one task shape,
no controlled comparison. The plausible reading is that asking for an account of a day produces an
account, and an account smooths over the places where the source does not support it. The design
below does not depend on that explanation being right; it depends only on the observation that a
finding and its verification must not come from the same pass.

## Decision

Reflection is a three-stage pipeline, and no stage may both produce a finding and be the last word
on it.

1. **Generate.** A cheap model reads the compacted transcripts and the rulebooks and proposes
   findings. Every quote carries a stable turn identifier, not a line number: the extractor assigns
   one per turn and emits it, so a citation survives a change in compaction. A finding whose quotes
   do not resolve is not a finding.
2. **Check the citations mechanically.** A script verifies each quote against the cited turn, and
   verifies any ordering the report asserts between two cited turns. No model is involved.
3. **Judge.** A model reviews the findings that carried their citations. It receives each cited turn
   **with its surrounding turns**, not the quoted fragment alone, and asks whether the quote still
   means what the finding claims, whether the diagnosis follows, and whether the proposed rule
   collides with an existing one. It separately receives the inventory of sessions that went into
   stage 1, so that a session the generator ignored can still be raised.

**Stage 2 establishes quotation fidelity only.** It cannot establish that a quote means what the
finding says it means: the `ListAgents` case above is a quote that matches its source exactly and
supports the opposite of the recommendation built on it, because a qualifying clause was dropped. A
citation that resolves is therefore a precondition for a finding, never evidence for it. Judging
whether the evidence supports the claim is stage 3's job, and an authentic quote attached to an
unrelated diagnosis has to fail there.

Stage 3 runs the cheap model on every run and a cross-vendor reviewer on a cadence the operator
sets, at minimum whenever the procedure itself changes. Neither reviewer has been measured on stage 3's
restricted input — both prototype runs saw the whole day — so that cadence is a starting point to
revise once the pipeline has run.

Severity is assigned from the finding's type rather than asked of the model, because a reviewer in
the experiment found a defect and still graded it as unremarkable. The taxonomy that makes this
implementable does not exist yet and is tracked in `todo.md`; until it does, the pipeline reports
findings unranked rather than ranked by a model.

**A turn body may not look like a turn header.** The whole scheme rests on a turn having an address,
and the address is a line at column 0 that `check_citations.py` and `build_judge_input.py` both match
on. A human turn is copied out verbatim, deliberately, and what it contains is whatever a repository
put in front of an agent — so a file somewhere can carry a line shaped like a turn header, and once
quoted into a session that line arrives in the extract. Written out unchanged it starts a turn with
an id the text chose, and choosing an existing id replaces the real turn: a quote then "resolves"
against text the same untrusted source supplied, which is precisely what stage 2 exists to prevent.
`extract_session.py` therefore indents any body line that would parse as structure. The parsers
anchor at column 0, and the checker collapses whitespace before matching, so a quote of such a line
still resolves.

**"Read and held nothing" is not "could not be read".** The session inventory only means something
if those two states stay apart, so `extract_session.py` exits 3 for the first and leaves every other
non-zero exit to mean the second. The runner records a 3 as an examined session and stops the run on
anything else. A crashed extraction recorded as an empty session would put a session in the
inventory whose evidence nobody ever read — the judge would then be told the generator saw it.

**The job is not a stage of the night loop.** It gets its own entry point in `bin/`, and the
operator starts it — no timer, no unit. Running it is a decision, not a schedule: its output is a
proposal that only a human can act on, so a report nobody asked for is a report nobody reads. Its input is text quoted out of repositories the agents were reading, and the night
loop's stages may commit and push, so the two are kept apart. That separation has to be a property
of the deployment, not of the code's intentions: before the job is enabled, its execution identity,
its writable paths, and which credentials it can reach are specified and verified, the same way
[ADR 0026](0026-the-ship-gate-runs-in-a-sandbox.md) bounds the ship gate. A job that merely refrains
from writing is not separated from anything.

**What the separation does not protect.** The report is written by models that read untrusted
repository text, and the operator supplies the write authority when they act on it — so a persuasive
recommendation to weaken a rulebook reaches its target through a human rather than through a push.
The report is therefore treated as untrusted input to a human decision, and a rule change is made
against the cited evidence, not against the report's summary of it. Sending the payload to a model
also discloses whatever it contains; where it may go is an operator decision recorded before the job
is enabled, and the job stays disabled until it is.

## Consequences

- **Positive:** the failure that produced rule proposals on contradicted evidence is caught by a
  script rather than by a second opinion, so it is caught on every run and without model inference.
- **Positive:** stage 3 sees a fraction of the material, which is what could make an occasional
  expensive reviewer affordable. The cost has not been measured.
- **Positive:** requiring a resolvable citation per quote makes an unciteable claim impossible to
  file, which is stronger than instructing a model not to make one. It does nothing about a claim
  that is citeable and still wrong.
- **Negative:** a real finding whose evidence spans many turns, or rests on tone rather than a
  quotable turn, is refused by stage 2. The loop will systematically favour friction that can be
  pointed at.
- **Negative:** two model passes and a scripted stage per run, against transcripts that grow with the
  day's work. The cheap model is what would make this affordable; changing it is a cost decision as
  much as a quality one.
- **Unchanged:** the night loop. This job shares the repository and the host with it, nothing else.

Open, and tracked in `todo.md`: the severity taxonomy; what the extractor keeps of tool results —
dropping them all makes any finding about what a command returned unsupportable, and both reviewers
named that; where the payload may be sent; and the citation format's details (multi-line quotes,
permitted elision, the unit that a failed check rejects).

The experiment described above is **not reproducible from this record**. Its payload quotes working
sessions verbatim and is not in the repository, and neither are the reports or the review briefs.
The counts stand as reported observations; re-deciding this ADR means running a new experiment, not
replaying that one.
