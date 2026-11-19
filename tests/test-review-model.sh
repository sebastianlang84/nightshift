#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# ADR 0044: the Review stage and the branch advice run on `agent.review_model`; every other stage
# keeps `agent.claude_model`. Asserted end to end through the real claude adapter, with only the CLI
# binary faked — the fake records which `--model` each stage was started with — and then the
# precedence (NIGHTSHIFT_REVIEW_MODEL > rulebook > the claude model) on the adapter directly.
# Every review gets the adversarial "same model family" brief, since the reviewer is always the
# author's vendor now.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-review-model: $*" >&2; exit 1; }

command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / true 2>/dev/null \
  || export NIGHTSHIFT_TEST_SANDBOX=none

mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
model="<none>" prev=""
for a in "$@"; do [ "$prev" = --model ] && model="$a"; prev="$a"; done
prompt=$(cat)
emit() { jq -nc --arg r "$1" '{type:"result",subtype:"success",is_error:false,result:$r,usage:{output_tokens:1}}'; }
case "$prompt" in
  *"EXPLORE stage"*)
    echo "explore $model" >> "$MODEL_LOG"
    files="$(git ls-files | jq -R . | jq -sc .)"
    checks="$(git ls-files | sed 's/^/checked /' | jq -R . | jq -sc .)"
    emit "$(jq -nc --argjson f "$files" --argjson c "$checks" '{found:true,coverage:{files:$f,entrypoints:["README -> rendered documentation"],checks:$c,invariants:{config_domain:"not-applicable: no config",semantic_sets:"not-applicable: no sets",artifact_identity:"checked: one README artifact",failure_translation:"checked: explicit result JSON",lifecycle:"not-applicable: no lifecycle"},unresolved:[]},findings:[{file:"README.md",type:"typo",line_window:"L1-L3",claim:"README contains teh",verify:"search README for teh",verifiability:"static",disposition:"fix",summary:"fix typo",fingerprint:"README.md:typo:L1-L3",rank:1,confidence:1.0}]}')" ;;
  *"FIX stage"*)
    echo "fix $model" >> "$MODEL_LOG"
    sed -i 's/teh/the/' README.md
    emit 'Fixed the typo in README.md.' ;;
  *"REVIEW stage"*)
    echo "review $model" >> "$MODEL_LOG"
    case "$prompt" in *"same model family"*) ;; *) echo "review without the adversarial brief" >> "$MODEL_LOG" ;; esac
    emit '{"verdict":"ship","proof":"verified","evidence":"README now contains the","reason":"minimal typo fix"}' ;;
  *) echo "other $model" >> "$MODEL_LOG"; exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/claude"

d="$TMP/night"
mkdir -p "$d/state" "$d/runs" "$d/digests" "$d/worktrees"
git init -q --bare "$d/remote.git"
git init -q -b main "$d/repo"
git -C "$d/repo" remote add origin "$d/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$d/repo/README.md"
git -C "$d/repo" -c user.name=test -c user.email=test@localhost add -A
git -C "$d/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$d/repo" push -q -u origin main
cat > "$d/rulebook.yaml" <<EOF
branch_prefix: nightshift/
agent:
  claude_model: work-model
  review_model: review-model
limits:
  max_open_branches: 5
  max_fix_iterations: 1
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $d/repo
    mode: branch-fix
    base: main
    test_cmd: grep -q "This is" README.md
EOF
: > "$d/models"
env -u NIGHTSHIFT_CLAUDE_MODEL -u NIGHTSHIFT_REVIEW_MODEL -u NIGHTSHIFT_ADVISORS \
  PATH="$TMP/bin:/usr/bin:/bin" RULEBOOK="$d/rulebook.yaml" MODEL_LOG="$d/models" \
  NIGHTSHIFT_AGENT=claude NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$d/state" NIGHTSHIFT_RUNS_DIR="$d/runs" \
  NIGHTSHIFT_DIGEST_DIR="$d/digests" NIGHTSHIFT_WORKTREES="$d/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$d/out" 2>"$d/err" || { cat "$d/err" >&2; fail "the night failed"; }

