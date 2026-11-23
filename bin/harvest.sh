#!/usr/bin/env bash
# nightshift harvest — records the human's verdict on every shipped branch.
#
# For each `shipped` row it derives merged | open | dropped from git (the ladder in reconcile(),
# ADR 0016) and appends a `verdict` event only when that changed: append-only and idempotent. It
# never overwrites a human verdict, except with an objective merge (ADR 0007).
# Findings (branch=null) have no sha to reconcile. The freshness probe (lib/probe_findings.py,
# ADR 0014, ADR 0021) records their state in state/findings-probe.json, a derived snapshot and never
# a ledger event; `todos` lists them and `close` records the human verdict.
#
#   harvest.sh                 # reconcile all shipped branches, append changed verdicts
#   harvest.sh --dry-run       # show the reconciliation, write nothing
#   harvest.sh verdict <sel> <verdict> [reason]   # record a manual verdict (findings/override)
#   harvest.sh todos           # list open findings, numbered, with freshness state
#   harvest.sh close <item|sel> [reason]          # record `resolved` for one open finding
#   harvest.sh probe           # re-run the freshness probe, print the table
#   harvest.sh survival        # re-measure whether merged fixes held (ADR 0043), print per repo
#   harvest.sh retract <night> [reason]           # withdraw a night's `empty` rows as evidence
#   harvest.sh --help          # print the usage above (see usage(), which this mirrors)
# Any other argument is an error (exit 2), never a silent fall-through to the
# argument-less form — that form WRITES to the ledger. See the dispatch in main.
set -euo pipefail

NIGHTSHIFT_HOME="${NIGHTSHIFT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# NIGHTSHIFT_STATE_DIR is the operator's state override for every entry point and must reach here,
# or todos/close/verdict would silently write the default ledger. A bare STATE_DIR still wins: the
# runner and the tests hand this run's state dir down under that name.
STATE_DIR="${STATE_DIR:-${NIGHTSHIFT_STATE_DIR:-$NIGHTSHIFT_HOME/state}}"
LEDGER="${LEDGER:-$STATE_DIR/ledger.jsonl}"
RULEBOOK="${RULEBOOK:-$NIGHTSHIFT_HOME/rulebook.yaml}"
[ -f "$RULEBOOK" ] || RULEBOOK="$NIGHTSHIFT_HOME/rulebook.example.yaml"
PROBE_SNAPSHOT="${PROBE_SNAPSHOT:-$STATE_DIR/findings-probe.json}"
SURVIVAL_SNAPSHOT="${SURVIVAL_SNAPSHOT:-$STATE_DIR/fix-survival.json}"
# Every ledger read and write goes through lib/ledger.py (row format, failure exits, jq semantics).
# Imported, not run as a file, so Python reuses the module's cached bytecode (as in lib/digest.sh).
ledger() {
  python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger; sys.exit(ledger.cli(sys.argv[2:]))' \
    "$NIGHTSHIFT_HOME/lib" --ledger "$LEDGER" "$@"
}
BRANCH_PREFIX="nightshift/"   # overridden by the rulebook's branch_prefix; the orphan sweep needs it
# The Runner's commit identity marks a recorded sha as nightshift's work (step 1 of reconcile()).
# shellcheck source=../lib/commit_identity.sh
source "$NIGHTSHIFT_HOME/lib/commit_identity.sh"

declare -a REPO_PATHS=() REPO_BASES=()
repo_id() { realpath -m -- "$1" 2>/dev/null || printf '%s' "${1%/}"; }
# shellcheck source=../lib/base_resolution.sh
source "$NIGHTSHIFT_HOME/lib/base_resolution.sh"
# shellcheck source=../lib/rulebook.sh
source "$NIGHTSHIFT_HOME/lib/rulebook.sh"

