#!/usr/bin/env bash
# Sourced by bin/nightshift.sh after its path globals are initialized.

# The Runner-owned CODEX_HOME a codex stage runs under (ADR 0019) — echoes the path, empty on
# failure. It deliberately contains NOTHING but a symlink to the operator's credentials: no
# AGENTS.md (the leak this closes), no config.toml, no skills, no memories, no session history.
# NIGHTSHIFT_CODEX_STAGE_HOME overrides the location; set it EMPTY to run under the operator's real
# home instead (escape hatch — reopens the leak). Cheap enough to re-assert per stage, and doing so
# self-heals a stale symlink after `codex login`.
codex_stage_home() {
  local real stage
  real="${CODEX_HOME:-$HOME/.codex}"
  stage="${NIGHTSHIFT_CODEX_STAGE_HOME-$STATE_DIR/codex-home}"
  [ -n "$stage" ] || { printf '%s' "$real"; return 0; }
  mkdir -p "$stage" || { log "codex stage home $stage not creatable"; return 1; }
  # Same path = the operator's own home; never relink credentials onto themselves.
  # Reaching the operator's own directory is a supported escape hatch, but never a silent one: it
  # reopens the AGENTS.md leak this function exists to close, and a stage worknote is pushed.
  [ "$(cd "$stage" && pwd -P)" != "$(cd "$real" 2>/dev/null && pwd -P || echo "$real")" ] || {
    log "WARNING: pi stage home IS the operator's pi directory ($real) — stages inherit its AGENTS.md"
    printf '%s' "$stage"; return 0; }
  if [ -e "$real/auth.json" ]; then
    ln -sfn "$real/auth.json" "$stage/auth.json"
  else
    # No credential file to carry over (e.g. API-key-in-env auth). Isolating still beats leaking:
    # codex fails loudly on a real auth problem, whereas falling back to the real home would fail
    # SILENTLY — as a leak nobody sees until it is in a commit body.
    log "codex: no auth.json under $real — stage home carries no credentials"
  fi
  printf '%s' "$stage"
}

# The Runner-owned agent dir a pi stage runs under (ADR 0019 / ADR 0031) — echoes the path, empty on
# failure. pi resolves ~/.pi/agent from $PI_CODING_AGENT_DIR, and that directory holds the operator's
# global AGENTS.md, which pi injects into EVERY stage: verified 2026-08-30 against pi 0.84.2, a stage
# launched with --no-extensions --no-skills --no-prompt-templates and a cwd outside $HOME still named
# ~/.pi/agent/AGENTS.md as an injected instruction file. `--no-context-files` is the wrong lever — it
# is all-or-nothing and would drop the TARGET repo's AGENTS.md too, which a stage legitimately needs.
# So the same shape as codex_stage_home: a Runner-owned dir holding NOTHING but symlinks to the
# credential store and the model catalogs — personal config out, repo AGENTS.md unaffected. Verified
# with the same probe: the stage answered NONE.
# NIGHTSHIFT_PI_STAGE_HOME overrides the location; set it EMPTY to run under the operator's real pi
# dir instead (escape hatch — reopens the leak).
pi_stage_home() {
  local real stage f
  real="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
  stage="${NIGHTSHIFT_PI_STAGE_HOME-$STATE_DIR/pi-home}"
  [ -n "$stage" ] || { printf '%s' "$real"; return 0; }
  mkdir -p "$stage" || { log "pi stage home $stage not creatable"; return 1; }
  # Reaching the operator's own directory is a supported escape hatch, but never a silent one: it
  # reopens the AGENTS.md leak this function exists to close, and a stage worknote is pushed.
  [ "$(cd "$stage" && pwd -P)" != "$(cd "$real" 2>/dev/null && pwd -P || echo "$real")" ] || {
    log "WARNING: pi stage home IS the operator's pi directory ($real) — stages inherit its AGENTS.md"
    printf '%s' "$stage"; return 0; }
  # auth.json carries the credentials; the models*.json catalogs are what let pi RESOLVE a model id
  # at all — without them a `--model` the operator declared is rejected as unknown before any
  # request is made. Both are re-linked per stage, which self-heals a stale link after `pi auth`.
  for f in auth.json models.json models-store.json; do
    if [ -e "$real/$f" ]; then
      ln -sfn "$real/$f" "$stage/$f"
    else
      rm -f "$stage/$f"
      [ "$f" != auth.json ] || log "pi: no auth.json under $real — stage home carries no credentials"
    fi
  done
  printf '%s' "$stage"
}
# Credential-failure signatures, matched against what the CLI says about ITSELF: the stage's
# captured stderr, plus the CLI's own verdict inside raw stdout (the claude CLI reports the failure
# as a JSON result object there, codex on stderr). Deliberately broad, because a false negative
# costs a forged clean fleet.
AGENT_AUTH_RE='not logged in|/login|authentication_failed|invalid api key|unauthorized|oauth token|credentials? (not found|expired|invalid)|codex login'

