#!/usr/bin/env bash
# Shared base-ref resolution for the Runner, harvest and branch review.

# Use fully qualified names for Git queries. Tags named origin/... are legal.
cached_configured_base_ref() { # repo configured-base -> full remote-tracking ref
  local repo="$1" cfg="$2" ref
  [ -n "$cfg" ] || return 1
  ref="refs/remotes/origin/$cfg"
  # Preserve the existing base: origin/name spelling alongside bare branch names.
  if [[ "$cfg" = origin/* ]] && ! git -C "$repo" show-ref --verify --quiet "$ref"; then
    ref="refs/remotes/$cfg"
  fi
  git check-ref-format "$ref" || return
  printf '%s\n' "$ref"
}

live_origin_branch() { # repo configured-base -> branch on origin
  local repo="$1" cfg="$2" advertised value ref head="" head_advertised=0 candidate="" count=0
  if [ -n "$cfg" ]; then
    if [[ "$cfg" = origin/* ]]; then
      advertised=$(git -C "$repo" ls-remote --heads origin "refs/heads/$cfg") || return
      [ -n "$advertised" ] || cfg="${cfg#origin/}"
    fi
    printf '%s\n' "$cfg"
    return
  fi
  advertised=$(git -C "$repo" ls-remote --symref origin HEAD refs/heads/main refs/heads/master) || return
  while IFS=$'\t' read -r value ref; do
    case "$ref" in
      HEAD)
        head_advertised=1
        [[ "$value" != 'ref: refs/heads/'* ]] || head="${value#ref: refs/heads/}"
        ;;
      refs/heads/main|refs/heads/master) candidate="${ref#refs/heads/}"; count=$((count + 1)) ;;
    esac
  done <<< "$advertised"
  if [ -n "$head" ]; then
    printf '%s\n' "$head"
  elif [ "$head_advertised" -eq 0 ] && [ "$count" -eq 1 ]; then
    # Older bare origins can have an unborn HEAD and just one conventional base.
    printf '%s\n' "$candidate"
  else
    return 1
  fi
}

prune_conflicting_base_refs() { # repo full remote-tracking base ref
  local repo="$1" base="$2" listing oid ref symref advertised
  local source_ref="refs/heads/${base#refs/remotes/origin/}"
  local -a stale_refs=() stale_oids=()
  listing=$(git -C "$repo" for-each-ref --format='%(objectname)%09%(refname)%09%(symref)' refs/remotes/origin/) || return
  while IFS=$'\t' read -r oid ref symref; do
    [ -n "$ref" ] && [ -z "$symref" ] || continue
    if [[ "$base" = "$ref/"* || "$ref" = "$base/"* ]]; then
      stale_refs+=("$ref")
      stale_oids+=("$oid")
    fi
  done <<< "$listing"
  [ "${#stale_refs[@]}" -gt 0 ] || return 0

  # A branch and its parent or child cannot coexist on origin. Confirm the replacement before
  # removing any local tracking ref, and compare its old object ID in case it moved meanwhile.
  advertised=$(git -C "$repo" ls-remote --exit-code --heads origin "$source_ref") || return
  grep -Fxq -- "$source_ref" < <(cut -f2 <<< "$advertised") || return
  local i
  for i in "${!stale_refs[@]}"; do
    git -C "$repo" update-ref --no-deref -d "${stale_refs[$i]}" "${stale_oids[$i]}" || return
  done
}

branch_inventory_base() { # repo branch-prefix configured-base [branch-name] -> fresh full base ref
  local repo="$1" prefix="$2" cfg="$3" only="${4:-}" branch base shallow
  local -a specs=("+refs/heads/$prefix*:refs/remotes/origin/$prefix*") history=(--update-shallow)
  git check-ref-format "refs/heads/${prefix}branch" || return
  branch=$(live_origin_branch "$repo" "$cfg") || return
  # Refresh other tracking branches when possible. A narrow clone can still request a deleted
  # former base here; the explicit fetch below independently verifies the required refs.
  git -C "$repo" fetch --prune -q origin >/dev/null 2>&1 || true
  base="refs/remotes/origin/$branch"
  git check-ref-format "$base" || return
  prune_conflicting_base_refs "$repo" "$base" || return
  case "$base" in
    "refs/remotes/origin/$prefix"*) ;;
    *) specs+=("+refs/heads/${base#refs/remotes/origin/}:$base") ;;
  esac
  if [ -n "$only" ] && [[ "$only" != "$prefix"* && "refs/remotes/origin/$only" != "$base" ]]; then
    git check-ref-format "refs/heads/$only" || return
    specs+=("+refs/heads/$only:refs/remotes/origin/$only")
  fi
  shallow=$(git -C "$repo" rev-parse --is-shallow-repository) || return
  [ "$shallow" != true ] || history=(--unshallow)
  # The explicit inventory must bypass configured negative refspecs and prune deleted managed
  # branches even in a single-branch clone. The exact base participates in the same update.
  git -C "$repo" fetch --atomic --prune --no-prune-tags --no-tags -q --refmap= "${history[@]}" origin "${specs[@]}" >&2 \
    || return
  [ "$(git -C "$repo" rev-parse --is-shallow-repository)" = false ] || return 1
  git -C "$repo" show-ref --verify --quiet "$base" || return
  printf '%s\n' "$base"
}

managed_open_refs() { # repo base-ref branch-prefix -> full refs, one per line
  git -C "$1" for-each-ref --no-merged "$2" --format='%(refname)' "refs/remotes/origin/$3"
}

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

resolve_base() { # repo configured-base -> configured ref when present, else auto-detected ref
  local repo="$1" cfg="${2:-}"
  if [ -n "$cfg" ]; then
    git -C "$repo" rev-parse -q --verify "origin/$cfg" >/dev/null 2>&1 \
      && { echo "origin/$cfg"; return 0; }
    git -C "$repo" rev-parse -q --verify "$cfg" >/dev/null 2>&1 \
      && { echo "$cfg"; return 0; }
    if [ "${BASE_RESOLUTION_WARN_MISSING:-0}" = 1 ] && declare -F log >/dev/null; then
      log "  $(basename "$repo"): configured base '$cfg' not found — auto-detecting"
    fi
  fi
  base_ref "$repo"
}

configured_base_for_repo() { # path -> configured branch, 1 if the rulebook has no entry
  local path="$1" i
  for i in "${!REPO_PATHS[@]}"; do
    if [ "${REPO_PATHS[$i]}" = "$path" ]; then
      printf '%s\n' "${REPO_BASES[$i]:-}"
      return
    fi
  done
  return 1
}

# Rulebook base lookup that REFUSES to guess for a repo the rulebook does not list: prints nothing
# and returns 1. A verdict derived against a guessed base is not a weaker answer, it is a wrong one.
# Observed 2026-09-06: the operator narrowed the rulebook to one repo, and the next harvest ran the
# reconcile loop over the whole ledger — that loop is fleet-wide by design, it must reach a branch
# whose repo was removed. A lookup that fell back to auto-detection then picked `origin/main` for
# six gitflow repos whose base is `develop`, so sixteen branches demonstrably merged into develop were not ancestors
# of main and their `merged` verdicts were rewritten to `open`. Removing a repo from the rulebook
# must not rewrite the history of the decisions already made about it.
base_for_repo_strict() { # path -> configured/auto ref for a listed repo; 1 for an unlisted one
  local cfg
  cfg=$(configured_base_for_repo "$1") || return
  resolve_base "$1" "$cfg"
}
