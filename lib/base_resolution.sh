#!/usr/bin/env bash
# Shared base-ref resolution for the Runner, harvest and branch review.

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

base_for_repo() { # path -> configured ref from REPO_PATHS/REPO_BASES, else auto-detected ref
  local path="$1" i
  for i in "${!REPO_PATHS[@]}"; do
    [ "${REPO_PATHS[$i]}" = "$path" ] \
      && { resolve_base "$path" "${REPO_BASES[$i]:-}"; return 0; }
  done
  resolve_base "$path" ""
}

# Same lookup, but it REFUSES to guess for a repo the rulebook does not list: prints nothing and
# returns 1. A verdict derived against a guessed base is not a weaker answer, it is a wrong one.
# Observed 2026-09-06: the operator narrowed the rulebook to one repo, and the next harvest ran the
# reconcile loop over the whole ledger — that loop is fleet-wide by design, it must reach a branch
# whose repo was removed. `base_for_repo` then auto-detected `origin/main` for six gitflow repos
# whose base is `develop`, so sixteen branches demonstrably merged into develop were not ancestors
# of main and their `merged` verdicts were rewritten to `open`. Removing a repo from the rulebook
# must not rewrite the history of the decisions already made about it.
base_for_repo_strict() { # path -> configured/auto ref for a listed repo; 1 for an unlisted one
  local path="$1" i
  for i in "${!REPO_PATHS[@]}"; do
    [ "${REPO_PATHS[$i]}" = "$path" ] \
      && { resolve_base "$path" "${REPO_BASES[$i]:-}"; return 0; }
  done
  return 1
}