# The signatures are PROSE, and prose matched against a stage's whole raw stdout matches the prose
# of the repo under review. On 2026-08-24 an explore lens read bin/nightshift.sh — including line
# 331, which self-heals a stale symlink after `codex login` — and AGENT_AUTH_RE read that as the
# account being logged out. The night aborted after one stage while .usage_explore recorded 29,600
# output tokens, 2.4M cache reads and $3.32 spent; a CLI that cannot authenticate spends nothing.
# The pattern sits latent in 33 of 197 archived raw streams, and goes off whenever a stage fails to
# parse for any other reason.
#
# So the raw stream is no longer searched whole. claude's is a JSON event array in which the CLI's
# own verdict is the `result` event; the assistant/user/system events are the model's work, i.e.
# the repo's words. codex's shape is unverified here (no codex night has run), so its raw passes
# through unfiltered rather than through a guess — a CLI signature is claimed only once a run has
# shown it. A raw stream that is not a parseable event array is not model output either, and passes
# through whole: that is the shape of the 2026-08-05 outage, where the CLI printed one line.
agent_diagnosis() { # raw_file -> what the CLI said about the run, on stdout
  local f="$1" n
  [ -s "$f" ] || return 0
  if [ "${NIGHTSHIFT_AGENT:-}" = claude ]; then
    n=$(jq -r 'if type=="array" then . else [.] end
               | map(select((.type? // "") == "result")) | length' "$f" 2>/dev/null) || n=""
    case "$n" in
      ''|*[!0-9]*|0) : ;;                 # no result event: not a stream we can filter, so do not
      *)
        # `is_error: false` is the CLI's receipt that it ran the session — nothing to diagnose, and
        # .result there is the MODEL's answer, which may discuss credentials as a matter of code.
        # Only a failed result is worth reading, and then its text is the CLI's own.
        jq -r 'if type=="array" then . else [.] end
               | map(select((.type? // "") == "result"))
               | if any(.is_error? == false) then ""
                 else map([(.subtype? // ""), (.result? // "")] | join(" ")) | join("\n") end' \
          "$f" 2>/dev/null
        return 0 ;;
    esac
  fi
  if [ "${NIGHTSHIFT_AGENT:-}" = pi ]; then
    # Same hazard the claude branch above exists for: pi's event stream carries the user prompt and
    # every tool result verbatim, i.e. the REPO's words, and matching credential prose against that
    # is how a lens that merely READ about logging in aborted a healthy night. pi states its own
    # verdict in one place — `errorMessage` on a message whose stopReason is "error" — so only that
    # is offered for diagnosis. A stream with no such message has nothing the CLI said about itself.
    jq -rs '[ .[] | select(type=="object" and .type=="message_end") | .message
              | select(type=="object" and .stopReason=="error") | .errorMessage // "" ] | join("\n")' \
      "$f" 2>/dev/null || true
    return 0
  fi
  cat "$f"
}

agent_credentials_failed() { # errfile rawfile -> 0 if the CLI's own output reports a credential failure
  local errf="$1" rawf="$2"
  [ -s "$errf" ] && grep -qiE "$AGENT_AUTH_RE" "$errf" 2>/dev/null && return 0
  agent_diagnosis "$rawf" | grep -qiE "$AGENT_AUTH_RE"
}

# Second, adapter-independent riddle-out, and the one that covers codex too: a stage that reached
# the API cannot have failed to authenticate. The adapters write .usage_$stage from the CLI's own
# counters, so a non-zero token count is the CLI's receipt for a completed request.
agent_reached_the_api() { # usage_file -> 0 if the run spent tokens or money
  local f="$1"
  [ -s "$f" ] || return 1
  # A CLI may report the bill without the token split (Claude's turn-ceiling result carries
  # `total_cost_usd`), and a billed request reached the model just the same.
  [ "$(jq -r '(((.output_tokens? // 0) + (.input_tokens? // 0)
               + (.cache_read_tokens? // 0) + (.cost_usd? // 0)) > 0) // false' "$f" 2>/dev/null)" = true ]
}
AGENT_WALL_SECONDS=30     # a stage that ran longer did reach something, whatever its counters say

agent_hit_a_wall() { # usage_file elapsed_seconds -> 0 if the failed stage never reached the model
  ! agent_reached_the_api "$1" && [ "$2" -le "$AGENT_WALL_SECONDS" ]
}

# ---------------------------------------------------------------- pi update ----
# What to put in FRONT of PATH for a pi subprocess (empty unless the launcher supplied it). pi is an
# npm-global under nvm and its `#!/usr/bin/env node` shebang takes whatever node comes first — under
# the unattended launcher's PATH that is /usr/bin/node v18, while pi requires >= 22.19. Prepending is
# confined to the pi subprocess on purpose: the Runner's own PATH keeps the system dirs first so
# nothing under $HOME can shadow its unqualified jq/git/python3 calls (risk-analysis.md R10/N4).
pi_path_prefix() { # -> "dir:" or ""
  local p="${NIGHTSHIFT_PI_PATH:-}"
  [ -n "$p" ] || return 0
  printf '%s:' "$p"
}

# ---- mock adapter (deterministic; the tested path) ----
mock_explore() { # workdir item_dir — emits the v2 container {found, findings:[…]} with up to N planted defects
  local wd="$1" id="$2" arr='[]' files
  if [ -f "$wd/README.md" ] && grep -q 'teh ' "$wd/README.md"; then
    arr=$(printf '%s' "$arr" | jq -c '. + [{file:"README.md",type:"typo",line_window:"L1-L40",
      disposition:"fix",verifiability:"static",summary:"typo \"teh\" -> \"the\" in README",
      fingerprint:"README.md:typo:L1-L40",rank:1,confidence:0.9}]')
  fi
  if [ -f "$wd/app.py" ] && grep -q 'retrun' "$wd/app.py"; then
    arr=$(printf '%s' "$arr" | jq -c '. + [{file:"app.py",type:"typo",line_window:"L1-L10",
      disposition:"fix",verifiability:"static",summary:"typo \"retrun\" -> \"return\" in app.py comment",
      fingerprint:"app.py:typo:L1-L10",rank:2,confidence:0.9}]')
  fi
  # An intent-ambiguous divergence (ADR 0006): the reviewer can prove it but cannot know which side is
  # authoritative, so it must SURFACE as a human-owned finding, never auto-fix. Deterministic trigger.
  if [ -f "$wd/NOTES.md" ] && grep -q 'AMBIGUOUS' "$wd/NOTES.md"; then
    arr=$(printf '%s' "$arr" | jq -c '. + [{file:"NOTES.md",type:"divergence",line_window:"L1-L5",
      disposition:"surface",verifiability:"static",summary:"ambiguous divergence in NOTES.md — needs a human",
      fingerprint:"NOTES.md:divergence:L1-L5",rank:1,confidence:0.8}]')
  fi
  # An UNRECOGNISED disposition must fail closed (surface, not auto-fix). Deterministic trigger.
  if [ -f "$wd/WEIRD.md" ] && grep -q 'FROB' "$wd/WEIRD.md"; then
    arr=$(printf '%s' "$arr" | jq -c '. + [{file:"WEIRD.md",type:"other",line_window:"L1-L3",
      disposition:"frobnicate",verifiability:"static",summary:"unknown disposition must fail closed",
      fingerprint:"WEIRD.md:other:L1-L3",rank:1,confidence:0.8}]')
  fi
  # ADR 0015 scope: when nothing is found, declare whether the lens even applies here. Deterministic
  # trigger — a `NOSCOPE` sentinel file makes the mock return out_of_scope (the "no surface" verdict).
  local scope=in_scope_no_findings
  [ -f "$wd/NOSCOPE" ] && scope=out_of_scope
  files="$(git -C "$wd" ls-files | sed -n '1,5p' | jq -R . | jq -sc .)"
  jq -nc --argjson f "$arr" --arg scope "$scope" --argjson files "$files" \
    --arg dimension "${NIGHTSHIFT_DIMENSION:-}" \
    '{found:($f|length>0),findings:$f,
      coverage:{files:$files,
        entrypoints:(if ($files|length)>0 then [($files[0] + " -> repository behavior")] else [] end),
        checks:["searched planted correctness markers","checked selected lens surface","ranked all candidate findings"],
        invariants:(if $dimension == "knowledge" then
          {canonicality:"checked: mock canonical concept",
           consistency:"checked: mock claim agreement",
           routing:"checked: mock index path",
           provenance_trust:"checked: mock source identity",
           lifecycle_freshness:"checked: mock concept lifecycle"}
        else
          {config_domain:"checked: mock rulebook path",
           semantic_sets:"checked: mock finding set",
           artifact_identity:"checked: one mock worktree",
           failure_translation:"checked: explicit mock exit code",
           lifecycle:"checked: mock finding lifecycle"}
        end),
        unresolved:[]}}
      + (if ($f|length>0) then {} else {scope:$scope} end)' > "$id/finding.json"
  # A stage that FAILS is not the same as a stage that found nothing, and a stage can fail after
  # having written a usable verdict — the claude CLI's `--max-turns` ceiling is the live case for both.
  # The sentinel is the exit code itself (env, not a file in the worktree) so a test can reach either
  # half of the Runner's response: with findings on disk it must keep them, without it must record no
  # verdict at all. finding.json is written first on purpose, exactly as the failing case leaves it.
  return "${NIGHTSHIFT_MOCK_EXPLORE_RC:-0}"
}
mock_fix() { # workdir item_dir — applies the fix for THIS finding (dispatched on .file)
  local wd="$1" id="$2" file
  file=$(jq -r '.file' "$id/finding.json" 2>/dev/null || echo "")
  # The Fix stage's honest way out: it looked, it could not stand behind any change, it left the
  # tree alone. Reaching that path in a test needs a fix that deliberately changes nothing.
  if [ "${NIGHTSHIFT_MOCK_FIX_NOOP:-0}" = 1 ]; then
    printf '# Worknote\n\nThe finding does not hold up on reading the code; nothing changed.\n' \
      > "$id/worknote.md"
    return 0
  fi
  # The commit retry (ADR 0036): a mock that reads the hook's demand out of the PROMPT the real
  # adapters would send, so a test proves the output reached the Fix prompt, redaction included. It
  # copies the hook's `NEED=…` demand into HOOK_OK.
  # `revert` instead undoes the whole change, the retry's other way to reach an empty commit.
  if [ -s "$id/commit-rejected.log" ]; then
    case "${NIGHTSHIFT_MOCK_FIX_HEEDS_HOOK:-0}" in
      1) stage_prompt fix "$wd" "$id" | grep -o 'NEED=[A-Za-z0-9]*' | tail -n 1 > "$wd/HOOK_OK" || true ;;
      revert) git -C "$wd" checkout -q HEAD -- .
        printf '# Worknote\n\nCould not satisfy the hook; reverted.\n' > "$id/worknote.md"; return 0 ;;
    esac
  fi
  case "$file" in
    README.md) sed -i 's/teh /the /g' "$wd/README.md"
      printf '# Worknote\n\nFixed typo "teh" -> "the" in README.md. Single file, reversible.\n' > "$id/worknote.md" ;;
    app.py)    sed -i 's/retrun/return/g' "$wd/app.py"
      printf '# Worknote\n\nFixed typo "retrun" -> "return" in app.py comment. Single file, reversible.\n' > "$id/worknote.md" ;;
    *)         printf '# Worknote\n\nNo mock fix registered for %s.\n' "$file" > "$id/worknote.md" ;;
  esac
}
mock_review() { # workdir item_dir
  local _wd="$1" id="$2" sentinel="${NIGHTSHIFT_MOCK_ABANDON_IF:-}"
  if [ "${NIGHTSHIFT_MOCK_REVIEW_FATAL:-0}" = 1 ]; then
    AGENT_FATAL="mock agent unavailable (stage review)"
    AGENT_FATAL_AGENT=mock
    return "${NIGHTSHIFT_MOCK_REVIEW_RC:-1}"
  fi
  [ "${NIGHTSHIFT_MOCK_REVIEW_NO_ARTIFACT:-0}" != 1 ] \
    || return "${NIGHTSHIFT_MOCK_REVIEW_RC:-1}"
  # Deterministic `abandon`, so the reviewer's give-up verdict is reachable in mock mode like every
  # other path. The trigger is a sentinel PATH, not content in the worktree, because a test must be
  # able to arm it MID-loop — from a failing test_cmd, say.
  # A RELATIVE sentinel resolves against the worktree, which is the only place a test_cmd can write
  # since ADR 0026 sandboxed the gate. Keeping it out of the commit is then the fixture's job (a
  # .gitignore entry), not the path's.
  case "$sentinel" in ""|/*) ;; *) sentinel="$_wd/$sentinel" ;; esac
  if [ -n "$sentinel" ] && [ -e "$sentinel" ]; then
    jq -nc '{verdict:"abandon",reason:"mock: abandon sentinel present."}' > "$id/review.md"
    return "${NIGHTSHIFT_MOCK_REVIEW_RC:-0}"
  fi
  jq -nc '{verdict:"ship",reason:"Typo fix; single file, reversible, no behaviour change — clears the smallness bar."}' > "$id/review.md"
  return "${NIGHTSHIFT_MOCK_REVIEW_RC:-0}"
}
mock_advise() { # workdir item_dir — deterministic second-opinion from the branch's finding type
  local _wd="$1" id="$2" type rec
  type=$(jq -r '.type // ""' "$id/finding.json" 2>/dev/null || echo "")
  # NIGHTSHIFT_MOCK_ADVICE=merge,none,… overrides the verdict per advisor slot (ADVISE_SLOT, set by
  # advise_branches); `none` writes no answer, i.e. an advisor that failed to give one; `bare` a fix
  # verdict with no other field; `pipe` a merge whose reason holds a literal `\|`; `noauth` a CLI that
  # is not logged in and `empty` an empty answer, both left for run_agent's own detection to find.
  rec=$(printf '%s' "${NIGHTSHIFT_MOCK_ADVICE:-}" | cut -d, -f"${ADVISE_SLOT:-1}")
  [ -n "$rec" ] || { [ "$type" = typo ] && rec=merge || rec=fix; }
  [ "$rec" != none ] || return 1
  [ "$rec" != noauth ] || { echo "mock: Not logged in" > "$id/advise.err"; return 1; }
  [ "$rec" != empty ] || { : > "$id/advise.out"; return 1; }
  [ "$rec" != bare ] || { jq -nc '{recommendation:"fix"}' > "$id/advice.json"; return 0; }
  jq -nc --arg r "$rec" '{recommendation:(if $r=="pipe" then "merge" else $r end),what:"Fixes a README typo.",benefit:"Readers see correct text.",
    reason:(if $r=="merge" then "Typo fix; trivial, reversible, no behaviour change." elif $r=="pipe" then "a\\|b" else "mock: "+$r+" verdict." end)}
    + (if $r=="fix" then {required_fix:"mock: name the missing evidence."} else {} end)' > "$id/advice.json"
}
mock_verify() { # workdir item_dir — resolved iff the planted defect is gone from the target file
  local wd="$1" id="$2" file marker
  [ "${NIGHTSHIFT_MOCK_VERIFY_NO_ARTIFACT:-0}" != 1 ] \
    || return "${NIGHTSHIFT_MOCK_VERIFY_RC:-1}"
  file=$(jq -r '.file // ((.files // [])[0] // "")' "$id/finding.json" 2>/dev/null || echo "")
  case "$file" in
    README.md) marker="teh " ;;
    app.py)    marker="retrun" ;;
    *)         marker="" ;;
  esac
  if [ -n "$marker" ] && [ -f "$wd/$file" ] && ! grep -qF "$marker" "$wd/$file"; then
    jq -nc --arg f "$file" '{resolved:true,confidence:"high",
      evidence:("planted defect no longer present in " + $f)}' > "$id/verify.json"
  else
    jq -nc --arg f "$file" '{resolved:false,confidence:"high",
      evidence:("defect still present in " + $f)}' > "$id/verify.json"
  fi
  return "${NIGHTSHIFT_MOCK_VERIFY_RC:-0}"
}
mock_recon() { # workdir item_dir — deterministic yield straight from recon_signals.json (ADR 0015)
  local _wd="$1" id="$2" sig
  sig=$(cat "$id/signals.json" 2>/dev/null || echo '{}')
  # Recon reprioritizes, never excludes (ADR 0015): every dimension gets a yield label, never
  # dropped. high = strong signal the lens pays off here; low = little signal, still rotated in.
  printf '%s' "$sig" | jq -c '. as $s | {
    dimensions: {
      correctness:{yield:"normal", hint:"any code path"},
      security:   {yield:"normal", hint:"trust boundaries"},
      infra:      {yield:(if (($s.has_compose//false) or ($s.has_dockerfile//false) or ($s.has_ci//false) or ($s.has_iac//false)) then "high" else "low" end), hint:"compose/docker/ci present"},
      docs:       {yield:"normal", hint:"docs vs code"},
      tests:      {yield:(if ($s.has_tests//false) then "normal" else "low" end), hint:"test dir present"},
      perf:       {yield:"low", hint:"hot path only if data volume"},
      "ui-ux":    {yield:(if ($s.has_frontend//false) then "high" else "low" end), hint:"frontend present"},
      deps:       {yield:(if ((($s.lockfiles//[])|length)>0) then "normal" else "low" end), hint:"lockfiles present"},
      bloat:      {yield:(if ((($s.languages//[])|length)>0) then "normal" else "low" end), hint:"code surface and structural redundancy"},
      knowledge:  {yield:(if ($s.has_knowledge//false) then "high" elif ($s.has_docs//false) then "normal" else "low" end), hint:"OKF/Markdown knowledge structure"},
      general:    {yield:"normal", hint:"free search across improvement categories"},
      craft:      {yield:"normal", hint:"floor lens"}
    }, notes:"mock recon (deterministic yield mapping from filesystem signals)"}' > "$id/recon.json"
}

# Convert a stage's textual answer into its machine artifact. Invalid output must propagate a
# non-zero status to run_agent: inventing `found:false` here would make the Runner advance coverage
# for a review the model never completed.
materialize_stage_output() { # stage item_dir
  local stage="$1" id="$2"
  case "$stage" in
    explore) python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/finding.json" 2>>"$id/$stage.err" ;;
    fix)     cp "$id/$stage.out" "$id/worknote.md" ;;
    review)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/review.md" 2>>"$id/$stage.err" ;;
    recon)   python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/recon.json" 2>>"$id/$stage.err" ;;
    advise)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/advice.json" 2>>"$id/$stage.err" ;;
    verify)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/verify.json" 2>>"$id/$stage.err" ;;
  esac
  # A repaired verdict parses, so the stage succeeds and run_agent never prints its stderr. Surface
  # the repair here instead: the artifact that reaches the ledger is not byte-for-byte what the
  # model wrote, and a night log that hides that is the wrong kind of quiet (ADR 0030).
  local rc=$?
  if [ -s "$id/$stage.err" ] && grep -q '^json-repair:' "$id/$stage.err" 2>/dev/null; then
    log "  stage $stage: $(grep -m1 '^json-repair:' "$id/$stage.err")"
  fi
  return $rc
}

# ---- claude adapter (first-party CLI headless, ADR 0003) ----
# The agent only reads/edits files; the Runner owns all git (branch/commit/push).
# Sandbox default uses --dangerously-skip-permissions (throwaway repo; git-level
# confinement via hooks/pre-push holds regardless of Claude's permission mode).
claude_run() { # stage workdir item_dir
  local stage="$1" wd="$2" id="$3" prompt out model
  local rawf="$id/.raw_$stage" errf="$id/$stage.err" rc=0 parse_rc=0
  # A Read-only tool profile does not stop startup hooks or MCP servers. Inspect before
  # launching ANY Claude stage, including advice on branches not produced by this Runner.
  if ! python3 "$NIGHTSHIFT_HOME/lib/check_claude_controls.py" worktree "$wd" >"$errf" 2>&1; then
    : > "$rawf"
    log "  stage $stage: Claude control files refused — see $errf"
    # Status 2: a deterministic configuration refusal, not a wall. As status 1 it counted as "did not
    # reach its model" and two of them aborted the whole night (run_agent's wall logic).
    return 2
  fi
  # --max-turns is the C6 runaway cap (docs/design/risk-analysis.md), not a budget: the spend cap and
  # the wall-clock bound are what limit cost. It was 25, which Explore reached and died on for 5 of 26
  # items on 2026-08-12 — each after spending its full ~$2 of tokens and returning nothing. A ceiling
  # that is hit routinely is the wrong ceiling: 60 still hard-stops a loop, but leaves a navigating
  # stage room to finish. Every abort is now visible in the digest rather than read as "found nothing".
  local flags="${NIGHTSHIFT_CLAUDE_FLAGS:---dangerously-skip-permissions --max-turns 60}"
  # Which model this stage runs on. Precedence: the env var if SET (an explicitly empty value is the
  # escape hatch — pass no --model), else the rulebook's `agent.claude_model` (ADR 0020), else
  # nothing and the CLI resolves its own default. The rulebook layer matters because stage isolation
  # (ADR 0019) drops the CLI's `user` settings scope, so a pin in ~/.claude/settings.json cannot
  # reach a stage; the host declares the model in its own governance file instead. nightshift still
  # commits no model of its own — rulebook.yaml is host-owned and untracked.
  local -a model_arg=()
  model="${NIGHTSHIFT_CLAUDE_MODEL-${RB_CLAUDE_MODEL:-}}"
  [ -z "$model" ] || model_arg=(--model "$model")
  # Stage isolation from the OPERATOR's personal Claude Code config (docs/design/hook-spec.md).
  # `--setting-sources` selects which settings SCOPES the CLI loads; dropping `user` drops both
  # ~/.claude/settings.json AND ~/.claude/CLAUDE.md, while `project,local` keeps the TARGET repo's
  # own CLAUDE.md — the context a stage actually wants. Without this the operator's private
  # instructions (chat language, personal conventions, tripwires) end up verbatim in worknotes and
  # therefore in pushed commit bodies. Empty = pass no flag (escape hatch for a CLI too old to know
  # the option; the leak returns). Measured: ~3.8k tokens of personal rules dropped per stage call.
  local -a sources_arg=()
  local sources="${NIGHTSHIFT_CLAUDE_SETTING_SOURCES-project,local}"
  [ -z "$sources" ] || sources_arg=(--setting-sources "$sources")
  # Per-stage CAPABILITY profile: enforce each stage's rules by which tools EXIST, not by
  # asking the prompt nicely (same philosophy as the git-confinement hook). explore/review
  # are read-only by nature -> only Read/Grep/Glob, no Write/Edit/Bash. fix edits the working
  # tree -> Write/Edit, but still NO Bash, which capability-enforces fix.md's "do NOT run git,
  # no destructive commands". Verified: with these sets claude cannot write outside its granted
  # tools even under --dangerously-skip-permissions (adversarial test, 2026-07-09).
  local tools
  case "$stage" in
    fix) tools="${NIGHTSHIFT_FIX_TOOLS:-Read,Grep,Glob,Write,Edit}" ;;
    *)   tools="${NIGHTSHIFT_READONLY_TOOLS:-Read,Grep,Glob}" ;;
  esac
  prompt="$(stage_prompt "$stage" "$wd" "$id")"
  # Layer 1 for the agent: inject core.hooksPath via env so EVERY git the agent runs is
  # confined by hooks/pre-push — no writes to any repo config. Layer 2: the PreToolUse guard
  # (blocks disabling Layer 1) via --settings. NIGHTSHIFT_BRANCH_PREFIX is already exported.
  # shellcheck disable=SC2086
  # NIGHTSHIFT_WORKTREE tells the PreToolUse guard which root to confine Write/Edit to
  # (the Fix stage has Write/Edit but no Bash; absolute paths would otherwise escape — R8).
  # CLAUDE_CODE_DISABLE_AUTO_MEMORY: the auto-memory store is keyed by cwd under ~/.claude/projects/
  # and is NOT covered by --setting-sources. A stage worktree is throwaway, so there is nothing to
  # read — but the memory writer is a write path OUTSIDE the worktree that the PreToolUse guard
  # never sees (R8). Off for stages: nightshift's memory is its ledger, not a per-cwd store.
  # stdout and stderr both go to FILES, and the exit code is inspected afterwards, rather than the
  # older `out="$(… 2>/dev/null)" || return 1`. That form discarded the CLI's diagnosis twice over:
  # stderr went to /dev/null, and a non-zero exit dropped the captured stdout on the floor with it —
  # so a stage that never started left an empty item dir and no trace of why (see AGENT_FATAL above).
  # Keeping both lets run_agent report the reason and recognise a credential failure.
  (cd "$wd" && \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR" \
    NIGHTSHIFT_WORKTREE="$wd" CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
    claude -p "$prompt" --output-format json --settings "$STATE_DIR/claude-settings.json" --tools "$tools" "${model_arg[@]}" "${sources_arg[@]}" $flags </dev/null) >"$rawf" 2>"$errf" || rc=$?
  out="$(cat "$rawf")"
  # `claude -p --output-format json` is NOT a stable shape. Sometimes it is a single
  # result object ({result,usage,total_cost_usd}); sometimes a JSON ARRAY of events with
  # the result object as one element (observed with claude 2.1.197, e.g. when a
  # rate_limit_event is present). A parser that assumes one shape silently yields an empty
  # result on the other — every explore then reports found:false and claude mode does
  # nothing. So normalise both: pick the result object whether top-level is it or an array.
  local pick='if type=="array" then (map(select(.type=="result"))|last) else . end'
  printf '%s' "$out" | jq -r "$pick"' | (.result // "")' > "$id/$stage.out" 2>/dev/null \
    || : > "$id/$stage.out"
  # Telemetry sidecar for run_agent. `modelUsage` is keyed by the REAL model ID
  # ("claude-opus-5", "claude-opus-4-8[1m]", …) and is the only place the served model appears — the
  # adapter name alone cannot answer "which model ran, and did it need the [1m] context variant". A
  # stage may touch more than one model (e.g. a small model for side work), so attribute it to the
  # one that consumed the most tokens; fall back to a top-level `.model` for older result shapes.
  # `model_id`, `context_window` and `model_cost_usd` all come from that ONE attributed entry, so
  # they never describe different models. `contextWindow` is the window the model actually ran with
  # (200000 vs 1000000) — it settles the [1m] question outright, instead of bounding it from the
  # cumulative token sums. Note the casing asymmetry the CLI emits: `usage.*` is snake_case,
  # `modelUsage.<id>.*` is camelCase.
  # Every field is optional: absent -> null, and a jq failure here must never fail the stage.
  printf '%s' "$out" | jq -c "$pick"' |
    (((.modelUsage // {}) | to_entries
      | map(select((.value | type) == "object"))
      | max_by((.value.inputTokens // 0) + (.value.outputTokens // 0)
               + (.value.cacheReadInputTokens // 0) + (.value.cacheCreationInputTokens // 0))) // null) as $top |
    {
      model_id: (($top.key) // .model // null),
      output_tokens:         (.usage.output_tokens // null),
      input_tokens:          (.usage.input_tokens // null),
      cache_read_tokens:     (.usage.cache_read_input_tokens // null),
      cache_creation_tokens: (.usage.cache_creation_input_tokens // null),
      context_window:        ($top.value.contextWindow // null),
      cost_usd:              (.total_cost_usd // null),
      model_cost_usd:        ($top.value.costUSD // null)
    }' > "$id/.usage_$stage" 2>/dev/null || true
  materialize_stage_output "$stage" "$id" || parse_rc=$?
  # Preserve the CLI's own nonzero status, but only AFTER materializing any valid partial result it
  # returned. main() can then keep a grounded finding while still logging that Explore hit a limit.
  [ "$rc" -eq 0 ] || return "$rc"
  return "$parse_rc"
}

# ---- codex adapter (first-party CLI headless, ADR 0003) ----
# Recon/Explore/Review run read-only. Fix can write and execute commands only inside the disposable
# worktree, with network disabled. The Runner still owns branch/commit/push.
#
# Fix-stage confinement — the two adapters differ, deliberately, and NOT symmetrically:
#   claude: capability-restricted to Read,Grep,Glob,Write,Edit — NO Bash, so it cannot run any
#           command (git or otherwise). Its PreToolUse guard confines Write/Edit paths to the
#           Runner-injected worktree root, including absolute paths.
#   codex:  OS-level `--sandbox workspace-write` — CAN exec commands (incl. git) but only inside the
#           worktree, and network is off. Out-of-tree writes are blocked by the sandbox.
# Neither can push (the Runner owns push; the pre-push hook + PreToolUse guard hold regardless), so
# neither is exploitable to reach main — but their fix-stage boundaries are enforced by different
# mechanisms (tool capability vs OS sandbox) with different residual gaps. See risk-analysis.md.
codex_run() { # stage workdir item_dir
  local stage="$1" wd="$2" id="$3" prompt sandbox events model effort rc=0 parse_rc=0
  local -a args=(--ask-for-approval never exec --ephemeral --ignore-user-config --ignore-rules
    --strict-config --json -o "$id/$stage.out")
  prompt="$(stage_prompt "$stage" "$wd" "$id")"
  case "$stage" in
    fix) sandbox=workspace-write ;;
    *)   sandbox=read-only ;;
  esac
  args+=(--sandbox "$sandbox")
  [ "$stage" != fix ] || args+=(-c 'sandbox_workspace_write.network_access=false')
  # Same precedence as the claude half: env if SET (empty = pass no --model), else the rulebook's
  # `agent.codex_model` (ADR 0020), else the CLI default.
  model="${NIGHTSHIFT_CODEX_MODEL-${RB_CODEX_MODEL:-}}"
  [ -z "$model" ] || args+=(--model "$model")
  # Effort resolves the same way: env if SET (empty = pass none), else `agent.codex_effort`, else
  # the CLI default.
  effort="${NIGHTSHIFT_CODEX_REASONING_EFFORT-${RB_CODEX_EFFORT:-}}"
  [ -z "$effort" ] || args+=(-c "model_reasoning_effort=\"$effort\"")
  # Stage isolation, codex half (ADR 0019). `--ignore-user-config` covers $CODEX_HOME/config.toml and
  # `--ignore-rules` the execpolicy files, but NEITHER covers $CODEX_HOME/AGENTS.md — the operator's
  # global instructions leak into the stage verbatim (verified 2026-08-02, codex-cli 0.145.0). The
  # only lever that separates the scopes is the home itself: a Runner-owned CODEX_HOME with no
  # AGENTS.md in it drops the global file while the TARGET repo's own AGENTS.md still loads. The
  # config-level knob is the wrong way round — `project_doc_max_bytes=0` kills the repo's AGENTS.md
  # and leaves the global one standing. Auth is the one thing the isolated home must keep: codex
  # resolves credentials under CODEX_HOME, so auth.json is symlinked in (verified: a real API call
  # succeeds through it). No auth.json -> still isolate, and let codex report the auth failure
  # itself rather than silently reopening the leak.
  local cx_home
  cx_home="$(codex_stage_home)"
  [ -n "$cx_home" ] || return 2   # configuration refusal, not a wall (see claude_run)

  # Same capture contract as the claude half: stderr to $stage.err, unparsed stdout to .raw_$stage
  # (here the event stream, which is also what codex uses to report an auth failure), so run_agent
  # can name the reason a stage died and spot a credential failure. Codex's stderr previously landed
  # unlabelled in the night log; per stage and per item dir it is attributable.
  events="$id/.raw_$stage"
  # The repo's toolchain goes in FRONT of PATH for this subprocess alone (ADR 0037): under the
  # unattended launcher /usr/bin comes first and its node is v18, which a Node 24 repo's pnpm refuses
  # to start under. Prepended here and nowhere else, like pi_path_prefix, so the Runner's own
  # unqualified calls keep resolving to the system dirs (R10/N4). The binary is resolved first, so
  # the prepended directory can never decide which `codex` runs.
  local cx_bin
  local -a cx_env=()
  # Anything but an absolute executable file (unresolved, a relative PATH entry that would resolve
  # inside the worktree after the cd, a function) becomes a path that cannot exist, so it fails as
  # a missing codex did before (127) instead of being found in the prepended directory.
  cx_bin="$(command -v codex 2>/dev/null)" || cx_bin=""
  case "$cx_bin" in /*) [ -x "$cx_bin" ] || cx_bin=/nonexistent/codex ;; *) cx_bin=/nonexistent/codex ;; esac
  # pnpm records the store it installed from and, from pnpm 11 on, reinstalls before every `pnpm
  # run`/`exec` when the store it resolves differs. Inside the gate's sandbox HOME is a separate
  # mount, so the setup's store lands in `<worktree>/.pnpm-store`; outside it pnpm would resolve the
  # operator's shared store, which this sandbox cannot write ("could not open its store database").
  # So a Fix stage whose setup left a store in the worktree is pointed at that store — inside the
  # worktree, ignored by the repo, and purged before the gate like every other ignored file.
  [ "$stage" != fix ] || [ ! -d "$wd/.pnpm-store" ] || cx_env+=("pnpm_config_store_dir=$wd/.pnpm-store")
  # Every variable goes through `env`, which is resolved on the Runner's PATH before the prefixed
  # one takes effect.
  (cd "$wd" && printf '%s' "$prompt" | \
    env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR" \
      CODEX_HOME="$cx_home" PATH="${NIGHTSHIFT_CODEX_PATH:+$NIGHTSHIFT_CODEX_PATH:}$PATH" \
      ${cx_env[@]+"${cx_env[@]}"} "$cx_bin" "${args[@]}" - > "$events" 2>"$id/$stage.err") || rc=$?
  # Telemetry sidecar for run_agent — same object contract as the claude adapter. Codex's event
  # stream is no more stable than claude's JSON: a payload sits either at the top level of an event
  # or wrapped in `.msg`, so consider both for every event. Usage rides on `turn.completed` (with
  # `token_count`/`total_token_usage` as the older shape) and is cumulative, hence `last`. The model
  # ID is announced once by a session/thread event. Codex's `input_tokens` INCLUDES
  # `cached_input_tokens`, unlike claude's, and codex reports neither cost nor the context window it
  # ran with — those degrade to null rather than being inferred. See documentation-system.md.
  jq -sc '
    def evs: [.[] | select(type == "object") | ., (.msg | select(type == "object"))];
    def usage: [ evs[]
                 | (select(.type == "turn.completed") | .usage)
                 , (select(.type == "token_count")   | .info.total_token_usage)
                 | select(type == "object") ] | last // {};
    def modelid: [ evs[]
                   | (try (.model, .session.model, .thread.model, .turn.model) catch empty)
                   | select(type == "string" and . != "") ] | last // null;
    usage as $u |
    { model_id: modelid,
      output_tokens:         ($u.output_tokens // null),
      input_tokens:          ($u.input_tokens // null),
      cache_read_tokens:     ($u.cached_input_tokens // $u.cache_read_input_tokens // null),
      cache_creation_tokens: null,
      context_window:        null,
      cost_usd:              null,
      model_cost_usd:        null }' \
    "$events" > "$id/.usage_$stage" 2>/dev/null || true
  materialize_stage_output "$stage" "$id" || parse_rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  return "$parse_rc"
}

# ---- pi adapter (first-party CLI headless, ADR 0031) ----
# READ-ONLY STAGES BY DEFAULT, and that is a safety boundary, not a convenience. The Fix stage's write
# confinement (R8, hook-spec.md Layer 2b) is enforced per adapter: claude by a PreToolUse guard that
# rejects Write/Edit outside the worktree, codex by an OS-level `--sandbox workspace-write`. pi has
# NEITHER — its tool allowlist can withhold `edit`/`write`/`bash` entirely, but it offers no hook and
# no sandbox that could bound an absolute path once `write` is granted. A read-only stage needs no
# such bound (no write primitive exists to confine), so pi is admitted for exactly those and refuses
# `fix` unless the host opts in (`pi_allow_fix`, pi_run below) — and then only inside the hull below,
# unless the host also turns the hull off (NIGHTSHIFT_PI_SANDBOX=none).
# The write confinement pi itself cannot provide (hook-spec.md Layer 2b): the same bwrap hull the
# ship gate runs in (ADR 0026), wrapped around the AGENT process instead of the test command. It is
# what turns `pi_allow_fix` from an accepted risk into a bounded one — the worktree and the stage's
# own agent dir are the only writable paths, so a confused absolute path to `~/web-app` or `/tmp`
# is refused by the kernel rather than landing invisibly outside every diff.
#
# `host` networking, deliberately: the model gateway is a LAN address and the ADR 0028 vetting proxy
# forwards to public addresses only, so an isolated namespace would not narrow this stage, it would
# stop it working. The stage's network reach is therefore unchanged from before this existed; only
# its filesystem reach is narrowed. Private gateway egress remains an open isolation question.
#
# Fails CLOSED: no bwrap means no confinement, and an unconfined writer is what pi_allow_fix was
# supposed to stop being. `NIGHTSHIFT_PI_SANDBOX=none` is the documented opt-out and restores the
# pre-2026-09-06 behaviour, i.e. an agent that may write anywhere this account may.
pi_sandbox_argv() { # worktree pi_home item_dir -> fills TEST_SANDBOX_ARGV (empty when opted out)
  local wd="$1" pi_home="$2" id="$3" f real p
  TEST_SANDBOX_ARGV=()
  if [ "${NIGHTSHIFT_PI_SANDBOX:-bwrap}" = none ]; then
    log "  pi fix stage: sandbox disabled by NIGHTSHIFT_PI_SANDBOX=none — writes are NOT confined"
    return 0
  fi
  if ! command -v bwrap >/dev/null 2>&1; then
    log "pi cannot serve the fix stage: bwrap is missing, so the write confinement has no mechanism"
    printf 'nightshift: the pi fix stage needs bwrap for its write confinement (see hook-spec.md Layer 2b)\n' \
      > "$id/fix.err"
    return 1
  fi
  build_test_sandbox "$wd" "$pi_home" host "$id"
  # The stage home holds SYMLINKS into the operator's pi directory (pi_stage_home), and $HOME is not
  # bound — so each link target is bound read-only on its own path or it dangles and pi starts
  # without credentials or catalogs. Read-only: a stage has no business rewriting auth.json.
  for f in auth.json models.json models-store.json; do
    [ -e "$pi_home/$f" ] || continue
    real="$(realpath -e "$pi_home/$f" 2>/dev/null || true)"
    [ -n "$real" ] && [ "$real" != "$pi_home/$f" ] && _test_robind "$real"
  done
  # pi and node live under nvm, i.e. under $HOME, which is not bound. Two directories are bound and
  # put on PATH: NIGHTSHIFT_PI_PATH, the host's declared pi location, and the directory `pi` ACTUALLY
  # resolves from — they are the same in production, and binding only the former would leave the
  # sandbox without the binary on any host that installs pi somewhere else entirely. Resolved with
  # the same PATH prefix pi_run launches under, so the two can never disagree.
  local pidir
  p="${NIGHTSHIFT_PI_PATH:-}"
  pidir="$(PATH="$(pi_path_prefix)$PATH" command -v pi 2>/dev/null || true)"
  [ -n "$pidir" ] && pidir="$(dirname -- "$(realpath -e "$pidir" 2>/dev/null || printf '%s' "$pidir")")"
  for f in "$p" "$pidir"; do
    [ -n "$f" ] && [ -d "$f" ] || continue
    # node resolves its own lib/ relative to `..`, so an nvm bin dir needs its prefix bound too.
    [ -x "$f/node" ] && [ -d "$(dirname -- "$f")/lib/node_modules" ] && _test_robind "$(dirname -- "$f")"
    _test_robind "$f"
  done
  # Extensions loaded BY PATH (`-e`, pi_run below) — on this host the auth extension that stamps the
  # device header, i.e. the difference between a working call and a 403 that reads like a revoked
  # credential. They live under the operator's pi directory, which is not bound, so each one's
  # PACKAGE ROOT is bound read-only: the entry file alone is not enough, a TypeScript entry resolves
  # imports and its package.json relative to that root.
  local exts ext root
  exts="${NIGHTSHIFT_PI_EXTENSIONS-${RB_PI_EXTENSIONS:-}}"
  if [ -n "$exts" ]; then
    local IFS=,
    for ext in $exts; do
      ext="$(printf '%s' "$ext" | tr -d '[:space:]')"
      [ -n "$ext" ] && [ -e "$ext" ] || continue
      root="$(dirname -- "$ext")"
      while [ "$root" != / ] && [ ! -e "$root/package.json" ]; do root="$(dirname -- "$root")"; done
      [ "$root" != / ] || root="$(dirname -- "$ext")"
      _test_robind "$root"
    done
    unset IFS
  fi
  # A resolver, unlike the gate's sandbox. There the deliberate absence of /etc/resolv.conf is what
  # forces every name through the vetting proxy, which resolves it on the host and checks the answer
  # against the address policy. This stage has the host's own namespace and no such proxy, so
  # withholding the resolver would not add a check — it would only break a provider addressed by
  # name (this host's gateway is an IP literal; another host's need not be).
  TEST_SANDBOX_ARGV+=( --ro-bind-try /etc/resolv.conf /etc/resolv.conf )
  # --clearenv dropped the caller's environment, so what pi needs is re-declared here. GIT_CONFIG_*
  # carries the Layer 1 pre-push hook, which is why HOOKS_DIR is bound read-only too.
  _test_robind "$HOOKS_DIR"
  TEST_SANDBOX_ARGV+=(
    --setenv PATH "${p:+$p:}${pidir:+$pidir:}${NIGHTSHIFT_TEST_PATH:+$NIGHTSHIFT_TEST_PATH:}/usr/local/bin:/usr/bin:/bin"
    --setenv PI_CODING_AGENT_DIR "$pi_home"
    --setenv GIT_CONFIG_COUNT 1
    --setenv GIT_CONFIG_KEY_0 core.hooksPath
    --setenv GIT_CONFIG_VALUE_0 "$HOOKS_DIR"
    --setenv NIGHTSHIFT_PI_SANDBOX_ACTIVE 1
  )
  return 0
}

pi_run() { # stage workdir item_dir
  local stage="$1" wd="$2" id="$3" prompt model provider tools rc=0 parse_rc=0
  # The Fix stage is refused unless the HOST explicitly opts in (`agent.pi_allow_fix: true`, env
  # NIGHTSHIFT_PI_ALLOW_FIX=1). The other two adapters confine a Fix-stage write to the worktree by a
  # MECHANISM of their own — claude's PreToolUse guard rejects a Write/Edit resolving outside it,
  # codex's OS sandbox makes the write impossible — and pi has neither, so the Runner supplies one:
  # pi_sandbox_argv's bwrap hull (ADR 0032), below at launch, leaves only the worktree and the stage's
  # agent dir writable and refuses the stage when bwrap is missing. The failure it bounds is not
  # malice but a confused absolute path: a worktree named `web-app` and a live repo at ~/web-app
  # are one keystroke apart, and such a write appears in NO diff, so the morning branch review
  # cannot catch it — which is exactly what NIGHTSHIFT_PI_SANDBOX=none brings back. The hull shares
  # the host's network, so only filesystem reach is narrowed. `bash` stays withheld regardless (see
  # the profile below), so a fix can still edit files but never execute anything.
  local allow_fix="${NIGHTSHIFT_PI_ALLOW_FIX:-}"
  [ -n "$allow_fix" ] || { [ "${RB_PI_ALLOW_FIX:-false}" = true ] && allow_fix=1; }
  if [ "$stage" = fix ] && [ "${allow_fix:-0}" != 1 ]; then
    log "pi cannot serve the fix stage: no write confinement mechanism (see hook-spec.md Layer 2b)"
    printf 'nightshift: the pi adapter is read-only and refuses the fix stage\n' > "$id/$stage.err"
    return 2
  fi
  # `-ne` (no extension discovery) is not merely a context-hygiene flag here: on a host whose models
  # are served through a gateway, AUTHENTICATION ITSELF is provided by a pi extension that stamps the
  # caller's device header, and dropping it makes every call fail with a 403 naming a device
  # mismatch — a message that reads like a revoked credential and is not. Verified 2026-08-30 against
  # this host's proxy. So discovery stays off (the operator's memory/subagent/websearch extensions
  # have no business in a stage) and the auth extension is loaded back BY PATH, which `-e` does even
  # under `-ne`. A host whose provider needs no such extension declares none and loses nothing.
  local -a args=(-p --mode json --no-session --no-extensions --no-skills --no-prompt-templates
    --no-approve)
  local exts ext
  exts="${NIGHTSHIFT_PI_EXTENSIONS-${RB_PI_EXTENSIONS:-}}"
  if [ -n "$exts" ]; then
    local IFS=,
    for ext in $exts; do
      [ -n "$ext" ] || continue
      # Absolute, because the check happens in the RUNNER's cwd while pi runs in the worktree: a
      # relative path that exists here can be missing there, which produces exactly the 403 the log
      # line below exists to prevent.
      ext="$(realpath -m -- "$ext" 2>/dev/null || printf '%s' "$ext")"
      if [ -e "$ext" ]; then
        args+=(-e "$ext")
      else
        # Naming an extension that is not there is a config error, and the failure it causes without
        # this line is a 403 the operator would read as an auth problem. Say it once, here.
        log "pi: declared extension not found: $ext"
      fi
    done
  fi
  # Same precedence as the other adapters: env if SET (empty = pass no flag), else the rulebook's
  # `agent.pi_model` / `agent.pi_provider` (ADR 0020), else whatever pi resolves by itself.
  model="${NIGHTSHIFT_PI_MODEL-${RB_PI_MODEL:-}}"
  [ -z "$model" ] || args+=(--model "$model")
  provider="${NIGHTSHIFT_PI_PROVIDER-${RB_PI_PROVIDER:-}}"
  [ -z "$provider" ] || args+=(--provider "$provider")
  # Capability profile, same principle as the claude half: enforce the stage's rules by which tools
  # EXIST. Verified 2026-08-30 that pi honours the allowlist — a stage granted read,grep,find,ls was
  # told to write a file and answered that it had no tool to do it, and no file appeared.
  #
  # For the other two adapters the tool profile is one layer over a mechanism (the PreToolUse guard,
  # the OS sandbox). For pi it is the WHOLE confinement, so it may not be a knob an operator can
  # widen by accident: a tuning snippet adding `bash` "so the reviewer can run the tests" would hand
  # an unconfined shell to a stage on the Runner's host. The override may narrow the profile, never
  # widen it past read-only — a write or exec tool in it aborts the stage.
  # The Fix stage needs edit/write, and gets them ONLY on the stage the host opted into above —
  # never on a read-only stage, where a write tool has no purpose and only widens the blast radius.
  # `bash` is in neither profile and is rejected below whatever the host declares: an executing
  # stage could run git, gh, curl or rm on the Runner's host, which no allowlist can then bound.
  local permitted
  if [ "$stage" = fix ]; then
    tools="${NIGHTSHIFT_PI_FIX_TOOLS:-read,grep,find,ls,edit,write}"
    permitted='read|grep|find|ls|glob|edit|write'
  else
    tools="${NIGHTSHIFT_PI_READONLY_TOOLS:-read,grep,find,ls}"
    permitted='read|grep|find|ls|glob'
  fi
  local t
  local IFS_SAVE="$IFS"
  IFS=,
  for t in $tools; do
    t="$(printf '%s' "$t" | tr -d '[:space:]')"
    [ -n "$t" ] && ! printf '%s' "$t" | grep -qxE "$permitted" && {
      IFS="$IFS_SAVE"
      log "pi: refusing tool '$t' on stage $stage — pi has no mechanism to confine a shell, and a write only where the host opted in"
      printf 'nightshift: the pi %s profile may not grant %s\n' "$stage" "$t" > "$id/$stage.err"
      return 2
    }
  done
  IFS="$IFS_SAVE"
  args+=(--tools "$tools")
  prompt="$(stage_prompt "$stage" "$wd" "$id")"
  # Stage isolation (ADR 0019): a Runner-owned agent dir with no AGENTS.md in it. The discovery
  # flags above cover extensions, skills and prompt templates — none of which cover that file.
  local pi_home
  pi_home="$(pi_stage_home)"
  [ -n "$pi_home" ] || return 2   # configuration refusal, not a wall (see claude_run)
  # Same capture contract as the other adapters: stderr to $stage.err, the unparsed event stream to
  # .raw_$stage. GIT_CONFIG_* injects the pre-push confinement for consistency with the other
  # adapters even though this profile grants no shell — the hook costs nothing and the profile is
  # the only thing standing between a future `bash` grant and an unconfined push.
  local events="$id/.raw_$stage"
  # The Fix stage runs inside the filesystem sandbox; every read-only stage runs as before (it has
  # no write primitive to confine, so a sandbox would buy nothing and could only break a read).
  local -a launch=()
  if [ "$stage" = fix ]; then
    pi_sandbox_argv "$wd" "$pi_home" "$id" || return 2
    launch=( "${TEST_SANDBOX_ARGV[@]}" )
  fi
  (cd "$wd" && \
    PATH="$(pi_path_prefix)$PATH" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR" \
    PI_CODING_AGENT_DIR="$pi_home" \
    ${launch[@]+"${launch[@]}"} \
    pi "${args[@]}" -- "$prompt" </dev/null) > "$events" 2>"$id/$stage.err" || rc=$?
  # pi streams JSONL events and the ANSWER is the text content of the last assistant message that
  # actually stopped. `.role=="assistant"` alone is not enough: the same stream carries thinking
  # blocks and tool calls, and an aborted turn carries an empty content array.
  jq -rs '[ .[] | select(type=="object" and .type=="message_end") | .message
            | select(type=="object" and .role=="assistant" and .stopReason=="stop") ]
          | last // {} | [(.content // [])[] | select(type=="object" and .type=="text") | .text]
          | join("")' \
    "$events" > "$id/$stage.out" 2>/dev/null || : > "$id/$stage.out"
  # pi reports a provider/transport failure INSIDE the stream (stopReason "error" + errorMessage) and
  # still exits 0 — verified 2026-08-30, where a 403 from the model gateway produced rc=0 and an
  # empty answer. Left alone that is the exact failure ADR 0023 exists to prevent: a stage that never
  # reached a model, recorded as one that ran and found nothing. So the stream's own verdict, not the
  # exit code, decides whether the stage failed.
  #
  # An error event is not by itself a failed stage: pi retries a turn (its own stream says
  # `willRetry`), so a transient rejection can be followed by a completed answer. Failing on the
  # error alone would turn a provider hiccup into a lost review on the gate that decides shipping.
  # What decides is whether an ANSWER survived — the error is recorded either way, because a stage
  # that needed a retry is worth seeing in the morning.
  local pi_err
  pi_err="$(jq -rs '[ .[] | select(type=="object" and .type=="message_end") | .message
                      | select(type=="object" and .role=="assistant" and .stopReason=="error")
                      | .errorMessage // "unspecified error" ] | last // ""' \
              "$events" 2>/dev/null || true)"
  if [ -n "$pi_err" ]; then
    printf 'pi: %s\n' "$pi_err" >> "$id/$stage.err"
    [ "$rc" -ne 0 ] || [ -s "$id/$stage.out" ] || rc=1
  fi
  # Telemetry sidecar — same object contract as the other adapters. pi's usage rides on each
  # assistant message and is PER MESSAGE, not cumulative, so the counters are summed across the
  # stage's turns; the model id is taken from the last message that reports one. pi reports no
  # context window, so that field degrades to null rather than being inferred.
  jq -sc '[ .[] | select(type=="object" and .type=="message_end") | .message
            | select(type=="object" and .role=="assistant") ] as $m |
    [ $m[] | .usage | select(type=="object") ] as $u |
    { model_id: ([ $m[] | .model | select(type=="string" and . != "") ] | last // null),
      output_tokens:         ([ $u[] | .output    // 0 ] | add // null),
      input_tokens:          ([ $u[] | .input     // 0 ] | add // null),
      cache_read_tokens:     ([ $u[] | .cacheRead // 0 ] | add // null),
      cache_creation_tokens: ([ $u[] | .cacheWrite // 0 ] | add // null),
      context_window:        null,
      cost_usd:              ([ $u[] | .cost.total // 0 ] | add // null),
      model_cost_usd:        null }' \
    "$events" > "$id/.usage_$stage" 2>/dev/null || true
  materialize_stage_output "$stage" "$id" || parse_rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  return "$parse_rc"
}
