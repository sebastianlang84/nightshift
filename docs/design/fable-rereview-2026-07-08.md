# Fable re-review — nightshift v1 design (post-scope-cut)

- Reviewer: fable (claude-fable-5), 2026-07-08, after ADR 0004. Verbatim, unedited.
- Brief: sharp critic, read-only. Did the v1 cut resolve the prior critique
  ([`fable-review-2026-07-08.md`](fable-review-2026-07-08.md))? New holes? Doc-system soundness?
  What to kill/simplify, what's missing, the single sharpest open question.

---

**Headline verdict:** ADR 0004 is a genuinely good cut. It found the one decision — branch-only
output — that lets you delete five subsystems at once, and it correctly identifies that most of my
prior critique was aimed at machinery that only exists to protect a merge path v1 no longer has. But
it made one trade it hasn't admitted: **the load-bearing property (branch isolation) is itself not
mechanically enforced**, and the value-measurement half of my prior sharpest question was deleted
along with the safety half. Details below.

## 1. Prior §2 weaknesses, point by point

**1. Governor / budget bomb — genuinely resolved, with one unit-of-account bug.** `max_runs_per_night`
× per-run `--max-turns`/wall-clock × auto-compact-off (ADR 0004, "Budget") bounds total consumption
structurally, which the old spawn-depth caps never did. Usage-observation demoted to backstop is
right. Residual defect: ADR 0004 defines the pipeline as `Select → Explore → Fix ⟷ Review →
Finalize`, *each a fresh `claude -p`*, with Fix⟷Review capped at N iterations — so one "run" is
actually ~4–2N+3 invocations. Is `max_runs_per_night: 3` three work-items (~20+ invocations) or three
invocations (less than one work-item)? The budget's primary control is denominated in a unit the same
ADR made ambiguous. Define it in invocations or state the multiplier.

**2. Chain-mode redundancy — genuinely resolved.** ADR 0004 explicitly supersedes chain/parallel and
the agent-proposed `{mode, items[]}` plan. The runner-enforced iteration cap is the right shape.
Hygiene problem: `execution-modes.md` still reads "idea-stage, not decided" with no superseded
banner, and `docs/design/README.md` still advertises it straight-faced. See §3 — this repo is
currently violating its own documentation invariants.

**3. Critic bias — dissolved by scope cut, correctly.** With nothing merging, correlated
producer/critic blind spots are a taste problem, and taste problems don't need a decorrelated vendor.
Acceptable. One nit: the digest ships "(repo, what, why, confidence)" — that confidence is
uncalibrated self-report by the same model that wrote the fix. Printing it invites the human to trust
a number that means nothing. Either drop it or label it as vibes.

**4. Retrospective at n=4 — dissolved by removal.** No auto trust-ramp, no live weight adjustment; the
rulebook `mode` knob is the trust-ramp. Clean. But `OPEN-QUESTIONS.md` §5 and §7 still cite
`self-evaluation.md`'s critic-as-gate and retrospective under headings marked RESOLVED — the
"Elaborated" pointers now point at superseded designs.

**5. Prompt injection — dissolved by scope cut, with an unexamined residual.** "Owner's own repos" is
the right v1 habitat and the deferral is honest (ADR 0004, "Habitat"). But *own repo ≠ own content*:
vendored dependencies, `node_modules`, contributors' branches, and test fixtures are third-party text
the Explore stage will read at 3am in unattended mode. The deferral is acceptable only because the
blast radius is bounded — and per §2 below, the blast radius is bounded by a hook that watches only
git.

**6. Enterprise framing — genuinely resolved in the ADR, unresolved in the constitution.** ADR 0004
narrows the habitat, but `constitution-and-rulebook.md` still tells the agent *"This may be a
production / enterprise server"* in the four-pillars stakes paragraph, and promises *"draft-PR, never
a merge"* — both now false. Shipping a system prompt that lies to the agent about its own deployment
is not harmless: stakes framing shapes behavior, and the PR promise contradicts the actual output
contract. The constitution needs rewriting for the branch-only world, not just a caveat.

**7. Two-tier memory — genuinely resolved, but the "non-blocking" label on staleness is wrong.**
`documentation-system.md` drops the semantic tier; episodic-only is right. But ADR 0004 files the
finding-hash/staleness rule under "still open, non-blocking." It's blocking. The abandoned set is the
anti-nag mechanism — the thing my prior review called "the difference between a steward and a nag" —
and it needs a working finding identity by **night two**, because LLM explorers reliably re-converge
on the same salient findings. Prose doesn't hash stably; without at least a crude rule (file path +
finding type + line-window, say), `abandoned.jsonl` is decorative.

**8. ADR 0002 vs 0003 — resolved in ADR 0004, but the losing documents were never updated.** ADR
0002's Decision still names MartinLoop for the budget/test gate; `CONTEXT.md` ("Scope" section) still
says "a wrapper like MartinLoop for the budget/verify gate"; `CONTEXT.md` Non-goals still says
"Humans review the morning-after PRs." `CONTEXT.md` declares itself canonical in its own header and
contradicts ADR 0004 in two places. ADR 0002 needs an amendment note; CONTEXT.md needs the sweep.

