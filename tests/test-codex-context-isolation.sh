#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# Stage isolation, codex half (ADR 0019). `--ignore-user-config` and `--ignore-rules` do NOT cover
# $CODEX_HOME/AGENTS.md, so the operator's global instructions reach the stage. The only lever that
# separates the scopes is the home itself: a Runner-owned CODEX_HOME with no AGENTS.md drops the
# global file while the target repo's own AGENTS.md still loads. So what this test guards is the
# INVARIANT that makes the isolation work — the stage home must carry credentials and nothing else.
# A stub `codex` on PATH records the CODEX_HOME it was handed; the adapter runs via NIGHTSHIFT_SOURCED=1.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/wd" "$TMP/item" "$TMP/real-codex"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Stand in for the operator's real ~/.codex: credentials plus exactly the personal-config surface
# this isolation exists to keep out of a stage.
printf '{"tokens":"fake"}\n' > "$TMP/real-codex/auth.json"
printf 'Always answer in the operator private style.\n' > "$TMP/real-codex/AGENTS.md"
printf 'model = "operator-pin"\n' > "$TMP/real-codex/config.toml"

cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$CODEX_HOME" != "$OPERATOR_HOME" && "$HOME" = "$CODEX_HOME" ]]
[ ! -e "$CODEX_HOME/AGENTS.md" ]
[ ! -e "$CODEX_HOME/config.toml" ]
[ ! -e "$HOME/.agents/skills" ]
for dir in "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"; do
  [[ "$dir" = "$HOME/"* ]]
done
if [ -e "$OPERATOR_HOME/auth.json" ]; then
  [ "$CODEX_HOME/auth.json" -ef "$OPERATOR_HOME/auth.json" ]
else
  [ ! -e "$CODEX_HOME/auth.json" ]
fi
printf '%s' "$CODEX_HOME" > "$NIGHTSHIFT_TEST_HOME"
out=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
cat >/dev/null
[ -z "$out" ] || printf '{}\n' > "$out"     # codex writes the stage answer itself, via -o
printf '%s\n' '{"type":"turn.completed","usage":{"output_tokens":1}}'
EOF
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"

export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
       NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
export CODEX_HOME="$TMP/real-codex" OPERATOR_HOME="$TMP/real-codex"
mkdir -p "$TMP/user-home/.agents/skills"
export HOME="$TMP/user-home"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"

export NIGHTSHIFT_TEST_HOME="$TMP/home"
invoke() {
  codex_run recon "$TMP/wd" "$TMP/item" >/dev/null 2>&1 || fail "codex_run failed ($1)"
  HANDED="$(cat "$TMP/home")"
}

invoke default
[ ! -e "$HANDED" ] || fail "stage home survived the stage"
first="$HANDED"
invoke second
[ "$first" != "$HANDED" ] || fail "separate stages shared a home"

rm -f "$OPERATOR_HOME/auth.json"
invoke no-credentials
[ ! -e "$HANDED" ] || fail "unauthenticated stage retained a home"

echo "test-codex-context-isolation: ok"