load_rulebook() {
  local i
  # Fail closed: reconciling on a partial repo set would misjudge the rest.
  rulebook_load "$RULEBOOK" || { echo "rulebook parse failed ($RULEBOOK) — aborting harvest" >&2; exit 1; }
  [ -n "${RB[branch_prefix]}" ] && BRANCH_PREFIX="${RB[branch_prefix]}"
  for ((i = 0; i < RB_REPOS; i++)); do
    REPO_PATHS+=("$(repo_id "${RB[repos.$i.path]}")"); REPO_BASES+=("${RB[repos.$i.base]}")
  done
}

# Last recorded verdict for a repo+branch as "verdict<TAB>source" (empty fields if none); source
# `manual` marks a human decision the loop must not clobber.
last_verdict_meta() { # repo branch
  ledger last-branch-verdict "$1" "$2" 2>/dev/null || printf '\t\n'
}

append_verdict() { # item repo fingerprint branch sha verdict reason [source]
  ledger append-verdict "$(date +%F)" "$(date -Iseconds)" "$@"
}

# Reconcile one shipped branch -> echo merged|open|dropped|skip (ADR 0016). `skip` means unknown:
# an errored or blind probe never produces a terminal verdict, so the last one stays (fail closed).
reconcile() { # repo base branch sha [pr_url]
  local repo="$1" base="$2" branch="$3" sha="$4" pr_url="${5:-}"
  # 1. sha is an ancestor of base (merge commit / fast-forward); holds after the ref is deleted.
  if git -C "$repo" merge-base --is-ancestor "$sha" "$base" 2>/dev/null; then
    # Unless nightshift never authored that commit: then finalize's commit failed and the branch
    # sits on its base commit, and `merged` (the one verdict that outranks a human's) would be
    # invented. Only a READABLE foreign commit proves that; a gc'd object still counts as merged.
    # Scoped to this rung: a squash/rebase merge is settled by step 2, whoever replayed it.
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
  # Without the shipped object or resolving PR evidence, a deleted ref cannot distinguish
  # a squash/rebase merge from a drop. Preserve the last verdict (ADR 0016).
  if ! git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    echo skip; return
  fi
  # 4/5. ref on origin -> open; ref gone -> dropped; a failed probe -> skip. `|| rc=$?`, not
  #      `; rc=$?`: under `set -e` a failing substitution in a bare assignment aborts harvest there.
  local refs rc=0
  refs="$(git -C "$repo" ls-remote --heads origin "$branch" 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ] && { echo skip; return; }
  [ -n "$refs" ] && { echo open; return; }
  echo dropped
}

# Adopt an orphan (ADR 0018): synthesize its lost `shipped` row so the branch re-enters reconcile.
# The sha comes from ls-remote; unknown fields are null, and `adopted`/`source` mark the row as
# synthetic. Idempotent: an adopted branch is in the ledger's known set.
adopt_orphan() { # repo branch sha
  ledger adopt-orphan "$(date +%F)" "$(date -Iseconds)" "$@"
}

