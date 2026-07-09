#!/usr/bin/env bash
# nightshift — the Brain / Runner (prototype).
#
# Outer loop: select a repo -> Explore -> Fix<->Review (capped) -> Finalize
# (push a nightshift/* branch) -> record. Enforces the nightly branch cap and the
# global open-branch backpressure. The agent invocation sits behind run_agent()
# (ADR 0001 adapter seam): NIGHTSHIFT_AGENT=mock (tested) | claude (experimental).
set -euo pipefail

NIGHTSHIFT_HOME="${NIGHTSHIFT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NIGHTSHIFT_AGENT="${NIGHTSHIFT_AGENT:-mock}"
# After pushing a nightshift/* branch, open a normal PR for it on GitHub (1=on).
# A PR is a GitHub-API object, not a push to main — the pre-push hook is untouched
# and the merge stays the human's click. Set 0 to go back to bare branches.
NIGHTSHIFT_OPEN_PR="${NIGHTSHIFT_OPEN_PR:-1}"
RULEBOOK="${RULEBOOK:-$NIGHTSHIFT_HOME/rulebook.yaml}"
[ -f "$RULEBOOK" ] || RULEBOOK="$NIGHTSHIFT_HOME/rulebook.example.yaml"
HOOKS_DIR="$NIGHTSHIFT_HOME/hooks"
STATE_DIR="$NIGHTSHIFT_HOME/state"
NIGHT="$(date +%Y-%m-%d)"
RUNS_DIR="$NIGHTSHIFT_HOME/runs/$NIGHT"
DIGEST_DIR="$NIGHTSHIFT_HOME/digests"
LEDGER="$STATE_DIR/ledger.jsonl"
RUNSLOG="$STATE_DIR/runs.jsonl"
# Worktrees live OUTSIDE the control repo, so nightshift can target its own repo
# without nesting a worktree inside a working tree.
WORKTREES_DIR="${NIGHTSHIFT_WORKTREES:-${TMPDIR:-/tmp}/nightshift-worktrees}"
mkdir -p "$STATE_DIR" "$RUNS_DIR" "$DIGEST_DIR" "$WORKTREES_DIR"

log() { echo "[nightshift] $*" >&2; }

# ---------------------------------------------------------------- rulebook ----
declare -a REPO_PATHS=() REPO_MODES=() REPO_BASES=()
load_rulebook() {
  local tag a b c rb_run_branches=""
  while IFS=$'\t' read -r tag a b c; do
    case "$tag" in
      prefix)               BRANCH_PREFIX="$a" ;;
      max_open)             MAX_OPEN="$a" ;;
      max_branches_per_run) rb_run_branches="$a" ;;
      max_fix_iterations)   MAX_FIX_ITER="$a" ;;
      max_files)            MAX_FILES="$a" ;;
      max_lines)            MAX_LINES="$a" ;;
      repo)                 REPO_PATHS+=("$a"); REPO_MODES+=("$b"); REPO_BASES+=("$c") ;;
    esac
  done < <(python3 "$NIGHTSHIFT_HOME/lib/parse_rulebook.py" "$RULEBOOK")
  # Per-run safety ceiling: the rulebook wins; NIGHTSHIFT_MAX_RUN_BRANCHES stays as an
  # ops override for when it is not set there; 50 is the last-resort default.
  MAX_RUN_BRANCHES="${rb_run_branches:-${NIGHTSHIFT_MAX_RUN_BRANCHES:-50}}"
  export NIGHTSHIFT_BRANCH_PREFIX="$BRANCH_PREFIX"
}

