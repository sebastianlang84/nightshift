#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# Independent branch review (ADR 0038): every advisor adapter gives a merge/fix/reject
# recommendation on each open nightshift/* branch, combined into one digest table. Off unless
# advisors are named (rulebook agent.advisors, NIGHTSHIFT_ADVISORS, or the legacy
# NIGHTSHIFT_BRANCH_REVIEW=1). Answers are cached per branch tip/base/adapter/model. Never pushes.

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
EOF

run() { # tag  [extra env assignments...]
  local tag="$1"; shift
  env "$@" \
  RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out.$tag" 2>"$TMP/err.$tag"
}
branch_count() { git --git-dir="$TMP/remote.git" for-each-ref 'refs/heads/nightshift/*' | wc -l; }

# Run 1: ships a typo branch. Branch review OFF by default → no review section.
run 1
[ "$(branch_count)" -eq 1 ] || { echo "expected 1 shipped branch after run 1" >&2; exit 1; }
digest="$(ls -t "$TMP/digests"/*.md | head -1)"
! grep -q "Independent branch review" "$digest" || { echo "branch review ran while disabled" >&2; exit 1; }

advise_rows() { jq -s '[.[]|select(.stage=="advise")]|length' "$TMP/state/runs.jsonl"; }
fail() { echo "$1" >&2; [ -z "${2:-}" ] || cat "$2" >&2; exit 1; }

# Run 2: the legacy single-advisor opt-in still works. It advises the open branch, into the digest.
run 2 NIGHTSHIFT_BRANCH_REVIEW=1 NIGHTSHIFT_ADVISOR_AGENT=mock
after="$(branch_count)"
[ "$after" -eq 1 ] || fail "branch review created/pushed a branch (count $after)"
digest="$(ls -t "$TMP/digests"/*.md | head -1)"
grep -q "Independent branch review (advisors: mock)" "$digest" || fail "digest missing branch-review section" "$digest"
grep -q '^| Repo | Branch | What | Benefit | mock | Recommendation | Required fix |$' "$digest" \
  || fail "single-advisor table header wrong" "$digest"
# A typo fix → mock advisor recommends merge.
grep -qE '^\| repo \| nightshift/.* \| Fixes a README typo\. \|.*\*\*merge\*\* \| *\|$' "$digest" \
  || fail "advisor recommendation missing/wrong" "$digest"
# No advise worktrees left behind.
[ -z "$(find "$TMP/worktrees" -mindepth 1 -maxdepth 1 2>/dev/null)" ] || fail "advise worktree left behind"
[ "$(advise_rows)" -eq 1 ] || fail "expected 1 advise stage after run 2, got $(advise_rows)"

# Run 3: two advisors. Slot 1 asks the same question as run 2 (same tip, base, adapter, model) and
# must come from the cache; only slot 2 calls a stage.
run 3 NIGHTSHIFT_ADVISORS=mock,mock
digest="$(ls -t "$TMP/digests"/*.md | head -1)"
grep -q '^| Repo | Branch | What | Benefit | mock | mock | Recommendation | Required fix |$' "$digest" \
  || fail "two-advisor table header wrong" "$digest"
grep -qE '\*\*merge\*\* — .* \| \*\*merge\*\* — .* \| \*\*merge\*\* \|' "$digest" || fail "merge+merge did not combine to merge" "$digest"
[ "$(advise_rows)" -eq 2 ] || fail "expected 2 advise stages after run 3 (one cache hit), got $(advise_rows)"

# Run 4: nothing changed → every answer is cached, no stage runs.
run 4 NIGHTSHIFT_ADVISORS=mock,mock
[ "$(advise_rows)" -eq 2 ] || fail "unchanged branch was re-reviewed (advise stages: $(advise_rows))"

