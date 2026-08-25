#!/usr/bin/env bash
set -euo pipefail

# Layer 1 operates on resolved refs and object ids. Owning `nightshift/*` permits creating and
# advancing those branches, never rewriting their published history.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
HOOK="$ROOT/hooks/pre-push"
ZERO=0000000000000000000000000000000000000000

fail() { echo "test-pre-push-confinement: $*" >&2; exit 1; }
git init -q -b main "$REPO"
echo one > "$REPO/file"
git -C "$REPO" -c user.name=t -c user.email=t@localhost add file
git -C "$REPO" -c user.name=t -c user.email=t@localhost commit -q -m one
old="$(git -C "$REPO" rev-parse HEAD)"
echo two >> "$REPO/file"
git -C "$REPO" -c user.name=t -c user.email=t@localhost commit -qam two
new="$(git -C "$REPO" rev-parse HEAD)"

feed() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" | (cd "$REPO" && env -u NIGHTSHIFT_BRANCH_PREFIX bash "$HOOK"); }

feed refs/heads/nightshift/x "$new" refs/heads/nightshift/x "$ZERO" \
  || fail "a new owned branch was rejected"
feed refs/heads/nightshift/x "$new" refs/heads/nightshift/x "$old" \
  || fail "a fast-forward update was rejected"
if feed refs/heads/nightshift/x "$old" refs/heads/nightshift/x "$new" 2>"$TMP/err"; then
  fail "a non-fast-forward update was accepted"
fi
grep -q 'non-fast-forward update not allowed' "$TMP/err" \
  || fail "the force-update refusal did not name the reason"
if feed refs/heads/main "$new" refs/heads/main "$old" >/dev/null 2>&1; then
  fail "a main update was accepted"
fi
if feed '(delete)' "$ZERO" refs/heads/nightshift/x "$new" >/dev/null 2>&1; then
  fail "a branch delete was accepted"
fi

echo "test-pre-push-confinement: ok"
