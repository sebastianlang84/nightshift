#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT

# lib/probe_survival.py (ADR 0043): whether a merged fix held WINDOW days after its verdict.
# One repo, one fix per case, commits back-dated so the 30-day cutoff falls between them:
#   held      later unrelated change              -> held
#   reworked  most added lines rewritten in time  -> not held
#   reverted  `git revert` in time                -> reverted, not held
#   removed   the file deleted in time            -> removed, counted neither way
#   late      rewritten only after the cutoff     -> held
#   fresh     verdict younger than the window     -> pending
#   gone      sha unknown to the repo             -> unknown
#   renamed   file moved unchanged in time        -> held (the lines moved with it)
#   unmerged  its merge commit reverted (-m 1)    -> reverted

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "$ROOT/.test-survival.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-fix-survival: $*" >&2; exit 1; }

R="$TMP/repo"
git init -q -b main "$R"
day() { date -u -d "$1 days ago" +%Y-%m-%dT12:00:00Z; }
commit() { # days-ago message
  GIT_AUTHOR_DATE="$(day "$1")" GIT_COMMITTER_DATE="$(day "$1")" \
    git -C "$R" -c user.name=t -c user.email=t@l commit -qam "$2"
}
for f in held reworked reverted removed late fresh other renamed unmerged; do printf 'base of %s\n' "$f" > "$R/$f.txt"; done
git -C "$R" add -A; commit 100 base
for f in held reworked reverted removed late renamed; do printf '%s one\n%s two\n%s three\n%s four\n' $f $f $f $f >> "$R/$f.txt"; commit 90 "fix $f"; done
# A fix that arrives through a merge commit, as the merge job lands them.
git -C "$R" checkout -q -b side
printf 'one\ntwo\nthree\nfour\n' >> "$R/unmerged.txt"; commit 90 "fix unmerged"
git -C "$R" checkout -q main
echo y >> "$R/other.txt"; commit 90 "main moves"
GIT_AUTHOR_DATE="$(day 90)" GIT_COMMITTER_DATE="$(day 90)" \
  git -C "$R" -c user.name=t -c user.email=t@l merge -q --no-ff -m "merge side" side
printf 'one\ntwo\n' >> "$R/fresh.txt"; commit 5 "fix fresh"
sha() { git -C "$R" log --format=%H -1 --grep="^fix $1\$"; }

echo x >> "$R/other.txt"; commit 80 unrelated
sed -i 's/two/TWO/; s/three/THREE/; s/four/FOUR/' "$R/reworked.txt"; commit 80 rework
GIT_AUTHOR_DATE="$(day 80)" GIT_COMMITTER_DATE="$(day 80)" \
  git -C "$R" -c user.name=t -c user.email=t@l revert --no-edit "$(sha reverted)" >/dev/null
git -C "$R" rm -q removed.txt; commit 80 "drop removed"
git -C "$R" mv renamed.txt moved.txt; commit 80 "move renamed"
GIT_AUTHOR_DATE="$(day 80)" GIT_COMMITTER_DATE="$(day 80)" \
  git -C "$R" -c user.name=t -c user.email=t@l revert --no-edit -m 1 "$(git -C "$R" log --format=%H -1 --grep="^merge side$")" >/dev/null 2>&1 \
  || fail "fixture: could not revert the merge"
# Only git's own revert line counts: a message that merely mentions reverting the held fix does not.
GIT_AUTHOR_DATE="$(day 80)" GIT_COMMITTER_DATE="$(day 80)" git -C "$R" -c user.name=t -c user.email=t@l \
  commit -q --allow-empty -m "note" -m "Do not revert commit $(sha held); it is still needed."
sed -i 's/two/TWO/; s/three/THREE/; s/four/FOUR/' "$R/late.txt"; commit 10 "late rewrite"

L="$TMP/ledger.jsonl"
for f in held reworked reverted removed late renamed unmerged; do
  printf '{"outcome":"verdict","verdict":"merged","item":"i-%s","repo":"%s","sha":"%s","ts":"%s"}\n' \
    "$f" "$R" "$(sha "$f")" "$(day 89)" >> "$L"
done
printf '{"outcome":"verdict","verdict":"merged","item":"i-fresh","repo":"%s","sha":"%s","ts":"%s"}\n' \
  "$R" "$(sha fresh)" "$(day 4)" >> "$L"
printf '{"outcome":"verdict","verdict":"merged","item":"i-gone","repo":"%s","sha":"%s","ts":"%s"}\n' \
  "$R" "0123456789012345678901234567890123456789" "$(day 89)" >> "$L"
# A later verdict decides: a merged item that was then dropped is not measured.
printf '{"outcome":"verdict","verdict":"merged","item":"i-undone","repo":"%s","sha":"%s","ts":"%s"}\n' \
  "$R" "$(sha held)" "$(day 89)" >> "$L"
