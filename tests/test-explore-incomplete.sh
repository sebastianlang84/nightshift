#!/usr/bin/env bash
set -euo pipefail

# An Explore that could not run to COMPLETION is not evidence about the repo, and must not leave the
# three artifacts that say otherwise: the `empty` ledger row (which ADR 0023 lets the fleet trust as
# "this lens was clean here tonight"), the dim-scan marker that rotates the lens onward, and the
# `considered` count.
#
# Regression for the night of 2026-08-12: five of 26 items ended in the claude CLI's
# `error_max_turns` — "Reached maximum number of turns (25)" — after ~$2 of tokens each. Every one was
# logged as "nothing worth doing (scope=in_scope_no_findings)", stamped as serviced, and written into
# the ledger, so the digest's coverage matrix reported those lenses as freshly reviewed. Unlike a
# credential failure (test-agent-auth-abort.sh) the night must NOT abort — the agent is alive and the
# next repo may well finish.
#
# Findings that did land are kept: a stage can hit the ceiling after writing a usable verdict.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-explore-incomplete: $*" >&2; exit 1; }

# $1 = case dir, $2 = README body (`teh` is what the mock Explore finds and the mock Fix repairs)
make_fleet() {
  local d="$1" body="$2" r
  mkdir -p "$d/state" "$d/runs" "$d/digests" "$d/worktrees" "$d/bin"
  for r in repo-a repo-b; do
    git init -q --bare "$d/$r.git"
    git init -q -b main "$d/$r"
    git -C "$d/$r" remote add origin "$d/$r.git"
    printf '# Demo\n\n%s\n' "$body" > "$d/$r/README.md"
    git -C "$d/$r" -c user.name=test -c user.email=test@localhost add -A
    git -C "$d/$r" -c user.name=test -c user.email=test@localhost commit -q -m initial
    git -C "$d/$r" push -q -u origin main
  done
  cat > "$d/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 3
  max_findings_per_item: 1
  max_fix_iterations: 1
recon:
  enabled: false
dimensions:
  - docs
repos:
  - path: $d/repo-a
    mode: branch-fix
    base: main
  - path: $d/repo-b
    mode: branch-fix
    base: main
EOF
}

run_night() { # case_dir agent [extra env…]
  local d="$1" agent="$2"; shift 2
  set +e
  env "$@" PATH="$d/bin:$PATH" \
    RULEBOOK="$d/rulebook.yaml" NIGHTSHIFT_AGENT="$agent" NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
    NIGHTSHIFT_STATE_DIR="$d/state" NIGHTSHIFT_RUNS_DIR="$d/runs" \
    NIGHTSHIFT_DIGEST_DIR="$d/digests" NIGHTSHIFT_WORKTREES="$d/worktrees" \
    "$ROOT/bin/nightshift.sh" >"$d/out" 2>"$d/err"
  echo $? > "$d/rc"
  set -e
}

assert_nothing_recorded() { # case_dir
  local d="$1" n
  if [ -f "$d/state/ledger.jsonl" ]; then
    n=$(jq -s '[.[]|select(.outcome=="empty")]|length' "$d/state/ledger.jsonl")
    [ "$n" -eq 0 ] || { jq -c 'select(.outcome=="empty")' "$d/state/ledger.jsonl" >&2
      fail "$n forged 'empty' ledger row(s) — the fleet now believes this lens was clean"; }
  fi
  [ -z "$(find "$d/state/dim-scans" -type f 2>/dev/null)" ] \
    || fail "the lens rotation advanced on a pass that never completed"
  [ -z "$(find "$d/worktrees" -mindepth 1 -maxdepth 1 2>/dev/null)" ] \
    || fail "worktree left behind on the incomplete-explore path"
}

# --- 1. the real shape: the claude CLI's turn ceiling --------------------------------------------
d="$TMP/max-turns"; make_fleet "$d" "This is teh demo."
# The CLI reports the ceiling as a result object on STDOUT with is_error/subtype and exits non-zero.
# Deliberately carries no credential signature, so AGENT_FATAL must not fire and the night must not
# abort — this stub answers every stage the same way.
cat > "$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"is_error":true,"subtype":"error_max_turns","num_turns":26,"total_cost_usd":2.26,
 "errors":["Reached maximum number of turns (25)"],"type":"result"}
JSON
exit 1
EOF
chmod +x "$d/bin/claude"

run_night "$d" claude
[ "$(cat "$d/rc")" = 0 ] \
  || { cat "$d/err" >&2; fail "the night exited $(cat "$d/rc") — a turn ceiling is not a dead agent"; }
grep -q 'stage explore FAILED (exit 1)' "$d/err" \
  || { cat "$d/err" >&2; fail "the failing stage was not reported"; }
grep -q 'explore did not complete (exit 1)' "$d/err" \
  || { cat "$d/err" >&2; fail "the incomplete pass was not named as such in the night log"; }
grep -q 'nothing worth doing' "$d/err" \
  && { cat "$d/err" >&2; fail "an incomplete explore was still reported as 'nothing worth doing'"; }
assert_nothing_recorded "$d"
# Both repos are still attempted: the agent is alive, unlike the credential case.
[ "$(grep -c 'explore did not complete' "$d/err")" -eq 2 ] \
  || { cat "$d/err" >&2; fail "the fleet did not carry on to the second repo"; }
# The digest is the one artifact read in the morning, so the loss must be visible there too.
digest="$(find "$d/digests" -name '*.md' | head -1)"
[ -n "$digest" ] || fail "no digest written"
grep -q 'did not complete' "$digest" \
  || { cat "$digest" >&2; fail "the digest does not report the stages that never finished"; }

# --- 2. same failure, but the stage had already written findings ---------------------------------
# Those must be used, not thrown away — dropping them would be a second, self-inflicted loss.
d="$TMP/partial"; make_fleet "$d" "This is teh demo."
run_night "$d" mock NIGHTSHIFT_MOCK_EXPLORE_RC=1
[ "$(cat "$d/rc")" = 0 ] || { cat "$d/err" >&2; fail "the night exited $(cat "$d/rc") on the partial path"; }
grep -q 'left 1 finding(s) — continuing with those' "$d/err" \
  || { cat "$d/err" >&2; fail "findings from a failed explore were discarded"; }
jq -e 'select(.outcome=="shipped")' "$d/state/ledger.jsonl" >/dev/null 2>&1 \
  || { cat "$d/err" >&2; fail "the surviving finding never reached a branch"; }

# --- 3. an explore that completes and finds nothing still records its clean verdict --------------
# The guard must not swallow the honest empty pass ADR 0015/0023 depend on.
d="$TMP/clean"; make_fleet "$d" "This demo is clean."
run_night "$d" mock
[ "$(cat "$d/rc")" = 0 ] || { cat "$d/err" >&2; fail "the night exited $(cat "$d/rc") on the clean path"; }
grep -q 'nothing worth doing' "$d/err" \
  || { cat "$d/err" >&2; fail "a completed empty pass no longer reports itself"; }
n=$(jq -s '[.[]|select(.outcome=="empty")]|length' "$d/state/ledger.jsonl")
[ "$n" -eq 2 ] || fail "expected 2 'empty' rows from two clean repos, got $n"
[ -n "$(find "$d/state/dim-scans" -type f 2>/dev/null)" ] \
  || fail "a completed pass did not advance the lens rotation"

echo "test-explore-incomplete: ok"