# --------------------------------------------------------------- telemetry ----
append_run() { # stage agent start dur tokens status item cost
  jq -nc \
    --arg night "$NIGHT" --arg item "$7" --arg stage "$1" --arg model "$2" \
    --argjson start "$3" --argjson dur "$4" --arg tokens "$5" --argjson status "$6" --arg cost "$8" \
    '{night:$night,item:$item,stage:$stage,model:$model,start:$start,
      duration_s:$dur,
      tokens:($tokens|if .=="" then null else (tonumber? // null) end),
      cost_usd:($cost|if .=="" then null else (tonumber? // null) end),
      exit:$status}' >> "$RUNSLOG"
}

ledger_append() { # item repo fp branch sha outcome [summary] [pr_url]
  jq -nc \
    --arg night "$NIGHT" --arg item "$1" --arg repo "$2" --arg fp "$3" \
    --arg branch "$4" --arg sha "$5" --arg outcome "$6" --arg summary "${7:-}" --arg pr "${8:-}" --arg ts "$(date -Iseconds)" \
    '{night:$night,item:$item,repo:$repo,fingerprint:$fp,
      branch:($branch|if .=="" then null else . end),
      sha:($sha|if .=="" then null else . end),
      pr_url:($pr|if .=="" then null else . end),
      outcome:$outcome,summary:$summary,ts:$ts}' >> "$LEDGER"
}

# Robust identity for a finding. The agent (claude mode) may omit `fingerprint`
# despite the prompt; a missing field reads back as the literal "null" via jq -r
# and would then poison dedup (every fingerprint-less finding collapses onto one
# key). Use the model's value when present, else synthesise from file:type:line_window,
# else echo "" so the caller can drop an unusable finding.
finding_fingerprint() { # finding.json -> fingerprint or ""
  jq -r '
    (.fingerprint // "") as $fp
    | if ($fp|type)=="string" and ($fp|length)>0 and $fp!="null" then $fp
      else [(.file // ""),(.type // ""),(.line_window // "")]
           | map(select(. != "" and . != null))
           | if length>0 then join(":") else "" end
      end' "$1" 2>/dev/null || true
}

already_done() { # fingerprint — ANY prior ledger entry (used by findings-only, report once)
  [ -n "$1" ] && [ "$1" != null ] || return 1   # never dedup on an unusable key
  [ -f "$LEDGER" ] || return 1
  grep -Fq "\"fingerprint\":\"$1\"" "$LEDGER"
}
already_acted() { # fingerprint — only shipped/abandoned/deferred (used by branch-fix)
  [ -n "$1" ] && [ "$1" != null ] || return 1   # never dedup on an unusable key
  [ -f "$LEDGER" ] || return 1
  # jq match, not a grep regex: fingerprints contain '.'/'/'/':' that would be
  # interpreted as regex metacharacters and could match a *different* fingerprint.
  # Slurp + any() so the verdict is order-independent (a non-matching *last* line
  # must not flip jq -e's exit status).
  jq -se --arg fp "$1" \
    'any(.[]; .fingerprint==$fp and (.outcome=="shipped" or .outcome=="abandoned" or .outcome=="deferred"))' \
    "$LEDGER" >/dev/null 2>&1
}

# Layer 2 settings for the agent: register the PreToolUse guard so the agent
# cannot disable the pre-push hook (--no-verify / core.hooksPath override).
write_claude_settings() {
  jq -nc --arg cmd "$HOOKS_DIR/pretooluse-guard.sh" \
    '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]}}' \
    > "$STATE_DIR/claude-settings.json"
}

# --------------------------------------------------------------- run_agent ----
run_agent() { # stage workdir item_dir
  local stage="$1" workdir="$2" item_dir="$3" start end status=0 tokens="" cost=""
  start=$(date +%s)
  if [ "$NIGHTSHIFT_AGENT" = mock ]; then
    "mock_$stage" "$workdir" "$item_dir" || status=$?
  else
    claude_run "$stage" "$workdir" "$item_dir" || status=$?
    tokens=$(cat "$item_dir/.tokens_$stage" 2>/dev/null || true)
    cost=$(cat "$item_dir/.cost_$stage" 2>/dev/null || true)
  fi
  end=$(date +%s)
  append_run "$stage" "$NIGHTSHIFT_AGENT" "$start" "$((end - start))" "$tokens" "$status" "$(basename "$item_dir")" "$cost"
  return "$status"
}

# ---- mock adapter (deterministic; the tested path) ----
mock_explore() { # workdir item_dir
  local wd="$1" id="$2"
  if [ -f "$wd/README.md" ] && grep -q 'teh ' "$wd/README.md"; then
    jq -nc '{found:true,file:"README.md",type:"typo",line_window:"L1-L40",
             summary:"typo \"teh\" -> \"the\" in README",
             fingerprint:"README.md:typo:L1-L40",confidence:0.9}' > "$id/finding.json"
  else
    jq -nc '{found:false}' > "$id/finding.json"
  fi
}
mock_fix() { # workdir item_dir
  local wd="$1" id="$2"
  sed -i 's/teh /the /g' "$wd/README.md"
  printf '# Worknote\n\nFixed typo "teh" -> "the" in README.md.\nSingle file, reversible, no behaviour change.\n' > "$id/worknote.md"
}
mock_review() { # workdir item_dir
  local _wd="$1" id="$2"
  jq -nc '{verdict:"ship",reason:"Typo fix; single file, reversible, no behaviour change — clears the smallness bar."}' > "$id/review.md"
}

# ---- claude adapter (first-party CLI headless, ADR 0003) ----
# The agent only reads/edits files; the Runner owns all git (branch/commit/push).
# Sandbox default uses --dangerously-skip-permissions (throwaway repo; git-level
# confinement via hooks/pre-push holds regardless of Claude's permission mode).
claude_run() { # stage workdir item_dir
  local stage="$1" wd="$2" id="$3" prompt out
  local flags="${NIGHTSHIFT_CLAUDE_FLAGS:---dangerously-skip-permissions --max-turns 25}"
  prompt="$(cat "$NIGHTSHIFT_HOME/prompts/$stage.md")

## Context
Repo working directory: $wd"
  case "$stage" in
    explore|fix) prompt="$prompt

## Change-size guidance (soft — not a hard cap)
Prefer a change under ${MAX_FILES:-15} files and ${MAX_LINES:-400} lines. Larger is acceptable only
if it is genuinely ONE coherent, reviewable improvement — never bundle unrelated changes." ;;
  esac
  case "$stage" in
    fix|review) prompt="$prompt

### finding.json
$(cat "$id/finding.json")" ;;
  esac
  if [ "$stage" = review ]; then
    prompt="$prompt

### git diff (working tree)
$(git -C "$wd" diff)"
  fi
  # Layer 1 for the agent: inject core.hooksPath via env so EVERY git the agent runs is
  # confined by hooks/pre-push — no writes to any repo config. Layer 2: the PreToolUse guard
  # (blocks disabling Layer 1) via --settings. NIGHTSHIFT_BRANCH_PREFIX is already exported.
  # shellcheck disable=SC2086
  out="$(cd "$wd" && \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR" \
    claude -p "$prompt" --output-format json --settings "$STATE_DIR/claude-settings.json" $flags </dev/null 2>/dev/null)" || return 1
  # `claude -p --output-format json` prints a SINGLE result object — .result/.usage/
  # .total_cost_usd are top-level (docs: code.claude.com/docs/en/headless). An earlier
  # `.[-1]` (array-index) errored on the object, yielding an empty result → the extract
  # fallback made every explore report found:false, so claude mode silently did nothing.
  printf '%s' "$out" | jq -r '.result // ""'               > "$id/$stage.out"
  printf '%s' "$out" | jq -r '.usage.output_tokens // empty' > "$id/.tokens_$stage" 2>/dev/null || true
  printf '%s' "$out" | jq -r '.total_cost_usd // empty'      > "$id/.cost_$stage"   2>/dev/null || true
  case "$stage" in
    explore) python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/finding.json" ;;
    fix)     cp "$id/$stage.out" "$id/worknote.md" ;;
    review)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/review.md" ;;
  esac
  return 0
}

