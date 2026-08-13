#!/usr/bin/env bash
set -euo pipefail

# The runner's commit subject is a CLAIM a host repo's `commit-msg` gate checks. git-workflow's
# changelog-check.sh demands a CHANGELOG entry for `feat|fix|perf`, exempts the internal types, and
# treats an UNPARSEABLE subject as user-visible so a malformed message is never a bypass. The old
# fixed `nightshift: ` subject was exactly that unparseable case, so every change touching a
# code-classified file was blocked for a CHANGELOG entry — and the Fix stage could not satisfy the
# gate by writing a better subject, because it does not write the subject at all.
# (Observed 2026-08-07: pi-ext-auth lost two comment-only `doc` findings, and two `bug` fixes on
# 08-05; its `pre-commit` is a SKILL.md lint and its `commit-msg` carries the CHANGELOG gate.)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh" 2>/dev/null

# --- 1. the type mapping, every arm ---------------------------------------------------
# Each finding type maps to the Conventional Commits type that is TRUE of it: `bug`/`typo` are
# defects and claim user visibility; the rest are internal and must not.
check() { # finding_type expected_subject
  local got; got="$(commit_subject "$1" "s")"
  [ "$got" = "$2" ] || { echo "commit_subject $1: expected '$2', got '$got'" >&2; exit 1; }
}
check bug        'fix(nightshift): s'
check typo       'fix(nightshift): s'
check doc        'docs(nightshift): s'
check convention 'chore(nightshift): s'
check cleanup    'refactor(nightshift): s'
check smell      'refactor(nightshift): s'
check naming     'refactor(nightshift): s'
check complexity 'refactor(nightshift): s'

# An unknown type must NOT be given a type. Guessing one would let nightshift under-claim its way
# past a gate; the old unparseable subject is the fail-closed answer, and every such gate reads it
# as user-visible.
check change     'nightshift: s'
check ''         'nightshift: s'
check divergence 'nightshift: s'

# --- 2. the Fix stage is told the subject VERBATIM ------------------------------------
# Left to guess it, the model reasons about a subject it will never get: pi-ext-auth's `doc` fix
# concluded "a `docs:`-typed subject passes cleanly" and was then committed as `nightshift: `.
mk() { git init -q --template= -b main "$1"; }   # this host installs hooks via init.templateDir
mkdir -p "$TMP/item"
jq -nc '{fingerprint:"f",summary:"the summary",type:"doc"}' > "$TMP/item/finding.json"

mk "$TMP/gated"
printf '# Changelog\n' > "$TMP/gated/CHANGELOG.md"
p="$(stage_prompt fix "$TMP/gated" "$TMP/item")"
grep -qF 'docs(nightshift): the summary' <<<"$p" \
  || { echo "fix prompt does not name the runner's commit subject" >&2; exit 1; }
grep -q 'do NOT write the commit' <<<"$p" \
  || { echo "fix prompt does not say the subject is out of the model's hands" >&2; exit 1; }

# --- 3. a `commit-msg` hook is detected, not only `pre-commit` ------------------------
# A repo that moved its CHANGELOG check to `commit-msg` — the only hook that can see the commit
# type — was reported as ungated, and the gate that rejected the commit was never named.
mk "$TMP/msgonly"
mkdir -p "$TMP/msgonly/.git/hooks"     # `--template=` leaves the hooks dir out entirely
printf '#!/bin/sh\nexit 1\n' > "$TMP/msgonly/.git/hooks/commit-msg"
chmod +x "$TMP/msgonly/.git/hooks/commit-msg"
p="$(stage_prompt fix "$TMP/msgonly" "$TMP/item")"
grep -q 'commit-msg` hook is installed' <<<"$p" \
  || { echo "commit-msg hook not named to the Fix stage" >&2; exit 1; }
grep -q 'pre-commit` hook is installed' <<<"$p" \
  && { echo "claimed a pre-commit hook that does not exist" >&2; exit 1; }

# --- 4. end to end: a type-reading gate now accepts the runner's commit ---------------
git init -q --bare "$TMP/remote.git"
git init -q --template= -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

# The shape every Conventional-Commits gate shares: an untyped subject is refused. Worktrees share
# the common .git, so this governs the commit finalize makes inside the throwaway worktree.
mkdir -p "$TMP/repo/.git/hooks"
cat > "$TMP/repo/.git/hooks/commit-msg" <<'EOF'
#!/usr/bin/env bash
subject="$(grep -v '^#' -- "$1" | sed '/^[[:space:]]*$/d' | head -1)"
if [[ ! "$subject" =~ ^(feat|fix|perf|refactor|test|chore|docs|ci|build|style|revert)(\([^\)]*\))?!?: ]]; then
  echo "[host-hook] BLOCKED: subject carries no Conventional Commits type: $subject" >&2
  exit 1
fi
EOF
chmod +x "$TMP/repo/.git/hooks/commit-msg"

mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"
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

RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out" 2>"$TMP/err"

LEDGER="$TMP/state/ledger.jsonl"
if jq -e 'select(.outcome=="commit-failed")' "$LEDGER" >/dev/null 2>&1; then
  echo "the type-reading gate still rejects the runner's commit" >&2
  grep -h 'BLOCKED\|commit rejected' "$TMP/out" "$TMP/err" >&2 || true
  exit 1
fi
jq -e 'select(.outcome=="shipped")' "$LEDGER" >/dev/null 2>&1 \
  || { echo "nothing shipped — the night did not reach a commit" >&2; jq -c . "$LEDGER" >&2; exit 1; }

# The typo fix is a defect fix, so the subject must CLAIM user visibility rather than hide behind an
# internal type — the gate's judgement has to stay correct, not merely permissive.
branch="$(git -C "$TMP/remote.git" for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*' | head -1)"
[ -n "$branch" ] || { echo "no nightshift/* branch on the remote" >&2; exit 1; }
subject="$(git -C "$TMP/remote.git" log -1 --format='%s' "$branch")"
case "$subject" in
  'fix(nightshift): '*) ;;
  *) echo "unexpected commit subject: $subject" >&2; exit 1 ;;
esac

echo "test-commit-subject-type: ok"
