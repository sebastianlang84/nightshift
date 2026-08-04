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
    test_cmd: make test && ./extra check
EOF

actual=$(python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rulebook.yaml" | grep '^repo')
# test_cmd rides last on purpose (ADR 0022): a command contains spaces, and the Runner's
# `read` soaks the remainder into the final variable — so it must have no field after it.
expected=$(printf '%s\n' \
  $'repo\tpath=/srv/no-base\tmode=branch-fix\tbase=\tfindings=5\tdimensions=\ttest_cmd=' \
  $'repo\tpath=/srv/no-findings\tmode=findings-only\tbase=develop\tfindings=\tdimensions=security,infra\ttest_cmd=' \
  $'repo\tpath=/srv/all-fields\tmode=branch-fix\tbase=release\tfindings=3\tdimensions=docs,tests\ttest_cmd=make test && ./extra check')

[ "$actual" = "$expected" ]

# A tab inside test_cmd would split the field and shift everything after it — reject it.
cat > "$TMP/tabbed.yaml" <<EOF
repos:
  - path: /srv/tabbed
    mode: branch-fix
    test_cmd: make$(printf '\t')test
EOF
if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/tabbed.yaml" >/dev/null 2>&1; then
  echo "test-rulebook-parser: a tab in test_cmd must be rejected" >&2; exit 1
fi

# test_timeout_seconds: defaulted when absent, validated when present.
cat > "$TMP/notimeout.yaml" <<'EOF'
repos:
  - path: /srv/x
    mode: branch-fix
EOF
python3 "$ROOT/lib/parse_rulebook.py" "$TMP/notimeout.yaml" | grep -qx $'test_timeout_seconds\t600' \
  || { echo "test-rulebook-parser: test_timeout_seconds must default to 600" >&2; exit 1; }
cat > "$TMP/zerotimeout.yaml" <<'EOF'
limits:
  test_timeout_seconds: 0
repos:
  - path: /srv/x
    mode: branch-fix
EOF
if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/zerotimeout.yaml" >/dev/null 2>&1; then
  echo "test-rulebook-parser: test_timeout_seconds 0 must be rejected" >&2; exit 1
fi

echo "test-rulebook-parser: ok"