# --------------------------------------------------------------- selection ----
select_order() { # emit "path<TAB>mode<TAB>base", most-recently-changed first (cold-start churn)
  local i path mode base ts
  for i in "${!REPO_PATHS[@]}"; do
    path="${REPO_PATHS[$i]}"; mode="${REPO_MODES[$i]}"; base="${REPO_BASES[$i]:-}"
    case "$mode" in branch-fix|findings-only) ;; *) continue ;; esac
    [ -d "$path/.git" ] || { log "skip $path (not a git repo)"; continue; }
    ts=$(git -C "$path" log -1 --format=%ct 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\n' "$ts" "$path" "$mode" "$base"
  done | sort -rn | cut -f2-
}

open_branch_count() { # unmerged nightshift/* across all repos (reconciles against reality, §3e)
  local total=0 i path n
  for i in "${!REPO_PATHS[@]}"; do
    path="${REPO_PATHS[$i]}"
    [ -d "$path/.git" ] || continue
    git -C "$path" fetch -q origin 2>/dev/null || true
    if git -C "$path" show-ref -q --verify refs/remotes/origin/main 2>/dev/null; then
      n=$(git -C "$path" branch -r --no-merged origin/main 2>/dev/null | grep -c "origin/${BRANCH_PREFIX}" || true)
    else
      n=$(git -C "$path" ls-remote --heads origin "${BRANCH_PREFIX}*" 2>/dev/null | wc -l | tr -d ' ')
    fi
    total=$((total + n))
  done
  echo "$total"
}

