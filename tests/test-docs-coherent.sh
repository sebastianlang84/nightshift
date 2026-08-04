#!/usr/bin/env bash
set -euo pipefail

# Docs rot in one mechanical way: they name a thing — a file, an ADR, a line — and that thing moves
# or disappears. Nightshift has shipped exactly that as findings twice (risk-analysis.md citing
# nightshift.sh:176 after the flag moved to 186; prototype.md's Files table omitting
# lib/extract_json.py), which is the argument for spending a `test -e` instead of a human on it.
#
# Two halves. First: THIS repo's docs must be clean — the check that actually protects the tree,
# and the one that runs in the ship gate and in CI. Second: the checker must genuinely catch each
# claim it advertises, proven on a fixture repo, so a checker that silently degrades to `exit 0`
# cannot pass for a green tree.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/lib/check_docs.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. the real tree is coherent ---------------------------------------------
if ! out="$(python3 "$CHECK" "$ROOT" 2>&1)"; then
  echo "test-docs-coherent: this repo's docs make claims that no longer hold:" >&2
  echo "$out" >&2
  exit 1
fi

# --- 2. each claim class is genuinely caught ----------------------------------
# A fresh git repo, because the checker reads `git ls-files` — an untracked scratch note is not a doc.
fixture() { # doc-body -> prints the fixture root
  local d; d="$(mktemp -d -p "$TMP")"
  git init -q -b main "$d"
  mkdir -p "$d/docs/adr" "$d/bin"
  printf 'line1\nline2\n' > "$d/bin/real.sh"
  printf '# ADR 0001 — a real one\n' > "$d/docs/adr/0001-real.md"
  printf '%s\n' "$1" > "$d/README.md"
  git -C "$d" add -A
  echo "$d"
}

expect_caught() { # label doc-body needle
  local d out; d="$(fixture "$2")"
  if out="$(python3 "$CHECK" "$d" 2>&1)"; then
    echo "test-docs-coherent: $1 was NOT caught" >&2; echo "$out" >&2; exit 1
  fi
  grep -q -- "$3" <<<"$out" || {
    echo "test-docs-coherent: $1 was caught but not reported as expected (want: $3)" >&2
    echo "$out" >&2; exit 1
  }
}

expect_clean() { # label doc-body
  local d out; d="$(fixture "$2")"
  if ! out="$(python3 "$CHECK" "$d" 2>&1)"; then
    echo "test-docs-coherent: $1 must NOT be a finding" >&2; echo "$out" >&2; exit 1
  fi
}

expect_caught "a dead relative link"      'See [the thing](docs/design/gone.md).'      "dead link"
expect_caught "a missing ADR"             'This follows ADR 0042 closely.'             "ADR 0042"
expect_caught "a named file that is gone" 'Run `bin/vanished.sh` nightly.'             "does not exist"
expect_caught "a citation past EOF"       'The flag lives at `bin/real.sh:99`.'        "only 2 lines"

# The counterparts must stay quiet, or the checker is just noise people switch off.
expect_clean "a live link"                'See [the ADR](docs/adr/0001-real.md).'
expect_clean "a resolvable ADR"           'This follows ADR 0001 closely.'
expect_clean "a file that exists"         'Run `bin/real.sh` nightly.'
expect_clean "a citation inside the file" 'The flag lives at `bin/real.sh:2`.'
expect_clean "an external URL"            'See [upstream](https://example.com/x.md).'
expect_clean "a pure anchor"              'Jump to [the section](#context).'
expect_clean "runtime state, not source"  'The ledger is `state/ledger.jsonl` and is gitignored.'

echo "test-docs-coherent: ok"
