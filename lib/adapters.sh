#!/usr/bin/env bash
# Sourced by bin/nightshift.sh after its path globals are initialized.

# Credential-failure signatures, matched against what the CLI says about ITSELF: the stage's
# captured stderr, plus the CLI's own verdict inside raw stdout (the claude CLI reports the failure
# as a JSON result object there). Deliberately broad, because a false negative costs a forged clean
# fleet.
AGENT_AUTH_RE='not logged in|/login|authentication_failed|invalid api key|unauthorized|oauth token|credentials? (not found|expired|invalid)|codex login'

# The signatures are prose, so claude's raw stream is never searched whole: its assistant/user/system
# events quote the repo under review, which can mention logins. Only the CLI's own `result` event is
# read; codex's stream is cut to its error events. A stream neither filter can parse passes through
# whole: usually a CLI that could not start (one plain line), but a truncated codex stream also
# lands here, model text included.
agent_diagnosis() { # raw_file -> what the CLI said about the run, on stdout
  local f="$1" n
  [ -s "$f" ] || return 0
  if [ "${NIGHTSHIFT_AGENT:-}" = claude ]; then
    n=$(jq -r 'if type=="array" then . else [.] end
               | map(select((.type? // "") == "result")) | length' "$f" 2>/dev/null) || n=""
    case "$n" in
      ''|*[!0-9]*|0) : ;;                 # no result event: not a stream we can filter, so do not
      *)
        # `is_error: false` means the session ran, and its .result is the MODEL's answer. Only a
        # failed result's text is the CLI's own.
        jq -r 'if type=="array" then . else [.] end
               | map(select((.type? // "") == "result"))
               | if any(.is_error? == false) then ""
                 else map([(.subtype? // ""), (.result? // "")] | join(" ")) | join("\n") end' \
          "$f" 2>/dev/null
        return 0 ;;
    esac
  fi
  if [ "${NIGHTSHIFT_AGENT:-}" = codex ]; then
    # item events contain the repository's text. Only error events speak for the CLI.
    jq -sr '.[] | select(type == "object") |
      select(.type == "error" or .type == "turn.failed") |
      (.error.message? // .message? // empty)' "$f" 2>/dev/null && return 0
  fi
  cat "$f"
}

agent_credentials_failed() { # errfile rawfile -> 0 if the CLI's own output reports a credential failure
  local errf="$1" rawf="$2"
  [ -s "$errf" ] && grep -qiE "$AGENT_AUTH_RE" "$errf" 2>/dev/null && return 0
  agent_diagnosis "$rawf" | grep -qiE "$AGENT_AUTH_RE"
}

# A stage that reached the API cannot have failed to authenticate. .usage_$stage comes from the CLI's
# own counters, so a non-zero count is its receipt for a completed request.
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
  # A stage can fail after writing a usable verdict (the CLI's --max-turns ceiling). finding.json is
  # written first on purpose, so a test can check the Runner keeps findings on disk and records no
  # verdict without them.
  return "${NIGHTSHIFT_MOCK_EXPLORE_RC:-0}"
}
mock_fix() { # workdir item_dir — applies the fix for THIS finding (dispatched on .file)
  local wd="$1" id="$2" file
  file=$(jq -r '.file' "$id/finding.json" 2>/dev/null || echo "")
  # A Fix stage that changes nothing, the honest way out when no change holds up.
  if [ "${NIGHTSHIFT_MOCK_FIX_NOOP:-0}" = 1 ]; then
    printf '# Worknote\n\nThe finding does not hold up on reading the code; nothing changed.\n' \
      > "$id/worknote.md"
    return 0
  fi
  # The commit retry (ADR 0036): read the hook's `NEED=…` demand out of the real Fix PROMPT into
  # HOOK_OK, so a test proves the hook output reached it, redaction included. `revert` undoes the
  # whole change instead, the retry's other way to an empty commit.
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
  # Deterministic `abandon`, armed by a sentinel PATH so a test can arm it mid-loop (from a failing
  # test_cmd). A relative path resolves against the worktree, the only place a sandboxed test_cmd
  # can write (ADR 0026); the fixture keeps it out of the commit with .gitignore.
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
  # A repaired verdict parses, so run_agent never prints its stderr; log the repair here, since the
  # artifact is not byte-for-byte what the model wrote (ADR 0030).
  local rc=$?
  if [ -s "$id/$stage.err" ] && grep -q '^json-repair:' "$id/$stage.err" 2>/dev/null; then
    log "  stage $stage: $(grep -m1 '^json-repair:' "$id/$stage.err")"
  fi
  return $rc
}

# The review override belongs to the primary adapter. An advisor from the other
# vendor uses its own work model. advise_branches keeps night_agent across its
# temporary rebinding of NIGHTSHIFT_AGENT for each advisor.
stage_model() { # stage [adapter]
  local adapter="${2:-$NIGHTSHIFT_AGENT}" review="${NIGHTSHIFT_REVIEW_MODEL-${RB_REVIEW_MODEL:-}}"
  case "$1" in
    review|advise)
      if [ "$adapter" = "${night_agent:-${NIGHTSHIFT_AGENT:-$adapter}}" ] && [ -n "$review" ]; then
        printf '%s' "$review"
        return 0
      fi ;;
  esac
  case "$adapter" in
    claude) printf '%s' "${NIGHTSHIFT_CLAUDE_MODEL-${RB_CLAUDE_MODEL:-}}" ;;
    codex)  printf '%s' "${NIGHTSHIFT_CODEX_MODEL-${RB_CODEX_MODEL:-}}" ;;
  esac
}

stage_effort() { # adapter
  case "$1" in
    claude) printf '%s' "${NIGHTSHIFT_CLAUDE_EFFORT-${RB_CLAUDE_EFFORT:-}}" ;;
    codex)  printf '%s' "${NIGHTSHIFT_CODEX_REASONING_EFFORT-${RB_CODEX_EFFORT:-}}" ;;
  esac
}

# ---- claude adapter (first-party CLI headless, ADR 0003) ----
# Use the same effective source selection for every startup check and the CLI launch.
check_claude_controls() {
  python3 "$NIGHTSHIFT_HOME/lib/check_claude_controls.py" \
    --sources="${NIGHTSHIFT_CLAUDE_SETTING_SOURCES-local}" "$@"
}

# The agent only reads/edits files; the Runner owns all git (branch/commit/push).
# Sandbox default uses --dangerously-skip-permissions (throwaway repo; git-level
# confinement via hooks/pre-push holds regardless of Claude's permission mode).
claude_run() { # stage workdir item_dir
  local stage="$1" wd="$2" id="$3" prompt out model sources flag
  local rawf="$id/.raw_$stage" errf="$id/$stage.err" rc=0 parse_rc=0
  # --max-turns is the C6 runaway cap (docs/design/risk-analysis.md), not a budget: the spend cap and
  # wall clock limit cost. It must stay high enough that a navigating stage rarely hits it.
  local flags_override="${NIGHTSHIFT_CLAUDE_FLAGS:---dangerously-skip-permissions --max-turns 60}"
  local -a flags=()
  # Read through EOF to split multiline overrides without expanding filenames.
  IFS=$' \t\n' read -r -d '' -a flags <<< "$flags_override" || true
  for flag in "${flags[@]}"; do
    case "${flag%%=*}" in
      --mcp-config|--setting-sources|--settings)
        : > "$rawf"
        printf 'NIGHTSHIFT_CLAUDE_FLAGS contains reserved flag %s\n' "${flag%%=*}" > "$errf"
        log "  stage $stage: $(<"$errf") — refusing Claude launch"
        return 2
        ;;
    esac
  done
  # Startup checks apply even to read-only stages and branches not produced by this Runner.
  if ! sources="$(check_claude_controls --print-sources worktree "$wd" 2>"$errf")"; then
    : > "$rawf"
    out="$(<"$errf")"
    log "  stage $stage: ${out:-Claude control inspection failed} — see $errf"
    # Status 2 signals a deterministic configuration refusal to run_agent's wall logic.
    return 2
  fi
  # Which model this stage runs on (stage_model above; ADR 0020, ADR 0044).
  local -a model_arg=()
  model="$(stage_model "$stage" claude)"
  [ -z "$model" ] || model_arg=(--model "$model")
  local effort
  effort="$(stage_effort claude)"
  [ -z "$effort" ] || model_arg+=(--effort "$effort")
  # The default local scope skips personal settings and project hooks while keeping the repo's
  # CLAUDE.md. The Runner's --settings still loads its guard (docs/design/hook-spec.md).
  local -a sources_arg=()
  [ -z "$sources" ] || sources_arg=(--setting-sources "$sources")
  # Per-stage CAPABILITY profile: a stage's rules are enforced by which tools exist, even under
  # --dangerously-skip-permissions. Read-only stages get Read/Grep/Glob; fix adds Write/Edit but
  # still no Bash, so it cannot run git or commands.
  local tools
  case "$stage" in
    fix) tools="${NIGHTSHIFT_FIX_TOOLS:-Read,Grep,Glob,Write,Edit}" ;;
    *)   tools="${NIGHTSHIFT_READONLY_TOOLS:-Read,Grep,Glob}" ;;
  esac
  prompt="$(stage_prompt "$stage" "$wd" "$id")"
  # Layer 1 for the agent: inject core.hooksPath via env so EVERY git the agent runs is
  # confined by hooks/pre-push — no writes to any repo config. Layer 2: the PreToolUse guard
  # (blocks disabling Layer 1) via --settings. NIGHTSHIFT_BRANCH_PREFIX is already exported.
  # NIGHTSHIFT_WORKTREE tells the PreToolUse guard which root to confine Write/Edit to
  # (the Fix stage has Write/Edit but no Bash; absolute paths would otherwise escape — R8).
  # CLAUDE_CODE_DISABLE_AUTO_MEMORY: the auto-memory writer is a write path outside the worktree that
  # --setting-sources does not cover and the PreToolUse guard never sees (R8).
  # stdout and stderr both go to FILES and the status is read afterwards, so run_agent can report a
  # failed start and recognise a credential failure.
  (cd "$wd" && \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR" \
    NIGHTSHIFT_WORKTREE="$wd" CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
    claude -p --output-format json --settings "$STATE_DIR/claude-settings.json" --tools "$tools" \
      "${model_arg[@]}" "${sources_arg[@]}" --strict-mcp-config "${flags[@]}" < <(printf '%s' "$prompt")) >"$rawf" 2>"$errf" || rc=$?
  out="$(cat "$rawf")"
  # `claude -p --output-format json` is either one result object or an ARRAY of events holding it
  # (e.g. after a rate_limit_event). Assuming one shape silently yields an empty result on the
  # other, so both are normalised to the result object.
  local pick='if type=="array" then (map(select(.type=="result"))|last) else . end'
  printf '%s' "$out" | jq -r "$pick"' | (.result // "")' > "$id/$stage.out" 2>/dev/null \
    || : > "$id/$stage.out"
  # Telemetry sidecar for run_agent. `modelUsage`, keyed by the served model id, is the only place
  # that id appears. A stage may use several models, so the one with the most tokens is attributed,
  # and model_id, context_window and model_cost_usd all come from that ONE entry; a top-level
  # `.model` is the fallback. `usage.*` is snake_case, `modelUsage.<id>.*` camelCase.
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

# ---- codex adapter (first-party CLI headless, ADR 0045) ----
codex_run() { # stage workdir item_dir
  local stage="$1" wd="$2" id="$3" prompt sandbox events model effort rc=0 parse_rc=0
  id="$(realpath -e -- "$id")" || return 2
  local -a args=(--ask-for-approval never exec --ephemeral --ignore-user-config --ignore-rules
    --strict-config --json -o "$id/$stage.out")
  prompt="$(stage_prompt "$stage" "$wd" "$id")"
  case "$stage" in
    fix) sandbox=workspace-write ;;
    *)   sandbox=read-only ;;
  esac
  args+=(--sandbox "$sandbox")
  [ "$stage" != fix ] || args+=(-c 'sandbox_workspace_write.network_access=false'
    -c 'sandbox_workspace_write.exclude_slash_tmp=true' -c 'sandbox_workspace_write.exclude_tmpdir_env_var=true')
  # Same precedence as the claude half: env if SET (empty = pass no --model), else the rulebook's
  # `agent.codex_model` (ADR 0020), else the CLI default.
  model="$(stage_model "$stage" codex)"
  [ -z "$model" ] || args+=(--model "$model")
  # Effort resolves the same way: env if SET (empty = pass none), else `agent.codex_effort`, else
  # the CLI default.
  effort="$(stage_effort codex)"
  [ -z "$effort" ] || args+=(-c "model_reasoning_effort=\"$effort\"")
  # The CLI loads global instructions from CODEX_HOME and user skills from HOME.
  # Start each stage with fresh directories and carry over only file-based auth.
  local auth home
  auth="$(realpath -m -- "${CODEX_HOME:-$HOME/.codex}/auth.json")" || return 2
  home="$(mktemp -d -- "$id/.codex-home.XXXXXXXX")" || return 2
  events="$id/.raw_$stage"
  (
    trap 'rm -rf -- "$home"' EXIT
    [ ! -f "$auth" ] || ln -s -- "$auth" "$home/auth.json" || exit 2
    cd "$wd" || exit 2
    HOME="$home" CODEX_HOME="$home" XDG_CONFIG_HOME="$home/.config" \
      XDG_DATA_HOME="$home/.local/share" XDG_STATE_HOME="$home/.local/state" XDG_CACHE_HOME="$home/.cache" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR" \
      codex "${args[@]}" - < <(printf '%s' "$prompt")
  ) > "$events" 2>"$id/$stage.err" || rc=$?
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
