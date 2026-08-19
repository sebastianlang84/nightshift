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

echo "test-json-extraction: ok"
