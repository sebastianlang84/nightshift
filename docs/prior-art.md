# Prior art — adopt vs. build

Survey done 2026-07-08 (LLM web research). Scored against the 7 requirements below.

## The 7 requirements

1. Runs unattended on a schedule (nightly), no human watching.
2. Works across **multiple** repos and **self-selects** what to work on.
3. Persistent **memory/ledger** to avoid repeating work.
4. **Configurable rules/policy** (allowed repos, tools, limits, prohibitions).
5. Both **reviews and fixes** — fixes as test-gated draft PRs, no auto-merge.
6. **Budget-aware** — uses a subscription/quota window and stops.
7. **Self-hostable**, uses your own subscription/key (not per-seat SaaS).

## Bottom line

**No off-the-shelf, self-hostable product covers all 7.** The architecturally closest *complete*
thing is Anthropic's **Claude Code Routines** — but it runs in Anthropic's cloud, is Research
Preview, and bills via API tokens, failing #6 and #7. In the self-hosted camp, two patterns hit
~5/7: **Aeon** (a GitHub-Actions "agent OS") and the **Ralph-loop** DIY family. The specific
combination — autonomous multi-repo **self-prioritization** + a ledger against duplicate work +
policy + review *and* fix + quota-window budget — exists nowhere as one product. **That is our gap.**

## Tools by group

### 1. Self-hostable autonomous agent "operating systems" (closest to the concept)
- **Aeon** — <https://github.com/aaronjmars/aeon> — MIT. Fork + YAML + GitHub Actions cron; state in
  `memory/MEMORY.md` (skills `memory-flush`/`reflect`/`goal-tracker`); policy via `STRATEGY.md` +
  self-hosted "Fleet Watcher" ALLOW/BLOCK with per-skill caps; dev skills (pr-review, issue-triage,
  code-health, repo-scanner, cost/spend-monitor); fix via labeling an issue `ai-build`. Auth via
  Pro/Max sub or key. **Gaps:** fixing is issue-*triggered*, not self-prioritizing across repos;
  generic background-agent bloat + a crypto-token (AEON) affiliation to strip out.
- **oss-autopilot** — <https://github.com/costajohnt/oss-autopilot> — hits the rarest requirement:
  cross-repo **self-prioritization**. Repo score 1–10 (merge/close history, recency, maintainer
  responsiveness), `minRepoScoreThreshold` cutoff, anti-LLM-policy skip (scans CONTRIBUTING/README).
  Headless cron; CLI + MCP + Claude Code plugin; private repos ok. **Gaps:** aimed at OSS
  *contribution*, not tending your own repos; drafts only (human-approval gate); GitHub-only. Great
  template for "ledger + multi-repo discovery + scoring".
- **nodeglobal/agents** — <https://github.com/nodeglobal/agents> — self-hosted, Claude-Code-based,
  multi-project `config.yaml`, **SQLite** memory, weekly self-improvement, isolated worktrees,
  validator agent (0–100 + retry). **Gap:** task-submission + approval gate; no nightly self-select.

### 2. Budget/safety wrappers (requirement #6 as a ready module)
- **MartinLoop** — <https://martinloop.com> · <https://github.com/Keesan12/martin-loop> — Apache-2.0.
  Wraps any agent run with a hard $ budget cap (real-time spend, stop before cap), smart-exit on
  diminishing returns, verifier gate (`--verify "pnpm test"`), rollback, receipts. Wraps
  Claude/Codex/Cursor. **Gap:** single-run; no scheduler/multi-repo/ledger. Ideal as a budget+test
  gate module.

### 3. DIY overnight loops (the pattern we'll likely reuse)
- **Ralph-loop** (Geoffrey Huntley) + impls: <https://github.com/frankbria/ralph-claude-code>, `dex`,
  `ralph-orchestrator`. A recursive loop where the agent re-reads a prompt file each iteration and
  uses the **filesystem/git/TODO file as memory** (fresh context per iteration). Anthropic documents
  this for long-running work (progress file, test oracle, CLAUDE.md rules the agent updates). One
  tool in the `ralph-loop` topic is nearly single-repo nightshift: works a GitHub issue backlog
  overnight with Claude Code, hands you a branch in the morning, never pushes/PRs — on your sub quota.