**Score: 5 genuinely resolved, 2 dissolved-by-scope-cut legitimately, 0 newly worse — but 6
documents now contain statements the ADR overruled.** The decisions are good; the corpus hasn't
caught up with them.

## 2. New holes introduced by the v1 decisions

**(a) The load-bearing wall is not load-bearing.** ADR 0004's entire argument is "output is
branch-isolated, therefore bad output is cheap." Then the safety section allows normal pushes
*including to main*, on the theory that a wrong push is git-revertible. Two problems. First: this
leaves the single property everything rests on — branch-only — enforced by prompt, which is exactly
the posture `constitution-and-rulebook.md` correctly forbids ("prompt = intent, enforcement =
guarantee"). The v1 design's one guarantee is a hope. Second: "reversible" is defined git-locally,
but consequences aren't. A push to main at 3am triggers whatever `on: push` CI exists — deploys,
package publishes (npm is immutable), webhooks, emails. Git revert un-does none of that.
Irreversibility lives in CI, not in the ref update. The fix is one line: the hook (or the Finalize
push script — note the matrix has the *Brain* doing the push, which makes this trivial) allows pushes
only to `branch_prefix`-matching refspecs. There is no argument for a branch-only steward holding
push-to-main capability, and the ADR's explicit choice to allow it undermines its own headline.

**(b) The hook watches git; unattended mode grants the shell.** "Irreversible operations" in v1 means
force-push and ref deletes. But the agent in unattended permission mode can run `gh` (close issues,
comment, worse), `curl`, `npm publish`, `rm -rf` outside the worktree — none of it git, none of it
hooked, plenty of it irreversible. Worktree isolation is mentioned only as a borrowed pattern (OQ
§8), not as an enforced invariant in ADR 0004's safety paragraph. For owner's-own-repos v1 this may
be an accepted risk — but then *accept it in writing*. Right now the safety section reads as more
complete than it is.

**(c) Branch pushes trigger CI too.** `nightshift/*` pushes will run workflows on any repo with
unrestricted `on: push` — Actions minutes, arbitrary workflow code, preview deploys. Cheap mitigation
exists (`[skip ci]` trailer policy, or a rulebook note per repo); currently absent.

**(d) The v1 cut lowered the cost of a bad change and raised the cost of harvesting a good one.** A PR
has a rendered diff, CI status, and a merge button. A bare `nightshift/*` branch requires fetch,
checkout/diff, manual merge, manual delete. The north star is value-per-night; v1's output format
makes value strictly harder to collect than the format it replaced, and nothing prevents branch
litter (who deletes stale branches? unaddressed). Worse: v1 dropped verdict harvesting entirely — the
ledger records "pushed" and never learns whether the branch was merged, ignored, or deleted in
disgust. The boring-death loop from my prior review (human stops looking → ground truth gone) is not
mitigated by v1; it's *un-instrumented* by v1. Deferring learning is fine. Not measuring harvest at
all means the north-star metric is unobservable. See §5.

**(e) `findings-only` mode betrays the argument.** If branch-isolation truly downgrades bad output to
"a branch you delete," a findings-only mode has no reason to exist — branch-fix is already harmless
by the ADR's own logic. Its survival as the trust-ramp reveals the true cost model: branches cost
*human review time*, which is exactly the resource the ADR's argument waves away as "quality not
taste." Either the argument is right and findings-only should be cut, or review-time is a real cost
and the "soft value bar" is under-designed. You can't hold both. (Also: where do findings-only
findings *land*? The matrix's Finalize row only has push-or-abandon; there's no findings path.
Under-specified.)

## 3. The documentation system

The four invariants are the right invariants. The matrix has real holes:

**(a) `abandoned.jsonl` violates invariants 1 and 2.** The ledger is declared SINGLE TRUTH, yet the
fact "this finding was abandoned as a false positive" is written twice — as a ledger outcome *and* as
an `abandoned.jsonl` row — by the same Finalize stage, non-atomically. That is a maintained-in-
parallel fact, precisely what invariant 2 forbids elsewhere. Crash between the two appends and they
disagree, with no stated reconciliation rule. Either `abandoned.jsonl` is a *derived index*
regenerated from `ledger.jsonl` (fine, say so, and say who regenerates), or the anti-retry data
(finding-hash, reason) lives only in the ledger entry and Select filters for it. Pick one.

