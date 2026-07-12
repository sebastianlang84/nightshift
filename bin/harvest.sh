#!/usr/bin/env bash
# nightshift harvest — the human-feedback loop (todo.md "NEXT").
#
# WHAT IT DOES
# The ledger records `shipped` when a branch is pushed, then goes deaf: it never
# learns whether the human MERGED, DROPPED, or is still sitting on the branch.
# That verdict is the only ground-truth signal in the system. harvest closes the
# loop: for every shipped branch it reconciles against git reality and appends a
# `verdict` event (append-only — never mutates the shipped row).
#
# HOW MERGE IS DETECTED (robust to branch deletion)
# We test whether the branch's recorded SHA is an ANCESTOR of the repo's base tip:
#     git merge-base --is-ancestor <sha> <base>
# This is authoritative even after the branch ref is deleted (the ledger keeps the
# sha), and needs no `gh`/PR API. Verdicts:
#     merged   — sha is contained in base (merged, whether or not the ref survives)
#     open     — not in base, branch ref still on origin (awaiting your decision)
#     dropped  — not in base, branch ref gone from origin (deleted unmerged)
#
# It is APPEND-ONLY and idempotent: a verdict event is written only when the state
# CHANGED since the last recorded verdict, so re-running nightly does not spam.
# Human verdicts are ground truth: reconcile only DERIVES merged|open|dropped, so it
# never overwrites a resolved/wontfix or a manually recorded terminal verdict with a
# machine value (only an objective merge — sha contained in base — can supersede them).
# Findings (branch=null) have no sha to test — give them a verdict by hand:
#     harvest.sh verdict <item|branch|fingerprint> <merged|dropped|resolved|wontfix|open> [reason]
#
#   harvest.sh                 # reconcile all shipped branches, append changed verdicts
#   harvest.sh --dry-run       # show the reconciliation, write nothing
#   harvest.sh verdict <sel> <verdict> [reason]   # record a manual verdict (findings/override)
set -euo pipefail

NIGHTSHIFT_HOME="${NIGHTSHIFT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-$NIGHTSHIFT_HOME/state}"
LEDGER="${LEDGER:-$STATE_DIR/ledger.jsonl}"
RULEBOOK="${RULEBOOK:-$NIGHTSHIFT_HOME/rulebook.yaml}"
[ -f "$RULEBOOK" ] || RULEBOOK="$NIGHTSHIFT_HOME/rulebook.example.yaml"
SCHEMA_VERSION=2

declare -a REPO_PATHS=() REPO_BASES=()
load_rulebook() {
  local tag a b c d e parsed
  # Capture output + exit status; a parse error via process substitution is invisible
  # to `set -euo pipefail` and would reconcile on a truncated repo set. Fail closed.
  parsed="$(python3 "$NIGHTSHIFT_HOME/lib/parse_rulebook.py" "$RULEBOOK")" \
    || { echo "rulebook parse failed ($RULEBOOK) — aborting harvest" >&2; exit 1; }
  while IFS=$'\t' read -r tag a b c d e; do
    case "$tag" in
      repo) REPO_PATHS+=("${a#path=}"); REPO_BASES+=("${c#base=}") ;;
    esac
  done <<< "$parsed"
}