### 4. AI review/auto-fix bots (strong at review+fix, weak elsewhere — all PR/issue-*triggered*)
- **Qodo Merge / PR-Agent** — <https://github.com/qodo-ai/pr-agent> — most interesting: open source,
  self-hostable with your own keys (even local via Ollama), per-repo `.pr_agent.toml`, multi-agent
  (bug/security/quality/coverage). **Gap:** PR-triggered; no scheduler/ledger/multi-repo self-select.
- **CodeRabbit** — SaaS; self-host only Enterprise (~$15k/mo). Effectively out for self-host.
- **Greptile** — $30/seat; self-host only Enterprise; PR-triggered.
- **Cursor BugBot** — GitHub-only SaaS; Autofix spawns a cloud agent that patches in-PR. PR-triggered.
- **Ellipsis** — SaaS, reviews every commit, can open a side-PR with fixes. PR-triggered.
- **Sweep** — <https://github.com/sweepai/sweep> — Apache-2.0, self-hostable; issue → PR. Single-repo.
- **Sourcery / Bito / Codacy / SonarQube** — similar (seat SaaS or narrow).

### 5. Autonomous coding agents (task-driven, not scheduled self-selecting)
- **OpenHands** — <https://github.com/All-Hands-AI/OpenHands> — OSS, headless-capable, self-host.
  Per-task; no nightshift scheduler/ledger.
- **Aider** (OSS CLI, scriptable, single-task); **Devin** (SaaS, per-ACU); **SWE-agent** (research,
  one issue/run).
- **Copilot Coding Agent / Codex Cloud / Google Jules / Kiro** — mostly cloud/managed, sub-per-plan,
  not self-host/own-key. Notable: **Codex** CLI `/goal` loops until self-evaluated done or the token
  **budget** is spent (Apache-2.0); **Kiro** can coordinate multiple repos on a schedule (managed).

### 6. Scheduled PR bots as a pattern (req 1+2+4, but no LLM fixing)
- **Renovate** — <https://docs.renovatebot.com/self-hosted-configuration/> — the archetype:
  self-host, cron, multi-repo autodiscover, very rule-heavy (`minimumReleaseAge`, …), opens PRs.
  **Gap:** dependency updates only. Perfect *model* for "scheduled + multi-repo + policy + PR".

## Comparison table

Legend: ✓ yes · ◐ partial · ✗ no

