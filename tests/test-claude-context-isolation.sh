#!/usr/bin/env bash
set -euo pipefail

# Stage isolation from the operator's personal Claude Code config. Two mechanisms, both runner-owned:
#   1. --setting-sources project,local  -> the CLI loads project+local settings scopes only, so
#      ~/.claude/settings.json and ~/.claude/CLAUDE.md are out while the TARGET repo's own CLAUDE.md
#      stays in. Without it, personal chat-language/convention rules reached pushed commit bodies.
#   2. CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 -> no per-cwd memory store is read or WRITTEN; the writer
#      is a write path outside the worktree that the PreToolUse guard never sees (R8).
# NIGHTSHIFT_CLAUDE_SETTING_SOURCES is the escape hatch (empty = pass no flag), so it needs the same
# unset/set/spaced treatment as the model lever. A stub `claude` on PATH records argv AND the env.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/wd" "$TMP/item"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Stub the first-party CLI boundary only: dump argv (NUL-separated, so no flag value can be
# mistaken for a separate argument) plus the one env var under test, then emit the result shape.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "$NIGHTSHIFT_TEST_ARGV"
printf '%s' "${CLAUDE_CODE_DISABLE_AUTO_MEMORY-<unset>}" > "$NIGHTSHIFT_TEST_ENV"
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

export NIGHTSHIFT_TEST_ARGV="$TMP/argv" NIGHTSHIFT_TEST_ENV="$TMP/env"
invoke() {
  claude_run recon "$TMP/wd" "$TMP/item" >/dev/null 2>&1 || fail "claude_run failed ($1)"
  mapfile -d '' -t ARGV < "$TMP/argv"
}
index_of() { local i; for i in "${!ARGV[@]}"; do [ "${ARGV[$i]}" = "$1" ] && { echo "$i"; return; }; done; }
show() { printf '[%s] ' "${ARGV[@]}"; }

# (a) DEFAULT (env unset) -> the isolation is ON. This is the whole point: an operator who does
# nothing must still get a stage that cannot see ~/.claude/CLAUDE.md.
unset NIGHTSHIFT_CLAUDE_SETTING_SOURCES
invoke default
i="$(index_of --setting-sources)"; [ -n "$i" ] || fail "default must pass --setting-sources: $(show)"
[ "${ARGV[$((i + 1))]:-}" = project,local ] \
  || fail "default sources must be project,local (user scope excluded): $(show)"
[ "$(cat "$TMP/env")" = 1 ] || fail "stage env must carry CLAUDE_CODE_DISABLE_AUTO_MEMORY=1: $(cat "$TMP/env")"

# (b) explicit EMPTY -> no flag at all, and no stray empty argument in its place (escape hatch for a
# CLI too old to know the option). Distinct from unset, hence the ${VAR-default} form in the runner.
export NIGHTSHIFT_CLAUDE_SETTING_SOURCES=""
invoke empty
[ -z "$(index_of --setting-sources)" ] || fail "empty override must not pass --setting-sources: $(show)"
[ -z "$(index_of '')" ] || fail "empty override must not pass an empty argument: $(show)"
# The memory lever is NOT tied to the escape hatch — the R8 write path stays closed regardless.
[ "$(cat "$TMP/env")" = 1 ] || fail "CLAUDE_CODE_DISABLE_AUTO_MEMORY must survive the escape hatch"

# (c) custom value passed through verbatim, as an adjacent flag/value pair.
export NIGHTSHIFT_CLAUDE_SETTING_SOURCES=project
invoke custom
i="$(index_of --setting-sources)"; [ -n "$i" ] || fail "custom value must pass --setting-sources: $(show)"
[ "${ARGV[$((i + 1))]:-}" = project ] || fail "--setting-sources must carry the env value: $(show)"

# (d) a value with a space stays ONE argument (array expansion, not word splitting).
export NIGHTSHIFT_CLAUDE_SETTING_SOURCES='project, local'
invoke spaced
i="$(index_of --setting-sources)"; [ -n "$i" ] || fail "spaced value must still pass the flag: $(show)"
[ "${ARGV[$((i + 1))]:-}" = 'project, local' ] || fail "value must survive as ONE argument: $(show)"

echo "test-claude-context-isolation: ok"
