#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/rulebook.yaml" <<'EOF'
repos:
  - path: /srv/example
    mode: branch-fix
    findings: security,infra
EOF

if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rulebook.yaml" >"$TMP/stdout" 2>"$TMP/stderr"; then
  echo "parser accepted a non-numeric findings override" >&2
  exit 1
fi
grep -q "repo /srv/example: findings must be a positive integer" "$TMP/stderr"

echo "test-rulebook-validation: ok"