**(b) Every derived view except the digest has no deriver.** Select reads "ledger (distilled)";
Explore reads "'already done here' (derived from ledger)." Distilled and derived *by which stage,
when*? No row in the matrix produces these artifacts. If the Brain synthesizes them in-memory per
run, the matrix should say so (and that's code that must exist); if they're written to disk,
invariant 2's "never stored" is violated. The central-ledger-with-derived-views claim is sound only
if derivation is someone's job; right now it's nobody's.

**(c) Push-then-append has no ordering or crash rule.** Finalize's write is really two: a push to the
*target* repo, then a ledger append in the *control* repo. Crash between them → an orphan branch the
ledger doesn't know, invisible to the digest and to don't-repeat. State the order and the recovery
scan (cheap: on startup, list remote `nightshift/*` branches, reconcile against ledger).

**(d) `NIGHTSHIFT.md` is read by Explore only.** Fix reads `finding.json` + target files — so a
"don't touch" glob constrains Fix only if Explore faithfully transcribes it into the finding. A
repo-local prohibition enforced via a game of telephone through one LLM stage is not enforcement. The
Brain should evaluate NIGHTSHIFT.md rules against the diff at Finalize, mechanically.

**(e) The ledger has no reconciliation with reality.** The human merges or deletes branches (mutating
target repos), but the human's only write in the matrix is `rulebook.yaml`. Ledger entries say
"branch pushed" forever; the "already done here" view slowly fills with dead facts. Even without v1
verdict-learning, a mechanical branch-still-exists check would keep the view honest.

**(f) The meta-irony.** The note's closing claim — "this mirrors the project's own doc philosophy" —
is currently false in the embarrassing direction: as catalogued in §1, CONTEXT.md, OPEN-QUESTIONS.md,
ADR 0002, and three design notes hold hand-maintained parallel statements that have already drifted
from ADR 0004, within *hours* of ratification. The runtime system's invariant 2 exists precisely
because this happens. Apply it to the design corpus: superseded banners on `execution-modes.md`,
`memory-model.md`, `self-evaluation.md`; sweep CONTEXT.md and the constitution note.

Single-writer-per-artifact itself is sound for v1 (sequential pipeline), and honestly future-proofs
less than claimed — under any future parallelism, multiple Finalize instances share the ledger append
— but that's a tomorrow problem and JSONL append is the right substrate today.

## 4. Kill / simplify further, and what's missing

**Kill or simplify:**
1. **Kill push-to-main capability.** Hook allows only `nightshift/*` refspecs (plus block `+refspec`
   force syntax and `:branch` empty-refspec deletes — a naive `--force` regex misses both classic
   bypasses). This turns the load-bearing claim into a mechanism and simplifies the safety story to
   one sentence.
2. **Kill `abandoned.jsonl` as a written file** — derive it, or fold it into ledger outcomes (§3a).
3. **Kill `backlog.md` for v1.** It's the semantic tier's last remnant: agent-authored free-prose
   Markdown with no provenance. `outcome: deferred` ledger entries + a digest section cover the same
   need without reintroducing the confabulation surface I flagged in the prior review.
4. **Kill the confidence number in the digest**, or label it self-report.
5. **Decide `findings-only`'s fate** (§2e): either cut it (trust the branch-isolation argument fully)
   or keep it and admit review-time is the real cost being managed.
6. `OPEN-QUESTIONS.md` §9's residual action ("verify licenses/maturity of borrowed pieces") is mostly
   moot now that borrowing is patterns-only; close it.

**Missing for one real night:**
- **The hook spec itself** — exact command patterns, including the bypass syntaxes above. This is the
  only safety mechanism; it deserves more than a parenthetical.
- **The distillation step** (§3b) — the actual code path from ledger to Select/Explore context.
- **A minimal finding-identity rule** — blocking by night two (§1.7).
- **Crash/failure handling** — run dies mid-night: stale worktrees, orphan branches, whether the
  night resumes or aborts.
- **Cold-start selection** — "signals/scoring detail deferred to build" (OQ §1), but the selector is
  *the* novel component per ADR 0002, and night one runs against an empty ledger. What signal makes
  it pick anything? Even a dumb v1 rule (round-robin + churn) should be written down before code.
- **CI-trigger policy** for `nightshift/*` pushes (§2c).
- **Secrets hygiene for the control repo**: `finding.json`, `worknote.md`, and digests will quote
  target-repo content verbatim; if a repo contains a secret, it now lives in the control repo's git
  history too. One redaction rule, stated.

## 5. The sharpest open question

**By what concrete mechanism does a `nightshift/*` branch become merged code — and what, if anything,
records that it did?**

Everything in v1 optimizes "value-per-night," and v1 deleted every instrument that could observe it.
The morning workflow is unspecified past "read the digest, then the branches": no defined path from
branch to merge, no verdict field in the ledger schema, no branch-lifecycle reconciliation. If
branches go unreviewed — the boring death I named last time — v1's value-per-night is zero *by its
own north star*, and the system cannot tell. This must be settled before orchestration code because
it decides the ledger schema (verdict field or explicitly none), the digest format (is it a worklist
or a report?), and possibly the output format itself (a branch plus a one-line `gh pr create` command
in the digest costs nothing and halves harvest friction). ADR 0004 answered the safety half of my
prior sharpest question and quietly deleted the measurement half. Put it back — one field and one
morning ritual is enough for v1.

---

**Bottom line:** the cut is real, the ADR is the best document in the repo, and the design is now
small enough to build. Three things stand between it and an honest first night: enforce branch-only
mechanically instead of asserting it, give the abandoned/derived-view machinery an actual owner in
the matrix, and define the morning harvest so value-per-night is observable. The rest is doc-sweep.
