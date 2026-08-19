#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 1
  max_findings_per_item: 1
  max_branches_per_run: 1
  max_fix_iterations: 1
recon:
  enabled: true
  ttl_days: 7
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: branch-fix
    test_cmd: true
    base: main
    findings: 1
    dimensions: correctness
EOF

# Fake only the first-party CLI boundary. Runner, recon, worktree, git, and ledger paths stay real.
# The fake asserts the per-stage CAPABILITY profile (--tools) and the runner-owned flags, then emits
# the two DIFFERENT --output-format json shapes claude_run must normalise (bin/nightshift.sh:461-468):
# explore returns the ARRAY-of-events shape (a rate_limit_event ahead of the result object) — the
# documented silent-failure trap; the other stages return the top-level result-object shape. If the
# array normalisation regresses, explore.out is empty -> no finding -> no branch -> this test fails.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="" outfmt="" settings="" tools="" skip=0 maxturns=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --output-format) outfmt="$2"; shift 2 ;;
    --settings) settings="$2"; shift 2 ;;
    --tools) tools="$2"; shift 2 ;;
    --dangerously-skip-permissions) skip=1; shift ;;
    --max-turns) maxturns="$2"; shift 2 ;;
    --mcp-config) shift 2 ;;
    *) shift ;;
  esac
done
# Runner-owned flags every stage must carry (headless JSON, Layer-2 settings, sandbox default).
# Keep this one assertion: separate commands or an && chain under set -e can let a non-final false
# clause pass as an exempt condition.
[[ "$outfmt" = json && "$skip" = 1 && "$maxturns" = 60 && -f "$settings" ]]

# The usage block mirrors the real headless result object: `modelUsage` keyed by the REAL model ID —
# the only source for runs.jsonl's `model_id` — plus the cumulative input/cache counters. A second,
# smaller model is present so the adapter must attribute the stage to the heaviest consumer, and the
# keys are deliberately camelCase (modelUsage) vs snake_case (usage), as the CLI emits them.
# Both entries carry a DIFFERENT contextWindow and costUSD, so `context_window`/`model_cost_usd` must
# come from the SAME entry `model_id` was attributed to — picking either arbitrarily fails below.
emit_object() { # result-string  -> top-level result-object shape
  jq -nc --arg r "$1" '{type:"result",result:$r,
    usage:{input_tokens:11,cache_read_input_tokens:1300,cache_creation_input_tokens:200,output_tokens:7},
    modelUsage:{"claude-haiku-4-5-20251001":{inputTokens:5,outputTokens:1,
                                             contextWindow:200000,costUSD:0.0001},
                "claude-opus-5":{inputTokens:11,outputTokens:7,
                                 cacheReadInputTokens:1300,cacheCreationInputTokens:200,
                                 contextWindow:1000000,costUSD:0.0099}},
    total_cost_usd:0.01}'
}

case "$prompt" in
  *"RECON stage"*)
    [ "$tools" = "Read,Grep,Glob" ]
    emit_object '{"dimensions":{"correctness":{"applicable":true,"hint":"code"}},"notes":"test recon"}' ;;
  *"EXPLORE stage"*)
    [ "$tools" = "Read,Grep,Glob" ]
    r='{"found":true,"coverage":{"files":["README.md"],"entrypoints":["README -> rendered documentation"],"checks":["checked typo marker"],"invariants":{"config_domain":"not-applicable: no config","semantic_sets":"not-applicable: no sets","artifact_identity":"checked: one README artifact","failure_translation":"checked: explicit result JSON","lifecycle":"not-applicable: no lifecycle"},"unresolved":[]},"findings":[{"file":"README.md","type":"typo","line_window":"L1-L3","claim":"README contains teh","verify":"search README for teh","verifiability":"static","disposition":"fix","summary":"fix typo","fingerprint":"README.md:typo:L1-L3","rank":1,"confidence":1.0}]}'
    # ARRAY-of-events shape: rate_limit_event ahead of the SAME result object.
    jq -nc --argjson o "$(emit_object "$r")" '[{type:"rate_limit_event"},$o]' ;;
  *"FIX stage"*)
    [ "$tools" = "Read,Grep,Glob,Write,Edit" ]
    sed -i 's/teh/the/' README.md
    emit_object 'Fixed the typo in README.md.' ;;
  *"REVIEW stage"*)
    [ "$tools" = "Read,Grep,Glob" ]
    emit_object '{"verdict":"ship","proof":"verified","evidence":"README now contains the","reason":"minimal typo fix"}' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/claude"

PATH="$TMP/bin:/usr/bin:/bin" \
RULEBOOK="$TMP/rulebook.yaml" \
NIGHTSHIFT_AGENT=claude \
NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >/dev/null

branch=$(git --git-dir="$TMP/remote.git" for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*')
[ -n "$branch" ]
git --git-dir="$TMP/remote.git" show "$branch:README.md" | grep -q 'This is the demo.'
# Telemetry: `model` stays the ADAPTER name, `model_id` carries the model that actually served the
# stage (the heaviest consumer in modelUsage, NOT the small side model), and the input/cache counters
# are recorded so context-window sizing is measurable. `context_window` (1000000, the attributed
# model's window — NOT the side model's 200000) records which variant actually ran, and
# `model_cost_usd` is that model's slice of the run-wide `cost_usd`. Asserted on EVERY line, so one
# stage losing its usage sidecar fails the test.
jq -se 'all(.model=="claude" and .model_id=="claude-opus-5" and .tokens==7 and .input_tokens==11
            and .cache_read_tokens==1300 and .cache_creation_tokens==200
            and .context_window==1000000
            and .cost_usd==0.01 and .model_cost_usd==0.0099 and .exit==0)' \
  "$TMP/state/runs.jsonl" >/dev/null
jq -e 'select(.outcome=="shipped" and .branch!=null)' "$TMP/state/ledger.jsonl" >/dev/null
echo "test-claude-adapter: ok"
