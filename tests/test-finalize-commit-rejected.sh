#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# A target repo's OWN hooks run for the nightshift commit — deliberately, so nightshift never
# manufactures a commit its host repo would reject. A rejected commit must therefore END the item:
# no branch on the remote, no `shipped` row. Before finalize checked the commit's exit status,
# `rev-parse HEAD` returned the BASE sha, the UNCHANGED branch was pushed, and the ledger claimed
# `shipped` — a fix that does not exist, occupying an open-branch slot until a human dropped it.
# (Observed 2026-08-02 on partflow, whose pre-commit hook demands a CHANGELOG entry.)
# Since ADR 0036 a rejection first earns ONE Fix retry with the hook's output; only a retry that
# does not ship ends the item this way. The second half of this file drives that retry.

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

# 7. A rejection earns exactly ONE retry (ADR 0036): the Fix and Review stages ran twice, the log
#    says so, and the second rejection ends it as commit-failed — one row, not two.
grep -q "commit retry: rerunning the fix once" "$TMP/err" \
  || { echo "no retry announced after the first rejection" >&2; cat "$TMP/err" >&2; exit 1; }
grep -q "commit retry: rejected again" "$TMP/err" \
  || { echo "second rejection not reported as the retry's outcome" >&2; cat "$TMP/err" >&2; exit 1; }
nfix="$(jq -s '[.[]|select(.stage=="fix")]|length' "$TMP/state/runs.jsonl")"
nrev="$(jq -s '[.[]|select(.stage=="review")]|length' "$TMP/state/runs.jsonl")"
[ "$nfix" = 2 ] && [ "$nrev" = 2 ] \
  || { echo "expected 2 fix + 2 review runs (one retry), got fix=$nfix review=$nrev" >&2; exit 1; }
[ "$(jq -s '[.[]|select(.outcome=="commit-failed")]|length' "$LEDGER")" = 1 ] \
  || { echo "a retried item must record exactly one commit-failed row" >&2; jq -c . "$LEDGER" >&2; exit 1; }

