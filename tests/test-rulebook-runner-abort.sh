#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# H1 regression: a malformed rulebook must ABORT the run, not silently truncate the
# fleet. Before the fix, parse_rulebook.py died mid-stream on the bad repo and the
# runner — reading it via process substitution — saw only the repos emitted BEFORE
# the error, servicing a partial fleet with no error surfaced.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "$ROOT/.test-rulebook-runner-abort.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo1"
git -C "$TMP/repo1" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo1/README.md"
git -C "$TMP/repo1" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo1" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo1" push -q -u origin main

# repo1 is valid and FIRST; the bad findings override sits on repo #2. A truncating
# parser would still hand the runner repo1 and let it ship — the bug this guards.
cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 3
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo1
    mode: branch-fix
    test_cmd: true
  - path: /srv/second
    mode: branch-fix
    test_cmd: true
    findings: nope
  - path: /srv/third
    mode: findings-only
EOF

assert_aborts() {
  local rulebook="$1" diagnostic="$2"
  if RULEBOOK="$rulebook" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_OPEN_PR=0 \
     NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
     NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
     "$ROOT/bin/nightshift.sh" >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "runner did not abort for $rulebook" >&2; cat "$TMP/stderr" >&2; exit 1
  fi
  grep -Fq "$diagnostic" "$TMP/stderr" \
    || { echo "missing abort message for $rulebook" >&2; cat "$TMP/stderr" >&2; exit 1; }
  [ "$(git --git-dir="$TMP/remote.git" for-each-ref 'refs/heads/nightshift/*' | wc -l)" -eq 0 ] \
    || { echo "runner shipped despite an invalid rulebook" >&2; exit 1; }
  [ ! -f "$TMP/state/ledger.jsonl" ] || { echo "ledger written despite abort" >&2; exit 1; }
}

assert_aborts "$TMP/rulebook.yaml" "rulebook parse failed"

# Different spellings of the same checkout must not supply competing gate settings.
ln -s "$TMP/repo1" "$TMP/alias"
cat > "$TMP/duplicate.yaml" <<EOF
repos:
  - path: $TMP/repo1
    mode: findings-only
  - path: $TMP/alias
    mode: branch-fix
    test_cmd: true
EOF
assert_aborts "$TMP/duplicate.yaml" "duplicate repo path"

cat > "$TMP/conflicting-gates.yaml" <<EOF
repos:
  - path: $TMP/repo1
    mode: branch-fix
    test_cmd: true
  - path: $TMP/alias
    mode: branch-fix
    test_cmd: false
EOF
assert_aborts "$TMP/conflicting-gates.yaml" "duplicate repo path"

# Simulate the device and inode returned for a bind mount without needing mount privileges.
mkdir "$TMP/mount" "$TMP/bin"
git init -q -b main "$TMP/mount"
sed "s|$TMP/alias|$TMP/mount|" "$TMP/duplicate.yaml" > "$TMP/bind.yaml"
export REAL_STAT="$(command -v stat)" CHECKOUT="$TMP/repo1" MOUNT="$TMP/mount"
cat > "$TMP/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [ "${SEPARATE_DEVICES:-}" = 1 ]; then
  case "${!#}" in
    "$CHECKOUT") echo '1:42'; exit ;;
    "$MOUNT") echo '2:42'; exit ;;
  esac
fi
if [ "${!#}" = "$MOUNT" ]; then
  exec "$REAL_STAT" -Lc '%d:%i' -- "$CHECKOUT"
fi
exec "$REAL_STAT" "$@"
EOF
chmod +x "$TMP/bin/stat"
PATH="$TMP/bin:$PATH" assert_aborts "$TMP/bind.yaml" "identify the same checkout"

cat >> "$TMP/bind.yaml" <<EOF
  - path: $TMP/missing
    mode: findings-only
EOF
PATH="$TMP/bin:$PATH" SEPARATE_DEVICES=1 RULEBOOK="$TMP/bind.yaml" NIGHTSHIFT_SOURCED=1 \
  NIGHTSHIFT_STATE_DIR="$TMP/state" bash -ec 'source "$1"; load_rulebook; [ "${#REPO_PATHS[@]}" = 3 ]' \
  _ "$ROOT/bin/nightshift.sh"
cat >> "$TMP/bind.yaml" <<EOF
  - path: $TMP/missing/
    mode: findings-only
EOF
PATH="$TMP/bin:$PATH" SEPARATE_DEVICES=1 assert_aborts "$TMP/bind.yaml" "duplicate repo path '$TMP/missing/"

# The two gates independently refuse a repo without a command, even after rulebook loading.
NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_STATE_DIR="$TMP/state" \
  NIGHTSHIFT_RUNS_DIR="$TMP/runs" NIGHTSHIFT_DIGEST_DIR="$TMP/digests" \
  NIGHTSHIFT_WORKTREES="$TMP/worktrees" bash -s "$ROOT" "$TMP" <<'EOF'
set -euo pipefail
source "$1/bin/nightshift.sh"
REPO_PATHS=("$2/repo1")
REPO_TEST_CMDS=("")
rc=0
base_precheck "$2/repo1" unused "$2/runs" || rc=$?
[[ $rc = 1 && $BASE_PRECHECK_WHY == *'no test_cmd'* ]]
rc=0
run_test_gate "$2/repo1" "$2/repo1" "$2/runs" || rc=$?
[[ $rc = 2 ]]
EOF

echo "test-rulebook-runner-abort: ok"