# Orphan sweep (ADR 0016, ADR 0018): a <prefix>* branch on origin without a ledger row can never get
# a verdict yet holds an open-branch cap slot, so it is adopted and the next reconcile judges it.
# It acts on what is really on origin, so it also repairs orphans the run-start guard (ADR 0017)
# cannot see. --dry-run reports only.
sweep_orphans() {
  local i repo n=0 sha ref b key known_repo known_branch
  local -A known=()
  # Branch names are unique only inside one repository; the ledger spans the whole fleet.
  while IFS=$'\x1f' read -r known_repo known_branch; do
    [ -n "$known_repo" ] && [ -n "$known_branch" ] || continue
    known_repo="$(repo_id "$known_repo")"
    known["$known_repo"$'\x1f'"$known_branch"]=1
  done < <(ledger known-branches 2>/dev/null || true)
  for i in "${!REPO_PATHS[@]}"; do
    repo="${REPO_PATHS[$i]}"
    [ "${RECONCILE_BASE[$repo]-unfetched}" = "" ] && continue   # unreachable — don't guess (fail closed)
    [ -d "$repo/.git" ] || continue
    while read -r sha ref; do
      [ -n "$ref" ] || continue
      b="${ref#refs/heads/}"
      key="$repo"$'\x1f'"$b"
      [ -n "${known[$key]:-}" ] && continue
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
manual_verdict() { # scope selector verdict [reason]
  local scope="$1" sel="$2" verdict="$3" reason="${4:-}" verdicts v known=0
  verdicts="$(ledger verdict-names)"
  for v in $verdicts; do [ "$v" = "$verdict" ] && known=1; done
  if [ "$known" -eq 0 ]; then
    echo "verdict must be one of: $verdicts" >&2
    exit 2
  fi
  # Open findings for `findings` (close), else every shipped/finding row; each match carries its
  # `selector` (the adoption id of an adopted branch, else its item) and `adoption`.
  local matches
  matches=$(ledger verdict-matches "$scope" "$sel")
  if [ "$matches" = "[]" ]; then
    case "$scope" in
      findings) echo "no open finding matches '$sel'" >&2 ;;
      adopted)  echo "no adopted branch matches '$sel'" >&2 ;;
      *)        echo "no shipped/finding ledger row matches '$sel'" >&2 ;;
    esac
    exit 1
  fi
  # A branch or fingerprint can repeat across fleet repos. A human verdict outranks the machine, so
  # an ambiguous selector is refused rather than resolved to the newest row.
  local ndistinct
  ndistinct=$(jq -r '[.[]|[.repo, (.branch // ""), (.fingerprint // "")]]|unique|length' <<<"$matches")
  if [ "$ndistinct" -gt 1 ]; then
    echo "ambiguous selector '$sel' matches $ndistinct repo-scoped findings/branches; use an item id, --adopted, or --fingerprint —" >&2
    jq -r '.[] | (if .adoption then "--adopted " + (.selector | @sh) else .item end) as $selector
          | "  \(.repo)  \(.branch // "(finding)")  [\($selector)]"' <<<"$matches" | sort -u >&2
    exit 2
  fi
  local row item repo fp branch sha
  row=$(jq -c 'last' <<<"$matches")
  item=$(jq -r '.item' <<<"$row"); repo=$(jq -r '.repo' <<<"$row")
  fp=$(jq -r '.fingerprint // ""' <<<"$row"); branch=$(jq -r '.branch // ""' <<<"$row")
  sha=$(jq -r '.sha // ""' <<<"$row")
  # Idempotent: don't append a duplicate identical manual verdict on the same branch.
  local was was_src
  IFS=$'\t' read -r was was_src < <(last_verdict_meta "$repo" "$branch") || true
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
  local i args=()
  for i in "${!REPO_PATHS[@]}"; do
    args+=(--base "${REPO_PATHS[$i]}" "${REPO_BASES[$i]:-}")
  done
  python3 "$NIGHTSHIFT_HOME/lib/probe_findings.py" \
    --ledger "$LEDGER" --out "$PROBE_SNAPSHOT" "${args[@]}" "$@"
}

# Whether merged fixes held (ADR 0043): pure observation like the findings probe, and non-fatal.
run_survival() { # [--print]
  local i args=()
  for i in "${!REPO_PATHS[@]}"; do
    args+=(--base "${REPO_PATHS[$i]}" "${REPO_BASES[$i]:-}")
  done
  python3 "$NIGHTSHIFT_HOME/lib/probe_survival.py" \
    --ledger "$LEDGER" --out "$SURVIVAL_SNAPSHOT" "${args[@]}" "$@"
}

# Age in whole days, for the "how long has this been rotting" column.
age_days() { # iso_ts
  local then now
  then=$(date -d "$1" +%s 2>/dev/null) || { echo "?"; return; }
  now=$(date +%s)
  echo $(( (now - then) / 86400 ))
}