grep -qx 'explore work-model' "$d/models" || fail "Explore did not run on claude_model: $(cat "$d/models")"
grep -qx 'fix work-model' "$d/models" || fail "Fix did not run on claude_model: $(cat "$d/models")"
grep -qx 'review review-model' "$d/models" || fail "Review did not run on review_model: $(cat "$d/models")"
grep -q 'adversarial brief' "$d/models" && fail "a review prompt lacked the same-model-family brief"
grep -vxE '(explore|fix) work-model|review review-model' "$d/models" \
  && fail "a stage ran on the wrong model, or an unexpected stage ran: $(cat "$d/models")"
git --git-dir="$d/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*' | grep -q . \
  || { cat "$d/err" >&2; fail "the reviewed fix did not ship, so the run proves less than it claims"; }
# The night announces both requested models and where each came from.
grep -q 'claude model: work-model (from rulebook agent.claude_model)' "$d/err" \
  || fail "the claude model was not announced: $(grep -i model "$d/err")"
grep -q 'claude review model: review-model (from rulebook agent.review_model)' "$d/err" \
  || fail "the review model was not announced: $(grep -i model "$d/err")"

# Precedence on the adapter itself, for every stage that reaches the CLI.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
model="<none>" prev=""
for a in "$@"; do [ "$prev" = --model ] && model="$a"; prev="$a"; done
cat >/dev/null
printf '%s' "$model" > "$MODEL_LOG"
jq -nc '{type:"result",result:"{}",usage:{output_tokens:1}}'
EOF
mkdir -p "$TMP/wd" "$TMP/item" "$TMP/u-state"
(
  export PATH="$TMP/bin:$PATH" MODEL_LOG="$TMP/model" NIGHTSHIFT_SOURCED=1
  export NIGHTSHIFT_STATE_DIR="$TMP/u-state" NIGHTSHIFT_RUNS_DIR="$TMP/u-runs"
  export NIGHTSHIFT_DIGEST_DIR="$TMP/u-digests" NIGHTSHIFT_WORKTREES="$TMP/u-worktrees"
  unset NIGHTSHIFT_CLAUDE_MODEL NIGHTSHIFT_REVIEW_MODEL
  # shellcheck disable=SC1090
  source "$ROOT/bin/nightshift.sh"
  : > "$STATE_DIR/claude-settings.json"
  model_of() { rm -f "$TMP/model"; claude_run "$1" "$TMP/wd" "$TMP/item" >/dev/null 2>&1 || true; cat "$TMP/model"; }
  RB_CLAUDE_MODEL=work-model RB_REVIEW_MODEL=review-model
  for s in recon explore fix verify; do
    [ "$(model_of "$s")" = work-model ] || fail "$s did not run on claude_model"
  done
  for s in review advise; do
    [ "$(model_of "$s")" = review-model ] || fail "$s did not run on review_model"
  done
  NIGHTSHIFT_REVIEW_MODEL=env-review
  [ "$(model_of review)" = env-review ] || fail "NIGHTSHIFT_REVIEW_MODEL did not beat the rulebook"
  [ "$(model_of fix)" = work-model ] || fail "NIGHTSHIFT_REVIEW_MODEL leaked into Fix"
  NIGHTSHIFT_REVIEW_MODEL=
  [ "$(model_of review)" = work-model ] || fail "an empty NIGHTSHIFT_REVIEW_MODEL did not fall back to the claude model"
  unset NIGHTSHIFT_REVIEW_MODEL; RB_REVIEW_MODEL=""
  [ "$(model_of review)" = work-model ] || fail "an undeclared review model did not fall back to the claude model"
  RB_CLAUDE_MODEL=""
  [ "$(model_of review)" = '<none>' ] || fail "no declared model at all must pass no --model"
  # The advice cache key follows the review model, so a new reviewer re-reviews every branch.
  RB_CLAUDE_MODEL=work-model RB_REVIEW_MODEL=review-model
  [ "$(advisor_model claude 1)" = review-model ] || fail "the advice cache key does not name the review model"
  out="$(log_model_selection "claude review" NIGHTSHIFT_REVIEW_MODEL "" review_model "Review and branch advice use the claude model" 2>&1)"
  case "$out" in *"not declared"*"use the claude model"*) ;; *) fail "an undeclared review model is not announced: $out" ;; esac
)

echo "test-review-model: ok"
