#!/usr/bin/env bash
set -euo pipefail

# A clean verdict is evidence only when the model names enough of the repository and the checks it
# performed. The validator uses the tracked-file count to stay fair to tiny repositories.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git init -q "$TMP/repo"
for n in 1 2 3 4 5 6; do printf 'file %s\n' "$n" > "$TMP/repo/f$n.txt"; done
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add .
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial

cat > "$TMP/valid.json" <<'JSON'
{"found":false,"findings":[],"scope":"in_scope_no_findings","coverage":{
  "files":["f1.txt","f2.txt","f3.txt","f4.txt","f5.txt"],
  "entrypoints":["f1.txt -> f2.txt"],
  "checks":["checked invariant one","checked invariant two","checked invariant three"],
  "invariants":{
    "config_domain":"checked: parser values reach their consumers",
    "semantic_sets":"checked: counted members match the policy noun",
    "artifact_identity":"checked: producer and consumer use the same artifact",
    "failure_translation":"checked: failures cannot become clean results",
    "lifecycle":"checked: terminal states release their resources"},
  "unresolved":[]}}
JSON
python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/valid.json"

jq '.coverage.invariants={
  "canonicality":"checked: one canonical page per claim",
  "consistency":"checked: overlapping claims agree",
  "routing":"checked: index reaches the concepts",
  "provenance_trust":"checked: claim resolves to source id",
  "lifecycle_freshness":"checked: stale and superseded states traced"}' \
  "$TMP/valid.json" > "$TMP/knowledge.json"
python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/knowledge.json" knowledge
if python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/knowledge.json" 2> "$TMP/err"; then
  echo "test-explore-coverage: knowledge matrix passed for a code lens" >&2; exit 1
fi
if python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/valid.json" knowledge 2> "$TMP/err"; then
  echo "test-explore-coverage: code matrix passed for knowledge lens" >&2; exit 1
fi

jq '.coverage.files=["f1.txt","f2.txt"]' "$TMP/valid.json" > "$TMP/shallow.json"
if python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/shallow.json" 2> "$TMP/err"; then
  echo "test-explore-coverage: shallow verdict passed" >&2; exit 1
fi
grep -q 'coverage.files needs 5' "$TMP/err"

jq '.coverage.files[4]="missing.txt"' "$TMP/valid.json" > "$TMP/missing.json"
if python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/missing.json" 2> "$TMP/err"; then
  echo "test-explore-coverage: invented path passed" >&2; exit 1
fi
grep -q 'not tracked files' "$TMP/err"

jq 'del(.coverage)' "$TMP/valid.json" > "$TMP/absent.json"
if python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/absent.json" 2> "$TMP/err"; then
  echo "test-explore-coverage: verdict without coverage passed" >&2; exit 1
fi
grep -q 'coverage must be an object' "$TMP/err"

jq 'del(.coverage.invariants.artifact_identity)' "$TMP/valid.json" > "$TMP/no-invariant.json"
if python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/no-invariant.json" 2> "$TMP/err"; then
  echo "test-explore-coverage: incomplete invariant matrix passed" >&2; exit 1
fi
grep -q 'coverage.invariants must contain exactly' "$TMP/err"

jq '.coverage.invariants.lifecycle="checked:"' "$TMP/valid.json" > "$TMP/empty-evidence.json"
if python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/empty-evidence.json" 2> "$TMP/err"; then
  echo "test-explore-coverage: empty invariant evidence passed" >&2; exit 1
fi
grep -q 'coverage.invariants.lifecycle needs' "$TMP/err"

echo "test-explore-coverage: ok"
