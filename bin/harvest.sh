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
# FINDINGS (branch=null) have no sha to test, so the reconcile loop can never reach them. Two
# things close that gap, and neither invents a verdict:
#   * the freshness probe (lib/probe_findings.py) recomputes each open finding's content signature
#     (ADR 0014, ADR 0021) and records untouched / code_changed / unknown into
#     state/findings-probe.json — a derived snapshot, never a ledger event. It runs on every harvest.
#   * `todos` lists what is open with that state attached, and `close` records the human verdict.
#
#   harvest.sh                 # reconcile all shipped branches, append changed verdicts
#   harvest.sh --dry-run       # show the reconciliation, write nothing
#   harvest.sh verdict <sel> <verdict> [reason]   # record a manual verdict (findings/override)
#   harvest.sh --help          # print the usage above
# Any other argument is an error (exit 2), never a silent fall-through to the
# argument-less form — that form WRITES to the ledger. See the dispatch in main.
set -euo pipefail

NIGHTSHIFT_HOME="${NIGHTSHIFT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-$NIGHTSHIFT_HOME/state}"
LEDGER="${LEDGER:-$STATE_DIR/ledger.jsonl}"
RULEBOOK="${RULEBOOK:-$NIGHTSHIFT_HOME/rulebook.yaml}"
[ -f "$RULEBOOK" ] || RULEBOOK="$NIGHTSHIFT_HOME/rulebook.example.yaml"
PROBE_SNAPSHOT="${PROBE_SNAPSHOT:-$STATE_DIR/findings-probe.json}"
SCHEMA_VERSION=2
BRANCH_PREFIX="nightshift/"   # overridden by the rulebook's branch_prefix; the orphan sweep needs it
# The author identity bin/nightshift.sh commits under. It is what marks a recorded sha as OUR work
# rather than a base commit the branch merely points at — see step 0 of reconcile().
NIGHTSHIFT_COMMIT_EMAIL="nightshift@localhost"

declare -a REPO_PATHS=() REPO_BASES=()
load_rulebook() {
  local tag a b c d e parsed
  # Capture output + exit status; a parse error via process substitution is invisible
  # to `set -euo pipefail` and would reconcile on a truncated repo set. Fail closed.
  parsed="$(python3 "$NIGHTSHIFT_HOME/lib/parse_rulebook.py" "$RULEBOOK")" \
    || { echo "rulebook parse failed ($RULEBOOK) — aborting harvest" >&2; exit 1; }
  while IFS=$'\t' read -r tag a b c d e; do
    case "$tag" in
      repo)   REPO_PATHS+=("${a#path=}"); REPO_BASES+=("${c#base=}") ;;
      prefix) [ -n "$a" ] && BRANCH_PREFIX="$a" ;;
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
    '{night:$night,item:$item,repo:$repo,
      fingerprint:($fp|if .=="" then null else . end),
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
    # …unless nightshift never created that commit. Then finalize's commit was rejected (a repo
    # hook, or an empty change), the branch still sits on the base commit it was CUT from, and its
    # containment in base is trivial rather than a merge. Reporting `merged` there invents a merge,
    # counts it into the merge-rate, and — since `merged` is the one verdict that outranks a
    # human's — silently reverses an operator's `dropped` on every harvest. Scoped deliberately to
    # this branch of the ladder: a squash/rebase merge is NOT contained in base and is settled by
    # step 2 below, whatever identity replayed it. A gc'd object falls through to `merged` as
    # before — only a READABLE foreign commit proves our work is absent.
    if git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null \
       && [ "$(git -C "$repo" log -1 --format=%ae "$sha" 2>/dev/null)" != "$NIGHTSHIFT_COMMIT_EMAIL" ]; then
      echo dropped; return
    fi
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

