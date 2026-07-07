# Fable review — nightshift design (idea stage)

- Reviewer: fable (claude-fable-5), 2026-07-08. Verbatim, unedited.
- Brief: sharp critic, no implementation details. What's good / weak / kill / wild ideas / sharpest
  open question. Captured here so the critique survives into tomorrow's decisions.

---

## 1. What's genuinely good

**The single best idea: the guiding asymmetry.** *"The cost of a missed improvement is zero; the
cost of a bad merge-able change is high. When in doubt: do nothing, log it, defer to the backlog."*
This one sentence is the load-bearing wall. It makes "do nothing" a first-class success outcome, and
it's what the anti-churn bar, escalation mode, and trust-ramp all derive from. Most autonomous-agent
projects die because they implicitly reward activity; you've explicitly rewarded restraint. Keep it
verbatim.

Also strong:

- **Prompt = intent, enforcement = guarantee.** The three-layer split where critical rules (never
  `main`, no secrets, no force-push) are *mechanical* and the prompt is merely motivational is the
  correct posture. Anyone who lets the constitution do safety work is fooling themselves; you didn't.
- **Agent proposes, runner spawns.** "The agent never calls `claude -p` on itself" is the right
  ownership of the spawn primitive.
- **ADR 0003.** Recognizing that the subscription token in a custom wrapper is "the move that gets
  broken" is grounded, unsexy realism. Rare in these docs' genre.
- **Build the brain, borrow the body.** The prior-art table is honest work and the scope conclusion
  (the unfilled niche is exactly self-prioritization + ledger) is credible.
- **Human verdicts as ground truth** outranking self-assessment. Correct instinct; underspecified
  (see §2).
- **Abandoned set + staleness.** "Same false positive not retried nightly" is the single most
  practical ledger feature — it's the difference between a steward and a nag.

## 2. What's weak or wrong

**The governor solves the wrong bomb.** Caps on depth/fan-out bound *spawn count*, but the actual
budget bomb is per-run consumption times a shared window. Worse: your budget sensor is third-party
log parsers (`ccusage`, `claude-token-lens`) that lag and break on CLI updates, and the window is
**shared with your daytime self**. The realistic failure isn't a 3am runaway — it's waking up Monday
with your weekly quota eaten by six mediocre chain links. Also: "every spawn is logged so a runaway
is visible and killable" — visible *to whom* at 3am? Nobody is watching; that's the premise.
Killable-by-log is not killable without a watchdog, and no watchdog exists in the design.

**Chain mode is redundant.** The outer loop is already `{pick → bounded run → record}` repeated
until the window is spent. That *is* a chain. Letting the agent additionally propose
`{mode, items[], depth}` adds a second, agent-authored control plane over the same loop — more
surface, no new capability. The Brain picks the *next* item; the runner decides whether there's
budget for another iteration. Done.

**The critic's bias mitigation is half-right.** Fresh context reduces sycophancy toward *the
transcript*, but the critic is the same model with the same training — it shares the producer's
blind spots (correlated errors), so it catches scope-creep and noise but systematically misses
whatever class of bug the producer also misses. And a fixed rubric invites Goodhart: the producer
will learn (via retrospective) to write PRs that pass the rubric, not PRs that are good. The honesty
caveat names the problem and then under-treats it.

**The retrospective learns from ~nothing.** A few PRs per night, verdicts that are confounded
(closed-because-busy ≠ bad work; merged ≠ good), and from that you'll down-weight lenses? That's
fitting noise at n=4. Same problem infects the trust-ramp: "acceptance rate" from a single lenient
human grants fix-mode fast and means little.

**Prompt injection is entirely absent.** An unattended agent reading arbitrary repo content
overnight is the *textbook* injection target — a malicious TODO comment, test fixture, or vendored
README can steer it, and nobody is watching. On the enterprise server you keep invoking, repo
contents are untrusted input. Not one of the eleven docs mentions this. This is the biggest hole in
the safety story, bigger than the fork bomb.

**The enterprise framing is aspirational, not designed.** "Agent picks its own work on a production
server" is not a hardening problem, it's a *sales* problem — no security team accepts
nondeterministic scope selection at night, and read access alone (secrets in repos, data leaking
into PR text) is exfiltration surface. The constitution doc gestures at this with stricter
rulebooks, but the honest answer is: v1's habitat is *your own repos*. Design for that; treat
enterprise as a different product with a different trust model.

**Two-tier memory: half over-engineered.** The episodic tier (JSONL log, abandoned set, selection
state) earns its keep from night one. The semantic tier is where LLM memory systems rot:
agent-authored `notes.md` will accumulate confabulations ("tests here are flaky" from one flake)
with no provenance, no decay, no verification — self-reinforcing false beliefs that then bias
selection. And reflect/compaction solves a context-size problem you won't have for months at
a-few-repos scale. Also, quietly: **finding-hash dedup is fragile** — findings are prose, prose
doesn't hash stably across runs, and file-SHA staleness means any touch to a hot file reopens
everything. Expect dedup to silently degrade exactly where it matters (churny files).

