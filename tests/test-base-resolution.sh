#!/usr/bin/env bash
set -euo pipefail

# Runner, harvest and branch review must resolve the same configured/default base through one module.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"

git init -q -b main "$REPO"
git -C "$REPO" -c user.name=test -c user.email=test@localhost commit -q --allow-empty -m main
git -C "$REPO" branch develop
git -C "$REPO" remote add origin "$TMP/remote.git"
git init -q --bare "$TMP/remote.git"
git -C "$REPO" push -q -u origin main develop
git -C "$REPO" remote set-head origin main

# shellcheck disable=SC1091
source "$ROOT/lib/base_resolution.sh"
REPO_PATHS=("$REPO")
REPO_BASES=(develop)

[ "$(base_ref "$REPO")" = origin/main ] \
  || { echo "test-base-resolution: origin HEAD was not preferred" >&2; exit 1; }
[ "$(resolve_base "$REPO" develop)" = origin/develop ] \
  || { echo "test-base-resolution: configured remote base was not preferred" >&2; exit 1; }
[ "$(base_for_repo "$REPO")" = origin/develop ] \
  || { echo "test-base-resolution: rulebook lookup disagrees with resolve_base" >&2; exit 1; }

echo "test-base-resolution: ok"