# --- base resolution, mirrored from bin/nightshift.sh (resolve_base / base_ref) ---
base_ref() {
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
resolve_base() {
  local repo="$1" cfg="$2"
  if [ -n "$cfg" ]; then
    git -C "$repo" rev-parse -q --verify "origin/$cfg" >/dev/null 2>&1 && { echo "origin/$cfg"; return 0; }
    git -C "$repo" rev-parse -q --verify "$cfg"        >/dev/null 2>&1 && { echo "$cfg";        return 0; }
  fi
  base_ref "$repo"
}
base_for_repo() {
  local path="$1" i
  for i in "${!REPO_PATHS[@]}"; do
    [ "${REPO_PATHS[$i]}" = "$path" ] && { resolve_base "$path" "${REPO_BASES[$i]}"; return 0; }
  done
  resolve_base "$path" ""
}

# last recorded verdict for a branch as "verdict<TAB>source" (empty fields if none).
# source distinguishes a human 'manual' verdict from a machine reconcile so the loop
# can refuse to clobber a human decision.
last_verdict_meta() { # branch
  jq -rs --arg b "$1" \
    '([.[]|select(.outcome=="verdict" and .branch==$b)]|last) as $v
     | "\($v.verdict // "")\t\($v.source // "")"' \
    "$LEDGER" 2>/dev/null || printf '\t\n'
}

append_verdict() { # item repo fingerprint branch sha verdict reason [source]
  jq -nc \
    --arg item "$1" --arg repo "$2" --arg fp "$3" --arg branch "$4" --arg sha "$5" \
    --arg verdict "$6" --arg reason "${7:-}" --arg source "${8:-}" \
    --arg ts "$(date -Iseconds)" \
    --arg night "$(date +%F)" --argjson sv "$SCHEMA_VERSION" \
    '{night:$night,item:$item,repo:$repo,fingerprint:$fp,
      branch:($branch|if .=="" then null else . end),
      sha:($sha|if .=="" then null else . end),
      outcome:"verdict",verdict:$verdict,
      reason:($reason|if .=="" then null else . end),
      source:($source|if .=="" then null else . end),
      ts:$ts,schema_version:$sv}' >> "$LEDGER"
}

# reconcile one shipped branch -> echo merged|open|dropped|skip (ADR 0016).
# An authoritative ladder derives the verdict; a `skip` means "unknown" — an errored or blind
# probe must never produce a terminal verdict (fail closed), so the last verdict is left intact.
reconcile() { # repo base branch sha [pr_url]
  local repo="$1" base="$2" branch="$3" sha="$4" pr_url="${5:-}"
  # 1. sha is an ancestor of base (merge-commit / fast-forward) — cheapest definitive test.
  if git -C "$repo" merge-base --is-ancestor "$sha" "$base" 2>/dev/null; then
    echo merged; return
  fi
  # 2. the branch's one-commit patch already landed in base (squash / rebase merge, ADR 0011).
  #    Needs the sha as a real local object; a gc'd sha falls through to the PR probe below,
  #    never to 'dropped' on a can't-evaluate. `git cherry` marks a patch-equal commit "- <sha>".
  if git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null \
     && git -C "$repo" cherry "$base" "$sha" 2>/dev/null | grep -q '^- '; then
    echo merged; return
  fi
  # 3. authoritative PR state — covers a gc'd sha the local tests could not evaluate. Optional:
  #    only when the shipped row carried a pr_url and `gh` is available/authenticated.
  if [ -n "$pr_url" ] && command -v gh >/dev/null 2>&1; then
    local st
    st="$(gh pr view "$pr_url" --json state -q .state 2>/dev/null)" || st=""
    case "$st" in
      MERGED) echo merged; return ;;
      CLOSED) echo dropped; return ;;
      OPEN)   echo open;   return ;;
    esac
  fi
  # 4/5. ref on origin -> open; ref gone -> dropped. Distinguish a real 'gone' from a failed
  #      probe: capture ls-remote's exit status separately from its output and fail closed.
  local refs rc
  refs="$(git -C "$repo" ls-remote --heads origin "$branch" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && { echo skip; return; }
  [ -n "$refs" ] && { echo open; return; }
  echo dropped
}

# ---------------------------------------------------------- manual verdict ----
manual_verdict() { # selector verdict [reason]
  local sel="$1" verdict="$2" reason="${3:-}"
  case "$verdict" in
    merged|dropped|resolved|wontfix|open) ;;
    *) echo "verdict must be one of: merged dropped resolved wontfix open" >&2; exit 2 ;;
  esac
  # find the newest shipped/finding row matching selector by item, branch, or fingerprint
  local row
  row=$(jq -sc --arg s "$sel" \
    '[.[]|select(.outcome=="shipped" or .outcome=="finding")
         |select(.item==$s or .branch==$s or .fingerprint==$s)]|last' "$LEDGER")
  if [ "$row" = null ] || [ -z "$row" ]; then
    echo "no shipped/finding ledger row matches '$sel'" >&2; exit 1
  fi
  local item repo fp branch sha
  item=$(jq -r '.item' <<<"$row"); repo=$(jq -r '.repo' <<<"$row")
  fp=$(jq -r '.fingerprint' <<<"$row"); branch=$(jq -r '.branch // ""' <<<"$row")
  sha=$(jq -r '.sha // ""' <<<"$row")
  append_verdict "$item" "$repo" "$fp" "$branch" "$sha" "$verdict" "$reason" manual
  printf 'recorded verdict: %s = %s%s\n' "$sel" "$verdict" "${reason:+ ($reason)}"
}

