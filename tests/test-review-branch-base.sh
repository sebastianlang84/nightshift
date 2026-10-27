#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# bin/review-branch.sh must find a repo's rulebook `base:` however the path is spelled. The lookup
# compares paths as strings, so a trailing slash, a relative path or a symlink used to miss it: a
# gitflow branch was reviewed against origin/main, with develop's commits in its diff, and the tool
# printed a direct push to main — the one thing a gitflow base exists to forbid. Paths are now
# normalized with repo_id, as in the Runner and harvest.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
g() { git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost "$@"; }

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
g remote add origin "$TMP/remote.git"
printf 'base\n' > "$TMP/repo/README.md"; g add -A; g commit -q -m initial; g push -q -u origin main
g checkout -q -b develop main
printf 'dev\n' > "$TMP/repo/dev.txt"; g add -A; g commit -q -m "develop moves"; g push -q origin develop
g checkout -q -b nightshift/x develop
printf 'x\n' > "$TMP/repo/x.txt"; g add -A; g commit -q -m "fix: x.txt"; g push -q origin nightshift/x
g checkout -q main
ln -s "$TMP/repo" "$TMP/link"

rulebook() { # path-as-written -> rulebook file
  cat > "$TMP/rulebook.yaml" <<YAML
branch_prefix: nightshift/
repos:
  - path: $1
    mode: findings-only
    base: develop
YAML
}
review() { # tag repo-arg [cwd]
  local tag="$1" arg="$2" cwd="${3:-$TMP}"
  set +e
  (cd "$cwd" && RULEBOOK="$TMP/rulebook.yaml" bash "$ROOT/bin/review-branch.sh" "$arg") \
    >"$TMP/out.$tag" 2>"$TMP/err.$tag"
  echo $? > "$TMP/rc.$tag"
  set -e
}
fail() { echo "test-review-branch-base: $1" >&2; cat "$TMP/out.$2" "$TMP/err.$2" >&2; exit 1; }
check() { # tag what
  [ "$(cat "$TMP/rc.$1")" -eq 0 ] || fail "$2: review exited non-zero" "$1"
  grep -q '^base: origin/develop$' "$TMP/out.$1" || fail "$2: configured base was not used" "$1"
  grep -q 'gitflow base (develop)' "$TMP/out.$1" || fail "$2: no PR instruction for the gitflow base" "$1"
  ! grep -q 'push origin main' "$TMP/out.$1" || fail "$2: printed a direct push to main" "$1"
  ! grep -q 'dev.txt' "$TMP/out.$1" || fail "$2: develop's own commit leaked into the branch diff" "$1"
}

rulebook "$TMP/repo"
review exact "$TMP/repo";        check exact "exact path"
review slash "$TMP/repo/";       check slash "trailing slash"
review rel   repo "$TMP";        check rel   "relative path"
review dot   . "$TMP/repo";      check dot   "dot path"
review link  "$TMP/link";        check link  "symlinked path"

# The rulebook's own spelling is normalized too.
rulebook "$TMP/repo/"
review rbslash "$TMP/repo";      check rbslash "rulebook path with trailing slash"

echo "test-review-branch-base: ok"
