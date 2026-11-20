#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

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
    test_robind: /opt/dep/.git:/srv/shared
    protected_paths: .//hooks/, lib//sandbox.sh
    test_cmd: make test && ./extra check
EOF

# Every repo key appears in the output, an absent optional one as "" or [].
actual=$(python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rulebook.yaml" | jq -cS '.repos')
expected=$(jq -cS . <<'EOF'
[{"path":"/srv/no-base","mode":"branch-fix","base":"","findings":"5","dimensions":[],"test_net":"false",
  "test_robind":"","protected_paths":[],"test_cmd":"make check"},
 {"path":"/srv/no-findings","mode":"findings-only","base":"develop","findings":"","dimensions":["security","infra"],
  "test_net":"false","test_robind":"","protected_paths":[],"test_cmd":""},
 {"path":"/srv/all-fields","mode":"branch-fix","base":"release","findings":"3","dimensions":["docs","tests"],
  "test_net":"true","test_robind":"/opt/dep/.git:/srv/shared","protected_paths":["hooks/","lib/sandbox.sh"],
  "test_cmd":"make test && ./extra check"}]
EOF
)
[ "$actual" = "$expected" ] || { echo "test-rulebook-parser: repos: $actual" >&2; exit 1; }

# A relative test_robind entry would resolve against whatever directory the Runner is in — reject it.
cat > "$TMP/relative-robind.yaml" <<'EOF2'
repos:
  - path: /srv/rel
    mode: branch-fix
    test_robind: /opt/ok:dep/.git
    test_cmd: make test
EOF2
if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/relative-robind.yaml" >/dev/null 2>"$TMP/stderr"; then
  echo "test-rulebook-parser: a relative test_robind entry must be rejected" >&2; exit 1
fi
grep -q "test_robind entries must be absolute paths" "$TMP/stderr"

# A tab is never part of a test_robind or protected_paths entry; one typed for the separator would
# merge two entries into one that matches nothing. Refuse it with the key's own message.
printf 'repos:\n  - path: /srv/t\n    mode: branch-fix\n    test_cmd: true\n    test_robind: /opt/a\t/opt/b\n' \
  > "$TMP/tab-robind.yaml"
if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/tab-robind.yaml" >/dev/null 2>"$TMP/stderr"; then
  echo "test-rulebook-parser: a tab in test_robind must be rejected" >&2; exit 1
fi
grep -q "test_robind must not contain a tab" "$TMP/stderr"
printf 'repos:\n  - path: /srv/t\n    mode: findings-only\n    protected_paths: hooks/\tlib/sandbox.sh\n' \
  > "$TMP/tab-protected.yaml"
if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/tab-protected.yaml" >/dev/null 2>"$TMP/stderr"; then
  echo "test-rulebook-parser: a tab in protected_paths must be rejected" >&2; exit 1
fi
grep -q "protected_paths entries must be paths inside the repo" "$TMP/stderr"
cat > "$TMP/removed-setup.yaml" <<EOF
repos:
  - path: /srv/setup
    mode: branch-fix
    setup_cmd: make deps
    test_cmd: make test
EOF
if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/removed-setup.yaml" >/dev/null 2>&1; then
  echo "test-rulebook-parser: the removed setup_cmd key (ADR 0037, ADR 0044) must be rejected" >&2; exit 1
fi

# protected_paths stay inside the repo (ADR 0042).
for bad in /etc/passwd ../other hooks/../../x ./ . .//hooks/../..; do
  printf 'repos:\n  - path: /srv/p\n    mode: findings-only\n    protected_paths: %s\n' "$bad" > "$TMP/prot.yaml"
  if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/prot.yaml" >/dev/null 2>&1; then
    echo "test-rulebook-parser: protected_paths accepted $bad" >&2; exit 1
  fi
done

# test_timeout_seconds: defaulted when absent, validated when present.
cat > "$TMP/notimeout.yaml" <<'EOF'
repos:
  - path: /srv/x
    mode: branch-fix
    test_cmd: true
EOF
python3 "$ROOT/lib/parse_rulebook.py" "$TMP/notimeout.yaml" | jq -e '.limits.test_timeout_seconds == "600"' >/dev/null \
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
jq -e '.limits.test_memory_mb == "4096"' <<<"$out" >/dev/null \
  || { echo "test-rulebook-parser: test_memory_mb must default to 4096" >&2; exit 1; }
jq -e '.limits.test_max_procs == "2048"' <<<"$out" >/dev/null \
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

# The change-size guidance limits, unlike the rlimits above, have no "no cap" meaning: 0 and
# non-numeric values are refused, and the defaults stand when the keys are absent.
for key in max_files_per_change max_lines_per_change; do
  for bad in 0 x -3; do
    printf '%s\n' limits: "  $key: $bad" repos: '  - path: /srv/x' '    mode: findings-only' \
      > "$TMP/badsize.yaml"
    if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/badsize.yaml" >/dev/null 2>"$TMP/badsize.err"; then
      echo "test-rulebook-parser: $key: $bad must be refused" >&2; exit 1
    fi
    grep -q "limits.$key must be a positive integer" "$TMP/badsize.err" \
      || { echo "test-rulebook-parser: $key: $bad refused for the wrong reason" >&2; exit 1; }
  done
done
jq -e '.limits.max_files_per_change == "15" and .limits.max_lines_per_change == "400"' <<<"$out" >/dev/null \
  || { echo "test-rulebook-parser: change-size limits must default to 15 / 400" >&2; exit 1; }

echo "test-rulebook-parser: ok"