# ---------------------------------------------------------------- worktree ----
# Every work item runs in a throwaway, isolated git worktree — never the repo's
# live checkout. So nightshift never touches your branch/state, and any misstep
# (incl. non-git shell, §2b) is confined to a dir we delete afterwards.
base_ref() { # repo -> best base ref to branch from
  local repo="$1" r
  for r in ORIGIN_HEAD origin/main origin/master main master; do
    if [ "$r" = ORIGIN_HEAD ]; then
      r=$(git -C "$repo" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/##') || true
      [ -z "$r" ] && continue
    fi
    git -C "$repo" rev-parse -q --verify "$r" >/dev/null 2>&1 && { echo "$r"; return 0; }
  done
  echo HEAD
}
resolve_base() { # repo cfgbase -> ref to branch from (rulebook `base:` wins, else auto-detect)
  local repo="$1" cfg="$2"
  if [ -n "$cfg" ]; then
    if git -C "$repo" rev-parse -q --verify "origin/$cfg" >/dev/null 2>&1; then echo "origin/$cfg"; return 0; fi
    if git -C "$repo" rev-parse -q --verify "$cfg"        >/dev/null 2>&1; then echo "$cfg";        return 0; fi
    log "  $(basename "$repo"): configured base '$cfg' not found — auto-detecting"
  fi
  base_ref "$repo"
}
setup_worktree() { git -C "$1" worktree add -q --detach "$2" "$3"; }   # repo wt base
remove_worktree() {                                                    # repo wt
  git -C "$1" worktree remove --force "$2" 2>/dev/null || true
  git -C "$1" worktree prune 2>/dev/null || true
}

# --------------------------------------------------------------------- pr ----
# Open a normal (non-draft) PR for a freshly pushed nightshift/* branch. A PR is a
# GitHub-API object, NOT a push to main — the pre-push hook is untouched and the
# merge stays the human's click. Best-effort: PR off, no GitHub remote (e.g. a
# local bare remote / sandbox), missing gh, or a gh failure all just skip the PR;
# the branch is already pushed either way. Echoes the PR url ("" if none). All
# progress/errors go to stderr so stdout stays clean for the caller.
open_pr() { # repo wt branch item_dir -> echoes PR url ("" if none)
  local repo="$1" wt="$2" branch="$3" id="$4" base url
  [ "$NIGHTSHIFT_OPEN_PR" = 1 ] || return 0
  case "$(git -C "$repo" remote get-url origin 2>/dev/null || true)" in
    *github.com*) ;;
    *) log "  no GitHub remote — branch pushed, PR skipped"; return 0 ;;
  esac
  command -v gh >/dev/null 2>&1 || { log "  gh not found — branch pushed, no PR"; return 0; }
  base="$(base_ref "$repo")"; base="${base#origin/}"; [ "$base" = HEAD ] && base=main
  { jq -r '.summary // "improvement"' "$id/finding.json"
    echo; echo '---'
    echo '_Opened by nightshift — review at leisure; the merge is yours._'; echo
    cat "$id/worknote.md" 2>/dev/null || true
  } > "$id/pr-body.md"
  url="$( (cd "$wt" && gh pr create --base "$base" --head "$branch" \
            --title "nightshift: $(jq -r '.summary // "improvement"' "$id/finding.json")" \
            --body-file "$id/pr-body.md" 2>/dev/null) )" \
    || { log "  gh pr create failed — branch pushed, no PR"; return 0; }
  log "  PR opened: $url"
  printf '%s' "$url"
}

