#!/usr/bin/env bash
set -euo pipefail
# The Runner keeps only absolute PATH entries: it runs git, jq, env and claude after `cd` into a
# worktree a stage can write, where a relative or empty entry would resolve to a planted binary.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
left="$(PATH="bin::.:$PATH" NIGHTSHIFT_SOURCED=1 bash -c 'source "$1"; printf "%s" "$PATH"' _ "$ROOT/bin/nightshift.sh")"
[ -n "$left" ] || { echo "test-runner-path: the PATH filter dropped every entry" >&2; exit 1; }
case ":$left:" in *::*|*:[!/]*) echo "test-runner-path: a relative PATH entry survived: $left" >&2; exit 1 ;; esac
echo "test-runner-path: ok"