| Tool | 1 Scheduled | 2 Multi-repo + self-select | 3 Ledger | 4 Policy | 5 Review **&** fix (draft-PR) | 6 Budget | 7 Self-host + own sub/key |
|---|---|---|---|---|---|---|---|
| **Claude Code Routines** | ✓ cron | ◐ multi, no self-select | ◐ per routine | ◐ prompt scope | ✓ review + PR | ✗ API tokens | ✗ Anthropic cloud |
| **Aeon** | ✓ GH-Actions cron | ◐ cross-repo, issue-triggered | ✓ MEMORY.md | ✓ STRATEGY.md + ALLOW/BLOCK | ◐ review ✓, fix via `ai-build` label | ◐ cost/spend-monitor | ✓ MIT, Pro/Max or key |
| **oss-autopilot** | ✓ headless cron | ✓ discovery + repo scoring | ✓ state + history | ✓ score threshold + anti-LLM skip | ◐ drafts, posts after approval | ◐ rate-limit aware | ✓ plugin/CLI, gh auth |
| **nodeglobal/agents** | ◐ task-submit | ◐ multi-project, no self-select | ✓ SQLite | ◐ config + validator | ◐ builds, approval gate | ✗ | ✓ self-host, key |
| **MartinLoop** | ✗ (wrapper) | ✗ | ◐ receipts | ◐ stop/verify | ◐ verifier + rollback | ✓ hard $ cap + smart-exit | ✓ Apache-2.0, BYO-agent |
| **Ralph-loop (DIY)** | ◐ you build cron | ◐ you build self-select | ✓ fs/git/TODO | ◐ CLAUDE.md rules | ◐ you build PR gate | ◐ via `claude -p` window | ✓ full, `claude -p` |
| **Qodo Merge / PR-Agent** | ✗ PR-triggered | ✗ single-PR | ✗ | ✓ .pr_agent.toml | ✓ review + /improve | ✗ | ✓ self-host, own keys |
| **CodeRabbit** | ✗ PR-triggered | ✗ | ◐ learns | ✓ rules | ◐ review + suggest | ✗ seat | ✗ (self-host $15k/mo) |
| **Greptile** | ✗ PR-triggered | ✗ | ◐ learns | ✓ custom rules + API | ◐ review + fix-suggest | ✗ seat | ◐ Enterprise self-host |
| **Cursor BugBot** | ✗ PR-triggered | ✗ | ◐ learned rules | ✓ BUGBOT.md | ✓ review + autofix-PR | ✗ usage | ✗ SaaS, GitHub-only |
| **Sweep** | ✗ issue-triggered | ✗ single-repo | ◐ vector index | ◐ | ✓ issue→fix-PR | ✗ | ✓ Apache-2.0, self-host |
| **OpenHands** | ✗ task | ✗ | ◐ | ◐ | ✓ generates fixes | ✗ | ✓ self-host, own keys |
| **Renovate** | ✓ cron | ✓ autodiscover (deps only) | ◐ dep dashboard | ✓ very granular | ✗ dep bumps only | n/a | ✓ self-host |
| **Copilot Agent / Kiro / Codex Cloud** | ◐/✓ | ◐ Kiro multi-repo | ◐ | ◐ | ✓ issue→draft-PR | ◐ Codex `/goal` budget | ✗ managed/sub-per-plan |

## Verdict

**Nothing off-the-shelf fits** (self-hosted, own sub, autonomous nightly, across your own repos,
with ledger + policy). Each tool fails at least one hard requirement:

- Review/fix *quality* is solved (Qodo/PR-Agent self-hosted, Sweep, OpenHands) — but all are
  **event-triggered**; none self-selects work across repos overnight.
- The *scheduler + cross-repo + memory + policy* frame is solved (Aeon, oss-autopilot, Renovate
  pattern) — but none autonomously *fixes your own repos with test-gated draft PRs*.
- The *budget gate* is solved (MartinLoop, Codex `/goal`) — but isolated.

### Decision: build the brain, borrow the body
Do **not** build from scratch. Combine three existing pieces and write only the orchestration brain:

1. **Runtime + subscription use:** `claude -p` headless (first-party, ToS-safe) in the **Ralph-loop
   pattern** — filesystem/git as ledger substrate, `CLAUDE.md`/`AGENTS.md` as rulebook. Reference
   architecture: Aeon's GH-Actions cron.
2. **Budget/test gate:** **MartinLoop** as the wrapper (`--budget`, `--verify`) for #5 + #6.
3. **Multi-repo discovery + scoring + ledger:** adapt **oss-autopilot**'s heuristics (repo score,
   threshold, "what's due") to *your own* repos.

**The unfilled core — what nightshift builds — is the middle layer: cross-repo self-prioritization
with a dedicated ledger** (a + b). Requirements c/d/e are largely off-the-shelf (MartinLoop +
CLAUDE.md + branch protection). Every review bot (PR-triggered) and every coding agent (task-driven)
skips exactly the self-prioritization + ledger. **If we build, build that; borrow the rest.**

### ToS constraint (affects design)
Anthropic actively shut down third-party tools that tapped the subscription quota outside Claude
Code in 2026. Keep `claude -p` as the execution layer and respect the 5h/weekly windows (usage
trackers: `ccusage`, `claude-token-lens`). Do **not** put the subscription token into a custom API
wrapper — that is the move that gets broken. See [ADR 0003](adr/0003-subscription-safe-execution.md).
