#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# Stage isolation at the CLI boundary:
#   1. --setting-sources local excludes user and project settings. The repo's CLAUDE.md still loads.
#   2. --strict-mcp-config without an MCP config prevents MCP servers from loading.
#   3. CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 -> no per-cwd memory store is read or WRITTEN; the writer
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
  local settings_index
  claude_run recon "$TMP/wd" "$TMP/item" >/dev/null 2>&1 || fail "claude_run failed ($1)"
  mapfile -d '' -t ARGV < "$TMP/argv"
  [ -n "$(index_of --strict-mcp-config)" ] || fail "missing --strict-mcp-config ($1): $(show)"
  [ -z "$(index_of --mcp-config)" ] || fail "unexpected --mcp-config ($1): $(show)"
  settings_index="$(index_of --settings)"
  [ -n "$settings_index" ] && [ "${ARGV[$((settings_index + 1))]:-}" = "$STATE_DIR/claude-settings.json" ] \
    || fail "missing Runner guard settings ($1): $(show)"
}
index_of() { local i; for i in "${!ARGV[@]}"; do [ "${ARGV[$i]}" = "$1" ] && { echo "$i"; return; }; done; }
show() { printf '[%s] ' "${ARGV[@]}"; }

# (a) DEFAULT (env unset) -> the isolation is ON. This is the whole point: an operator who does
# nothing must still get a stage that cannot see ~/.claude/CLAUDE.md.
unset NIGHTSHIFT_CLAUDE_SETTING_SOURCES NIGHTSHIFT_CLAUDE_FLAGS
invoke default
i="$(index_of --setting-sources)"; [ -n "$i" ] || fail "default must pass --setting-sources: $(show)"
[ "${ARGV[$((i + 1))]:-}" = local ] || fail "default sources must be local: $(show)"
[ "$(cat "$TMP/env")" = 1 ] || fail "stage env must carry CLAUDE_CODE_DISABLE_AUTO_MEMORY=1: $(cat "$TMP/env")"

# (b) explicit EMPTY lets the CLI load its default sources. There is no flag or empty argument.
export NIGHTSHIFT_CLAUDE_SETTING_SOURCES=""
invoke empty
[ -z "$(index_of --setting-sources)" ] || fail "empty override must not pass --setting-sources: $(show)"
[ -z "$(index_of '')" ] || fail "empty override must not pass an empty argument: $(show)"
# The memory lever is NOT tied to the escape hatch — the R8 write path stays closed regardless.
[ "$(cat "$TMP/env")" = 1 ] || fail "CLAUDE_CODE_DISABLE_AUTO_MEMORY must survive the escape hatch"

# (c) a single scope is passed as an adjacent flag/value pair.
export NIGHTSHIFT_CLAUDE_SETTING_SOURCES=project
invoke custom
i="$(index_of --setting-sources)"; [ -n "$i" ] || fail "custom value must pass --setting-sources: $(show)"
[ "${ARGV[$((i + 1))]:-}" = project ] || fail "--setting-sources must carry the env value: $(show)"

# (d) whitespace around each scope is removed and the canonical list stays one argument.
export NIGHTSHIFT_CLAUDE_SETTING_SOURCES=' user , project, local '
invoke spaced
i="$(index_of --setting-sources)"; [ -n "$i" ] || fail "spaced value must still pass the flag: $(show)"
[ "${ARGV[$((i + 1))]:-}" = user,project,local ] || fail "expected canonical sources as one argument: $(show)"

# Ordinary overrides still reach Claude. Runner-owned flags are refused in both forms.
NIGHTSHIFT_CLAUDE_FLAGS=$'--max-turns 8\n--verbose' invoke flags
i="$(index_of --max-turns)"; [ -n "$i" ] || fail "missing --max-turns override: $(show)"
[ "${ARGV[$((i + 1))]:-}" = 8 ] || fail "expected overridden --max-turns: $(show)"
[ -n "$(index_of --verbose)" ] || fail "missing --verbose override: $(show)"
rm "$TMP/argv"
for flag in --mcp-config --setting-sources --settings; do
  for override in "$flag test-value" "$flag=test-value"; do
    rc=0
    output="$(NIGHTSHIFT_CLAUDE_FLAGS=$'--max-turns 8\n'"$override" claude_run recon "$TMP/wd" "$TMP/item" 2>&1)" || rc=$?
    [ "$rc" = 2 ] || fail "expected status 2 for reserved flag $override, got $rc"
    [[ "$output" == *"NIGHTSHIFT_CLAUDE_FLAGS contains reserved flag $flag"* ]] || fail "missing reserved flag diagnostic: $output"
    [ ! -e "$TMP/argv" ] || fail "Claude received the reserved flag $override"
  done
done

echo "test-claude-context-isolation: ok"