# Adopt an orphan (ADR 0018): synthesize the lost `shipped` row so the branch re-enters the
# reconcile loop and its verdict becomes recordable. The branch name is the only surviving
# provenance (dim/type/repo/timestamp/seq are embedded but not machine-reparsed here); the real
# sha comes from ls-remote. fingerprint/dimension/type/verifiability are unknown → null; `adopted`
# and `source` mark the row so it is never mistaken for a first-hand shipped record. Idempotent:
# once written, the branch is in the ledger's `known` set and is never adopted twice.
adopt_orphan() { # repo branch sha
  jq -nc \
    --arg item "orphan-adopt" --arg repo "$1" --arg branch "$2" --arg sha "$3" \
    --arg ts "$(date -Iseconds)" --arg night "$(date +%F)" --argjson sv "$SCHEMA_VERSION" \
    '{night:$night,item:$item,repo:$repo,fingerprint:null,
      branch:$branch,sha:($sha|if .=="" then null else . end),pr_url:null,
      outcome:"shipped",source:"orphan-adopt",adopted:true,
      summary:"adopted orphan branch (lost shipped row restored)",
      ts:$ts,schema_version:$sv}' >> "$LEDGER"
}

# Orphan sweep (ADR 0016) + adoption (ADR 0018): a <prefix>* branch on origin that the ledger has no
# row for can never receive a verdict (reconcile iterates ledger `shipped` rows), yet it still
# occupies an open-branch cap slot. Such a branch means a shipped record was lost — an isolated-state
# run that pushed to the real origin, or a crash between push and ledger_append. We ADOPT it: write a
# synthetic `shipped` row so the NEXT reconcile derives merged/open/dropped normally (idempotent).
# --dry-run reports only. This is the backstop the run-start guard (ADR 0017) cannot be — it repairs
# orphans from ANY origin (other checkout, other host) because it acts on what is really on origin.
sweep_orphans() {
  local i repo known n=0 sha ref b
  known="$(jq -rs '[.[]|select((.branch//"")!="")|.branch]|unique|.[]' "$LEDGER" 2>/dev/null || true)"
  for i in "${!REPO_PATHS[@]}"; do
    repo="${REPO_PATHS[$i]}"
    [ "${FETCHED[$repo]:-}" = fail ] && continue   # unreachable — don't guess (fail closed)
    [ -d "$repo/.git" ] || continue
    while read -r sha ref; do
      [ -n "$ref" ] || continue
      b="${ref#refs/heads/}"
      grep -qxF "$b" <<<"$known" && continue
      [ "$n" -eq 0 ] && printf 'orphan %s* branches on origin (pushed, no ledger row):\n' "$BRANCH_PREFIX"
      if [ "$DRYRUN" -eq 1 ]; then
        printf '  %-28s %-46s %s\n' "$(basename "$repo")" "$b" "(would adopt)"
      else
        adopt_orphan "$repo" "$b" "$sha"
        printf '  %-28s %-46s %s\n' "$(basename "$repo")" "$b" "(adopted -> shipped)"
      fi
      n=$((n + 1))
    done < <(git -C "$repo" ls-remote --heads origin "${BRANCH_PREFIX}*" 2>/dev/null || true)
  done
  if [ "$n" -gt 0 ]; then
    if [ "$DRYRUN" -eq 1 ]; then
      printf '  -> %d orphan(s) would be adopted (synthetic shipped row); re-run without --dry-run.\n' "$n"
    else
      printf '  -> %d orphan(s) adopted: verdicts derive on the next harvest. Merge or delete on origin as usual.\n' "$n"
    fi
  fi
  return 0
}