printf '{"outcome":"verdict","verdict":"dropped","item":"i-undone","repo":"%s","sha":"%s","ts":"%s"}\n' \
  "$R" "$(sha held)" "$(day 88)" >> "$L"

S="$TMP/survival.json"
python3 "$ROOT/lib/probe_survival.py" --ledger "$L" --out "$S" --base "$R" main >/dev/null
got() { jq -r --arg i "i-$1" '.items[] | select(.item==$i) | [.state, (.held|tostring), (.reverted|tostring)] | join(" ")' "$S"; }
[ "$(got held)" = "measured true false" ]       || fail "held: $(got held)"
[ "$(got reworked)" = "measured false false" ]  || fail "reworked: $(got reworked)"
[ "$(got reverted)" = "measured false true" ]   || fail "reverted: $(got reverted)"
[ "$(got removed)" = "removed null false" ]     || fail "removed: $(got removed)"
[ "$(got late)" = "measured true false" ]       || fail "late: $(got late)"
[ "$(got fresh)" = "pending null null" ]        || fail "fresh: $(got fresh)"
[ "$(got gone)" = "unknown null null" ]         || fail "gone: $(got gone)"
[ "$(got renamed)" = "measured true false" ]    || fail "renamed: $(got renamed)"
[ "$(got unmerged)" = "measured false true" ]   || fail "unmerged: $(got unmerged)"
[ -z "$(got undone)" ]                          || fail "a dropped item was measured"
jq -e '.repos.repo | .measured==6 and .held==3 and .reverted==2 and .removed==1 and .pending==1 and .unknown==1' "$S" >/dev/null \
  || { jq .repos "$S" >&2; fail "summary counts are wrong"; }

# A matured measurement is cached: rewriting history after it does not change it.
cutoff="$(jq -r '.items[] | select(.item=="i-held") | .cutoff' "$S")"
printf 'x\n' > "$R/held.txt"; commit 1 "wipe held"
python3 "$ROOT/lib/probe_survival.py" --ledger "$L" --out "$S" --base "$R" main >/dev/null
[ "$(got held)" = "measured true false" ] || fail "a matured measurement was recomputed"
[ "$(jq -r '.items[] | select(.item=="i-held") | .cutoff' "$S")" = "$cutoff" ] || fail "the cutoff moved"

# A repo outside the rulebook is unknown, never guessed.
python3 "$ROOT/lib/probe_survival.py" --ledger "$L" --out "$TMP/none.json" >/dev/null
[ "$(jq '[.items[] | select(.state=="measured")] | length' "$TMP/none.json")" -eq 0 ] \
  || fail "a repo without a base was measured"

# Old adoptions all shared one item id, and old snapshots did not record the branch.
# Rewrite the original repo's base so only its matching frozen measurement can still be used.
other="$TMP/other/repo"
git clone -q "$R" "$other"
L="$TMP/adoptions.jsonl"
S_LEGACY="$TMP/adopted-survival.json"
jq '{schema_version, items: [.items[] | select(.item == "i-held")
  | .item = "orphan-adopt" | del(.branch)]}' "$S" > "$S_LEGACY"
adopted_verdict() { # repo branch sha verdict
  jq -nc --arg r "$1" --arg b "$2" --arg sha "$3" --arg v "$4" --arg ts "$(day 89)" \
    '{outcome:"verdict",item:"orphan-adopt",repo:$r,branch:$b,sha:$sha,verdict:$v,ts:$ts}' >> "$L"
}
adopted_verdict "$R" nightshift/held "$(sha held)" merged
adopted_verdict "$R" nightshift/dropped "$(sha held)" dropped
adopted_verdict "$other" nightshift/reworked "$(sha reworked)" merged
git -C "$R" update-ref refs/heads/main "$(git -C "$R" rev-list --max-parents=0 main)"
report="$(python3 "$ROOT/lib/probe_survival.py" --ledger "$L" --out "$S_LEGACY" \
  --base "$R" main --base "$other" main --print)"
jq -e --arg r "$R" --arg other "$other" --arg cutoff "$cutoff" '
  (.items | length == 2)
  and any(.items[]; .repo == $r and .branch == "nightshift/held"
                   and .state == "measured" and .held and .cutoff == $cutoff)
  and (.repos[$r] | .held == 1 and .measured == 1)
  and (.repos[$other] | .held == 0 and .measured == 1)
' "$S_LEGACY" >/dev/null || fail "legacy adoptions lost their own verdicts or frozen measurement"
[[ "$report" == *"$R"$'\theld 1/1'* && "$report" == *"$other"$'\theld 0/1'* ]] \
  || fail "same-named repositories are not distinguishable in the survival report"

echo "test-fix-survival: ok"
