#!/usr/bin/env bash
set -euo pipefail

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
printf '%s' "${CODEX_HOME-<unset>}" > "$NIGHTSHIFT_TEST_HOME"
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
export CODEX_HOME="$TMP/real-codex"
# shellcheck disable=SC1090
NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"

export NIGHTSHIFT_TEST_HOME="$TMP/home"
invoke() {
  codex_run recon "$TMP/wd" "$TMP/item" >/dev/null 2>&1 || fail "codex_run failed ($1)"
  HANDED="$(cat "$TMP/home")"
}

# (a) DEFAULT -> the stage runs under a Runner-owned home, NOT the operator's.
unset NIGHTSHIFT_CODEX_STAGE_HOME
invoke default
[ "$HANDED" != "$TMP/real-codex" ] || fail "default must not hand the operator's CODEX_HOME to a stage"
[ "$HANDED" = "$TMP/state/codex-home" ] || fail "default stage home must live under STATE_DIR: $HANDED"

# The invariant: credentials carried over, personal config left behind. A stage home that ever gains
# an AGENTS.md is the whole leak back again, so assert absence explicitly rather than by file count.
[ -e "$HANDED/auth.json" ] || fail "stage home must carry credentials"
[ "$(readlink -f "$HANDED/auth.json")" = "$(readlink -f "$TMP/real-codex/auth.json")" ] \
  || fail "auth.json must resolve to the operator's real credential file"
[ ! -e "$HANDED/AGENTS.md" ] || fail "stage home must NOT contain AGENTS.md — that is the leak"
[ ! -e "$HANDED/config.toml" ] || fail "stage home must NOT contain config.toml"

# (b) a stale credential symlink self-heals (the operator re-logs in and auth.json is replaced).
rm -f "$HANDED/auth.json"; ln -s "$TMP/real-codex/gone.json" "$HANDED/auth.json"
invoke relink
[ "$(readlink -f "$HANDED/auth.json")" = "$(readlink -f "$TMP/real-codex/auth.json")" ] \
  || fail "a stale credential symlink must be re-pointed on the next stage"

# (c) explicit EMPTY -> the escape hatch runs under the operator's real home (leak reopened, on purpose).
export NIGHTSHIFT_CODEX_STAGE_HOME=""
invoke escape
[ "$HANDED" = "$TMP/real-codex" ] || fail "empty override must fall back to the real home: $HANDED"

# (d) a custom path is honoured verbatim, and gets the same credentials-only treatment.
export NIGHTSHIFT_CODEX_STAGE_HOME="$TMP/custom home"
invoke custom
[ "$HANDED" = "$TMP/custom home" ] || fail "custom stage home must survive as ONE path: $HANDED"
[ -e "$HANDED/auth.json" ] || fail "custom stage home must carry credentials too"
[ ! -e "$HANDED/AGENTS.md" ] || fail "custom stage home must not contain AGENTS.md"

echo "test-codex-context-isolation: ok"
