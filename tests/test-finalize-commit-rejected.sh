#!/usr/bin/env bash
set -euo pipefail

# A target repo's OWN hooks run for the nightshift commit — deliberately, so nightshift never
# manufactures a commit its host repo would reject. A rejected commit must therefore END the item:
# no branch on the remote, no `shipped` row. Before finalize checked the commit's exit status,
# `rev-parse HEAD` returned the BASE sha, the UNCHANGED branch was pushed, and the ledger claimed
# `shipped` — a fix that does not exist, occupying an open-branch slot until a human dropped it.
# (Observed 2026-08-02 on partflow, whose pre-commit hook demands a CHANGELOG entry.)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

# The host repo's gate. Worktrees share the common .git, so this hook governs the commit finalize
# makes inside the throwaway worktree — exactly as a real repo's CHANGELOG/lint gate would.
cat > "$TMP/repo/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo "[host-hook] BLOCKED: this repo rejects the commit" >&2
exit 1
EOF
chmod +x "$TMP/repo/.git/hooks/pre-commit"

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
recon:
  enabled: false
dimensions:
  - docs
repos:
  - path: $TMP/repo
    mode: branch-fix
    test_cmd: true
    base: main
EOF

LEDGER="$TMP/state/ledger.jsonl"
RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out" 2>"$TMP/err"

# 1. The run survives a rejected commit — one blocked item must not abort the night.
grep -q "commit rejected" "$TMP/err" "$TMP/out" \
  || { echo "finalize did not report the rejected commit" >&2; cat "$TMP/err" >&2; exit 1; }

# 2. Nothing may be recorded as shipped: the fix never made it into a commit.
if [ -f "$LEDGER" ] && jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1; then
  echo "a rejected commit was recorded as shipped" >&2; jq -c . "$LEDGER" >&2; exit 1
fi

# 3. It IS recorded — the night stays auditable — with no branch/sha to imply a pushed artifact.
row="$(jq -sc '[.[]|select(.outcome=="commit-failed")][0] // empty' "$LEDGER" 2>/dev/null || true)"
[ -n "$row" ] || { echo "no commit-failed row in the ledger" >&2; jq -c . "$LEDGER" >&2; exit 1; }
jq -e '.branch==null and .sha==null' <<<"$row" >/dev/null \
  || { echo "commit-failed row names a branch/sha that was never pushed: $row" >&2; exit 1; }

# 4. The remote must carry no nightshift/* branch — an empty branch is the defect itself.
if git -C "$TMP/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*' | grep -q .; then
  echo "an empty nightshift/* branch reached the remote" >&2
  git -C "$TMP/remote.git" for-each-ref 'refs/heads/nightshift/*' >&2; exit 1
fi

# 5. No stale local branch left behind in the target repo.
if git -C "$TMP/repo" branch --list 'nightshift/*' | grep -q .; then
  echo "local nightshift/* branch left behind after the rejected commit" >&2; exit 1
fi

# 6. The digest reports it under the section for work that did not ship.
digest=""; for d in "$TMP/digests"/*.md; do digest="$d"; done
[ -f "$digest" ] || { echo "no digest written" >&2; exit 1; }
grep -qF "commit-failed" "$digest" \
  || { echo "digest hides the rejected commit" >&2; cat "$digest" >&2; exit 1; }

# --- The OTHER exit from the same place: an empty index is not a rejected commit ----------------
# A Fix stage that looked, found no change it could stand behind, and left the tree alone has
# abandoned the item — the verdict the reviewer's own `abandon` already writes. Recording that as
# `commit-failed` would make the stage's honest way out look like a malfunction, and an instruction
# to stop rather than force something is only usable if stopping is not counted against the night.
TMP2="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP2"' EXIT
mkdir -p "$TMP2/state" "$TMP2/runs" "$TMP2/digests" "$TMP2/worktrees"
git init -q --bare "$TMP2/remote.git"
git init -q -b main "$TMP2/repo"
git -C "$TMP2/repo" remote add origin "$TMP2/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP2/repo/README.md"
git -C "$TMP2/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$TMP2/repo" -c user.name=test -c user.email=test@localhost commit -q -m init
git -C "$TMP2/repo" push -q -u origin main
sed "s|$TMP/repo|$TMP2/repo|" "$TMP/rulebook.yaml" > "$TMP2/rulebook.yaml"

LEDGER2="$TMP2/state/ledger.jsonl"
RULEBOOK="$TMP2/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_MOCK_FIX_NOOP=1 \
NIGHTSHIFT_STATE_DIR="$TMP2/state" NIGHTSHIFT_RUNS_DIR="$TMP2/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP2/digests" NIGHTSHIFT_WORKTREES="$TMP2/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP2/out" 2>"$TMP2/err"

jq -e 'select(.outcome=="abandoned")' "$LEDGER2" >/dev/null 2>&1 \
  || { echo "a fix that changed nothing was not recorded as abandoned" >&2; jq -c . "$LEDGER2" >&2; exit 1; }
if jq -e 'select(.outcome=="commit-failed")' "$LEDGER2" >/dev/null 2>&1; then
  echo "a fix that changed nothing was recorded as a rejected commit" >&2; jq -c . "$LEDGER2" >&2; exit 1
fi
if jq -e 'select(.outcome=="shipped")' "$LEDGER2" >/dev/null 2>&1; then
  echo "a fix that changed nothing was recorded as shipped" >&2; jq -c . "$LEDGER2" >&2; exit 1
fi

echo "test-finalize-commit-rejected: ok"