# ---------------------------------------------------------------- finalize ----
finalize() { # repo worktree item_dir -> echoes branch name
  local repo="$1" wt="$2" id="$3" fp type slug branch sha
  fp=$(jq -r '.fingerprint' "$id/finding.json")
  type=$(jq -r '.type // "change"' "$id/finding.json")   # default so the branch slug never reads "null"
  slug="$(printf '%s-%s' "$type" "$(basename "$repo")" | tr '[:upper:] /' '[:lower:]--' | cut -c1-40)"
  branch="${BRANCH_PREFIX}${slug}-$(date +%Y%m%d-%H%M%S)"
  git -C "$wt" checkout -q -b "$branch"
  git -C "$wt" add -A
  git -C "$wt" -c user.name=nightshift -c user.email=nightshift@localhost \
      commit -q -m "nightshift: $(jq -r '.summary' "$id/finding.json")

$(cat "$id/worknote.md")"
  # Layer 1 hook active for THIS push only (-c), never persisted to the repo config.
  git -c core.hooksPath="$HOOKS_DIR" -C "$wt" push -q -u origin "$branch"
  sha=$(git -C "$wt" rev-parse HEAD)
  local pr_url; pr_url=$(open_pr "$repo" "$wt" "$branch" "$id")
  ledger_append "$(basename "$id")" "$repo" "$fp" "$branch" "$sha" "shipped" "$(jq -r '.summary // ""' "$id/finding.json")" "$pr_url"
  echo "$branch"
}

# ------------------------------------------------------------------- digest ----
write_digest() { # made open status
  local made="$1" open="$2" status="$3" f="$DIGEST_DIR/$NIGHT.md" runs dur
  {
    echo "# nightshift digest — $NIGHT"
    echo
    local fcount=0
    [ -f "$LEDGER" ] && fcount=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n and .outcome=="finding")]|length' "$LEDGER" 2>/dev/null || echo 0)
    echo "- agent: \`$NIGHTSHIFT_AGENT\` · shipped this run: ${made} · findings-only: ${fcount} · open (unmerged): ${open}/${MAX_OPEN} (cap)"
    if [ -f "$RUNSLOG" ]; then
      runs=$(grep -c "\"night\":\"$NIGHT\"" "$RUNSLOG" || true)
      dur=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n)|.duration_s]|add // 0' "$RUNSLOG")
      echo "- runs tonight: ${runs} stage-invocations, ${dur}s total"
    fi
    echo
    if [ "$status" = "backpressure" ]; then
      echo "**FULL STOP — open-branch cap reached.** Harvest (merge/delete) some \`${BRANCH_PREFIX}\` branches to resume."
    else
      echo "## Shipped"
      [ -f "$LEDGER" ] && jq -r --arg n "$NIGHT" \
        'select(.night==$n and .outcome=="shipped") | "- " + .repo + " → `" + (.branch // "") + "` — " + (.summary // .fingerprint) + (if .pr_url then "  ([open PR](" + .pr_url + "))" else "" end)' \
        "$LEDGER" 2>/dev/null || true
      echo
      echo "## Findings (findings-only — reported, not touched)"
      [ -f "$LEDGER" ] && jq -r --arg n "$NIGHT" \
        'select(.night==$n and .outcome=="finding") | "- " + .repo + " — " + (.summary // .fingerprint) + "  (" + .fingerprint + ")"' \
        "$LEDGER" 2>/dev/null || true
      echo
      echo "## Considered but not shipped"
      [ -f "$LEDGER" ] && jq -r --arg n "$NIGHT" \
        'select(.night==$n and (.outcome=="abandoned" or .outcome=="deferred")) | "- " + .repo + " — " + .outcome + ": " + (.summary // .fingerprint)' \
        "$LEDGER" 2>/dev/null || true
    fi
  } > "$f"
  log "digest -> $f"
}

