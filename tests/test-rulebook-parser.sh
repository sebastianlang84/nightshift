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
    test_cmd: make check
  - path: /srv/no-findings
    mode: findings-only
    base: develop
    dimensions: security,infra
  - path: /srv/all-fields
    mode: branch-fix
    base: release
    findings: 3
    dimensions: docs,tests
    test_net: true
    test_cmd: make test && ./extra check
EOF

actual=$(python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rulebook.yaml" | grep '^repo')
# test_cmd rides last on purpose (ADR 0022): a command contains spaces, and the Runner's
# `read` soaks the remainder into the final variable — so it must have no field after it.
# Every later field, test_net (ADR 0026) included, goes BEFORE it.
expected=$(printf '%s\n' \
  $'repo\tpath=/srv/no-base\tmode=branch-fix\tbase=\tfindings=5\tdimensions=\ttest_net=false\ttest_cmd=make check' \
  $'repo\tpath=/srv/no-findings\tmode=findings-only\tbase=develop\tfindings=\tdimensions=security,infra\ttest_net=false\ttest_cmd=' \
  $'repo\tpath=/srv/all-fields\tmode=branch-fix\tbase=release\tfindings=3\tdimensions=docs,tests\ttest_net=true\ttest_cmd=make test && ./extra check')

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
    test_cmd: true
EOF
python3 "$ROOT/lib/parse_rulebook.py" "$TMP/notimeout.yaml" | grep -qx $'test_timeout_seconds\t600' \
  || { echo "test-rulebook-parser: test_timeout_seconds must default to 600" >&2; exit 1; }
cat > "$TMP/zerotimeout.yaml" <<'EOF'
limits:
  test_timeout_seconds: 0
repos:
  - path: /srv/x
    mode: branch-fix
    test_cmd: true
EOF
if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/zerotimeout.yaml" >/dev/null 2>&1; then
  echo "test-rulebook-parser: test_timeout_seconds 0 must be rejected" >&2; exit 1
fi

# The gate sandbox's resource ceilings (ADR 0026) are defaulted here, not in bash — a missing
# default would reach `ulimit` as an empty string and silently apply nothing.
out=$(python3 "$ROOT/lib/parse_rulebook.py" "$TMP/notimeout.yaml")
grep -qx $'test_memory_mb\t4096' <<<"$out" \
  || { echo "test-rulebook-parser: test_memory_mb must default to 4096" >&2; exit 1; }
grep -qx $'test_max_procs\t2048' <<<"$out" \
  || { echo "test-rulebook-parser: test_max_procs must default to 2048" >&2; exit 1; }
# 0 is legitimate for both ("no cap"), unlike the timeout, where 0 would fail every gate instantly.
cat > "$TMP/zerolimits.yaml" <<'EOF'
limits:
  test_memory_mb: 0
  test_max_procs: 0
repos:
  - path: /srv/x
    mode: branch-fix
    test_cmd: true
EOF
python3 "$ROOT/lib/parse_rulebook.py" "$TMP/zerolimits.yaml" >/dev/null \
  || { echo "test-rulebook-parser: 0 must be accepted as 'no cap' for the sandbox rlimits" >&2; exit 1; }

echo "test-rulebook-parser: ok"
