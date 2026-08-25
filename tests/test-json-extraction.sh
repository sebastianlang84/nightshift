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

# The same repair must work when the mismatched closer is the outermost one. The first scan needs
# to return that complete malformed candidate so the repair pass gets a chance to correct it.
printf '%s\n' '{"found":false,"findings":[]]' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/outer-swapped" 2> "$TMP/err"
jq -e '.found == false and .findings == []' "$TMP/outer-swapped" >/dev/null
grep -q 'json-repair: swapped 1' "$TMP/err"

# A mismatched outer closer followed by another object member is not an end marker. Repairing only
# the prefix would silently drop the remaining fields and turn a partial stage verdict into valid
# JSON, so this shape must stay fail-closed.
if printf '%s\n' '{"verdict":"ship"],"caveats":["not reviewed"]}' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/truncated-prefix" 2> "$TMP/err"; then
  echo "test-json-extraction: repair silently truncated a continued object" >&2
  exit 1
fi
[ ! -s "$TMP/truncated-prefix" ]

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

# A comma left standing before a closer is the same class of slip, and needs even less reading than
# a swapped closer: it separates a value from nothing, so dropping it cannot pick one meaning over
# another. JSON5, JavaScript and Python all accept it; only JSON does not. Measured: this cost the
# explore lens of 2026-08-24, after seven minutes of work and a finding already written.
printf '%s\n' '{"found":true,"coverage":{"unresolved":[],},"findings":[1,2,],}' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/comma" 2> "$TMP/err"
jq -e '.found == true and (.findings | length) == 2 and (.coverage.unresolved | length) == 0' "$TMP/comma" >/dev/null
grep -q 'json-repair: dropped 3 trailing comma' "$TMP/err" || {
  echo "test-json-extraction: trailing commas were dropped silently or not at all" >&2
  cat "$TMP/err" >&2; exit 1;
}

# Both repairs in one candidate are reported as both, so the night log names every edit made to the
# artifact that reaches the ledger.
printf '%s\n' '{"found":true,"coverage":{"invariants":{"a":"checked"],},"findings":[]}' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/both" 2> "$TMP/err"
jq -e '.coverage.invariants.a == "checked"' "$TMP/both" >/dev/null
grep -q 'swapped 1 mismatched closer(s) and dropped 1 trailing comma(s)' "$TMP/err" || {
  echo "test-json-extraction: a candidate needing both repairs did not report both" >&2
  cat "$TMP/err" >&2; exit 1;
}

# A comma inside a string is data, not syntax, and must survive untouched — including one sitting
# right where the scanner looks for a trailing separator.
printf '%s\n' '{"found":true,"note":"a, b,","findings":[],}' |
  python3 "$ROOT/lib/extract_json.py" > "$TMP/instr" 2> "$TMP/err"
jq -e '.note == "a, b,"' "$TMP/instr" >/dev/null || {
  echo "test-json-extraction: repair reached inside a string literal" >&2; exit 1;
}

echo "test-json-extraction: ok"
