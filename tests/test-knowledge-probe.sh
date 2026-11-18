#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

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
See the [data](data.json) and the [license](LICENSE).
See the [directory](guide/) and the [versioned directory](v1.0/).
See the [linked data](linked.json).
These links are broken: [file as directory](LICENSE/) and [dangling](dangling.json).
[^spec]: Source.
EOF
# Tracked non-Markdown link targets: they exist, so they must not be reported as broken links.
echo '{}' > "$TMP/repo/data.json"
echo 'test licence' > "$TMP/repo/LICENSE"
mkdir -p "$TMP/repo/guide" "$TMP/repo/v1.0"
echo '# Guide' > "$TMP/repo/guide/index.md"
echo '# Version' > "$TMP/repo/v1.0/index.md"
ln -s data.json "$TMP/repo/linked.json"
ln -s missing.json "$TMP/repo/dangling.json"
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
  any(.diagnostics[]; .code == "broken_markdown_link" and (.message | endswith("missing.md"))) and
  any(.diagnostics[]; .code == "broken_markdown_link" and (.message | endswith("LICENSE/index.md"))) and
  any(.diagnostics[]; .code == "broken_markdown_link" and (.message | endswith("dangling.json"))) and
  ([.diagnostics[] | select(.code == "broken_markdown_link")] | length) == 3 and
  any(.diagnostics[]; .code == "duplicate_log_date") and
  any(.diagnostics[]; .code == "orphan_concept" and .file == "orphan.md")
' "$TMP/report.json" >/dev/null

# A repeated root key must be rejected even when the final value is supported.
cat > "$TMP/repo/index.md" <<'EOF'
---
okf_version: "0.1"
okf_version: "0.2"
---
# Index
* [Good](good.md) - grounded concept.
* [Computation](calc.md) - incomplete computation contract.
EOF
python3 "$ROOT/lib/knowledge_probe.py" "$TMP/repo" > "$TMP/duplicate-root-report.json"
jq -e '
  .profile == "okf-0.2" and
  .summary.portable_structure_clean == false and
  any(.diagnostics[]; .code == "duplicate_frontmatter_key" and .file == "index.md")
' "$TMP/duplicate-root-report.json" >/dev/null

# CommonMark link titles and <...> destinations are not part of the path: these links work, so
# they must count as inbound links and must not be reported as broken.
git init -q "$TMP/titled"
cat > "$TMP/titled/index.md" <<'EOF'
---
okf_version: "0.2"
---
# Index
* [Spec](spec.md "OKF spec") and its [part](spec.md#part 'Part').
* [Plan](<my plan.md>) and [Notes](notes.md (Notes)).
* [Missing](<gone.md> "Gone").
EOF
for page in spec.md "my plan.md" notes.md; do
  printf -- '---\ntype: Note\n---\n# Page\n' > "$TMP/titled/$page"
done
git -C "$TMP/titled" -c user.name=test -c user.email=test@localhost add .
git -C "$TMP/titled" -c user.name=test -c user.email=test@localhost commit -q -m initial
python3 "$ROOT/lib/knowledge_probe.py" "$TMP/titled" > "$TMP/titled-report.json"
jq -e '
  ([.diagnostics[] | select(.code == "orphan_concept")] | length) == 0 and
  ([.diagnostics[] | select(.code == "broken_markdown_link")] | length) == 1 and
  any(.diagnostics[]; .code == "broken_markdown_link" and (.message | endswith(": gone.md")))
' "$TMP/titled-report.json" >/dev/null || {
  echo "test-knowledge-probe: titled or <> links misparsed:" >&2; cat "$TMP/titled-report.json" >&2; exit 1;
}

# Invalid link syntax must not provide inbound evidence; valid title forms still must.
git init -q "$TMP/invalid-titles"
cat > "$TMP/invalid-titles/index.md" <<'EOF'
---
okf_version: "0.2"
---
# Index
* [Bare text](bare.md kein Titel)
* [Unclosed quote](quote.md "unfinished)
* [Trailing text](trailing.md 'Title' extra)
* [No separator](<adjacent.md>"Title")
* [Space in path](my plan.md)
* [Unclosed angle](<angle.md)
* [Missing outer parenthesis](outer.md (Title)
* [Junk after parentheses](junk.md (Title) extra)
* [Double quote](double.md "A title")
* [Single quote](single.md 'A title')
* [Parentheses](paren.md (A title))
* [Angle title](<angle title.md> "A title")
* [Fragment](fragment.md#part 'A title')
* [Escaped quote](escaped.md "A \"title\"")
* [Angle parentheses](<plan(1).md>)
* [Bare parentheses](plain(1).md)
* [Title parentheses](title-paren.md "A (title)")
* [Blank quoted title](blank-double.md "First

Second")
* [Blank paren title](blank-paren.md (First

Second))
* [Blank before target](

blank-target.md)
* [Wrapped title](wrapped-title.md "First
Second")
* [Wrapped separator](wrapped-separator.md
'Title')

Allowed range: [0, 1).

[After interval](after-interval.md)
EOF
# Generate whitespace-only blank lines without trailing whitespace in this script.
printf "\n* [Blank single title](blank-single.md 'First\n \t\nSecond')\n" >> "$TMP/invalid-titles/index.md"
for page in bare.md quote.md trailing.md adjacent.md "my plan.md" angle.md outer.md junk.md \
  double.md single.md paren.md "angle title.md" fragment.md escaped.md \
  "plan(1).md" "plain(1).md" title-paren.md \
  blank-double.md blank-single.md blank-paren.md blank-target.md wrapped-title.md wrapped-separator.md \
  after-interval.md; do
  printf -- '---\ntype: Note\n---\n# Page\n' > "$TMP/invalid-titles/$page"
done
git -C "$TMP/invalid-titles" add .
python3 "$ROOT/lib/knowledge_probe.py" "$TMP/invalid-titles" > "$TMP/invalid-titles-report.json"
jq -e '
  ([.diagnostics[] | select(.code == "orphan_concept") | .file] | sort) ==
    ["adjacent.md", "angle.md", "bare.md", "blank-double.md", "blank-paren.md", "blank-single.md",
     "blank-target.md", "junk.md", "my plan.md", "outer.md", "quote.md", "trailing.md"] and
  ([.diagnostics[] | select(.code == "broken_markdown_link")] | length) == 0
' "$TMP/invalid-titles-report.json" >/dev/null || {
  echo "test-knowledge-probe: invalid link syntax counted as inbound, or valid title rejected" >&2
  exit 1
}

# Restore the valid root index for the end-to-end Runner check below.
cat > "$TMP/repo/index.md" <<'EOF'
---
okf_version: "0.2"
---
# Index
* [Good](good.md) - grounded concept.
* [Computation](calc.md) - incomplete computation contract.
EOF

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
RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_AGENT=mock NIGHTSHIFT_OPEN_PR=0 \
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