**ADR 0002 contradicts ADR 0003.** MartinLoop's headline feature is a *hard dollar cap via
real-time spend metering*. On the subscription path there is no dollar metering — ADR 0003 says so
explicitly. So the "borrowed budget gate" doesn't work on your default execution path; at best
you're borrowing its verify-gate. The borrow list needs re-checking against this, and against the
fact that most of these are months-old solo GitHub projects.

## 3. Ideas to KILL

1. **Parallel mode.** Overnight, wall-clock time is the one resource you have in abundance; the only
   scarce resource is the shared quota window, and parallel makes the window race *worse* while
   adding worktree collisions and serialization caveats you've already had to write down. Sequential
   all night. Kill it — don't even keep it as rulebook-unlockable in v1.
2. **Chain mode as an agent-proposed plan.** Collapse into the outer loop (see above). The agent
   picks one item at a time; the runner loops.
3. **Live self-adjustment of selection weights.** The open question asks propose-only vs. live; the
   answer is propose-only *permanently until proven otherwise*, not "unlockable." It's the
   echo-chamber accelerator combined with the n=4 learning signal. Kill the live path.
4. **Enterprise/production server as a v1 design target.** It's distorting the docs — every note
   carries an enterprise caveat for a deployment you shouldn't attempt before the injection story and
   the trust story exist.
5. **MartinLoop as the budget gate** on the subscription path. Incoherent with ADR 0003. Keep at
   most the verify/rollback idea as pattern, not dependency.
6. **Reflect/compaction in v1.** Premature at your scale; revisit when the log actually outgrows
   context.

## 4. Wild ideas worth adding

1. **Honeypot repo.** Keep one canary repo in the whitelist seeded with adversarial content
   (injection attempts in comments, fake secrets, a "please disable branch protection" TODO). Every
   night is automatically also a red-team run; the digest reports whether the steward took the bait.
   Turns your biggest unaddressed risk into a nightly regression test.
2. **Shadow nights.** Before any repo graduates to fix-mode, the steward writes what it *would have*
   PRed. Weeks later, compare against what humans actually changed. Free ground truth for the
   trust-ramp, zero risk, and it fixes the n=4 retrospective problem.
3. **Seeded-fault recall tests.** Occasionally plant a known synthetic bug in a sandbox copy and
   check whether the steward finds it. Everything else in the design measures precision (was the PR
   good?); nothing measures *recall* (what did it miss?).
4. **Calibration-based autonomy.** Each PR ships with a self-reported confidence; track calibration
   (predicted vs. actual acceptance) over time. Grant fix-mode on *calibration*, not acceptance rate
   — a steward that knows what it doesn't know is safer than one with a lucky streak.
5. **Multi-night investigations.** Not everything is a one-night fix. Let the ledger carry epics —
   "flaky test in repo X, night 3 of evidence-gathering" — that accumulate observations across
   nights before proposing anything. This is the only idea that makes memory *leverage* rather than
   bookkeeping, and it's the capability none of the prior art has.
6. **The do-nothing report.** Nights where nothing shipped still produce a digest: what was
   considered, why each was rejected. Makes the asymmetry *observable*, builds trust in restraint,
   and gives you review data on the abandoned set (was that really a false positive?).
7. **In-repo consent marker.** A `NIGHTSHIFT.md` (robots.txt-style) in the target repo: opt-in,
   local rules, "don't touch" declarations owned by the repo's own maintainers. Composes with the
   central rulebook and is the only credible path to the multi-owner/enterprise setting later.
8. **Decorrelated critic.** On the explicitly-opted-in API-key path (ADR 0003 already allows it),
   run the pre-flight critic on a *different model vendor*. Cheap (one diff review, not a work
   session), and it's the only real fix for correlated producer/critic blind spots.
9. **Quota tide-pool.** The steward learns your weekly usage rhythm and reserves your typical
   daytime need — spends freely Friday night, frugally Sunday night. Directly addresses the real
   budget failure mode from §2.

## 5. The sharpest open question

**What makes a night's output worth more than the human review time it consumes — and how do you
know within the first two weeks?**

The project will not die from a fork bomb; the governor and branch protection handle catastrophe. It
dies the boring way: three mornings of marginal draft-PRs, the human skims instead of reviews, then
stops opening them at all — at which point the "human verdict is ground truth" loop loses its ground
truth, the retrospective goes blind, the trust-ramp can't ramp, and nightshift becomes a cron job
producing unread artifacts. Every subsystem in these docs (selection, ledger, critic, digest) is
instrumentation *around* that value bar, but the bar itself — OPEN-QUESTIONS §5 — is delegated to a
critic with zero calibration data on day one. If the docs settle only one thing before
implementation tomorrow, settle this: the value-per-night north star (§1) and the value bar (§5) are
the same question, and it's the one that sinks the project if answered wrong.