# ---------------------------------------------------------- manual verdict ----
manual_verdict() { # selector verdict [reason]
  local sel="$1" verdict="$2" reason="${3:-}"
  case "$verdict" in
    merged|dropped|resolved|wontfix|open) ;;
    *) echo "verdict must be one of: merged dropped resolved wontfix open" >&2; exit 2 ;;
  esac
  # all shipped/finding rows matching the selector by item, branch, or fingerprint
  local matches
  matches=$(jq -sc --arg s "$sel" \
    '[.[]|select(.outcome=="shipped" or .outcome=="finding")
         |select(.item==$s or .branch==$s or .fingerprint==$s)]' "$LEDGER")
  if [ "$matches" = "[]" ]; then
    echo "no shipped/finding ledger row matches '$sel'" >&2; exit 1
  fi
  # Don't silently guess: if the selector spans more than one branch, warn and show them; the
  # newest still wins (matching prior behaviour), but the operator can now see the mis-target.
  local ndistinct
  ndistinct=$(jq -r '[.[]|.branch]|unique|length' <<<"$matches")
  if [ "$ndistinct" -gt 1 ]; then
    echo "warning: '$sel' matches $ndistinct distinct branches; applying to the newest —" >&2
    jq -r '.[]|"  \(.branch // "(finding)")  [\(.item)]"' <<<"$matches" | sort -u >&2
  fi
  local row item repo fp branch sha
  row=$(jq -c 'last' <<<"$matches")
  item=$(jq -r '.item' <<<"$row"); repo=$(jq -r '.repo' <<<"$row")
  fp=$(jq -r '.fingerprint' <<<"$row"); branch=$(jq -r '.branch // ""' <<<"$row")
  sha=$(jq -r '.sha // ""' <<<"$row")
  # Idempotent: don't append a duplicate identical manual verdict on the same branch.
  local was was_src
  IFS=$'\t' read -r was was_src < <(last_verdict_meta "$branch") || true
  if [ -n "$branch" ] && [ "$was" = "$verdict" ] && [ "$was_src" = manual ]; then
    printf 'unchanged: %s is already %s (manual) — nothing appended\n' "$branch" "$verdict"
    return 0
  fi
  append_verdict "$item" "$repo" "$fp" "$branch" "$sha" "$verdict" "$reason" manual
  printf 'recorded verdict: %s = %s%s [item=%s repo=%s]\n' \
    "${branch:-$sel}" "$verdict" "${reason:+ ($reason)}" "$item" "$(basename "$repo")"
}

# ------------------------------------------------------- findings freshness ----
# The probe is pure observation (no model, no network, no ledger write), so it is safe to run on
# every harvest. Non-fatal by contract: a probe failure must never take down reconciliation.
run_probe() { # [--print]
  python3 "$NIGHTSHIFT_HOME/lib/probe_findings.py" \
    --ledger "$LEDGER" --out "$PROBE_SNAPSHOT" "$@"
}

# Age in whole days, for the "how long has this been rotting" column.
age_days() { # iso_ts
  local then now
  then=$(date -d "$1" +%s 2>/dev/null) || { echo "?"; return; }
  now=$(date +%s)
  echo $(( (now - then) / 86400 ))
}

# Open findings, oldest first — ONE ordering shared by `todos` and `close`, so the number a human
# reads off the list is the item `close` acts on.
todo_items() { jq -r '[.items[]] | sort_by(.ts) | .[] | @base64' "$PROBE_SNAPSHOT" 2>/dev/null; }

list_todos() {
  run_probe >/dev/null || { echo "probe failed — cannot list findings" >&2; exit 1; }
  local n=0 row item repo dim state ts summary verify age mark
  printf '%-4s %-6s %-18s %-11s %-13s %s\n' '#' 'AGE' 'REPO' 'DIMENSION' 'STATE' 'SUMMARY'
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    n=$((n + 1))
    item=$(base64 -d <<<"$row")
    repo=$(jq -r '.repo' <<<"$item"); dim=$(jq -r '.dimension // ""' <<<"$item")
    state=$(jq -r '.state' <<<"$item"); ts=$(jq -r '.ts' <<<"$item")
    summary=$(jq -r '.summary // ""' <<<"$item")
    verify=$(jq -r '.verify.result // ""' <<<"$item")
    age="$(age_days "$ts")d"
    case "$state" in
      untouched)    mark="untouched" ;;   # target code never changed -> certainly still open
      code_changed) mark="recheck" ;;     # something changed under it -> may already be fixed
      *)            mark="unknown" ;;
    esac
    [ -n "$verify" ] && mark="$mark/$verify"
    printf '%-4s %-6s %-18s %-11s %-13s %s\n' \
      "$n" "$age" "$(basename "$repo")" "${dim:-—}" "$mark" "${summary:0:96}"
  done < <(todo_items)
  if [ "$n" -eq 0 ]; then
    echo "(no open findings)"
  else
    printf '\n%d open finding(s). Close one with: harvest.sh close <#> [reason]\n' "$n"
  fi
}

