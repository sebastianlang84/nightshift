#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# bin/review-branch.sh must never turn a failed git query into a verdict. A failed history query
# read as "no commits" printed "ALREADY MERGED — safe to delete" for a branch with unmerged work; a
# failed file query read as CLEAN; a failed listing read as "no open branches"; a failed fetch judged
# stale refs. Each failure yields UNKNOWN, the review of the remaining branches goes on, and the
# exit status is 1. The failures are injected by a git shim.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
g() { git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost "$@"; }

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
g remote add origin "$TMP/remote.git"
printf 'base\n' > "$TMP/repo/README.md"; g add -A; g commit -q -m initial; g push -q -u origin main
for b in alpha beta; do
  g checkout -q -b "nightshift/$b" main
  printf '%s\n' "$b" > "$TMP/repo/$b.txt"; g add -A; g commit -q -m "fix: $b"; g push -q origin "nightshift/$b"
done
g checkout -q main

cat > "$TMP/rulebook.yaml" <<YAML
branch_prefix: nightshift/
repos:
  - path: $TMP/repo
    mode: findings-only
    base: origin/main
YAML

REAL_GIT="$(command -v git)"
mkdir -p "$TMP/shim"
cat > "$TMP/shim/git" <<SHIM
#!/usr/bin/env bash
args=" \$* "
if [ -n "\${FAIL_LOG_REF:-}" ] && [[ "\$args" == *" log --oneline "*"..\$FAIL_LOG_REF "* ]]; then exit 128; fi
if [ -n "\${FAIL_FETCH:-}" ] && [[ "\$args" == *" fetch "* ]]; then exit 128; fi
if [ -n "\${FAIL_NAMES:-}" ] && [[ "\$args" == *" diff --name-only "* ]]; then exit 128; fi
if [ -n "\${FAIL_LISTING:-}" ] && [[ "\$args" == *" branch -r --no-merged "* ]]; then exit 128; fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$TMP/shim/git"

review() { # tag [env...]
  local tag="$1"; shift
  set +e
  env "$@" PATH="$TMP/shim:$PATH" RULEBOOK="$TMP/rulebook.yaml" \
    bash "$ROOT/bin/review-branch.sh" "$TMP/repo" >"$TMP/out.$tag" 2>"$TMP/err.$tag"
  echo $? > "$TMP/rc.$tag"
  set -e
}
section() { # tag branch -> that branch's part of the review output
  awk -v h="=== repo : nightshift/$2 ===" '$0==h{on=1;next} /^=== /{on=0} on' "$TMP/out.$1"
}
fail() { echo "test-review-branch-unknown: $1" >&2; cat "$TMP/out.$2" "$TMP/err.$2" >&2; exit 1; }

# Baseline: both branches reviewed, nothing unknown, exit 0.
review ok
[ "$(cat "$TMP/rc.ok")" -eq 0 ] || fail "clean review exited non-zero" ok
! grep -q UNKNOWN "$TMP/out.ok" || fail "clean review printed UNKNOWN" ok

# The history query for the FIRST branch fails: UNKNOWN for it, no delete instruction, the second
# branch still gets its review, exit 1.
review log FAIL_LOG_REF=origin/nightshift/alpha
section log alpha | grep -q 'VERDICT: UNKNOWN' || fail "failed history query gave no UNKNOWN verdict" log
! section log beta | grep -q UNKNOWN || fail "the unaffected branch was judged UNKNOWN" log
! grep -q 'safe to delete' "$TMP/out.log" || fail "failed history query produced a delete instruction" log
grep -q '=== repo : nightshift/beta ===' "$TMP/out.log" || fail "review stopped before the next branch" log
[ "$(cat "$TMP/rc.log")" -eq 1 ] || fail "UNKNOWN verdict did not reach the exit status" log

# The changed-file query fails: UNKNOWN, never CLEAN, exit 1.
review names FAIL_NAMES=1
section names alpha | grep -q 'VERDICT: UNKNOWN — could not read' || fail "failed file query gave no UNKNOWN verdict" names
! grep -q 'VERDICT: CLEAN' "$TMP/out.names" || fail "failed file query produced a CLEAN verdict" names
[ "$(cat "$TMP/rc.names")" -eq 1 ] || fail "failed file query did not reach the exit status" names

# The branch listing fails: UNKNOWN for the repo, never "no open branches", exit 1.
review list FAIL_LISTING=1
grep -q 'VERDICT: UNKNOWN — could not list' "$TMP/out.list" || fail "failed listing gave no UNKNOWN verdict" list
! grep -q 'no open' "$TMP/out.list" || fail "failed listing read as no open branches" list
[ "$(cat "$TMP/rc.list")" -eq 1 ] || fail "failed listing did not reach the exit status" list

# The fetch fails: the refs may be stale, so no verdict at all — not even for the one branch asked
# about — and exit 1.
review fetch FAIL_FETCH=1
grep -q 'VERDICT: UNKNOWN — fetch from origin failed' "$TMP/out.fetch" || fail "failed fetch gave no UNKNOWN verdict" fetch
! grep -q '=== repo : nightshift/' "$TMP/out.fetch" || fail "failed fetch still reviewed branches from stale refs" fetch
[ "$(cat "$TMP/rc.fetch")" -eq 1 ] || fail "failed fetch did not reach the exit status" fetch

echo "test-review-branch-unknown: ok"
