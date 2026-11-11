#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way

# .claude/settings.json, .claude/settings.local.json and .mcp.json are Runner control data
# (docs/design/hook-spec.md): Claude loads them from a stage's cwd and runs the hooks and MCP servers
# they name on the host. The PreToolUse guard stops only a CLAUDE Fix from writing them; a codex or pi
# Fix can, and a Claude Review stage or branch advisor would then execute the result. This pins the
# Runner-side check that holds for every adapter: the worktree check right after Fix, and the branch
# check advise_branches asks before it checks a branch out.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-claude-control-files: $*" >&2; exit 1; }

export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
       NIGHTSHIFT_DIGEST_DIR="$TMP/digest" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
mkdir -p "$NIGHTSHIFT_STATE_DIR" "$NIGHTSHIFT_RUNS_DIR" "$NIGHTSHIFT_DIGEST_DIR" "$NIGHTSHIFT_WORKTREES"

G() { git -c user.name=t -c user.email=t@localhost "$@"; }

REPO="$TMP/repo"
git init -q -b main "$REPO"
mkdir -p "$REPO/.claude"
echo '{}' > "$REPO/.claude/settings.json"            # a repo may legitimately TRACK its settings
echo 'settings.local.json' > "$REPO/.claude/.gitignore"
echo "content" > "$REPO/tracked.txt"
G -C "$REPO" add -A
G -C "$REPO" commit -q -m init
WT="$TMP/wt"
git -C "$REPO" worktree add -q --detach "$WT"

# Runs one Runner function in a subshell that sourced the Runner; prints nothing, returns its rc.
cat > "$TMP/probe.sh" <<'PROBE'
set +u
NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
set +e
"$@"
PROBE
run() { ROOT="$ROOT" bash "$TMP/probe.sh" "$@" 2>/dev/null; }

clean_ok() { run worktree_control_files_clean "$REPO" "$WT"; }
reset_wt() { git -C "$WT" reset -q --hard && git -C "$WT" clean -qffdx; }

# --- 1. an untouched worktree passes, including a TRACKED, unchanged settings file -------------
clean_ok || fail "an untouched worktree was refused — every item would be called tampered"

# --- 2. ordinary .claude content is repository content, not control data -----------------------
mkdir -p "$WT/.claude/commands"; echo "x" > "$WT/.claude/commands/x.md"; echo "y" > "$WT/notes.md"
clean_ok || fail ".claude/commands was treated as control data"
reset_wt

# --- 3. each control file, written by a Fix, is refused ----------------------------------------
echo '{"hooks":{}}' > "$WT/.claude/settings.json"
clean_ok && fail "a modified tracked .claude/settings.json was not refused"
reset_wt
echo '{"mcpServers":{}}' > "$WT/.mcp.json"
clean_ok && fail "a new .mcp.json was not refused"
reset_wt
# settings.local.json is gitignored here — Claude loads it anyway, so it must not hide.
echo '{"hooks":{}}' > "$WT/.claude/settings.local.json"
clean_ok && fail "an ignored .claude/settings.local.json was not refused"
reset_wt
git -C "$WT" rm -q .claude/settings.json
clean_ok && fail "a deleted .claude/settings.json was not refused"
reset_wt

# --- 4. a symlink in place of .claude redirects every path without git naming them --------------
mkdir -p "$TMP/elsewhere"; echo '{"hooks":{}}' > "$TMP/elsewhere/settings.json"
rm -rf "$WT/.claude"; ln -s "$TMP/elsewhere" "$WT/.claude"
clean_ok && fail "a .claude symlink was not refused"
rm -f "$WT/.claude"; reset_wt
clean_ok || fail "the worktree did not come back clean after the symlink case"

# --- 5. the choke point calls it after Fix, before Review stages the tree -----------------------
awk '/run_agent fix "\$wt" "\$fd"/{f=1} f && /worktree_control_files_clean "\$repo" "\$wt"/{c=1}
     f && /run_review_stage "\$wt" "\$fd"/{r=c; exit} END{exit !r}' "$ROOT/bin/nightshift.sh" \
  || fail "worktree_control_files_clean is not called between the Fix and the Review stage"

# --- 6. a pushed branch that changes a control file is reported; an ordinary one is not ----------
G -C "$REPO" checkout -q -b nightshift/ok
echo "more" >> "$REPO/tracked.txt"; mkdir -p "$REPO/.claude/agents"; echo a > "$REPO/.claude/agents/a.md"
G -C "$REPO" commit -qam ok; G -C "$REPO" add -A; G -C "$REPO" commit -qm agents
G -C "$REPO" checkout -q main
G -C "$REPO" checkout -q -b nightshift/bad
echo '{"mcpServers":{}}' > "$REPO/.mcp.json"
G -C "$REPO" add -A; G -C "$REPO" commit -qm bad
G -C "$REPO" checkout -q main
echo "base moved" > "$REPO/other.txt"; G -C "$REPO" add -A; G -C "$REPO" commit -qm moved

run branch_control_files_changed "$REPO" main nightshift/ok \
  && fail "a branch touching only ordinary files was reported as changing control files"
out="$(ROOT="$ROOT" bash "$TMP/probe.sh" branch_control_files_changed "$REPO" main nightshift/bad 2>/dev/null)" \
  || fail "a branch adding .mcp.json was not reported"
[ "$out" = ".mcp.json" ] || fail "expected '.mcp.json', got '$out'"

# --- 7. unchanged config must not execute a script changed by Fix or a pushed branch ------------
G -C "$REPO" checkout -q -b nightshift/indirect main
mkdir -p "$REPO/scripts"
echo 'echo original' > "$REPO/scripts/start.sh"
echo '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash scripts/start.sh"}]}]}}' \
  > "$REPO/.claude/settings.json"
