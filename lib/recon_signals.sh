#!/usr/bin/env bash
# recon_signals.sh — deterministic, harness-independent filesystem probe for the
# RECON stage. Usage: recon_signals.sh <repo_path>
#
# Prints ONE line of JSON to stdout describing what is present in the repo: which
# review dimensions have real evidence (compose, frontend, tests, CI, IaC, ...).
# Pure filesystem/git inspection — NO model, NO network, and it NEVER writes.
# Safe on any repo: an empty or non-git dir yields all-false/empty but still valid
# JSON (jq must be able to parse the output).
#
# It is the cheap, always-true ground truth handed to prompts/recon.md so the recon
# model judges dimension applicability from signals, not guesses.
set -euo pipefail

log() { echo "[recon] $*" >&2; }

repo="${1:-}"
[ -n "$repo" ] || { echo "usage: recon_signals.sh <repo_path>" >&2; exit 2; }

# File inventory once, reused by every probe. Prefer `git ls-files` (respects the
# repo and .gitignore); fall back to `find` for a non-git dir or a repo with only
# untracked files. Never fatal — an unreadable/missing dir just yields an empty list.
files=""
if [ -d "$repo/.git" ] || git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  files="$(git -C "$repo" ls-files 2>/dev/null || true)"
fi
if [ -z "$files" ] && [ -d "$repo" ]; then
  files="$( (cd "$repo" && find . -type d -name .git -prune -o -type f -print 2>/dev/null) | sed 's#^\./##' || true)"
fi

# grep the path inventory; returns 0 on a match (used only inside `if`).
has() { printf '%s\n' "$files" | grep -Eq "$1"; }
# newline-separated stdin -> compact, unique, sorted JSON array of nonempty lines.
json_array() { jq -R . | jq -sc 'map(select(length>0)) | unique'; }

# ---- booleans ----------------------------------------------------------------
# docs: a docs/ dir, OR multiple top-level *.md beyond README.
has_docs=false
top_md_nonreadme="$(printf '%s\n' "$files" | grep -Ei '^[^/]+\.md$' | grep -Eiv '^readme' | grep -c . || true)"
if has '(^|/)docs/' || [ "$top_md_nonreadme" -ge 2 ]; then
  has_docs=true
fi

has_compose=false
has '(^|/)(docker-compose|compose)[^/]*\.ya?ml$' && has_compose=true

has_dockerfile=false
has '(^|/)[Dd]ockerfile[^/]*$|\.[Dd]ockerfile$' && has_dockerfile=true

# frontend: a package.json whose deps mention a UI framework, OR src/{app,pages,components}.
has_frontend=false
if has '(^|/)src/(app|pages|components)(/|$)'; then
  has_frontend=true
else
  while IFS= read -r pj; do
    [ -n "$pj" ] || continue
    if grep -Eiq '"(react|react-dom|vue|next|svelte|@angular)' "$repo/$pj" 2>/dev/null; then
      has_frontend=true; break
    fi
  done < <(printf '%s\n' "$files" | grep -E '(^|/)package\.json$' || true)
fi

has_tests=false
has '(^|/)(tests?|__tests__)/|\.(spec|test)\.[A-Za-z0-9]+$' && has_tests=true

has_ci=false
has '(^|/)\.github/workflows/|(^|/)bitbucket-pipelines\.yml$|(^|/)\.gitlab-ci\.yml$' && has_ci=true

# IaC: terraform, ansible, or k8s/helm manifests.
has_iac=false
has '\.tf$|(^|/)ansible(\.cfg|/)|(^|/)(playbooks?|roles)/|(^|/)(k8s|kubernetes|manifests)/|(^|/)kustomization\.ya?ml$|(^|/)Chart\.ya?ml$' && has_iac=true

# ---- lockfiles ---------------------------------------------------------------
lockfiles=""
add_lock() { has "(^|/)$1\$" && lockfiles="$lockfiles$2"$'\n' || true; }
add_lock 'package-lock\.json'   'package-lock.json'
add_lock 'yarn\.lock'           'yarn.lock'
add_lock 'pnpm-lock\.yaml'      'pnpm-lock.yaml'
add_lock 'poetry\.lock'         'poetry.lock'
add_lock 'Cargo\.lock'          'Cargo.lock'
add_lock 'go\.sum'              'go.sum'
# requirements*.txt is a glob, not a fixed name.
while IFS= read -r rq; do
  [ -n "$rq" ] || continue
  lockfiles="$lockfiles$(basename "$rq")"$'\n'
done < <(printf '%s\n' "$files" | grep -E '(^|/)requirements[^/]*\.txt$' || true)
lockfiles_json="$(printf '%s' "$lockfiles" | json_array)"

# ---- languages ---------------------------------------------------------------
# Rough language set from file extensions; unknown extensions are ignored.
langs=""
while IFS= read -r ext; do
  case "$ext" in
    .py)                  langs="${langs}py"$'\n' ;;
    .ts|.tsx)             langs="${langs}ts"$'\n' ;;
    .js|.jsx|.mjs|.cjs)   langs="${langs}js"$'\n' ;;
    .go)                  langs="${langs}go"$'\n' ;;
    .rs)                  langs="${langs}rs"$'\n' ;;
    .sh|.bash)            langs="${langs}sh"$'\n' ;;
    .rb)                  langs="${langs}rb"$'\n' ;;
    .java)                langs="${langs}java"$'\n' ;;
    .kt|.kts)             langs="${langs}kt"$'\n' ;;
    .c|.h)                langs="${langs}c"$'\n' ;;
    .cc|.cpp|.cxx|.hpp)   langs="${langs}cpp"$'\n' ;;
    .cs)                  langs="${langs}cs"$'\n' ;;
    .php)                 langs="${langs}php"$'\n' ;;
    .swift)               langs="${langs}swift"$'\n' ;;
    .scala)               langs="${langs}scala"$'\n' ;;
    .ex|.exs)             langs="${langs}ex"$'\n' ;;
  esac
done < <(printf '%s\n' "$files" | grep -oE '\.[A-Za-z0-9]+$' | tr '[:upper:]' '[:lower:]' | sort -u || true)
languages_json="$(printf '%s' "$langs" | json_array)"

# ---- emit --------------------------------------------------------------------
jq -nc \
  --argjson has_docs "$has_docs" \
  --argjson has_compose "$has_compose" \
  --argjson has_dockerfile "$has_dockerfile" \
  --argjson has_frontend "$has_frontend" \
  --argjson has_tests "$has_tests" \
  --argjson has_ci "$has_ci" \
  --argjson has_iac "$has_iac" \
  --argjson lockfiles "$lockfiles_json" \
  --argjson languages "$languages_json" \
  '{has_docs:$has_docs,has_compose:$has_compose,has_dockerfile:$has_dockerfile,
    has_frontend:$has_frontend,has_tests:$has_tests,has_ci:$has_ci,
    lockfiles:$lockfiles,languages:$languages,has_iac:$has_iac}'
