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
    base: main
    findings: 1
    dimensions: correctness
EOF

# Fake only the first-party CLI boundary. Runner, recon, worktree, git, and ledger paths stay real.
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="" model="" effort="" sandbox="" approval="" network="" codemap=""
ephemeral=0 ignore_config=0 ignore_rules=0 strict_config=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -m|--model) model="$2"; shift 2 ;;
    -s|--sandbox) sandbox="$2"; shift 2 ;;
    -a|--ask-for-approval) approval="$2"; shift 2 ;;
    --ephemeral) ephemeral=1; shift ;;
    --ignore-user-config) ignore_config=1; shift ;;
    --ignore-rules) ignore_rules=1; shift ;;
    --strict-config) strict_config=1; shift ;;
    -c)
      case "$2" in
        sandbox_workspace_write.network_access=false) network=off ;;
        'model_reasoning_effort="high"') effort=high ;;
        'mcp_servers.codemap.command="codemap-mcp"') codemap=on ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
[ "$model" = test-model ] && [ "$effort" = high ] && [ "$approval" = never ] \
  && [ "$ephemeral" = 1 ] && [ "$ignore_config" = 1 ] && [ "$ignore_rules" = 1 ] \
  && [ "$strict_config" = 1 ]
prompt=$(cat)
case "$prompt" in
  *"RECON stage"*)
    [ "$sandbox" = read-only ]
    printf '%s' '{"dimensions":{"correctness":{"applicable":true,"hint":"code"}},"notes":"test recon"}' > "$out" ;;
  *"EXPLORE stage"*)
    [ "$sandbox" = read-only ]
    printf '%s' '{"found":true,"findings":[{"file":"README.md","type":"typo","line_window":"L1-L3","claim":"README contains teh","verify":"search README for teh","verifiability":"static","disposition":"fix","summary":"fix typo","fingerprint":"README.md:typo:L1-L3","rank":1,"confidence":1.0}]}' > "$out" ;;
  *"FIX stage"*)
    [ "$sandbox" = workspace-write ] && [ "$network" = off ]
    sed -i 's/teh/the/' README.md
    printf '%s' 'Fixed the typo in README.md.' > "$out" ;;
  *"REVIEW stage"*)
    [ "$sandbox" = read-only ]
    printf '%s' '{"verdict":"ship","proof":"verified","evidence":"README now contains the","reason":"minimal typo fix"}' > "$out" ;;
  *) exit 2 ;;
esac
printf '%s\n' '{"type":"turn.completed","usage":{"output_tokens":7}}'
EOF
chmod +x "$TMP/bin/codex"

PATH="$TMP/bin:/usr/bin:/bin" \
RULEBOOK="$TMP/rulebook.yaml" \
NIGHTSHIFT_AGENT=codex NIGHTSHIFT_CODEX_MODEL=test-model NIGHTSHIFT_CODEX_REASONING_EFFORT=high \
NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >/dev/null

branch=$(git --git-dir="$TMP/remote.git" for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*')
[ -n "$branch" ]
git --git-dir="$TMP/remote.git" show "$branch:README.md" | grep -q 'This is the demo.'
jq -e 'select(.model=="codex" and .tokens==7 and .exit==0)' "$TMP/state/runs.jsonl" >/dev/null
jq -e 'select(.outcome=="shipped" and .branch!=null)' "$TMP/state/ledger.jsonl" >/dev/null
echo "test-codex-adapter: ok"
