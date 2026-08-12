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

# The `agent:` block decides which MODEL does the work (ADR 0020). Every way of getting it subtly
# wrong must fail loudly, because the fallback — running the night on the CLI's own default — is
# silent and is the exact failure this block exists to prevent. Each case below produced a valid
# parse with an empty model before it was rejected.
reject() { # label yaml-body expected-message
  printf '%s\nrepos:\n  - path: /srv/example\n    mode: findings-only\n' "$2" > "$TMP/agent.yaml"
  if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/agent.yaml" >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "parser accepted $1" >&2
    exit 1
  fi
  grep -q "$3" "$TMP/stderr" || {
    echo "$1: wrong error: $(cat "$TMP/stderr")" >&2
    exit 1
  }
}
reject "an unknown agent key"       'agent:
  claude-model: m'                  "agent: unknown key 'claude-model'"
reject "a duplicated agent key"     'agent:
  claude_model: a
  claude_model: b'                  "agent: duplicate key 'claude_model'"
reject "an agent key with no value" 'agent:
  claude_model:'                    "agent.claude_model is empty"
reject "an agent key with no colon" 'agent:
  claude_model'                     'agent: expected `key: value`'
reject "an unterminated quote"      'agent:
  claude_model: "m'                 "unterminated quoted value"

# The same standard applies to EVERY mapping section, not just `agent:`. Each section's key set is
# closed — the parser reads exactly those keys — so a key outside one is a typo, and the only other
# outcome is the knob silently reverting to a default the human never wrote: `max_open_branchs: 12`
# capping throughput at 2, a misspelled `ttl_days` resetting recon's TTL.
reject "an unknown limits key"      'limits:
  max_open_branchs: 12'             "limits: unknown key 'max_open_branchs'"
reject "a duplicated limits key"    'limits:
  max_open_branches: 2
  max_open_branches: 9'             "limits: duplicate key 'max_open_branches'"
reject "a limits key with no colon" 'limits:
  max_open_branches 2'              'limits: expected `key: value`'
reject "an unknown recon key"       'recon:
  ttl-days: 3'                      "recon: unknown key 'ttl-days'"

# A repo entry's keys are closed too, and this is the misconfig with the widest blast radius:
# `test-cmd:` parsed clean and left `test_cmd` empty, so the repo shipped UNGATED past its
# ADR 0022 ship gate — the human had written a gate and never got one.
cat > "$TMP/repo-key.yaml" <<'EOF'
repos:
  - path: /srv/example
    mode: branch-fix
    test-cmd: bash tests/run.sh
EOF
if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/repo-key.yaml" >"$TMP/stdout" 2>"$TMP/stderr"; then
  echo "parser accepted an unknown repo key" >&2
  exit 1
fi
grep -q "repos: unknown key 'test-cmd'" "$TMP/stderr"
# Tabs measure as indent 0, so a tab-indented key reads as a new top-level line and its whole
# section is silently lost — for `repos:` that would drop the fleet, not just a model.
printf 'agent:\n\tclaude_model: m\nrepos:\n  - path: /srv/x\n    mode: findings-only\n' > "$TMP/tabs.yaml"
if python3 "$ROOT/lib/parse_rulebook.py" "$TMP/tabs.yaml" >"$TMP/stdout" 2>"$TMP/stderr"; then
  echo "parser accepted tab indentation" >&2
  exit 1
fi
grep -q "indent with spaces, not tabs" "$TMP/stderr"

# Accepted shapes: a commented section header (it used to demote the section to "none" and drop
# every entry under it), and quoted scalars — including a `#` inside quotes, which the unquoted
# inline-comment rule would truncate.
cat > "$TMP/agent-ok.yaml" <<'EOF'
agent:   # the model this host runs its nights on
  claude_model: "claude-opus-5"
  codex_model: 'gpt-5 #2'
repos:
  - path: /srv/example
    mode: findings-only
EOF
python3 "$ROOT/lib/parse_rulebook.py" "$TMP/agent-ok.yaml" > "$TMP/stdout"
grep -qx "$(printf 'claude_model\tclaude-opus-5')" "$TMP/stdout" || {
  echo "quoted claude_model not unquoted: $(grep claude_model "$TMP/stdout")" >&2
  exit 1
}
grep -qx "$(printf 'codex_model\tgpt-5 #2')" "$TMP/stdout" || {
  echo "quoted codex_model with '#' mangled: $(grep codex_model "$TMP/stdout")" >&2
  exit 1
}

# The shipped example is the reference rulebook and the fallback every entry point parses when a host
# has no rulebook.yaml, so it must stay inside those closed key sets: a knob documented there but
# absent from the parser's sets would now abort every night rather than being quietly ignored.
python3 "$ROOT/lib/parse_rulebook.py" "$ROOT/rulebook.example.yaml" >/dev/null || {
  echo "rulebook.example.yaml no longer parses — a documented key is outside the parser's key sets" >&2
  exit 1
}

echo "test-rulebook-validation: ok"