# --------------------------------------------------------------------- main ----
main() {
  load_rulebook
  write_claude_settings
  log "agent=$NIGHTSHIFT_AGENT prefix=$BRANCH_PREFIX · cap: max $MAX_OPEN unmerged ${BRANCH_PREFIX} branches · run ceiling $MAX_RUN_BRANCHES · fix iters $MAX_FIX_ITER"

  local made=0 considered=0 findings=0 repo mode id found fp fnj iter verdict wt base b summary open pass=0 progress stop_reason=ok
  # No per-night production cap. The ONLY cap is the count of OPEN (unmerged) nightshift/* branches:
  # work continues while fewer than max_open_branches are unmerged; merging/closing frees slots and
  # work resumes; when merging stops it fills to the cap and stops. "All night" continuous operation
  # is bounded by this cap, by running out of new work, and by the subscription 5h window.
  while true; do
    [ "$made" -ge "$MAX_RUN_BRANCHES" ] && { log "safety ceiling ($MAX_RUN_BRANCHES) reached — stop"; break; }
    open=$(open_branch_count)
    if [ "$open" -ge "$MAX_OPEN" ]; then
      log "open-branch cap reached ($open/$MAX_OPEN) — stop; merge/close some to free slots"
      stop_reason=backpressure; break
    fi
    pass=$((pass + 1))
    progress=0
  while IFS=$'\t' read -r repo mode cfgbase; do
    [ -n "$repo" ] || continue
    open=$(open_branch_count)
    [ "$open" -ge "$MAX_OPEN" ] && { log "open-branch cap reached ($open/$MAX_OPEN) — stop"; stop_reason=backpressure; break; }

    id="$RUNS_DIR/item-$(date +%s%N)"; mkdir -p "$id"
    echo "$repo" > "$id/repo"
    wt="$WORKTREES_DIR/$(basename "$id")"
    base="$(resolve_base "$repo" "$cfgbase")"
    if ! setup_worktree "$repo" "$wt" "$base"; then
      log "  $(basename "$repo"): could not create worktree — skip"; continue
    fi

    run_agent explore "$wt" "$id" || true
    considered=$((considered + 1))
    found=$(jq -r '.found' "$id/finding.json" 2>/dev/null || echo false)
    if [ "$found" != "true" ]; then
      log "  $(basename "$repo") [$mode]: nothing worth doing"; remove_worktree "$repo" "$wt"; continue
    fi
    fp=$(finding_fingerprint "$id/finding.json")
    if [ -z "$fp" ]; then
      log "  $(basename "$repo") [$mode]: finding without a usable fingerprint — skip"; remove_worktree "$repo" "$wt"; continue
    fi
    # Persist the resolved fingerprint so finalize/ledger read the same identity.
    fnj=$(jq --arg fp "$fp" '.fingerprint=$fp' "$id/finding.json") && printf '%s' "$fnj" > "$id/finding.json"
    summary=$(jq -r '.summary // ""' "$id/finding.json")

    if [ "$mode" = findings-only ]; then
      if already_done "$fp"; then
        log "  $(basename "$repo") [findings-only]: already reported ($fp) — skip"; remove_worktree "$repo" "$wt"; continue
      fi
      ledger_append "$(basename "$id")" "$repo" "$fp" "" "" "finding" "$summary"
      findings=$((findings + 1))
      log "  $(basename "$repo") [findings-only]: $summary"
      remove_worktree "$repo" "$wt"; continue
    fi

    # branch-fix
    if already_acted "$fp"; then
      log "  $(basename "$repo"): already handled ($fp) — skip"; remove_worktree "$repo" "$wt"; continue
    fi
    iter=0; verdict="revise"
    while [ "$iter" -lt "$MAX_FIX_ITER" ]; do
      iter=$((iter + 1))
      run_agent fix "$wt" "$id" || true
      run_agent review "$wt" "$id" || true
      verdict=$(jq -r '.verdict' "$id/review.md" 2>/dev/null || echo abandon)
      [ "$verdict" = ship ] && break
      [ "$verdict" = abandon ] && break
    done

    b=""
    if [ "$verdict" = ship ]; then
      b=$(finalize "$repo" "$wt" "$id")
      made=$((made + 1)); progress=1
      log "  $(basename "$repo"): shipped -> $b"
    else
      ledger_append "$(basename "$id")" "$repo" "$fp" "" "" "abandoned" "$summary"
      log "  $(basename "$repo"): abandoned ($fp)"
    fi
    remove_worktree "$repo" "$wt"
    [ -n "$b" ] && git -C "$repo" branch -q -D "$b" >/dev/null 2>&1 || true
  done < <(select_order)
    [ "$progress" -eq 0 ] && { log "pass $pass: no new shippable work — stop"; break; }
  done

  open=$(open_branch_count)
  write_digest "$made" "$open" "$stop_reason"
  log "night done: $made shipped this run, $considered considered, $open now open (cap $MAX_OPEN)."
}

main "$@"
