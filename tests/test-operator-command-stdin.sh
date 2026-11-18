#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'recon:\n  enabled: false\nrepos:\n' > "$TMP/rulebook.yaml"
for repo in one two; do
  git init -q --bare "$TMP/$repo.git"
  git init -q -b main "$TMP/$repo"
  git -C "$TMP/$repo" -c user.name=test -c user.email=test@localhost commit -qm initial --allow-empty
  git -C "$TMP/$repo" remote add origin "$TMP/$repo.git"
  git -C "$TMP/$repo" push -qu origin main
  cat >> "$TMP/rulebook.yaml" <<EOF
  - path: $TMP/$repo
    mode: branch-fix
    base: main
    test_cmd: 'false'
EOF
done

export RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_BLOCKED_BASE_CMD=cat
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
export NIGHTSHIFT_TEST_SANDBOX=none
"$ROOT/bin/nightshift.sh" > "$TMP/log" 2>&1
printf '%s\n' "$TMP/one" "$TMP/two" > "$TMP/expected"
cut -f1 "$TMP/state/blocked-bases.tsv" | sort > "$TMP/actual"
diff -u "$TMP/expected" "$TMP/actual"

echo 'test-operator-command-stdin: ok'
