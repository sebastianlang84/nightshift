#!/usr/bin/env bash
set -euo pipefail

# A model response that contains no JSON is not a clean `found:false` review. The adapter must
# fail the stage so the Runner leaves coverage, rotation, and the ledger untouched.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf 'prefix {"found":true,"findings":[]} suffix\n' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/valid"
jq -e '.found == true' "$TMP/valid" >/dev/null

if printf 'analysis completed, but no machine-readable verdict\n' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/invalid" 2> "$TMP/err"; then
  echo "test-json-extraction: prose-only output was accepted as a verdict" >&2
  exit 1
fi
[ ! -s "$TMP/invalid" ] || {
  echo "test-json-extraction: failure forged a JSON verdict" >&2; cat "$TMP/invalid" >&2; exit 1;
}
grep -q 'no parseable JSON' "$TMP/err"

# A malformed outer verdict may contain a syntactically valid nested finding. Returning that inner
# object changes the schema and can make a partial answer look complete; skip past the whole broken
# candidate rather than searching inside it.
if printf '%s\n' '{"bad":"\q","nested":{"found":false,"findings":[]}}' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/nested" 2> "$TMP/err"; then
  echo "test-json-extraction: nested object escaped a malformed outer verdict" >&2
  exit 1
fi
[ ! -s "$TMP/nested" ]

# A closer that contradicts its own opener is a slip, not an unfinished answer: the model closed
# every bracket it opened and spelled one of them wrong, so the nesting it meant is unambiguous.
# Repair it, keep the verdict, and say on stderr that the artifact is not byte-for-byte the model's
# (ADR 0030). Measured: this exact shape — `coverage.invariants` opened `{` and closed `]` — cost
# 13 explore lenses across four nights, each after the model had already done the work.
printf '%s\n' '{"found":true,"coverage":{"invariants":{"a":"checked"],"unresolved":[]},"findings":[]}' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/swapped" 2> "$TMP/err"
jq -e '.found == true and .coverage.invariants.a == "checked"' "$TMP/swapped" >/dev/null
grep -q 'json-repair: swapped 1' "$TMP/err" || {
  echo "test-json-extraction: a repaired verdict was returned silently" >&2; exit 1;
}

# Repair has a ceiling. Past it the output is garbled enough that "the model meant this" is a guess.
if printf '%s\n' '{"a":{"b":{"c":{"d":1],"e":2],"f":3],"g":4]}' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/garbled" 2> "$TMP/err"; then
  echo "test-json-extraction: unbounded repair accepted a garbled verdict" >&2
  exit 1
fi
[ ! -s "$TMP/garbled" ]

# Truncated output is NOT repaired. A missing closer means the model never finished; appending one
# would fabricate the part it did not say, and the balanced object that follows the unclosed one is
# nested inside it — returning that fragment is the same laundering the nested case above forbids.
if printf '%s' '{"repo":"/x","dimensions":{"correctness":{"yield":"high"}}' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/cut" 2> "$TMP/err"; then
  echo "test-json-extraction: truncated output was completed into a verdict" >&2
  exit 1
fi
[ ! -s "$TMP/cut" ]
grep -q 'no parseable JSON' "$TMP/err"

echo "test-json-extraction: ok"
