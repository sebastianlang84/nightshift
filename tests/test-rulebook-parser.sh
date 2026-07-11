#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/rulebook.yaml" <<'EOF'
repos:
  - path: /srv/no-base
    mode: branch-fix
    findings: 5
  - path: /srv/no-findings
    mode: findings-only
    base: develop
    dimensions: security,infra
  - path: /srv/all-fields
    mode: branch-fix
    base: release
    findings: 3
    dimensions: docs,tests
EOF

actual=$(python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rulebook.yaml" | grep '^repo')
expected=$(printf '%s\n' \
  $'repo\tpath=/srv/no-base\tmode=branch-fix\tbase=\tfindings=5\tdimensions=' \
  $'repo\tpath=/srv/no-findings\tmode=findings-only\tbase=develop\tfindings=\tdimensions=security,infra' \
  $'repo\tpath=/srv/all-fields\tmode=branch-fix\tbase=release\tfindings=3\tdimensions=docs,tests')

[ "$actual" = "$expected" ]
echo "test-rulebook-parser: ok"
