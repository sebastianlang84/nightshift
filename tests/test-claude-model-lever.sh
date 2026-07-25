#!/usr/bin/env bash
set -euo pipefail

# NIGHTSHIFT_CLAUDE_MODEL is an OPTIONAL per-host lever (mirrors NIGHTSHIFT_CODEX_MODEL), not a
# second default: unset MUST invoke `claude` with no --model at all, so the nightly model stays
# whatever the CLI itself resolves. Set MUST pass --model <value> through verbatim. A stub `claude`
# on PATH records its own argv; the adapter is exercised directly via NIGHTSHIFT_SOURCED=1.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/wd" "$TMP/item"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Stub the first-party CLI boundary only: dump argv (NUL-separated, so no flag value can be
# mistaken for a separate argument), then emit the result-object shape claude_run parses.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "$NIGHTSHIFT_TEST_ARGV"
jq -nc '{type:"result",result:"{}",usage:{output_tokens:1},total_cost_usd:0.01}'
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"

export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
       NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"

# claude_run reads $STATE_DIR/claude-settings.json only as a path argument; an empty file is enough.
: > "$STATE_DIR/claude-settings.json"

# runs one recon stage through claude_run and loads the stub's argv into the ARGV array. Argument
# boundaries matter here, and the prompt argument itself is multi-line — so never compare line-wise.
export NIGHTSHIFT_TEST_ARGV="$TMP/argv"
invoke() {
  claude_run recon "$TMP/wd" "$TMP/item" >/dev/null 2>&1 || fail "claude_run failed ($1)"
  mapfile -d '' -t ARGV < "$TMP/argv"
}
# index of the first argument equal to $1, or "" if absent
index_of() { local i; for i in "${!ARGV[@]}"; do [ "${ARGV[$i]}" = "$1" ] && { echo "$i"; return; }; done; }
show() { printf '[%s] ' "${ARGV[@]}"; }

# (a) unset -> NO --model anywhere in the invocation, and no stray empty argument in its place.
unset NIGHTSHIFT_CLAUDE_MODEL
invoke unset
[ -z "$(index_of --model)" ] || fail "unset NIGHTSHIFT_CLAUDE_MODEL must not pass --model: $(show)"
[ -z "$(index_of '')" ] || fail "unset NIGHTSHIFT_CLAUDE_MODEL must not pass an empty argument: $(show)"
[ -n "$(index_of --output-format)" ] || fail "stub did not receive the runner-owned flags: $(show)"

# (b) set -> --model <value> passed through verbatim, as an adjacent flag/value pair.
export NIGHTSHIFT_CLAUDE_MODEL=test-model
invoke set
i="$(index_of --model)"; [ -n "$i" ] || fail "NIGHTSHIFT_CLAUDE_MODEL=test-model must pass --model: $(show)"
[ "${ARGV[$((i + 1))]:-}" = test-model ] || fail "--model must be followed by the env value: $(show)"

# (c) a value with a space stays ONE argument (array expansion, not word splitting).
export NIGHTSHIFT_CLAUDE_MODEL='model with space'
invoke spaced
i="$(index_of --model)"; [ -n "$i" ] || fail "spaced value must still pass --model: $(show)"
[ "${ARGV[$((i + 1))]:-}" = 'model with space' ] || fail "model value must survive as ONE argument: $(show)"

echo "test-claude-model-lever: ok"
