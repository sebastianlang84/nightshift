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

# max_fix_iterations: 0 would make the fix<->review loop never run — reject it too.
cat > "$TMP/rulebook2.yaml" <<'EOF'
limits:
  max_fix_iterations: 0
repos:
  - path: /srv/example
    mode: branch-fix
EOF

if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rulebook2.yaml" >"$TMP/stdout" 2>"$TMP/stderr"; then
  echo "parser accepted max_fix_iterations: 0" >&2
  exit 1
fi
grep -q "limits.max_fix_iterations must be a positive integer" "$TMP/stderr"

# A malformed recon.ttl_days silently became 0 in bash arithmetic (constant recon refresh) — reject it.
cat > "$TMP/rulebook3.yaml" <<'EOF'
recon:
  ttl_days: soon
repos:
  - path: /srv/example
    mode: branch-fix
EOF

if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rulebook3.yaml" >"$TMP/stdout" 2>"$TMP/stderr"; then
  echo "parser accepted a non-numeric ttl_days" >&2
  exit 1
fi
grep -q "recon.ttl_days must be a positive integer" "$TMP/stderr"

# A bare prefix broadens the hook glob (for example, m* includes main). Require a
# slash-terminated namespace so the wildcard can only match branches beneath it.
cat > "$TMP/rulebook4.yaml" <<'EOF'
branch_prefix: m
repos:
  - path: /srv/example
    mode: branch-fix
EOF

if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/rulebook4.yaml" >"$TMP/stdout" 2>"$TMP/stderr"; then
  echo "parser accepted a branch prefix without a dedicated namespace" >&2
  exit 1
fi
grep -q "branch_prefix must name a dedicated namespace ending in '/'" "$TMP/stderr"

echo "test-rulebook-validation: ok"
