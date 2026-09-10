#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
mkdir -p "$TMP/item" "$TMP/repo"
git -C "$TMP/repo" init -q
printf 'fixture\n' > "$TMP/repo/file"
git -C "$TMP/repo" add file
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -qm initial
jq -n '{found:false,findings:[],scope:"in_scope_no_findings",coverage:{
 files:["file"],entrypoints:["file to output"],checks:["actual check"],unresolved:[],
 invariants:{config_domain:"checked: fixture",semantic_sets:"checked: fixture",
 artifact_identity:"checked: fixture",failure_translation:"checked: fixture",lifecycle:"checked: fixture"}}}' > "$TMP/item/finding.json"
python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/item/finding.json" general
jq '.scope="out_of_scope"' "$TMP/item/finding.json" > "$TMP/invalid.json"
if python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/invalid.json" general 2> "$TMP/error"; then
  echo 'free search accepted out_of_scope' >&2; exit 1
fi
# Existing focused reviews retain their out_of_scope contract.
python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/invalid.json" ui-ux
for n in 1 2 3 4 5 6; do remember_search "$TMP/repo" "$TMP/repo" "$TMP/item/finding.json"; done
jq -e 'length==5' "$(search_history_path "$TMP/repo")" >/dev/null
old_head="$(git -C "$TMP/repo" rev-parse HEAD)"
printf 'changed\n' >> "$TMP/repo/file"
git -C "$TMP/repo" add file
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -qm changed
remember_search "$TMP/repo" "$TMP/repo" "$TMP/item/finding.json"
jq -e --arg old "$old_head" --arg new "$(git -C "$TMP/repo" rev-parse HEAD)" \
  '.[0].head==$old and .[-1].head==$new' "$(search_history_path "$TMP/repo")" >/dev/null
for n in $(seq 1 22); do
 jq -nc --arg r "$TMP/repo" --arg fp "item-$n" --arg ts "$n" \
   '{repo:$r,fingerprint:$fp,outcome:"verdict",verdict:"wontfix",summary:"old rejected claim",ts:$ts}' >> "$LEDGER"
done
jq -nc --arg r "$TMP/other" '{repo:$r,fingerprint:"foreign",outcome:"abandoned",summary:"FOREIGN-SECRET"}' >> "$LEDGER"
search_history "$TMP/repo" > "$TMP/history"
jq -s -e '.[0].recent_scans|length==5' "$TMP/history" >/dev/null
jq -s -e '.[1].recent_decisions|length==20' "$TMP/history" >/dev/null
! grep -q FOREIGN-SECRET "$TMP/history"
jq -s -e '.[1].recent_decisions[-1].fingerprint=="item-22"' "$TMP/history" >/dev/null
jq -nc --arg r "$TMP/repo" '{repo:$r,fingerprint:"item-22",outcome:"finding",summary:"reopened"}' >> "$LEDGER"
search_history "$TMP/repo" | jq -s -e '.[1].recent_decisions | all(.fingerprint!="item-22")' >/dev/null
printf '%s\n' "$TMP/repo" > "$TMP/item/repo"
NIGHTSHIFT_DIMENSION=general stage_prompt explore "$TMP/repo" "$TMP/item" > "$TMP/prompt"
grep -q '^## Free search$' "$TMP/prompt"
grep -q 'old rejected claim' "$TMP/prompt"
grep -q "$old_head" "$TMP/prompt"
! grep -q 'Rank findings WITHIN' "$TMP/prompt"
# Exercise the real runner path with an isolated remote and the general dimension.
git init -q --bare "$TMP/remote.git"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf 'This is teh fixture.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -qm defect
git -C "$TMP/repo" push -q origin HEAD:main
cat > "$TMP/rulebook.yaml" <<EOF
limits:
  max_open_branches: 1
recon:
  enabled: false
dimensions:
  - general
repos:
  - path: $TMP/repo
    mode: branch-fix
    base: main
    test_cmd: true
EOF
RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 \
  NIGHTSHIFT_TEST_SANDBOX=none bash "$ROOT/bin/nightshift.sh" > "$TMP/run.log" 2>&1
jq -se 'any(.outcome=="shipped" and .dimension=="general")' "$LEDGER" >/dev/null
jq -e '.[-1].files | index("README.md")!=null' "$(search_history_path "$TMP/repo")" >/dev/null
echo 'test-free-search: ok'