# Record a human `resolved` for an open finding, addressed by its `todos` line number (or any
# selector manual_verdict understands). Human input stays ground truth (ADR 0007) — this is just
# the ergonomic front door to `verdict <sel> resolved`.
close_todo() { # <n|selector> [reason]
  local sel="$1" reason="${2:-}" item
  if [[ "$sel" =~ ^[0-9]+$ ]]; then
    [ -f "$PROBE_SNAPSHOT" ] || run_probe >/dev/null || true
    item=$(todo_items | sed -n "${sel}p" | base64 -d 2>/dev/null | jq -r '.item // ""')
    [ -n "$item" ] || { echo "no open finding #$sel — run: harvest.sh todos" >&2; exit 1; }
    sel="$item"
  fi
  manual_verdict "$sel" resolved "$reason"
  # Re-probe so the snapshot (and with it the dashboard) drops the item immediately instead of
  # carrying a closed finding until the next harvest.
  run_probe >/dev/null || true
}

# --------------------------------------------------------------------- main ----
usage() {
  cat <<'EOF'
usage:
  harvest.sh                                    reconcile all shipped branches, append changed verdicts
  harvest.sh --dry-run                          show the reconciliation, write nothing
  harvest.sh verdict <sel> <verdict> [reason]   record a manual verdict (findings/override)
      <sel>      item id | branch | fingerprint
      <verdict>  merged | dropped | resolved | wontfix | open
  harvest.sh todos                              list open findings, numbered, with freshness state
  harvest.sh close <#|sel> [reason]             record `resolved` for one open finding
  harvest.sh probe                              re-run the finding freshness probe, print the table
  harvest.sh --help                             print this
EOF
}

# Dispatch BEFORE any other work, and reject anything unrecognised. Harvest is the one
# tool here whose ARGUMENT-LESS invocation is the mutating one: falling through to the
# default means appending `verdict` rows to the ledger. A typo'd preview flag (--dryrun,
# -n, --dry_run) or a stray selector must therefore be an error, not a silent write —
# the same contract bin/schedule.sh's `*) usage; exit 2` arm gives its subcommands.
DRYRUN=0
case "${1:-}" in
  '')        ;;                                  # reconcile (writes)
  --dry-run) DRYRUN=1 ;;
  -h|--help) usage; exit 0 ;;
  verdict)   ;;                                  # arity checked below, run after the ledger checks
  close)     ;;                                  # arity checked below, run after the ledger checks
  todos)     ;;                                  # read-only finding surfaces, run after the checks
  probe)     ;;
  *)         printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
# Arity, checked here so a malformed command line fails fast and identically whatever
# state the rulebook/ledger are in. Extra words are rejected rather than ignored: for
# `verdict` a 4th+ word is almost always an unquoted multi-word reason, which would
# otherwise be silently truncated to its first word in the ledger.
case "${1:-}" in
  verdict)
    [ "$#" -ge 3 ] && [ "$#" -le 4 ] \
      || { echo "verdict takes <selector> <verdict> [reason] (quote a multi-word reason)" >&2; usage >&2; exit 2; } ;;
  close)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] \
      || { echo "close takes <#|selector> [reason] (quote a multi-word reason)" >&2; usage >&2; exit 2; } ;;
  *)
    [ "$#" -le 1 ] || { printf 'unexpected extra arguments: %s\n' "${*:2}" >&2; usage >&2; exit 2; } ;;
esac

