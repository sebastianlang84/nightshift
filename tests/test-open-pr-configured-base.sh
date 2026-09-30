#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# A shipped fix branches from the pinned base commit, but its PR must still target the configured
# base BRANCH: `gh pr create --base <sha>` is refused, so the PR would silently never open.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees" "$TMP/bin"

# open_pr only runs against a GitHub remote; a local path containing github.com satisfies that check.
git init -q --bare "$TMP/github.com/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/github.com/remote.git"
printf '# Demo\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main
git -C "$TMP/repo" switch -qc develop
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -qam develop
git -C "$TMP/repo" push -q -u origin develop
git -C "$TMP/repo" switch -q main

cat > "$TMP/bin/gh" <<GH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/gh-args"
echo https://github.com/example/repo/pull/1
GH
chmod +x "$TMP/bin/gh"

cat > "$TMP/rulebook.yaml" <<YAML
branch_prefix: nightshift/
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: branch-fix
    base: develop
    test_cmd: true
YAML

PATH="$TMP/bin:$PATH" RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 \
NIGHTSHIFT_OPEN_PR=1 NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/stdout" 2>"$TMP/stderr"

[ "$(jq -s '[.[]|select(.outcome=="shipped")]|length' "$TMP/state/ledger.jsonl")" -ge 1 ] \
  || { echo "nothing shipped" >&2; cat "$TMP/stderr" >&2; exit 1; }
[ -f "$TMP/gh-args" ] || { echo "open_pr never called gh" >&2; exit 1; }
[ "$(grep -A1 -x -- --base "$TMP/gh-args" | tail -1)" = develop ] \
  || { echo "the PR must target the configured base branch, not a commit" >&2; cat "$TMP/gh-args" >&2; exit 1; }

echo "test-open-pr-configured-base: ok"