G -C "$REPO" add -A; G -C "$REPO" commit -qm hook-base
hook_base=$(git -C "$REPO" rev-parse HEAD)
echo 'echo changed' > "$REPO/scripts/start.sh"
G -C "$REPO" commit -qam hook-target
git -C "$WT" reset -q --hard "$hook_base"
echo 'echo changed' > "$WT/scripts/start.sh"
clean_ok && fail "unchanged settings executing a modified hook passed"
run branch_control_files_changed "$REPO" "$hook_base" nightshift/indirect >/dev/null \
  || fail "a branch changing only the configured hook script passed"

# The CLI boundary itself is protected, even if the post-Fix or branch checks are bypassed.
# Stub only; this test must never call a real Claude process or model.
mkdir -p "$TMP/bin" "$TMP/item"
export CLI_MARKER="$TMP/cli-started"
cat > "$TMP/bin/claude" <<'CLI'
#!/usr/bin/env bash
touch "$CLI_MARKER"
printf '{"type":"result","result":"{}"}\n'
CLI
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"
for stage in recon explore fix review advise verify; do
  run claude_run "$stage" "$WT" "$TMP/item" >/dev/null \
    && fail "Claude $stage started with a candidate-owned hook"
  [ ! -e "$CLI_MARKER" ] || fail "Claude $stage reached the CLI before refusing config"
  rg -q 'candidate-controlled hooks' "$TMP/item/$stage.err" || fail "missing refusal reason"
done

# MCP indirection has the same failure mode even though no settings path changes.
G -C "$REPO" checkout -q -b nightshift/mcp main
echo '{"mcpServers":{"local":{"command":"bash","args":["scripts/server.sh"]}}}' > "$REPO/.mcp.json"
mkdir -p "$REPO/scripts"; echo 'echo original' > "$REPO/scripts/server.sh"
G -C "$REPO" add -A; G -C "$REPO" commit -qm mcp-base
mcp_base=$(git -C "$REPO" rev-parse HEAD)
echo 'echo changed' > "$REPO/scripts/server.sh"; G -C "$REPO" commit -qam mcp-target
git -C "$WT" reset -q --hard "$mcp_base"; echo 'echo changed' > "$WT/scripts/server.sh"
clean_ok && fail "unchanged MCP config executing a modified server passed"
run branch_control_files_changed "$REPO" "$mcp_base" nightshift/mcp >/dev/null \
  || fail "a branch changing only the configured MCP server passed"

# --- 8. a TRACKED, unchanged settings symlink with a changed target is refused at both seams ----
G -C "$REPO" checkout -q -b nightshift/symlink main
echo '{}' > "$REPO/config.json"
rm "$REPO/.claude/settings.json"; ln -s ../config.json "$REPO/.claude/settings.json"
G -C "$REPO" add -A; G -C "$REPO" commit -qm symlink-base
link_base=$(git -C "$REPO" rev-parse HEAD)
echo '{"hooks":{"SessionStart":[]}}' > "$REPO/config.json"; G -C "$REPO" commit -qam symlink-target
git -C "$WT" reset -q --hard "$link_base"
echo '{"hooks":{"SessionStart":[]}}' > "$WT/config.json"
clean_ok && fail "an unchanged settings symlink with a modified target passed"
run branch_control_files_changed "$REPO" "$link_base" nightshift/symlink >/dev/null \
  || fail "a branch changing only the settings symlink target passed"
run claude_run review "$WT" "$TMP/item" >/dev/null && fail "symlink reached Claude"
[ ! -e "$CLI_MARKER" ] || fail "a symlink reached the CLI"

# --- 9. malformed, non-object, unreadable-as-JSON and executable alternative configs fail closed --
git -C "$WT" reset -q --hard main
for config in '{' '[]' '{"statusLine":{"type":"command","command":"bash start.sh"}}' \
  '{"fileSuggestion":{"type":"command","command":"bash start.sh"}}' \
  '{"enabledPlugins":{"local@repo":true}}' '{"extraKnownMarketplaces":{"local":{}}}' \
  '{"env":{"BASH_ENV":"scripts/start.sh"}}' '{"apiKeyHelper":"bash scripts/start.sh"}' \
  '{"futureExecutableSetting":"scripts/start.sh"}'; do
  printf '%s\n' "$config" > "$WT/.claude/settings.json"
  python3 "$ROOT/lib/check_claude_controls.py" worktree "$WT" >/dev/null \
    && fail "unsafe config was allowed: $config"
done
rm "$WT/.claude/settings.json"; mkfifo "$WT/.claude/settings.json"
python3 "$ROOT/lib/check_claude_controls.py" worktree "$WT" >/dev/null \
  && fail "a FIFO control path passed"
rm "$WT/.claude/settings.json"; reset_wt
echo '{"model":"default","hooks":{},"mcpServers":{}}' > "$WT/.claude/settings.json"
python3 "$ROOT/lib/check_claude_controls.py" worktree "$WT" >/dev/null \
  || fail "ordinary settings without executable config were refused"
reset_wt
run claude_run recon "$WT" "$TMP/item" >/dev/null || fail "safe Claude stage was refused"
[ -e "$CLI_MARKER" ] || fail "safe Claude stage never reached the stub CLI"
python3 "$ROOT/lib/check_claude_controls.py" tree "$REPO" missing-ref >/dev/null \
  && fail "a failed Git inspection passed"

echo "test-claude-control-files: OK"