# Open findings, oldest first. The ordinal is informational; mutations use the stable item id.
todo_items() { jq -r '[.items[]] | sort_by(.ts) | .[] | @base64' "$PROBE_SNAPSHOT" 2>/dev/null; }

list_todos() {
  run_probe >/dev/null || { echo "probe failed — cannot list findings" >&2; exit 1; }
  local n=0 row item repo dim state ts summary verify age mark
  printf '%-4s %-6s %-18s %-11s %-13s %-24s %s\n' '#' 'AGE' 'REPO' 'DIMENSION' 'STATE' 'ITEM' 'SUMMARY'
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
    printf '%-4s %-6s %-18s %-11s %-13s %-24s %s\n' \
      "$n" "$age" "$(basename "$repo")" "${dim:-—}" "$mark" "$(jq -r '.item' <<<"$item")" "${summary:0:96}"
  done < <(todo_items)
  if [ "$n" -eq 0 ]; then
    echo "(no open findings)"
  else
    printf '\n%d open finding(s). Close one with: harvest.sh close <item> [reason]\n' "$n"
  fi
}

# Record a human `resolved` for an open finding. Numeric selectors are refused: a probe can reorder
# the `todos` numbering before `close` runs; the item id is stable.
close_todo() { # <selector> [reason]
  local sel="$1" reason="${2:-}"
  if [[ "$sel" =~ ^[0-9]+$ ]]; then
    echo "numeric close selectors are unsafe because todo numbering can change; use the ITEM shown by: harvest.sh todos" >&2
    exit 2
  fi
  manual_verdict findings "$sel" resolved "$reason"
  # Re-probe so the snapshot drops the closed item now, not at the next harvest.
  run_probe >/dev/null || true
}

# ------------------------------------------------------------------ retract ----
# Withdraw a night's `empty` rows as evidence (ADR 0023). An `empty` row claims "this lens was
# reviewed and clean", which a night whose stages never ran cannot back. The ledger is append-only:
# one `outcome:"retracted"` row per item, which readers honour; the original row stays visible.
retract_night() { # <night> [reason]
  local night="$1" reason="${2:-}" rows n=0 row item repo dim
  case "$night" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) echo "retract takes a night as YYYY-MM-DD (got '$night')" >&2; exit 2 ;;
  esac
  # Only un-retracted `empty` rows, so re-running is a no-op.
  rows=$(ledger unretracted-empty "$night")
  if [ "$rows" = "[]" ]; then
    echo "nothing to retract for $night (no un-retracted \`empty\` rows)"; return 0
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    item=$(jq -r '.item' <<<"$row"); repo=$(jq -r '.repo' <<<"$row")
    dim=$(jq -r '.dimension // ""' <<<"$row")
    ledger append-retraction "$(date +%F)" "$(date -Iseconds)" "$item" "$repo" "$dim" "$night" "$reason"
    n=$((n + 1))
    printf 'retracted: %s × %s [item=%s]\n' "$(basename "$repo")" "${dim:-—}" "$item"
  done < <(jq -c '.[]' <<<"$rows")
  printf '%d `empty` row(s) from %s withdrawn as evidence%s\n' "$n" "$night" "${reason:+ ($reason)}"
}

# --------------------------------------------------------------------- main ----
usage() {
  cat <<'EOF'
usage:
  harvest.sh                                    reconcile all shipped branches, append changed verdicts
  harvest.sh --dry-run                          show the reconciliation, write nothing
  harvest.sh verdict <sel> <verdict> [reason]   record a manual verdict (findings/override)
      <sel>      item id | branch | fingerprint
  harvest.sh verdict --adopted <sel> <verdict> [reason]
      <sel>      orphan-adopt:<ledger repo path>:<branch>
  harvest.sh verdict --fingerprint <sel> <verdict> [reason]
EOF
  printf '      <verdict>  %s\n' "$(ledger verdict-names ' | ')"
  cat <<'EOF'
  harvest.sh todos                              list open findings with stable item ids and freshness
  harvest.sh close <item|sel> [reason]          record `resolved` for one open finding
  harvest.sh probe                              re-run the finding freshness probe, print the table
  harvest.sh survival                           re-measure whether merged fixes held, print per repo
  harvest.sh retract <YYYY-MM-DD> [reason]      withdraw that night's `empty` rows as evidence
                                                (a night whose stages never ran claimed nothing real)
  harvest.sh --help                             print this
EOF
}