# The combination rule, called directly with an empty cache per case.
combo() { # NIGHTSHIFT_MOCK_ADVICE -> the section advise_branches emits
  rm -rf "$TMP/state/advice"
  ( export NIGHTSHIFT_SOURCED=1 RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_ADVISORS=mock,mock \
      NIGHTSHIFT_MOCK_ADVICE="$1" NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
      NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
    source "$ROOT/bin/nightshift.sh"; load_rulebook; advise_branches ) 2>"$TMP/err.combo"
}
combo merge,reject | grep -qE '\*\*reject\*\* \| *\|$' || fail "merge+reject did not combine to reject"
out="$(combo merge,fix)"
printf '%s' "$out" | grep -qE '\*\*fix\*\* \| mock: mock: name the missing evidence\. \|$' || fail "merge+fix: combined/required fix wrong: $out"
out="$(combo merge,none)"
printf '%s' "$out" | grep -qF '| **?** | **fix (1 advisor missing)** |' || fail "a missing advisor not marked: $out"
[ "$(find "$TMP/state/advice" -name '*.json' | wc -l)" -eq 1 ] || fail "a missing answer was cached"
combo none,none | grep -qF '| **?** | **?** | **?** |' || fail "all advisors missing did not combine to ?"
# An incomplete answer (a bare verdict, no what/benefit/reason/required_fix) is "?" and not cached.
out="$(combo merge,bare)"
printf '%s' "$out" | grep -qF '| **?** | **fix (1 advisor missing)** |' || fail "an incomplete answer was taken as a verdict: $out"
[ "$(find "$TMP/state/advice" -name '*.json' | wc -l)" -eq 1 ] || fail "an incomplete answer was cached"
# A literal backslash-pipe in a reason survives as text and does not split the cell.
combo pipe,merge | grep -qF '**merge** — a\\\|b |' || fail "a reason holding \\| broke the table"

# Dead advisors are tracked per adapter (ADR 0038 §1), even when a DIFFERENT adapter already died in
# the night loop and so filled run_agent's night-wide AGENT_FATAL slot.
dead_combo() { # NIGHTSHIFT_MOCK_ADVICE -> the section, with the night's claude already dead
  rm -rf "$TMP/state/advice"
  ( export NIGHTSHIFT_SOURCED=1 RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_ADVISORS=mock,mock \
      NIGHTSHIFT_MOCK_ADVICE="$1" NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
      NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
    source "$ROOT/bin/nightshift.sh"; load_rulebook
    AGENT_FATAL="claude has no usable credentials (stage explore)"; AGENT_FATAL_AGENT=claude
    advise_branches ) 2>"$TMP/err.combo"
}
# A second adapter that cannot authenticate is recorded and not called again.
before=$(advise_rows)
out="$(dead_combo noauth,merge)"
grep -q 'branch review: mock skipped on nightshift/' "$TMP/err.combo" || fail "a second dead advisor was not skipped" "$TMP/err.combo"
[ "$(advise_rows)" -eq $((before + 1)) ] || fail "a second dead advisor was called again ($((before + 1)) advise stages expected, got $(advise_rows))"
printf '%s' "$out" | grep -qF '| **?** | **?** | **?** |' || fail "a dead advisor's slots were not marked missing: $out"
# An empty answer is still retried (ADR 0034): one stage for slot 1, two for slot 2.
before=$(advise_rows)
out="$(dead_combo merge,empty)"
[ "$(advise_rows)" -eq $((before + 3)) ] || fail "an empty advisor answer was not retried after another adapter died (got $(( $(advise_rows) - before )) stages)"
printf '%s' "$out" | grep -qF '| **?** | **fix (1 advisor missing)** |' || fail "an empty advisor answer was not marked missing: $out"

# Cell text cannot break the table.
( export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
  source "$ROOT/bin/nightshift.sh"
  [ "$(md_cell $'a|b\nc')" = 'a\|b c' ] || exit 1
  [ "$(md_cell 'a\|b')" = 'a\\\|b' ] || exit 1
  [ "$(md_cell 'a`b')" = 'a\`b' ] || exit 1
  # Answers lacking a field the table or the fix column needs are not verdicts.
  printf '{"recommendation":"merge"}' > "$TMP/a.json"; ! valid_advice "$TMP/a.json" || exit 1
  printf '{"recommendation":"fix","what":"w","benefit":"b","reason":"r"}' > "$TMP/a.json"; ! valid_advice "$TMP/a.json" || exit 1
  printf '{"recommendation":"merge","what":"w","benefit":" ","reason":"r"}' > "$TMP/a.json"; ! valid_advice "$TMP/a.json" || exit 1
  printf '{"recommendation":"fix","what":"w","benefit":"b","reason":"r","required_fix":"x"}' > "$TMP/a.json"; valid_advice "$TMP/a.json"
) || fail "md_cell escaping or valid_advice completeness wrong"

# The env list is normalised once, and that reading is what both validation and execution use.
( export NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
  source "$ROOT/bin/nightshift.sh"
  NIGHTSHIFT_ADVISORS=' claude , codex'; resolve_advisors && [ "${ADVISORS[*]}" = "claude codex" ] || exit 1
  NIGHTSHIFT_ADVISORS='mock,mock'; resolve_advisors && [ "${#ADVISORS[@]}" -eq 2 ] || exit 1
  for bad in 'claude,claude' 'claude,,codex' 'claude,' ' , ' $'claude,\ncodex'; do
    NIGHTSHIFT_ADVISORS="$bad"; ! resolve_advisors 2>/dev/null || { echo "accepted '$bad'" >&2; exit 1; }
  done ) || fail "resolve_advisors normalisation wrong"