load_rulebook
[ -f "$LEDGER" ] || { echo "no ledger at $LEDGER — nothing to harvest"; exit 0; }
# Validate the whole ledger up front. Every read below is `jq -s` (slurp); a single corrupt
# line would abort jq inside a process substitution, invisible to `set -e`, turning harvest
# into a silent no-op that exits 0 and quietly stops reconciling. Fail loud instead — the same
# fail-closed contract load_rulebook already honours for a broken rulebook.
jq -e . "$LEDGER" >/dev/null 2>&1 \
  || { echo "ledger is not valid JSONL ($LEDGER) — aborting harvest" >&2; exit 1; }

case "${1:-}" in
  verdict) shift; manual_verdict "$@"; exit 0 ;;
  todos)   list_todos;        exit 0 ;;
  close)   shift; close_todo "$@"; exit 0 ;;
  probe)   run_probe --print; exit 0 ;;
esac

# prefetch each repo once
declare -A FETCHED=()

# Precompute the latest verdict+source per branch in ONE ledger pass. last_verdict_meta
# slurps the whole append-only ledger on every call; calling it once per shipped branch in
# the reconcile loop below was O(shipped_branches x ledger_rows) — quadratic as history
# accumulates (the ledger is append-only, never pruned). Branch names are globally unique
# (timestamp+seq+dim), so no branch is reconciled twice and this map is behaviour-identical
# to the per-call scan. group_by preserves input order, so .[-1] is the last-appended verdict.
declare -A LAST_VERDICT=()
while IFS=$'\t' read -r _b _v _s; do
  [ -n "$_b" ] && LAST_VERDICT["$_b"]="$_v"$'\t'"$_s"
done < <(jq -rs '[.[]|select(.outcome=="verdict" and (.branch//"")!="")]
                 | group_by(.branch)[]
                 | .[-1]
                 | "\(.branch)\t\(.verdict // "")\t\(.source // "")"' "$LEDGER" 2>/dev/null)

printf '%-28s %-46s %-8s -> %-8s %s\n' REPO BRANCH WAS NOW ""
changed=0
# US (\x1f), NOT tab: tab is an IFS *whitespace* character, so bash collapses a run of tabs into
# one delimiter and every field after an empty one shifts left. `fingerprint` is legitimately null
# on an adopted orphan row (adopt_orphan writes it so by design, ADR 0018), which shifted branch
# into fp and sha into branch — reconcile then probed a branch named "<sha>" with an empty sha,
# found nothing on origin, and recorded `dropped` for a branch that was actually merged. A
# non-whitespace separator is never collapsed, so empty fields keep their position.
while IFS=$'\x1f' read -r item repo fp branch sha pr_url; do
  [ -z "$branch" ] && continue
  # Prefetch once per repo, recording reachability. A missing repo path or a failed fetch means
  # we cannot see git reality — skip every branch in that repo (fail closed) rather than
  # reconcile against a stale/absent view and stamp false 'dropped's fleet-wide.
  if [ -z "${FETCHED[$repo]:-}" ]; then
    if [ -d "$repo/.git" ] && git -C "$repo" fetch --prune -q origin 2>/dev/null; then
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
  IFS=$'\t' read -r was was_src <<< "${LAST_VERDICT[$branch]:-}" || true
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
done < <(jq -r '.[]|[.item,.repo,.fingerprint,(.branch//""),(.sha//""),(.pr_url//"")]|join("\u001f")' \
           <(jq -sc '[.[]|select(.outcome=="shipped" and .branch!=null and .sha!=null)]' "$LEDGER"))

echo
if [ "$DRYRUN" -eq 1 ]; then
  echo "(dry-run: $changed verdict change(s) NOT written; * marks what would change)"
else
  echo "$changed verdict event(s) appended (* = changed since last harvest)."
fi
sweep_orphans
# Findings never enter the reconcile loop (no branch, no sha). Refresh their freshness snapshot so
# `todos` and the dashboard see today's state. A --dry-run writes nothing here either.
if [ "$DRYRUN" -eq 0 ]; then
  run_probe >/dev/null 2>&1 || echo "(findings probe skipped — non-fatal)" >&2
fi