# Dispatch BEFORE any other work and reject anything unrecognised: the ARGUMENT-LESS form writes
# verdicts, so a typo'd --dry-run must be an error, not a silent write.
DRYRUN=0
case "${1:-}" in
  '')        ;;                                  # reconcile (writes)
  --dry-run) DRYRUN=1 ;;
  -h|--help) usage; exit 0 ;;
  verdict)   ;;                                  # arity checked below, run after the ledger checks
  close)     ;;                                  # arity checked below, run after the ledger checks
  todos)     ;;                                  # read-only finding surfaces, run after the checks
  probe)     ;;
  survival)  ;;
  retract)   ;;                                  # arity checked below, like verdict/close
  *)         printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
# Arity, checked before the rulebook and ledger are read. Extra words are rejected: an unquoted
# multi-word reason would otherwise be truncated to its first word in the ledger.
case "${1:-}" in
  verdict)
    verdict_args=$#
    case "${2:-}" in --adopted|--fingerprint) verdict_args=$((verdict_args - 1)) ;; esac
    [ "$verdict_args" -ge 3 ] && [ "$verdict_args" -le 4 ] \
      || { echo "verdict takes [--adopted|--fingerprint] <selector> <verdict> [reason] (quote a multi-word reason)" >&2; usage >&2; exit 2; } ;;
  close)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] \
      || { echo "close takes <item|selector> [reason] (quote a multi-word reason)" >&2; usage >&2; exit 2; } ;;
  retract)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] \
      || { echo "retract takes <YYYY-MM-DD> [reason] (quote a multi-word reason)" >&2; usage >&2; exit 2; } ;;
  *)
    [ "$#" -le 1 ] || { printf 'unexpected extra arguments: %s\n' "${*:2}" >&2; usage >&2; exit 2; } ;;
esac

load_rulebook
[ -f "$LEDGER" ] || { echo "no ledger at $LEDGER — nothing to harvest"; exit 0; }
# Validate the whole ledger up front: reads inside process substitutions fail invisibly to
# `set -e`, which would make harvest a silent no-op. Like `jq -e .`, this also refuses an empty
# ledger and one whose last row is null or false.
ledger validate --require-truthy-last >/dev/null 2>&1 \
  || { echo "ledger is not valid JSONL ($LEDGER) — aborting harvest" >&2; exit 1; }

case "${1:-}" in
  verdict)
    shift
    verdict_scope=all
    case "$1" in --adopted|--fingerprint) verdict_scope="${1#--}"; shift ;; esac
    manual_verdict "$verdict_scope" "$@"
    exit 0 ;;
  todos)   list_todos;        exit 0 ;;
  close)   shift; close_todo "$@"; exit 0 ;;
  probe)   run_probe --print; exit 0 ;;
  survival) run_survival --print; exit 0 ;;
  retract) shift; retract_night "$@"; exit 0 ;;
esac

# prefetch each repo once
declare -A RECONCILE_BASE=()

# Latest verdict+source per repo+branch in ONE ledger pass (last_verdict_meta per branch would be
# quadratic). Keyed by repo AND branch: branch names are repo-local. Lines come in jq's group_by
# order, so when two raw repo strings share one realpath the later line wins.
declare -A LAST_VERDICT=()
while IFS=$'\x1f' read -r _r _b _v _s; do
  _r="$(repo_id "$_r")"
  [ -n "$_r" ] && [ -n "$_b" ] && LAST_VERDICT["$_r"$'\x1f'"$_b"]="$_v"$'\t'"$_s"
