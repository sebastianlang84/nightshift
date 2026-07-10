# nightshift — todo / future ideas

Running list of enhancements to build later. Not design tensions (those live in OPEN-QUESTIONS.md)
and not the ratified v1 scope (ADR 0004) — just good ideas parked with enough context to act on.

## Scheduler — nightly 03:00 — DONE (2026-07-09)

**Shipped.** A systemd *user* timer fires `bin/nightshift-cron.sh` every night at 03:00 local
(`scheduler/nightshift.{service,timer}`, `Persistent=true` so a missed night runs at next wake,
`RandomizedDelaySec=120`). The launcher adds the three unattended-run essentials: a single-instance
`flock`, an explicit PATH (systemd's minimal env can't see `~/.local/bin/{claude,gh}`), and a
timestamped log under `~/.local/state/nightshift/logs/` (plus journald). Enabled + linger on; first
live fire Fri 2026-07-10 03:00. Manage with `bin/schedule.sh {install|enable|disable|status|logs|
dry-run|uninstall}` — this also subsumes the old "schedule management templates/scripts" item.

_PR-opening (revised 2026-07-10):_ the Runner *can* open a PR per shipped branch (`gh pr create`,
GitHub-only) but this is now **opt-in and OFF by default** (`NIGHTSHIFT_OPEN_PR=1` to enable).
A PR needs per-host API credentials the SSH transport doesn't provide, and the push identity (SSH)
and PR-API identity (token) are independent — so branch-only is the credential-free baseline and the
pushed `nightshift/*` branch is the unit of review (each host also prints a one-click "create PR" URL
on push). See ADR 0004 and "Multi-host PR automation (Lücke 1)". _(Supersedes the 2026-07-09 auto-PR
"default on" decision.)_

Open follow-ups on the scheduler (not blocking):
- **Sleep/suspend:** if the workstation suspends overnight the 03:00 fire is missed; `Persistent=true`
  catches it at next wake, but a true "wake to run" needs an RTC wake alarm — revisit if it matters.
- **Adaptive cadence / backoff** (from the nightly-review-pipeline skill): skip repos with no new
  commits, back off after empty runs. nightshift's open-branch cap already self-throttles, so this is
  a cost optimisation, not a correctness need.

## codemap structural index — fully autonomous (2026-07-10)

**Shipped.** explore/review can use `codemap_search`/`codemap_context` (an MCP tool — no Bash needed,
fits the capability model) to navigate structure instead of reading files blindly. **nightshift keeps
the index current itself**: before explore, the Runner runs `codemap index --approve --repo <repo>` —
local + incremental (seconds), so every run the index reflects tonight's code. No manual step, no
per-repo config, no staleness. `--approve` makes first-time indexing automatic because the rulebook is
already the human consent surface (you listed these repos). The agent runs in a throwaway worktree
(no index of its own), so the prompt tells it to query the stable real repo via `repoPath`. codemap
absent or an index failure → plain Read/Grep/Glob, no change. Kill switch: `NIGHTSHIFT_CODEMAP=0`.

Verified: MCP tool callable in the locked-down subprocess (`--tools` + `--dangerously-skip-permissions`);
full e2e where nightshift auto-indexed a sandbox and shipped a fix. Biggest payoff on large repos
(market-digest, 291 files) where blind reading is weakest and explore cost highest.

## Review = verify the claim, not judge the diff (2026-07-10)

