#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git init -q "$TMP/repo"
cat > "$TMP/repo/index.md" <<'EOF'
---
okf_version: "0.2"
---
# Index
* [Good](good.md) - grounded concept.
* [Computation](calc.md) - incomplete computation contract.
EOF
cat > "$TMP/repo/good.md" <<'EOF'
---
type: Method
generated: { by: process:test, at: 2026-08-19T00:00:00Z }
sources:
  - id: spec
    resource: https://example.test/spec
---
# Good
Grounded claim.[^spec]
[^spec]: Source.
EOF
cat > "$TMP/repo/calc.md" <<'EOF'
---
type: Attested Computation
---
# Calculation
See [[good]] and [missing](missing.md).
EOF
cat > "$TMP/repo/orphan.md" <<'EOF'
---
description: Missing its required type.
stale_after: 2020-01-01
sources:
  - id: incomplete
---
# Orphan
Unsupported footnote.[^unknown]
EOF
cat > "$TMP/repo/log.md" <<'EOF'
# Log
## 2026-08-19
* Added concepts.
## 2026-08-19
* Added them again.
EOF
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add .
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial

python3 "$ROOT/lib/knowledge_probe.py" "$TMP/repo" > "$TMP/report.json"
"$ROOT/lib/recon_signals.sh" "$TMP/repo" | jq -e '.has_knowledge == true' >/dev/null
jq -e '
  .profile == "okf-0.2" and
  .supported_okf_version == "0.2" and
  .summary.portable_structure_clean == false and
  any(.diagnostics[]; .code == "missing_type" and .file == "orphan.md") and
  any(.diagnostics[]; .code == "source_missing_resource") and
  any(.diagnostics[]; .code == "unresolved_source_id") and
  any(.diagnostics[]; .code == "stale_concept") and
  any(.diagnostics[]; .code == "computation_missing_runtime") and
  any(.diagnostics[]; .code == "computation_missing_executor") and
  any(.diagnostics[]; .code == "computation_missing_attester") and
  any(.diagnostics[]; .code == "nonstandard_wikilink") and
  any(.diagnostics[]; .code == "broken_markdown_link") and
  any(.diagnostics[]; .code == "duplicate_log_date") and
  any(.diagnostics[]; .code == "orphan_concept" and .file == "orphan.md")
' "$TMP/report.json" >/dev/null

# End-to-end: the opt-in lens runs the deterministic probe, the mock emits the knowledge-specific
# invariant matrix, validation accepts it, and findings-only records a clean pass without a branch.
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"
cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 1
recon:
  enabled: false
repos:
  - path: $TMP/repo
    mode: findings-only
    dimensions: knowledge
EOF
RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/stdout" 2>"$TMP/stderr"
grep -q 'lens=knowledge' "$TMP/stderr"
jq -se 'any(.[]; .outcome == "empty" and .dimension == "knowledge")' \
  "$TMP/state/ledger.jsonl" >/dev/null
[ -n "$(find "$TMP/runs" -name knowledge-probe.json -print -quit)" ] || {
  echo "test-knowledge-probe: Runner did not retain deterministic report" >&2; exit 1;
}

echo "test-knowledge-probe: ok"