done < <(ledger branch-verdicts 2>/dev/null)

printf '%-28s %-46s %-8s -> %-8s %s\n' REPO BRANCH WAS NOW ""
changed=0
# US (\x1f), NOT tab: bash collapses runs of IFS whitespace, so an empty field (an adopted row's
# null fingerprint, ADR 0018) would shift the rest left and misjudge the branch.
while IFS=$'\x1f' read -r item repo fp branch sha pr_url; do
  [ -z "$branch" ] && continue
  verdict_key="$(repo_id "$repo")"$'\x1f'"$branch"
  IFS=$'\t' read -r was was_src <<< "${LAST_VERDICT[$verdict_key]:-}" || true
  # Refresh once per listed repo. A guessed or stale base can write a terminal verdict that
  # also removes a still-open branch from the runner's cap.
  if [ -z "${RECONCILE_BASE[$repo]+set}" ]; then
    base=""
    if cfg=$(configured_base_for_repo "$(repo_id "$repo")") && [ -e "$repo/.git" ]; then
      base=$(branch_inventory_base "$repo" "$BRANCH_PREFIX" "$cfg" 2>/dev/null) || base=""
    fi
    RECONCILE_BASE[$repo]="$base"
  fi
  base="${RECONCILE_BASE[$repo]}"
  if [ -z "$base" ]; then
    printf '%-28s %-46s %-8s -> %-8s %s\n' "$(basename "$repo")" "$branch" \
      "${was:-—}" "skip" "(origin branches or base unknown — fail closed)"
    continue
  fi
  now=$(reconcile "$repo" "$base" "$branch" "$sha" "$pr_url")
  # A probe that could not decide (skip) leaves the recorded verdict untouched.
  if [ "$now" = skip ]; then
    printf '%-28s %-46s %-8s -> %-8s %s\n' "$(basename "$repo")" "$branch" "${was:-—}" "skip" "(probe failed — fail closed)"
    continue
  fi
  mark=""
  # Human verdicts hold (ADR 0007): never overwrite resolved/wontfix or a manual terminal verdict,
  # except with an objective merge.
  held=0
  case "$was" in
    resolved|wontfix) held=1 ;;
    merged|dropped)   [ "$was_src" = manual ] && held=1 ;;
  esac
  if [ "$held" -eq 1 ] && [ "$now" != merged ]; then
    printf '%-28s %-46s %-8s -> %-8s %s\n' "$(basename "$repo")" "$branch" "${was:-—}" "$was" "(held: human verdict)"
    continue
  fi
  # 'open' is the implicit default: an undecided branch with no prior verdict writes no row.
  if [ "$now" != "$was" ] && ! { [ "$now" = open ] && [ -z "$was" ]; }; then
    mark="*"
    if [ "$DRYRUN" -eq 0 ]; then append_verdict "$item" "$repo" "$fp" "$branch" "$sha" "$now" ""; fi
    changed=$((changed + 1))
  fi
  printf '%-28s %-46s %-8s -> %-8s %s\n' "$(basename "$repo")" "$branch" "${was:-—}" "$now" "$mark"
done < <(ledger reconcile-rows)

echo
if [ "$DRYRUN" -eq 1 ]; then
  echo "(dry-run: $changed verdict change(s) NOT written; * marks what would change)"
else
  echo "$changed verdict event(s) appended (* = changed since last harvest)."
fi
sweep_orphans
# Findings never enter the reconcile loop; refresh their snapshot. A --dry-run writes nothing.
if [ "$DRYRUN" -eq 0 ]; then
  run_probe >/dev/null 2>&1 || echo "(findings probe skipped — non-fatal)" >&2
  run_survival >/dev/null 2>&1 || echo "(fix survival probe skipped — non-fatal)" >&2
fi
