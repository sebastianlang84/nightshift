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
RULEBOOK="${RULEBOOK:-$NIGHTSHIFT_HOME/rulebook.yaml}"
[ -f "$RULEBOOK" ] || RULEBOOK="$NIGHTSHIFT_HOME/rulebook.example.yaml"
HOOKS_DIR="$NIGHTSHIFT_HOME/hooks"
STATE_DIR="$NIGHTSHIFT_HOME/state"
NIGHT="$(date +%Y-%m-%d)"
RUNS_DIR="$NIGHTSHIFT_HOME/runs/$NIGHT"
DIGEST_DIR="$NIGHTSHIFT_HOME/digests"
LEDGER="$STATE_DIR/ledger.jsonl"
RUNSLOG="$STATE_DIR/runs.jsonl"
mkdir -p "$STATE_DIR" "$RUNS_DIR" "$DIGEST_DIR"

log() { echo "[nightshift] $*" >&2; }

# ---------------------------------------------------------------- rulebook ----
declare -a REPO_PATHS=() REPO_MODES=()
load_rulebook() {
  local tag a b
  while IFS=$'\t' read -r tag a b; do
    case "$tag" in
      prefix)       BRANCH_PREFIX="$a" ;;
      max_branches) MAX_BRANCHES="$a" ;;
      max_open)     MAX_OPEN="$a" ;;
      max_files)    MAX_FILES="$a" ;;
      max_lines)    MAX_LINES="$a" ;;
      repo)         REPO_PATHS+=("$a"); REPO_MODES+=("$b") ;;
    esac
  done < <(python3 "$NIGHTSHIFT_HOME/lib/parse_rulebook.py" "$RULEBOOK")
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

ledger_append() { # item repo fp branch sha outcome
  jq -nc \
    --arg night "$NIGHT" --arg item "$1" --arg repo "$2" --arg fp "$3" \
    --arg branch "$4" --arg sha "$5" --arg outcome "$6" --arg ts "$(date -Iseconds)" \
    '{night:$night,item:$item,repo:$repo,fingerprint:$fp,
      branch:($branch|if .=="" then null else . end),
      sha:($sha|if .=="" then null else . end),
      outcome:$outcome,ts:$ts}' >> "$LEDGER"
}

already_done() { # fingerprint
  [ -f "$LEDGER" ] || return 1
  grep -Fq "\"fingerprint\":\"$1\"" "$LEDGER"
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
    fix|review) prompt="$prompt

### finding.json
$(cat "$id/finding.json")" ;;
  esac
  if [ "$stage" = review ]; then
    prompt="$prompt

### git diff (working tree)
$(git -C "$wd" diff)"
  fi
  # shellcheck disable=SC2086
  out="$(cd "$wd" && claude -p "$prompt" --output-format json $flags 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -r '.[-1].result // ""'          > "$id/$stage.out"
  printf '%s' "$out" | jq -r '.[-1].usage.output_tokens // empty' > "$id/.tokens_$stage" 2>/dev/null || true
  printf '%s' "$out" | jq -r '.[-1].total_cost_usd // empty'      > "$id/.cost_$stage"   2>/dev/null || true
  case "$stage" in
    explore) python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/finding.json" ;;
    fix)     cp "$id/$stage.out" "$id/worknote.md" ;;
    review)  python3 "$NIGHTSHIFT_HOME/lib/extract_json.py" < "$id/$stage.out" > "$id/review.md" ;;
  esac
  return 0
}