# The rulebook key alone turns the review on, and is validated like review_agent.
sed 's/^recon:/agent:\n  advisors: mock\nrecon:/' "$TMP/rulebook.yaml" > "$TMP/rulebook-adv.yaml"
python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rulebook-adv.yaml" | grep -qx "$(printf 'advisors\tmock')" || fail "advisors not emitted"
rm -rf "$TMP/state/advice"
( export NIGHTSHIFT_SOURCED=1 RULEBOOK="$TMP/rulebook-adv.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_STATE_DIR="$TMP/state" \
    NIGHTSHIFT_RUNS_DIR="$TMP/runs" NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
  unset NIGHTSHIFT_ADVISORS NIGHTSHIFT_BRANCH_REVIEW
  source "$ROOT/bin/nightshift.sh"; load_rulebook; advise_branches ) 2>/dev/null \
  | grep -q 'Independent branch review (advisors: mock)' || fail "rulebook agent.advisors did not enable the review"
reject_adv() { # value expected-error
  printf 'agent:\n  advisors: %s\nrepos:\n  - path: /srv/x\n    mode: findings-only\n' "$1" > "$TMP/bad.yaml"
  if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/bad.yaml" >/dev/null 2>"$TMP/bad.err"; then fail "parser accepted advisors: $1"; fi
  grep -qF "$2" "$TMP/bad.err" || fail "advisors: $1 refused with the wrong message" "$TMP/bad.err"
}
reject_adv claude,gemini "agent.advisors: unknown adapter 'gemini'"
reject_adv claude,claude "agent.advisors: an adapter is listed twice"
printf 'agent:\n  advisors: claude, codex\nrepos:\n  - path: /srv/x\n    mode: findings-only\n' > "$TMP/ok.yaml"
python3 "$ROOT/lib/parse_rulebook.py" "$TMP/ok.yaml" | grep -qx "$(printf 'advisors\tclaude,codex')" || fail "advisors: claude, codex not normalised"
# An env typo is refused before the night spends anything.
run 5 NIGHTSHIFT_ADVISORS=mock,gemini && fail "NIGHTSHIFT_ADVISORS=mock,gemini was accepted"
grep -q "invalid branch advisor 'gemini'" "$TMP/err.5" || fail "env advisor typo not reported" "$TMP/err.5"

run 6 NIGHTSHIFT_ADVISORS='codex, codex' && fail "a duplicate env advisor was accepted"
grep -q "'codex' is listed twice" "$TMP/err.6" || fail "duplicate env advisor not reported" "$TMP/err.6"

# A branch name holding `|` is escaped like any other cell text.
git -C "$TMP/repo" checkout -q -b 'nightshift/a|b'
echo extra > "$TMP/repo/extra.txt"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m extra
git -C "$TMP/repo" push -q origin 'nightshift/a|b'
git -C "$TMP/repo" checkout -q main
combo merge,merge | grep -qF '| nightshift/a\|b |' || fail "a branch name holding | broke the table"

# A branch the ledger has settled is not open (ADR 0025), even though its ref survives unmerged:
# no advisor is asked about it and it has no row, while the still-open branch keeps its own.
typo=$(git --git-dir="$TMP/remote.git" for-each-ref --format='%(refname:lstrip=2)' 'refs/heads/nightshift/*' | grep -vF 'a|b')
[ -n "$typo" ] || fail "typo branch not found on the remote"
jq -nc --arg r "$TMP/repo" --arg b "$typo" '{repo:$r,branch:$b,outcome:"verdict",verdict:"dropped",ts:"2026-10-23T00:00:00+00:00"}' \
  >> "$TMP/state/ledger.jsonl"
before=$(advise_rows)
out="$(combo merge,merge)"
printf '%s' "$out" | grep -qF "| $typo |" && fail "a dropped branch was still advised on: $out"
printf '%s' "$out" | grep -qF '| nightshift/a\|b |' || fail "the open branch lost its row beside a settled one: $out"
[ "$(advise_rows)" -eq $((before + 2)) ] || fail "a settled branch was billed an advise stage (got $(( $(advise_rows) - before )) stages, expected 2)"

echo "test-branch-review: ok"
