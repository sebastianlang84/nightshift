#!/usr/bin/env bash
# nightshift branch reviewer (read-only) — the reliable merge-decision routine.
#
# WHY THIS EXISTS
# A `git diff <base>..<branch>` (TWO-dot) is a trap for reviewing a steward branch:
# if <base> has ADVANCED since the branch was cut, the two-dot diff renders the base's
# OWN new commits as if the branch had DELETED them — a tiny one-line branch can look
# like it ripped out a whole feature (observed 2026-07-10, a false "scope explosion").
#
# This tool makes that failure impossible by construction: it only ever shows
#   * the branch's OWN commits         git log  <base>..<branch>
#   * the three-dot diff (merge-base)  git diff <base>...<branch>
# both of which are independent of how far <base> has moved. It also reports the drift
# explicitly, previews the real merge, and flags files changed-but-not-described.
#
# It is READ-ONLY: it never checks out, merges, deletes, or pushes. It prints the exact
# commands for you to run once you have judged the packet.
#
#   review-branch.sh                        # every managed repo, every open nightshift/* branch
#   review-branch.sh <repo-path>            # one repo, every open branch
#   review-branch.sh <repo-path> <branch>   # one specific branch (with or without origin/ prefix)
#
# Base per repo mirrors the Runner (rulebook `base:` wins, else auto-detect origin HEAD),
# so the review base is exactly the one nightshift branched from.
set -euo pipefail

NIGHTSHIFT_HOME="${NIGHTSHIFT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RULEBOOK="${RULEBOOK:-$NIGHTSHIFT_HOME/rulebook.yaml}"
[ -f "$RULEBOOK" ] || RULEBOOK="$NIGHTSHIFT_HOME/rulebook.example.yaml"

PREFIX="nightshift/"
declare -a REPO_PATHS=() REPO_BASES=()
load_rulebook() {
  local tag a b c d e
  while IFS=$'\t' read -r tag a b c d e; do
    case "$tag" in
      prefix) PREFIX="$a" ;;
      repo)   REPO_PATHS+=("${a#path=}"); REPO_BASES+=("${c#base=}") ;;
    esac
  done < <(python3 "$NIGHTSHIFT_HOME/lib/parse_rulebook.py" "$RULEBOOK")
}