# --------------------------------------------------------------- selection ----
select_order() { # emit branch-fix repo paths, most-recently-changed first (cold-start churn)
  local i path mode ts
  for i in "${!REPO_PATHS[@]}"; do
    path="${REPO_PATHS[$i]}"; mode="${REPO_MODES[$i]}"
    [ "$mode" = "branch-fix" ] || continue
    [ -d "$path/.git" ] || { log "skip $path (not a git repo)"; continue; }
    ts=$(git -C "$path" log -1 --format=%ct 2>/dev/null || echo 0)
    printf '%s\t%s\n' "$ts" "$path"
  done | sort -rn | cut -f2
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

# ---------------------------------------------------------------- finalize ----
finalize() { # repo item_dir  -> echoes branch name
  local repo="$1" id="$2" fp type slug branch sha
  fp=$(jq -r '.fingerprint' "$id/finding.json")
  type=$(jq -r '.type' "$id/finding.json")
  slug="$(printf '%s-%s' "$type" "$(basename "$repo")" | tr '[:upper:] /' '[:lower:]--' | cut -c1-40)"
  branch="${BRANCH_PREFIX}${slug}-$(date +%Y%m%d-%H%M%S)"
  git -C "$repo" config core.hooksPath "$HOOKS_DIR"   # ensure Layer 1 is active
  git -C "$repo" checkout -q -b "$branch"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=nightshift -c user.email=nightshift@localhost \
      commit -q -m "nightshift: $(jq -r '.summary' "$id/finding.json")

$(cat "$id/worknote.md")"
  git -C "$repo" push -q -u origin "$branch"
  sha=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  ledger_append "$(basename "$id")" "$repo" "$fp" "$branch" "$sha" "shipped"
  echo "$branch"
}

# ------------------------------------------------------------------- digest ----
write_digest() { # made open status
  local made="$1" open="$2" status="$3" f="$DIGEST_DIR/$NIGHT.md" runs dur
  {
    echo "# nightshift digest — $NIGHT"
    echo
    echo "- agent: \`$NIGHTSHIFT_AGENT\` · budget: ${made}/${MAX_BRANCHES} branches this night · open (unmerged): ${open}/${MAX_OPEN}"
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
        'select(.night==$n and .outcome=="shipped") | "- " + .repo + " → `" + .branch + "` — " + .fingerprint' \
        "$LEDGER" 2>/dev/null || true
      echo
      echo "## Considered but not shipped"
      [ -f "$LEDGER" ] && jq -r --arg n "$NIGHT" \
        'select(.night==$n and .outcome!="shipped") | "- " + .repo + " — " + .outcome + " (" + .fingerprint + ")"' \
        "$LEDGER" 2>/dev/null || true
    fi
  } > "$f"
  log "digest -> $f"
}

# --------------------------------------------------------------------- main ----
main() {
  load_rulebook
  log "agent=$NIGHTSHIFT_AGENT prefix=$BRANCH_PREFIX caps: ${MAX_BRANCHES}/night, ${MAX_OPEN} open"

  local open; open=$(open_branch_count)
  log "open nightshift branches (unmerged): $open / $MAX_OPEN"
  if [ "$open" -ge "$MAX_OPEN" ]; then
    log "FULL STOP — open-branch cap reached; producing nothing."
    write_digest 0 "$open" backpressure
    return 0
  fi

  local made=0 considered=0 repo id found fp iter verdict
  local -a order=()
  mapfile -t order < <(select_order)

  for repo in "${order[@]}"; do
    [ "$made" -ge "$MAX_BRANCHES" ] && { log "nightly branch cap reached ($MAX_BRANCHES) — stop"; break; }
    [ "$open" -ge "$MAX_OPEN" ] && { log "open-branch cap reached — stop"; break; }

    id="$RUNS_DIR/item-$(date +%s%N)"; mkdir -p "$id"
    echo "$repo" > "$id/repo"
    run_agent explore "$repo" "$id" || true
    considered=$((considered + 1))

    found=$(jq -r '.found' "$id/finding.json" 2>/dev/null || echo false)
    if [ "$found" != "true" ]; then log "  $(basename "$repo"): nothing worth doing"; continue; fi

    fp=$(jq -r '.fingerprint' "$id/finding.json")
    if already_done "$fp"; then log "  $(basename "$repo"): already handled ($fp) — skip"; continue; fi

    iter=0; verdict="revise"
    while [ "$iter" -lt 3 ]; do
      iter=$((iter + 1))
      run_agent fix "$repo" "$id" || true
      run_agent review "$repo" "$id" || true
      verdict=$(jq -r '.verdict' "$id/review.md" 2>/dev/null || echo abandon)
      [ "$verdict" = ship ] && break
      [ "$verdict" = abandon ] && break
    done

    if [ "$verdict" = ship ]; then
      local b; b=$(finalize "$repo" "$id")
      made=$((made + 1)); open=$((open + 1))
      log "  $(basename "$repo"): shipped -> $b"
    else
      git -C "$repo" checkout -- . 2>/dev/null || true
      git -C "$repo" clean -fdq 2>/dev/null || true
      ledger_append "$(basename "$id")" "$repo" "$fp" "" "" "abandoned"
      log "  $(basename "$repo"): abandoned ($fp)"
    fi
  done

  write_digest "$made" "$open" ok
  log "night done: $made shipped, $considered considered."
}

main "$@"