# --- The retry, driven against a hook that states what it wants -----------------------------------
# The hook accepts the commit only when the tree carries the token it names in its refusal, and the
# heeding mock copies that token out of the Fix prompt. So a ship proves the output
# reached the Fix stage; the other cases prove the revision cannot skip review or the test gate.
retry_night() { # dir test_cmd max_fix_iterations [env…] — one night against a token-demanding hook
  local d="$1" tc="$2" mfi="$3"; shift 3
  mkdir -p "$d/state" "$d/runs" "$d/digests" "$d/worktrees"
  git init -q --bare "$d/remote.git"
  git init -q -b main "$d/repo"
  git -C "$d/repo" remote add origin "$d/remote.git"
  printf '# Demo\n\nThis is teh demo.\n' > "$d/repo/README.md"
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost add -A
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost commit -q -m init
  git -C "$d/repo" push -q -u origin main
  cat > "$d/repo/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
echo run >> "$(git rev-parse --git-common-dir)/hook-runs"
git show :HOOK_OK 2>/dev/null | grep -q 'NEED=abc123' && exit 0
echo "[host-hook] BLOCKED: add a file HOOK_OK holding NEED=abc123" >&2
exit 1
HOOK
  chmod +x "$d/repo/.git/hooks/pre-commit"
  cat > "$d/rulebook.yaml" <<RB
branch_prefix: nightshift/
limits:
  max_open_branches: 5
  max_fix_iterations: $mfi
recon:
  enabled: false
dimensions:
  - docs
repos:
  - path: $d/repo
    mode: branch-fix
    test_cmd: $tc
    base: main
RB
  env RULEBOOK="$d/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
    NIGHTSHIFT_STATE_DIR="$d/state" NIGHTSHIFT_RUNS_DIR="$d/runs" \
    NIGHTSHIFT_DIGEST_DIR="$d/digests" NIGHTSHIFT_WORKTREES="$d/worktrees" "$@" \
    "$ROOT/bin/nightshift.sh" >"$d/out" 2>"$d/err"
}
outcomes() { jq -sc '[.[]|select(.outcome!=null and .outcome!="verdict")|.outcome]' "$1/state/ledger.jsonl"; }
runs_of() { jq -s --arg s "$2" '[.[]|select(.stage==$s)]|length' "$1/state/runs.jsonl"; }
remote_branches() { git -C "$1/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*'; }
TMP3="$(mktemp -d)"
trap 'rm -rf "$TMP" "${TMP2:-}" "$TMP3"' EXIT

# (1) Rejected, then accepted after the retry -> shipped, with the answer in the pushed commit.
d="$TMP3/ok"; retry_night "$d" true 3 NIGHTSHIFT_MOCK_FIX_HEEDS_HOOK=1
[ "$(outcomes "$d")" = '["shipped"]' ] \
  || { echo "(1) retry that satisfies the hook did not ship: $(outcomes "$d")" >&2; cat "$d/err" >&2; exit 1; }
grep -q "commit retry: the revised fix passed the repo's hooks" "$d/err" \
  || { echo "(1) retry success not logged" >&2; exit 1; }
rb="$(remote_branches "$d")"
[ -n "$rb" ] && git -C "$d/remote.git" show "$rb:HOOK_OK" | grep -q 'NEED=abc123' \
  && git -C "$d/remote.git" show "$rb:README.md" | grep -q 'This is the demo' \
  || { echo "(1) pushed branch lacks the hook's answer or the original fix" >&2; exit 1; }
# The hook was satisfied through the files: the pushed commit carries no escape-hatch trailer.
git -C "$d/remote.git" log -1 --format=%B "$rb" | grep -qi '^changelog-none:' \
  && { echo "(1) the runner added a Changelog-None trailer" >&2; exit 1; }
# The revision went through review AND the test gate again before the second commit.
[ "$(runs_of "$d" fix)" = 2 ] && [ "$(runs_of "$d" review)" = 2 ] \
  || { echo "(1) retry did not rerun fix+review: fix=$(runs_of "$d" fix) review=$(runs_of "$d" review)" >&2; exit 1; }
# The second commit went through the hook too: it ran on both attempts, never bypassed.
[ "$(wc -l < "$d/repo/.git/hook-runs")" = 2 ] \
  || { echo "(1) the hook did not run on both commit attempts" >&2; exit 1; }
[ "$(grep -c "test gate passed" "$d/err")" = 2 ] \
  || { echo "(1) the revision skipped the test gate" >&2; cat "$d/err" >&2; exit 1; }

# (2) Rejected twice -> covered above (the unconditional hook); and a retry needs a fix iteration:
#     with the budget at 1 there is none left, so no retry runs and the item is commit-failed.
d="$TMP3/nobudget"; retry_night "$d" true 1 NIGHTSHIFT_MOCK_FIX_HEEDS_HOOK=1
[ "$(outcomes "$d")" = '["commit-failed"]' ] && [ "$(runs_of "$d" fix)" = 1 ] \
  || { echo "(2) retry ran past the fix-iteration budget: $(outcomes "$d") fix=$(runs_of "$d" fix)" >&2; exit 1; }
grep -q "commit retry: not attempted — no fix iteration left" "$d/err" \
  || { echo "(2) skipped retry not explained" >&2; cat "$d/err" >&2; exit 1; }

# (3a) The test gate still judges the revision: a suite the hook's answer breaks refuses it, every
#      remaining iteration, and the item ends as the rejected commit it was — not tests-failed.
d="$TMP3/gate"; retry_night "$d" 'test ! -e HOOK_OK' 3 NIGHTSHIFT_MOCK_FIX_HEEDS_HOOK=1
[ "$(outcomes "$d")" = '["commit-failed"]' ] && [ -z "$(remote_branches "$d")" ] \
  || { echo "(3a) a revision the suite refused shipped or was misfiled: $(outcomes "$d")" >&2; cat "$d/err" >&2; exit 1; }
grep -q "gate overrules ship" "$d/err" \
  || { echo "(3a) the test gate never judged the revision" >&2; cat "$d/err" >&2; exit 1; }
# ONE retry means one Fix run after the rejection: the red suite must not buy another.
[ "$(runs_of "$d" fix)" = 2 ] \
  || { echo "(3a) the retry looped back into Fix: fix=$(runs_of "$d" fix)" >&2; exit 1; }
grep -q "commit retry: the revision did not reach a commit" "$d/err" \
  || { echo "(3a) retry outcome not logged" >&2; exit 1; }

# (3b) The reviewer still judges the revision: it gives up on it -> commit-failed, nothing shipped,
#      and not `abandoned`, which would latch a finding whose first fix the reviewer accepted.
d="$TMP3/review"; retry_night "$d" true 3 NIGHTSHIFT_MOCK_FIX_HEEDS_HOOK=1 NIGHTSHIFT_MOCK_ABANDON_IF=HOOK_OK
[ "$(outcomes "$d")" = '["commit-failed"]' ] && [ -z "$(remote_branches "$d")" ] \
  || { echo "(3b) a revision the reviewer abandoned shipped or was misfiled: $(outcomes "$d")" >&2; cat "$d/err" >&2; exit 1; }
[ "$(runs_of "$d" review)" = 2 ] || { echo "(3b) the revision was not reviewed" >&2; exit 1; }

# (4) A retry that reverts the whole change reaches an empty commit. That is still the rejected fix,
#     not `abandoned` — which would latch a finding whose first fix the reviewer had accepted.
d="$TMP3/revert"; retry_night "$d" true 3 NIGHTSHIFT_MOCK_FIX_HEEDS_HOOK=revert
[ "$(outcomes "$d")" = '["commit-failed"]' ] && [ -z "$(remote_branches "$d")" ] \
  || { echo "(4) a reverting retry was misfiled: $(outcomes "$d")" >&2; cat "$d/err" >&2; exit 1; }
grep -q "commit retry: the revision removed the whole change" "$d/err" \
  || { echo "(4) reverting retry not logged" >&2; cat "$d/err" >&2; exit 1; }

# --- The OTHER exit from the same place: an empty index is not a rejected commit ----------------
# A Fix stage that looked, found no change it could stand behind, and left the tree alone has
# abandoned the item — the verdict the reviewer's own `abandon` already writes. Recording that as
# `commit-failed` would make the stage's honest way out look like a malfunction, and an instruction
# to stop rather than force something is only usable if stopping is not counted against the night.
TMP2="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP2" "$TMP3"' EXIT
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