# --- base resolution, mirrored from bin/nightshift.sh (resolve_base / base_ref) ---
base_ref() { # repo -> best base ref
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
resolve_base() { # repo cfgbase -> ref (rulebook base wins, else auto-detect)
  local repo="$1" cfg="$2"
  if [ -n "$cfg" ]; then
    git -C "$repo" rev-parse -q --verify "origin/$cfg" >/dev/null 2>&1 && { echo "origin/$cfg"; return 0; }
    git -C "$repo" rev-parse -q --verify "$cfg"        >/dev/null 2>&1 && { echo "$cfg";        return 0; }
  fi
  base_ref "$repo"
}

# base_for_repo <path> -> resolved base ref, using the rulebook `base:` for that path
base_for_repo() {
  local path="$1" i
  for i in "${!REPO_PATHS[@]}"; do
    [ "${REPO_PATHS[$i]}" = "$path" ] && { resolve_base "$path" "${REPO_BASES[$i]}"; return 0; }
  done
  resolve_base "$path" ""   # not in rulebook — auto-detect
}

# ------------------------------------------------------------------ one branch ----
review_branch() { # repo base branchref
  local repo="$1" base="$2" ref="$3"
  local name="${ref#origin/}"            # nightshift/foo-...  (for display + delete cmd)
  local basebranch="${base#origin/}"

  printf '\n=== %s : %s ===\n' "$(basename "$repo")" "$name"
  printf 'base: %s\n' "$base"

  # (1) the branch's OWN commits — never affected by base drift
  local commits; commits=$(git -C "$repo" log --oneline "$base..$ref" 2>/dev/null || true)
  if [ -z "$commits" ]; then
    printf 'commits on branch: (none) — already contained in %s\n' "$base"
    printf 'VERDICT: ALREADY MERGED — safe to delete.\n'
    printf 'next: git -C %q push origin --delete %q\n' "$repo" "$name"
    return 0
  fi
  printf 'commits on branch:\n%s\n' "$(printf '%s\n' "$commits" | sed 's/^/  /')"

  # (2) base drift — how far base moved since the branch point (context, not a problem)
  local drift; drift=$(git -C "$repo" rev-list --count "$ref..$base" 2>/dev/null || echo 0)
  if [ "$drift" -gt 0 ]; then
    printf 'base drift: %s commit(s) landed on %s since the branch point — a TWO-dot diff would\n' "$drift" "$basebranch"
    printf '            misreport these as branch deletions. This tool uses three-dot, so it does not.\n'
  else
    printf 'base drift: none (branch is current with %s)\n' "$basebranch"
  fi

  # (3) the authoritative change: three-dot (merge-base...branch)
  printf 'change (three-dot, authoritative):\n%s\n' \
    "$(git -C "$repo" diff --stat "$base...$ref" | sed 's/^/  /')"

  # (4) merge preview — does it actually apply onto current base?
  local mt rc=0
  mt=$(git -C "$repo" merge-tree --write-tree "$base" "$ref" 2>&1) || rc=$?
  local merge_line conflicts=""
  if [ "$rc" -eq 0 ]; then
    merge_line="CLEAN — applies onto current $basebranch with no conflict"
  else
    conflicts=$(printf '%s\n' "$mt" | grep -iE 'conflict|CONFLICT' | head -8 || true)
    merge_line="CONFLICTS — needs rebase/resolve before merge"
  fi
  printf 'merge preview: %s\n' "$merge_line"
  [ -n "$conflicts" ] && printf '%s\n' "$conflicts" | sed 's/^/  /'

  # (5) scope check (advisory) — files changed but not named in any commit message (R9 guard)
  local changed msg unmentioned=""
  changed=$(git -C "$repo" diff --name-only "$base...$ref" || true)
  msg=$(git -C "$repo" log "$base..$ref" --format='%B' || true)
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! grep -qF "$f" <<<"$msg" && ! grep -qF "$(basename "$f")" <<<"$msg"; then
      unmentioned+="  $f"$'\n'
    fi
  done <<<"$changed"
  if [ -n "$unmentioned" ]; then
    printf 'scope note: changed file(s) NOT named in any commit message (verify intent):\n%s' "$unmentioned"
  else
    printf 'scope: changed files all referenced in the commit message(s)\n'
  fi

  # (6) verdict + the exact next commands (never executed here)
  local verdict
  if [ "$rc" -ne 0 ]; then
    verdict="CONFLICTS — resolve before merging"
  elif [ -n "$unmentioned" ]; then
    verdict="REVIEW — merges clean, but scope is wider than the message describes (see note)"
  else
    verdict="CLEAN — diff matches stated scope and merges without conflict"
  fi
  printf 'VERDICT: %s\n' "$verdict"
  printf 'next:\n'
  case "$basebranch" in
    main|master)
      printf '  merge : git -C %q checkout %s && git -C %q merge --no-ff %q && git -C %q push origin %s\n' \
        "$repo" "$basebranch" "$repo" "$name" "$repo" "$basebranch" ;;
    *)
      printf '  merge : gitflow base (%s) — open a PR: %s -> %s (do not push %s directly)\n' \
        "$basebranch" "$name" "$basebranch" "$basebranch" ;;
  esac
  printf '  reject: git -C %q push origin --delete %q\n' "$repo" "$name"

  # (7) full authoritative diff, last so the verdict stays on top
  printf -- '--- full diff (three-dot) ---\n'
  git -C "$repo" diff "$base...$ref" || true
}

# ------------------------------------------------------------------- one repo ----
review_repo() { # repo [branchref]
  local repo="$1" only="${2:-}"
  [ -d "$repo/.git" ] || { printf '\n=== %s ===\n(skip: not a git repo)\n' "$repo"; return 0; }
  git -C "$repo" fetch -q origin 2>/dev/null || true
  local base; base="$(base_for_repo "$repo")"

  if [ -n "$only" ]; then
    local ref="$only"; [[ "$ref" == origin/* ]] || ref="origin/$ref"
    git -C "$repo" rev-parse -q --verify "$ref" >/dev/null 2>&1 \
      || { printf '\n=== %s ===\n(branch not found on origin: %s)\n' "$(basename "$repo")" "$only"; return 1; }
    review_branch "$repo" "$base" "$ref"
    return 0
  fi

  # all OPEN (unmerged vs base) nightshift/* branches on origin
  local branches
  branches=$(git -C "$repo" branch -r --no-merged "$base" 2>/dev/null | tr -d ' ' | grep "^origin/${PREFIX}" || true)
  if [ -z "$branches" ]; then
    printf '\n=== %s ===\nno open %s* branches (base %s)\n' "$(basename "$repo")" "$PREFIX" "$base"
    return 0
  fi
  local b
  while IFS= read -r b; do review_branch "$repo" "$base" "$b"; done <<<"$branches"
}

# ---------------------------------------------------------------------- main ----
load_rulebook
if [ "$#" -ge 1 ]; then
  review_repo "$1" "${2:-}"
else
  for repo in "${REPO_PATHS[@]}"; do review_repo "$repo"; done
fi