# --------------------------------------------------------------------- main ----
DRYRUN=0
load_rulebook
[ -f "$LEDGER" ] || { echo "no ledger at $LEDGER — nothing to harvest"; exit 0; }

if [ "${1:-}" = verdict ]; then
  shift; [ "$#" -ge 2 ] || { echo "usage: harvest.sh verdict <selector> <verdict> [reason]" >&2; exit 2; }
  manual_verdict "$@"; exit 0
fi
[ "${1:-}" = --dry-run ] && DRYRUN=1

# prefetch each repo once
declare -A FETCHED=()
printf '%-28s %-46s %-8s -> %-8s %s\n' REPO BRANCH WAS NOW ""
changed=0
while IFS=$'\t' read -r item repo fp branch sha pr_url; do
  [ -z "$branch" ] && continue
  # Prefetch once per repo, recording reachability. A missing repo path or a failed fetch means
  # we cannot see git reality — skip every branch in that repo (fail closed) rather than
  # reconcile against a stale/absent view and stamp false 'dropped's fleet-wide.
  if [ -z "${FETCHED[$repo]:-}" ]; then
    if [ -d "$repo/.git" ] && git -C "$repo" fetch -q origin 2>/dev/null; then
      FETCHED[$repo]=ok
    else
      FETCHED[$repo]=fail
    fi
  fi
  if [ "${FETCHED[$repo]}" = fail ]; then
    printf '%-28s %-46s %-8s -> %-8s %s\n' "$(basename "$repo")" "$branch" "—" "skip" "(repo unreachable — fail closed)"
    continue
  fi
  base=$(base_for_repo "$repo")
  now=$(reconcile "$repo" "$base" "$branch" "$sha" "$pr_url")
  IFS=$'\t' read -r was was_src < <(last_verdict_meta "$branch") || true
  # A probe that could not decide (skip) leaves the recorded verdict untouched.
  if [ "$now" = skip ]; then
    printf '%-28s %-46s %-8s -> %-8s %s\n' "$(basename "$repo")" "$branch" "${was:-—}" "skip" "(probe failed — fail closed)"
    continue
  fi
  mark=""
  # Human decisions are ground truth. reconcile derives only merged|open|dropped, so it
  # must never overwrite a verdict it cannot itself produce (resolved/wontfix are
  # human-only) nor a manually recorded terminal verdict — that clobber flipped a manual
  # 'dropped' back to 'open' on the next run. Sole exception: an objective merge (sha in
  # base) outranks any prior label.
  held=0
  case "$was" in
    resolved|wontfix) held=1 ;;
    merged|dropped)   [ "$was_src" = manual ] && held=1 ;;
  esac
  if [ "$held" -eq 1 ] && [ "$now" != merged ]; then
    printf '%-28s %-46s %-8s -> %-8s %s\n' "$(basename "$repo")" "$branch" "${was:-—}" "$was" "(held: human verdict)"
    continue
  fi
  # 'open' is the implicit default — only terminal verdicts are recorded, so an
  # as-yet-undecided branch never writes a row and nightly re-runs stay quiet.
  if [ "$now" != "$was" ] && ! { [ "$now" = open ] && [ -z "$was" ]; }; then
    mark="*"
    if [ "$DRYRUN" -eq 0 ]; then append_verdict "$item" "$repo" "$fp" "$branch" "$sha" "$now" ""; fi
    changed=$((changed + 1))
  fi
  printf '%-28s %-46s %-8s -> %-8s %s\n' "$(basename "$repo")" "$branch" "${was:-—}" "$now" "$mark"
done < <(jq -r '.[]|[.item,.repo,.fingerprint,(.branch//""),(.sha//""),(.pr_url//"")]|@tsv' \
           <(jq -sc '[.[]|select(.outcome=="shipped" and .branch!=null and .sha!=null)]' "$LEDGER"))

echo
if [ "$DRYRUN" -eq 1 ]; then
  echo "(dry-run: $changed verdict change(s) NOT written; * marks what would change)"
else
  echo "$changed verdict event(s) appended (* = changed since last harvest)."
fi