**Shipped.** Reframed the pipeline around Sebastian's point (a review verifies a proposition against
truth — "is 2x = 4x/2" needs no diff/history) and the cold, first-contact reality (nightshift meets
most repos for the first time, with no privileged access to intent or history). Fable (cross-model)
hardened it into a policy:
- **explore** emits every finding as a FALSIFIABLE `claim` + a `verify` recipe + a `verifiability`
  class (`static` | `convention` | `runtime`); `confidence` redefined as "how completely provable
  statically", not vibes. Prefers correctness over craft. Craft is only raised if it cites THIS repo's
  own standard (else it's generic dogma → dropped).
- **review** runs the verification recipe against the RESULTING worktree (cwd = post-fix code; Grep is
  truth), and separates `proof: verified` from `proof: unproven`. Key guard: absence of a grep hit is
  not proof of absence when dynamic/string references (reflection, registries, CLI dispatch, entry
  points) are possible — so a clean grep is not blind trust. Unfalsifiable taste → abandon.
- **runtime findings** can't be statically proven (no Bash/execution) → ship only if safe-when-wrong,
  as `proof: unproven`, and the Runner stamps **[unverified]** on the PR title + digest so the morning
  human knows *this one needs tests before merge*. `proof`/`verifiability` now recorded in the ledger.
- Fixed the latent bug where review.md referenced a `worknote` the Runner never injected (the rewrite
  drops it — not seeing the producer's self-justification is the point: kills anchoring).
- **codemap role clarified:** its `repoPath` index is the REAL repo (no fix), so it's stale for "is
  the symbol still present after the edit" (use cwd Grep/Read for that). BUT for the reference hunt
  ("who references this name") it IS a valid verification aid — callers are unaffected by the fix, and
  its FTS surfaces symbol AND string references a `name(` grep misses. review.md uses it as the broad
  net; the "constructed / external name → unproven" clause still bounds it (no in-repo index proves a
  negative for runtime-constructed or out-of-repo references).

Verified: live static e2e (`verifiability:static` → `proof:verified`, no stamp) + unproven-path
plumbing (digest + PR title stamped `[unverified]`).

## Fable Nacht-1-Re-Review — Härtung geshippt (2026-07-10)

Nach dem ersten echten Timer-Lauf (03:00) ließ Sebastian **Fable** (cross-model) die Nachtarbeit
bewerten: beide offenen PRs (valuelens #1 invertierter Kommentar, market-digest #2 toter Validator)
unabhängig gegengeprüft → **beide korrekt, gemergt**. Fable fand kein falsches Ergebnis, aber echte
Prozess-Schwächen. Drei davon sofort eingearbeitet (Prompt-/Runner-only, kein Verhaltensrisiko):

- **`static-given-deps` als neue Verifiability-Klasse.** Fables schärfster Fund: PR #2 war als
  `proof:verified / static` gestempelt, aber der Dreh- und Angelpunkt („Pydantic v2 läuft Literal vor
  after-Validator") ist eine **Fremdbibliotheks-Semantik, durch keinen Repo-Grep beweisbar** — richtig
  aus Glück, nicht aus Beweis. Jetzt: explore stuft solche Claims als `static-given-deps` ein, nennt die
  Lib + wo die Version gepinnt ist; review MUSS die Semantik an der gepinnten Dependency bestätigen
  (installierte Package-Source / versionierte Docs lesen), sonst `proof:unproven` (+ `[unverified]`).
  (explore.md, review.md)
- **Root-Cause-Widening.** Ledger 2+3 waren dieselbe Ursache (5/150-Drift), auf zwei Files/Branches/
  Merges zersplittert. Jetzt: explore rahmt eine wiederkehrende Inkonsistenz als EINE Finding über alle
  Vorkommen (alle Orte in `verify`), review prüft, dass der Fix jeden Zwilling erwischt hat (sonst
  `revise`) — bounded durch das Change-Budget. (explore.md, review.md)
- **Evidence-Chain reist mit dem PR.** `open_pr` hängt jetzt Claim + Verifiability/Proof + Verify-Recipe
  + das, was der Reviewer tatsächlich fand, an den PR-Body → Morgen-Merge = 30-Sekunden-Audit statt
  Neu-Herleitung, und ein Rubber-Stamp-Review wird sichtbar statt versteckt. (bin/nightshift.sh open_pr)

Verifiziert: `bash -n` + PR-Body-Rendering-Smoke (voller static-given-deps-Fall zeigt die Verification-
Sektion, Fallback-Typo ohne Felder lässt sie sauber weg). Nicht separat e2e — Prompt-/Body-Wording auf
der bewiesenen Pipeline. Zwei Fable-Punkte bleiben offen: siehe NEXT (Harvest) + der Ledger-Schema-
Versions-Punkt dort.

## Craft / best-practice review — always on (2026-07-10)

**Shipped.** explore + review now cover **craft**, not just correctness: code smells, dead/unused
code, poor naming, needless complexity, inconsistency with the surrounding style. Grounded in the
repo's OWN standard (linter/formatter config, CONVENTIONS.md, CONTRIBUTING, surrounding code) — not
generic dogma — and held to the same smallness/reversibility/single-concern bar (no sweeping refactors,
no subjective restyle = churn). Finding types widened to
`bug|typo|doc|cleanup|smell|naming|convention|complexity`. Prompt-only change (explore.md, review.md);
always on. Verified with a claude e2e that found + fixed a pure-craft issue (unused `import os`, no
typo/bug present), shipped a correct 1-line diff.

## NEXT: verdict / harvest recording — the first human feedback loop

**This is the designated next build (Fable's ordering, 2026-07-10; Fable re-confirmed it dominates on
the night-1 review).** Today the ledger records `shipped` and then goes deaf: it never learns whether
the human **merged, closed, or deleted** the branch/PR. That human verdict is the only real ground-truth
signal in the whole system — and per Fable it is worth more than any additional machine reviewer,
because each same-vendor reviewer decorrelates less than the last while the human verdict decorrelates
completely. It is also the instrument that finally *validates or refutes* craft-always-on: if craft PRs
are mostly closed/deleted, craft mode is a churn generator; if merged, it earns its keep.

**Night-1 already demonstrated the gap twice:** (a) the finding-only entry (missing `extract_json.py` in
the docs table) is now actually FIXED in `docs/design/prototype.md`, but the ledger still reads
`outcome:finding` — it can't see its own resolution. (b) On 2026-07-10 the two open PRs (valuelens #1,
market-digest #2) were human-merged after a Fable review — the ledger doesn't record that verdict either.
Both are exactly the signal this build captures.

**Also fold in (Fable):** ledger schema drift. The proof/verifiability fields landed *between* the two
live nights, so early rows lack them (PR #1 unstamped, PR #2 stamped) — not nondeterminism, schema
evolution. Add a `schema_version` to ledger rows (and/or a one-time backfill) so a harvest/stats consumer
can tell "field absent because old schema" from "field genuinely empty."

Build sketch (do BEFORE any second-reviewer / merge-recommendation layer below):
- A harvest step (run at start of each night, and/or a `bin/harvest` command) that, for every ledger
  row with `outcome:"shipped"` and an open branch/PR, reconciles against reality: is the branch merged
  (`git branch --merged`, or the PR state via `gh pr view --json state,mergedAt`)? closed unmerged?
  deleted? still open? Write the result back as a `verdict` (merged | closed | deleted | open) + a
  timestamp — append a new ledger event rather than mutating the shipped row (keep it append-only).
- Surface it: a small stats line in the digest (merge rate, and merge rate split by `verifiability` /
  `proof` and by finding `type`) so the churn question is answered by data, not opinion.
- This is also what feeds the open-branch backpressure a truer signal (a closed/deleted branch frees a
  slot just like a merge). Builds on the review=verify work above (proof / verifiability per row).

## Scheduler-Koexistenz mit market-digest — geprüft, unkritisch (2026-07-10)

**Verdikt: kein echtes Issue, kein Blocker.** Geprüft, weil auf dieser Maschine neben nightshift die
market-digest-Timer laufen. Zeitlicher Überlapp existiert (`market-digest-tm-investing-fetch` feuert
stündlich `00..08,10..23:00` → auch **03:00:00**; `nightshift` feuert 03:00 +Jitter → real 03:00:15;
also dieselbe Minute). Aber die Berührungspunkte sind harmlos:
- **Datei/Git/Working-Tree: keine Kollision.** market-digest steht zwar in nightshifts rulebook, aber
  der tm-investing-Fetch schreibt nur nach `~/.local/state/market-digest` + `~/ai_stack_data/...`,
  NICHT ins Git-Working-Tree von `~/dev/market-digest`. Und nightshift arbeitet in einer Wegwerf-Worktree
  auf festem SHA — davon unberührt. Beide haben eigene `flock`s auf eigenen Lock-Dirs.
- **Geteiltes Claude-Konto: einzige reale Berührung, mild.** tm-investing ruft `claude` CLI auf
  (`TM_LLM_BACKEND=claude_cli`, Sonnet-5, Timeout 900s), nightshift ruft `claude` (Opus) zur selben
  Minute → beide ziehen aus demselben Abo-Rate-Limit. Worst case: nightshifts Explore wird langsamer
  oder kassiert ein `rate_limit_event` — **genau den Fall fängt der Parser seit f0e1898 ab** (Array-Shape).
  Kein Korrektheitsbruch. Zwei parallele CLI-Sessions sind fürs Abo normal; teils getrennte Modell-Kapazität.

Optionale billige Versicherung (nicht nötig): nightshift auf `OnCalendar=03:05` schieben, falls das
Morgen-Log Verlangsamung/Rate-Limits um 03:00 zeigt. 03:00 ist nicht sakrosankt. Erst bei Befund.

## PR / branch review mode — merge-recommendation layer

A separate mode that reviews **all open `nightshift/*` branches (or PRs)** and gives a
**merge / don't-merge recommendation** per branch — an extra review layer *on top* of the pipeline,
run with an **independent, empty context** (not the thread that produced the change).

**Value:**
- *Convenience / harvest:* turns the morning triage from "fetch + diff + judge each branch" into a
  ranked recommendation list — directly attacks the harvest-friction weak spot (re-review §2d/§5).
- *Extra safety:* a second, independent judgment before the human merges.

**Design notes for later:**
- Read-only + advisory: it recommends, never merges or pushes (consistent with "human merges").
- Fresh/empty context per branch reduces transcript-sycophancy — but same-model review still shares
  the producer's blind spots (re-review §2, fable wild-idea #8). For true decorrelation, run this
  layer on a *different model / vendor* (the opt-in API-key path, ADR 0003 allows it).
- Natural output: append recommendations to the morning digest (or a `reviews/<date>.md`).
- Could reconcile with the ledger: record the recommendation + (later) the human's actual verdict —
  the first place a real merge/verdict signal could re-enter the system (re-review §5).

## Capability escalation — can the agent widen its own tools? (2026-07-10)

Question raised: could the agent rewrite its config so a read-only profile gains Write tools? Should the
config be root-owned?

**Analysis (verified against the runner 2026-07-10):**
- The `--tools` allowlist is a **CLI argument** the Runner builds fresh per launch, hardcoded per stage
  (`claude_run` case: fix -> Read,Grep,Glob,Write,Edit; else -> Read,Grep,Glob). It is NOT read from any
  config file. `claude-settings.json` only wires the PreToolUse Bash guard and grants ZERO tools.
- So **read-only stages cannot self-escalate**: there is no tools-granting config to edit, and they have
  no Write/Edit/Bash primitive at all (empirically confirmed under `--dangerously-skip-permissions`). The
  premise fails twice. Root-owning config is unnecessary for read-only.
- **Real residual = the FIX stage.** It has Write/Edit (no Bash). Write/Edit take absolute paths and are
  NOT path-confined to the worktree (the guard matches only `Bash`), and the agent runs as the same uid
  that owns `bin/nightshift.sh` + `hooks/*` + `state/`. So a fix agent could overwrite the Runner or the
  hook scripts on disk to weaken a FUTURE run (not its own — args are fixed at exec): e.g. add Bash to the
  fix profile, or blank `hooks/pre-push`. Both confinement layers are Write-reachable this way.

**Options (proportionate first):**
- **Path-confine Write/Edit like Bash** — a PreToolUse guard that rejects Write/Edit to any path outside
  the current worktree (`$wd`). Same mechanism as the existing Bash guard, extended. Turns "fix can write
  anywhere" into "fix writes only its throwaway worktree." This is the right-sized fix and it also stops
  fix from touching `~/.bashrc`, target-repo non-git files, etc.
- **Root-own the control files** (`bin/nightshift.sh`, `hooks/`, `claude-settings.json`; mode 0644) as
  quick defense-in-depth — blocks the specific runner/hook-tamper vector. Caveats: `state/` must stay
  user-writable (runtime writes); `git pull` updates then need sudo; and it is a speed bump, not a jail
  (fix can still write any other wasti-owned file). Do NOT root-own the whole tree.
- **Full containment** (robust): run the fix agent as a dedicated unprivileged user or in bwrap/container
  with control files mounted read-only and `$HOME` isolated. Heaviest; revisit if fix-mode graduates
  beyond trusted local repos.
- Note the git-push confinement (Layer 1 pre-push hook + Layer 2 guard) is unaffected for the CURRENT
  run; the concern is strictly a fix agent editing those files to weaken the NEXT run. The path-confine
  guard closes exactly that.

## Deployment topology — the tool vs. the repos it tends (2026-07-09)

nightshift-the-tool lives in ONE git repo (github.com/sebastianlang84/nightshift), but is meant to
run on **several machines**, each tending that machine's **local** repos — which live on different
hosts (GitHub, Bitbucket e.g. `~/partflow`, GitLab, or bare/local). The control repo's host has
nothing to do with the target repos' hosts.

**Already handled (verified 2026-07-09; re-verified 2026-07-10):**
- Everything machine-specific is git-ignored — `rulebook.yaml`, `state/` (ledger/runs), `digests/`,
  `worktrees/`, `sandbox/`. So `git pull` to update the tool never clobbers local config/state.
  Re-checked 2026-07-10: `.gitignore` lists `/state/ /runs/ /digests/ /sandbox/ /worktrees/ rulebook.yaml`,
  `git ls-files state/` is empty (ledger untracked), `git check-ignore` confirms all — so the same-repo,
  many-machines checkout is safe: each install's ledger/rulebook stays local and un-versioned.
- `NIGHTSHIFT_HOME` is self-derived from the script path — no hardcoded location; clone anywhere.
- The core loop is host-agnostic (pure git over SSH: fetch/branch/push `nightshift/*`). The pre-push
  confinement is pure git and works against any remote.

**Still to handle:**
- **Document the deployment model** (README or `docs/design/deployment.md`) + graduate to an ADR:
  per-machine bootstrap = install `claude`+`jq` (+PR CLI) → clone → write `rulebook.yaml` → `schedule.sh
  install/enable`. Tool updates = `git pull` per machine.
- **One machine per target repo (v1 constraint).** The ledger is local per install; if the same repo
  is tended from two machines, ledgers diverge → duplicate findings/branches. State the constraint;
  a shared/remote ledger is out of v1 scope (memory-model.md).
- **Host-aware PR automation** — see next item; today PRs are GitHub-only, so Bitbucket/GitLab targets
  get bare branches regardless of where the control repo lives.

## Multi-host PR automation (Lücke 1, 2026-07-09)

`open_pr` only recognises `*github.com*` and shells out to `gh pr create`. On Bitbucket/GitLab remotes
it logs "no GitHub remote — PR skipped" and pushes a bare `nightshift/*` branch. So on `~/partflow`
(Bitbucket) the morning triage is branch-based, not PR-based.
- **Decided 2026-07-10: accept bare branches for now.** `NIGHTSHIFT_OPEN_PR` now defaults to 0, so no
  misleading "PR skipped" log and no credential needed; triage is branch-based across all hosts. Each
  host prints a one-click "create PR" URL on push (could be captured into the digest — small, no creds).
  Re-open the implement path (Bitbucket REST / GitLab, host-dispatched) only if/when API PRs are wanted
  and per-host credentials are provisioned.
- If implemented: keep it best-effort (branch is already pushed; a PR-API failure must not fail the run),
  mirroring the current GitHub path.

## Cost ceiling (2026-07-09)

No dollar/turn budget cap exists — the only caps are open-branch backpressure + per-run branch count
(ADR 0005). Observed: one findings-only explore on the real partflow codebase cost **~$4.60 / 357s**
(vs $0.18 on the toy sandbox) because explore reads many files under `--max-turns 25`. branch-fix over
several repos/night could run to tens of dollars.
- Consider a rulebook knob: per-stage `max_turns`, and/or a `ccusage`/`claude-token-lens` spend stop
  (ADR 0003 already names usage-window observation as the budget backstop — wire it in).

## Pre-go-live checklist (open from the 2026-07-09 readiness review)

The claude production path is now proven end-to-end (findings-only on partflow, accurate finding, zero
remote writes). Before enabling the live nightly timer on a real repo:
- **Verify Layer 2 under `--dangerously-skip-permissions`** — DONE (2026-07-09). Adversarial test:
  registered `hooks/pretooluse-guard.sh` as a PreToolUse hook exactly as the Runner does, launched
  `claude 2.1.197` with the production env+flags, had it attempt `git ... commit --no-verify ...`. The
  guard **fired** — verbatim deny "nightshift: git --no-verify would bypass the pre-push confinement
  hook"; a control command ran, the `--no-verify` one did not. So Layer 1 (git hook) + Layer 2 (guard)
  both hold in the unattended mode. Residual closed.
- **Server-side branch restrictions** — now defense-in-depth, not the sole backstop (Layer 2 proven).
  Still worth adding GitHub branch protection on `main` (with `enforce_admins`, else the agent's own
  admin creds bypass it) per target repo. Per-repo, per-host.
- **Graduate a repo to `branch-fix`** only with explicit human OK — it is the first real `nightshift/*`
  push to a shared remote. (The 4 live repos are already branch-fix in rulebook.yaml — human-approved.)
- **Enable the scheduler** — DONE; timer armed, first live fire Fri 2026-07-10 03:00.

_Also 2026-07-09:_ caught + fixed a latent parser bug — `claude -p --output-format json` returns an
ARRAY on 2.1.197 (result object as an element, when a rate_limit_event is present), but the Runner
parsed object-only (`.result`) → every explore would have reported `found:false` (silent no-op, no
branches). Now normalises both shapes (commit f0e1898); proven with a real-claude e2e that found+fixed
4 README typos and pushed a `nightshift/*` branch, with zero live-state pollution (commit e833979).
