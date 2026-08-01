#!/usr/bin/env bash
set -euo pipefail

# The rulebook's `agent:` block declares which model a stage runs on (ADR 0020). It exists because
# stage isolation (ADR 0019) drops the CLI's `user` settings scope, so a machine-wide pin in
# ~/.claude/settings.json can no longer reach a stage — the host declares the model in its own
# governance file instead. Precedence under test: NIGHTSHIFT_*_MODEL if SET (an explicitly EMPTY
# value is the escape hatch and must beat the rulebook) > rulebook > nothing at all.
# A stub `claude` on PATH records its own argv, NUL-separated so no flag value can be mistaken for
# a separate argument.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/wd" "$TMP/item"

fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "$NIGHTSHIFT_TEST_ARGV"
jq -nc '{type:"result",result:"{}",usage:{output_tokens:1},total_cost_usd:0.01}'
EOF
chmod +x "$TMP/bin/claude"
# The codex half needs its own stub: the two adapters build argv independently, so a claude-only
# test would pass while codex_run ignored the rulebook, used the wrong `${VAR:-}` form (breaking the
# empty escape hatch), or mis-split the value.
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "$NIGHTSHIFT_TEST_ARGV"
out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
[ -z "$out" ] || printf '%s' '{}' > "$out"
cat >/dev/null
printf '%s\n' '{"type":"turn.completed","usage":{"output_tokens":1}}'
EOF
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"

# A rulebook that declares BOTH adapters' models. `repos:` must stay valid — load_rulebook fails
# closed on a parse error, which would make every assertion below meaningless.
cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
agent:
  claude_model: rulebook-claude-model
  codex_model: rulebook-codex-model
limits:
  max_open_branches: 1
recon:
  enabled: true
dimensions:
  - correctness
repos:
  - path: $TMP/wd
    mode: findings-only
EOF

export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
       NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
export RULEBOOK="$TMP/rulebook.yaml"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
load_rulebook

# The parser must surface BOTH adapters' keys, not just the one the claude path exercises below.
[ "$RB_CLAUDE_MODEL" = rulebook-claude-model ] || fail "rulebook claude_model not loaded: '$RB_CLAUDE_MODEL'"
[ "$RB_CODEX_MODEL"  = rulebook-codex-model  ] || fail "rulebook codex_model not loaded: '$RB_CODEX_MODEL'"

: > "$STATE_DIR/claude-settings.json"
export NIGHTSHIFT_TEST_ARGV="$TMP/argv"
# The argv file is DELETED before every call. Putting the adapter on the left of `||` suspends
# errexit inside it, so a failure part-way through would leave the PREVIOUS call's argv in place and
# every assertion below would then pass against stale, valid-looking data.
invoke() { # label adapter_fn
  rm -f "$TMP/argv"
  "$2" recon "$TMP/wd" "$TMP/item" >/dev/null 2>&1 || fail "$2 failed ($1)"
  [ -f "$TMP/argv" ] || fail "$2 never reached the stub ($1)"
  mapfile -d '' -t ARGV < "$TMP/argv"
}
index_of() { local i; for i in "${!ARGV[@]}"; do [ "${ARGV[$i]}" = "$1" ] && { echo "$i"; return; }; done; }
show() { printf '[%s] ' "${ARGV[@]}"; }

# Both adapters get the identical four-case treatment: the precedence rule is shared, but the argv
# construction is not, so proving it once proves only one of them.
check_precedence() { # adapter_fn env_var rulebook_var rulebook_value
  local fn="$1" env_var="$2" rb_var="$3" rb_value="$4" i

  # (a) env unset -> the rulebook's value reaches the CLI.
  unset "$env_var"
  invoke "$fn/rulebook" "$fn"
  i="$(index_of --model)"; [ -n "$i" ] || fail "$fn: rulebook model must pass --model: $(show)"
  [ "${ARGV[$((i + 1))]:-}" = "$rb_value" ] || fail "$fn: --model must carry the rulebook value: $(show)"

  # (b) env set -> it wins; the rulebook is the weaker layer, not an override of the operator.
  export "$env_var=env-model"
  invoke "$fn/env-wins" "$fn"
  i="$(index_of --model)"; [ -n "$i" ] || fail "$fn: env $env_var must pass --model: $(show)"
  [ "${ARGV[$((i + 1))]:-}" = env-model ] || fail "$fn: env value must beat the rulebook: $(show)"

  # (c) env set but EMPTY -> the escape hatch. It must beat a rulebook that declares a model,
  # otherwise a configured host has no way back to the CLI's own default. This is exactly what
  # `${VAR:-…}` would break and `${VAR-…}` preserves.
  export "$env_var="
  invoke "$fn/escape-hatch" "$fn"
  [ -z "$(index_of --model)" ] || fail "$fn: empty $env_var must suppress --model: $(show)"
  [ -z "$(index_of '')" ] || fail "$fn: empty $env_var must not pass an empty argument: $(show)"

  # (d) neither layer declares a model -> no --model at all; the CLI resolves its own default.
  unset "$env_var"
  printf -v "$rb_var" '%s' ""
  invoke "$fn/neither" "$fn"
  [ -z "$(index_of --model)" ] || fail "$fn: no declared model must pass no --model: $(show)"
  printf -v "$rb_var" '%s' "$rb_value"

  # (e) a value with a space stays ONE argument (array expansion, not word splitting).
  printf -v "$rb_var" '%s' 'model with space'
  invoke "$fn/spaced" "$fn"
  i="$(index_of --model)"; [ -n "$i" ] || fail "$fn: spaced value must still pass --model: $(show)"
  [ "${ARGV[$((i + 1))]:-}" = 'model with space' ] || fail "$fn: value must survive as ONE argument: $(show)"
  printf -v "$rb_var" '%s' "$rb_value"
}

check_precedence claude_run NIGHTSHIFT_CLAUDE_MODEL RB_CLAUDE_MODEL rulebook-claude-model
check_precedence codex_run  NIGHTSHIFT_CODEX_MODEL  RB_CODEX_MODEL  rulebook-codex-model

# (f) the SELECTION is announced, never silent — a host that lost its pin must see it. What the run
# can announce is the model it requests and where that came from; which model actually served the
# stage is only knowable afterwards, from runs.jsonl `model_id`.
out="$(log_model_selection claude NIGHTSHIFT_CLAUDE_MODEL rulebook-claude-model 2>&1)"
case "$out" in *rulebook-claude-model*rulebook*) ;; *) fail "rulebook source not announced: $out" ;; esac
out="$(log_model_selection claude NIGHTSHIFT_CLAUDE_MODEL "" 2>&1)"
case "$out" in *"not declared"*) ;; *) fail "undeclared model not announced: $out" ;; esac

echo "test-rulebook-agent-model: ok"
