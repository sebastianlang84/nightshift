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

# Back-compat: the Runner documents a single finding object without a `findings` array and
# normalises it after this validator. The validator must not reject that supported shape first.
jq 'del(.findings) | .found=true | .file="f1.txt" | .summary="single finding"' \
  "$TMP/valid.json" > "$TMP/single.json"
python3 "$ROOT/lib/validate_explore.py" "$TMP/repo" "$TMP/single.json"

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

# The matrices above are only enforceable while the prompts ask the model for those exact keys:
# nothing in the code links the two sides, so a reworded prompt would make the Runner reject every
# Explore verdict for that lens (bin/nightshift.sh: the ADR 0029 receipt gates `considered` and the
# dimension scan marker) with the suite still green. Bind them the way tests/test-dimension-catalog.sh
# binds the dimension catalog to prompts/recon.md.

code_keys() { # code_keys DIMENSION — the keys validate_explore.py demands, sorted, one per line
  python3 - "$ROOT/lib/validate_explore.py" "$1" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("validate_explore", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("\n".join(sorted(module.invariant_keys(sys.argv[2]))))
PY
}

# matrix_keys FILE MARKER — the backticked keys of the bullet list introduced by MARKER, sorted.
# Collection stops at the first line that starts a new unindented paragraph.
matrix_keys() {
  awk -v marker="$2" '
    index($0, marker) { collecting = 1; next }
    collecting && /^ *- `[a-z_]+`:/ { gsub(/^ *- `|`:.*$/, ""); print; found = 1; next }
    found && /^[^ -]/ { exit }
  ' "$1" | sort
}

mapfile -t default_code < <(code_keys "")
mapfile -t default_matrix < <(matrix_keys "$ROOT/prompts/explore.md" 'complete the invariant matrix')
[ "${default_matrix[*]}" = "${default_code[*]}" ] || {
  echo "test-explore-coverage: prompts/explore.md matrix '${default_matrix[*]}' does not match" \
    "validate_explore.py '${default_code[*]}'" >&2; exit 1;
}

# Both output templates (found:true and found:false) must spell out the same keys.
mapfile -t contract_keys < <(
  grep -oE '"[a-z_]+":"checked: <evidence>"' "$ROOT/prompts/explore.md" |
    sed 's/^"//; s/":"checked.*//' | sort -u
)
[ "${contract_keys[*]}" = "${default_code[*]}" ] || {
  echo "test-explore-coverage: explore output contract '${contract_keys[*]}' does not match" \
    "validate_explore.py '${default_code[*]}'" >&2; exit 1;
}
contract_slots=$(grep -cE '"[a-z_]+":"checked: <evidence>"' "$ROOT/prompts/explore.md" || true)
[ "$contract_slots" -eq $((2 * ${#default_code[@]})) ] || {
  echo "test-explore-coverage: expected both explore output templates to name all" \
    "${#default_code[@]} invariants, found $contract_slots slots" >&2; exit 1;
}

# A lens may replace the code matrix with its own five classes; the validator must know about
# exactly the lenses that do, and about no others.
for prompt in "$ROOT"/prompts/dimensions/*.md; do
  dim="$(basename "$prompt" .md)"
  mapfile -t lens_code < <(code_keys "$dim")
  mapfile -t lens_matrix < <(matrix_keys "$prompt" 'REPLACE the generic code invariant matrix')
  if [ "${#lens_matrix[@]}" -eq 0 ]; then
    [ "${lens_code[*]}" = "${default_code[*]}" ] || {
      echo "test-explore-coverage: validate_explore.py demands a replacement matrix for '$dim'" \
        "that prompts/dimensions/$dim.md never asks for" >&2; exit 1;
    }
    continue
  fi
  [ "${lens_matrix[*]}" = "${lens_code[*]}" ] || {
    echo "test-explore-coverage: prompts/dimensions/$dim.md matrix '${lens_matrix[*]}' does not" \
      "match validate_explore.py '${lens_code[*]}'" >&2; exit 1;
  }
done

echo "test-explore-coverage: ok"
