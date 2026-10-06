#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# ADR 0037: a Fix stage that can execute commands (codex) starts from a worktree whose dependencies
# are installed and with the repo's toolchain first on PATH — and the ship gate never runs on what
# that left behind. Regression for the night of 2026-10-01: every codex Fix stage on partflow found
# node v18 first on PATH, no node_modules, no network and a read-only pnpm store, so all five
# branches shipped with checks the Fix stage had never run.
#
# Asserted through the real codex adapter, with only the CLI binary faked:
#   1. the repo's `setup_cmd` has run in the worktree before the Fix stage starts;
#   2. NIGHTSHIFT_CODEX_PATH is first on the codex subprocess's PATH, it does not decide which
#      `codex` runs, and it never reaches the Runner's own PATH (R10/N4);
#   3. an ignored file the Fix stage leaves behind is purged before the gate, so the gate does not
#      run on dependencies a stage could have written;
#   4. a failed setup does not stop the Fix stage — the gate decides, not the setup;
#   5. ignored files the purge cannot remove refuse the item instead of reaching the gate;
#   6. a setup that writes outside .gitignore refuses the item, and a store the setup left in the
#      worktree is the one pnpm is pointed at;
#   7. a file a stage wrote into a submodule path, which no git listing shows, refuses the item;
#   8. that hermeticity check compares bytes, so a rewrite under an unchanged status, or one git's
#      eol normalisation hides, is caught.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { echo "test-fix-stage-provisioning: $*" >&2; exit 1; }

# The ship gate's sandbox needs bwrap and user namespaces; without them the suite opts out the
# documented way, and every assertion below still holds.
command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / true 2>/dev/null \
  || export NIGHTSHIFT_TEST_SANDBOX=none

mkdir -p "$TMP/bin" "$TMP/toolchain"
# Stands in for ~/.nvm/versions/node/vX/bin: the tool the repo's checks need, plus a `git` and a
# `codex` that fail loudly. The Runner shells out to git constantly, and the adapter must have
# resolved its binary before the toolchain went in front.
printf '#!/usr/bin/env bash\necho toolchain\n' > "$TMP/toolchain/repo-node"
printf '#!/usr/bin/env bash\necho "SHADOWED: toolchain git used by the Runner" >&2; exit 66\n' > "$TMP/toolchain/git"
printf '#!/usr/bin/env bash\necho "SHADOWED: toolchain codex ran" >&2; exit 67\n' > "$TMP/toolchain/codex"
chmod +x "$TMP/toolchain/"*
# A competing `repo-node` on the Runner's own PATH, as /usr/bin/node competes with nvm's: appending
# the toolchain instead of prepending it would let this one win.
printf '#!/usr/bin/env bash\necho system\n' > "$TMP/bin/repo-node"
chmod +x "$TMP/bin/repo-node"

cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="" prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
prompt=$(cat)
case "$prompt" in
  *"EXPLORE stage"*)
    # The depth receipt (ADR 0029) must name every tracked path in a repo this small. /usr/bin/git,
    # because this process sees the toolchain dir first, and its `git` is a tripwire.
    files="$(/usr/bin/git -c core.quotePath=false ls-files | jq -R . | jq -sc .)"
    checks="$(/usr/bin/git -c core.quotePath=false ls-files | sed 's/^/checked /' | jq -R . | jq -sc .)"
    jq -nc --argjson f "$files" --argjson c "$checks" '{found:true,coverage:{files:$f,entrypoints:["README -> rendered documentation"],checks:$c,invariants:{config_domain:"not-applicable: no config",semantic_sets:"not-applicable: no sets",artifact_identity:"checked: one README artifact",failure_translation:"checked: explicit result JSON",lifecycle:"not-applicable: no lifecycle"},unresolved:[]},findings:[{file:"README.md",type:"typo",line_window:"L1-L3",claim:"README contains teh",verify:"search README for teh",verifiability:"static",disposition:"fix",summary:"fix typo",fingerprint:"README.md:typo:L1-L3",rank:1,confidence:1.0}]}' > "$out" ;;
  *"FIX stage"*)
    if [ "${EXPECT_SETUP:-1}" = 1 ]; then
      [ -f deps/installed ] || echo "setup had not run before the Fix stage" >> "$PROBE"
      [ -n "${pnpm_config_store_dir:-}" ] && [ "$pnpm_config_store_dir" -ef .pnpm-store ] \
        || echo "pnpm not pointed at the setup's store: ${pnpm_config_store_dir:-unset}" >> "$PROBE"
    elif [ -n "${pnpm_config_store_dir:-}" ]; then
      echo "pnpm pointed at a store no setup created: $pnpm_config_store_dir" >> "$PROBE"
    fi
    [ "$(command -v repo-node)" = "$EXPECT_TOOLCHAIN/repo-node" ] \
      || echo "toolchain not first on PATH: $(command -v repo-node || echo none)" >> "$PROBE"
    case "${POISON:-}" in
      file)   mkdir -p deps && echo poisoned > deps/poisoned ;;
      locked) mkdir -p deps/locked && echo x > deps/locked/f && chmod 555 deps/locked ;;
      submodule) echo 'poisoned' > vendör/index.js ;;
      submodule-locked) echo 'poisoned' > vendör/index.js && chmod 000 vendör ;;
      parent-locked) mkdir -p lib/vendored && echo 'poisoned' > lib/vendored/index.js && chmod 000 lib ;;
    esac
    sed -i 's/teh/the/' README.md
    printf '%s' 'Fixed the typo in README.md.' > "$out" ;;
  *"REVIEW stage"*)
    printf '%s' '{"verdict":"ship","proof":"verified","evidence":"README now contains the","reason":"minimal typo fix"}' > "$out" ;;
  *) exit 2 ;;
esac
printf '%s\n' '{"type":"turn.completed","usage":{"output_tokens":1}}'
EOF
chmod +x "$TMP/bin/codex"

# $1 case, $2 setup_cmd line ("" = omit), $3 poison mode for the Fix stage, $4 EXPECT_SETUP
run_night() {
  local d="$TMP/$1"
  mkdir -p "$d/state" "$d/runs" "$d/digests" "$d/worktrees"
  git init -q --bare "$d/remote.git"
  git init -q -b main "$d/repo"
  git -C "$d/repo" remote add origin "$d/remote.git"
  printf '# Demo\n\nThis is teh demo.\n' > "$d/repo/README.md"
  printf 'deps/\n.pnpm-store/\n' > "$d/repo/.gitignore"
  printf 'MIT\n' > "$d/repo/LICENSE"
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost add -A
  # A submodule path (gitlink) with no submodule behind it: every worktree gets it as an empty
  # directory, and neither `git clean` nor `ls-files` ever looks inside it.
  [ "$3" = parent-locked ] && git -C "$d/repo" update-index --add --cacheinfo \
    "160000,0123456789012345678901234567890123456789,lib/vendored"
  case "$3" in submodule*) git -C "$d/repo" update-index --add --cacheinfo \
    "160000,$(git -C "$d/repo" hash-object -t commit --stdin </dev/null 2>/dev/null || echo 0123456789012345678901234567890123456789),vendör" ;; esac
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
  git -C "$d/repo" push -q -u origin main
  {
    echo "branch_prefix: nightshift/"
    echo "limits:"
    echo "  max_open_branches: 5"
    echo "  max_fix_iterations: 1"
    echo "recon:"
    echo "  enabled: false"
    echo "dimensions:"
    echo "  - correctness"
    echo "repos:"
    echo "  - path: $d/repo"
    echo "    mode: branch-fix"
    echo "    base: main"
    [ -n "$2" ] && echo "    setup_cmd: $2"
    # Green only on a purged tree: anything under deps/ means the gate inherited a stage's files.
    echo '    test_cmd: test ! -e deps && test ! -e .pnpm-store && grep -q "This is the demo" README.md'
  } > "$d/rulebook.yaml"
  : > "$d/probe"
  PATH="$TMP/bin:/usr/bin:/bin" RULEBOOK="$d/rulebook.yaml" \
  NIGHTSHIFT_AGENT=codex NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_CODEX_PATH="$TMP/toolchain" \
  NIGHTSHIFT_STATE_DIR="$d/state" NIGHTSHIFT_RUNS_DIR="$d/runs" \
  NIGHTSHIFT_DIGEST_DIR="$d/digests" NIGHTSHIFT_WORKTREES="$d/worktrees" \
  PROBE="$d/probe" EXPECT_TOOLCHAIN="$TMP/toolchain" POISON="$3" EXPECT_SETUP="$4" \
    "$ROOT/bin/nightshift.sh" >"$d/out" 2>"$d/err" || true
}
shipped() { git --git-dir="$TMP/$1/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*' | grep -q .; }

# --- 1-3. setup before Fix, toolchain on PATH, poisoned deps purged before the gate ---
# The setup also leaves a pnpm store in the worktree, which is where pnpm puts it inside the sandbox.
run_night provisioned 'mkdir -p deps .pnpm-store && echo ok > deps/installed' file 1
d="$TMP/provisioned"
[ ! -s "$d/probe" ] || fail "the Fix stage saw: $(cat "$d/probe")"
grep -q SHADOWED "$d/err" "$d/out" && fail "the toolchain dir shadowed the Runner or the codex binary: $(grep -h SHADOWED "$d/err")"
shipped provisioned || { cat "$d/err" >&2; fail "the gate did not pass on the purged tree"; }
git --git-dir="$d/remote.git" show "$(git --git-dir="$d/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*'):README.md" \
  | grep -q 'This is the demo.' || fail "the shipped branch does not carry the fix"

# --- 4. a failed setup is logged and the Fix stage still runs ---
run_night setupfails 'exit 7' "" 0
d="$TMP/setupfails"
grep -q 'dependency setup failed (rc=7)' "$d/err" || { cat "$d/err" >&2; fail "a failed setup was not reported"; }
shipped setupfails || { cat "$d/err" >&2; fail "a failed setup must not stop the item; the gate decides"; }

# --- 5. ignored files the purge cannot remove refuse the item ---
run_night locked "" locked 0
d="$TMP/locked"
grep -q 'ignored files survived the pre-gate cleanup' "$d/err" || { cat "$d/err" >&2; fail "an unremovable ignored file was not refused"; }
shipped locked && fail "an item whose ignored files could not be purged must not ship"
jq -e 'select(.outcome=="gate-blocked")' "$d/state/ledger.jsonl" >/dev/null \
  || fail "the refusal is not recorded as gate-blocked"

# --- 6. a setup that writes outside .gitignore is refused: it would ship under the Fix stage's name ---
run_night strays 'echo x > stray.txt' "" 0
d="$TMP/strays"
grep -q 'dependency setup changed tracked or un-ignored files' "$d/err" || { cat "$d/err" >&2; fail "a non-hermetic setup was not refused"; }
shipped strays && fail "an item whose setup wrote outside .gitignore must not ship"
jq -e 'select(.outcome=="gate-blocked")' "$d/state/ledger.jsonl" >/dev/null \
  || fail "the non-hermetic setup is not recorded as gate-blocked"

# --- 7. a file written into a submodule path is refused: the purge cannot see it, the suite can ---
run_night submodule "" submodule 0
d="$TMP/submodule"
grep -q 'ignored files survived the pre-gate cleanup' "$d/err" || { cat "$d/err" >&2; fail "a file inside a submodule path was not refused"; }
shipped submodule && fail "an item with a stage-written file in a submodule path must not ship"
# … also when the path is non-ASCII (git prints it quoted) and the stage made it unreadable.
run_night submodule-locked "" submodule-locked 0
d="$TMP/submodule-locked"
grep -q 'ignored files survived the pre-gate cleanup' "$d/err" || { cat "$d/err" >&2; fail "an unreadable submodule path was not refused"; }
shipped submodule-locked && fail "an item with an unreadable submodule path must not ship"
# … and when it is a nested submodule path whose PARENT the stage made unsearchable, which makes the
# path itself look absent.
run_night parent-locked "" parent-locked 0
d="$TMP/parent-locked"
grep -q 'ignored files survived the pre-gate cleanup' "$d/err" || { cat "$d/err" >&2; fail "an unsearchable parent of a submodule path was not refused"; }
shipped parent-locked && fail "an item with an unsearchable directory must not ship"

# --- 8. the setup's hermeticity check compares content, not status lines ---
# From the second Fix iteration on a file the Fix stage edited is already ` M`; a setup rewriting it
# again leaves `git status` unchanged, so only a content comparison can notice.
u="$TMP/unit"; git init -q -b main "$u"
printf 'a\n' > "$u/f"; git -C "$u" -c user.name=t -c user.email=t@l add f
git -C "$u" -c user.name=t -c user.email=t@l commit -q -m i
printf 'b\n' > "$u/f"
st1="$(git -C "$u" status --porcelain)"
id1="$( (set +u; NIGHTSHIFT_WORKTREES="$TMP" NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1; worktree_content_id "$u") )"
printf 'c\n' > "$u/f"
st2="$(git -C "$u" status --porcelain)"
id2="$( (set +u; NIGHTSHIFT_WORKTREES="$TMP" NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1; worktree_content_id "$u") )"
[ "$st1" = "$st2" ] || fail "fixture: the status lines were meant to be identical"
[ -n "$id1" ] && [ -n "$id2" ] && [ "$id1" != "$id2" ] || fail "a content change under an unchanged status was not detected ($id1 / $id2)"
[ -z "$(git -C "$u" diff --cached --name-only)" ] || fail "worktree_content_id staged into the worktree's own index"
# Bytes, not git's normalised content: with `eol=lf`, an LF->CRLF rewrite leaves the tree id alone.
printf 'f text eol=lf\n' > "$u/.gitattributes"; printf 'a\nb\n' > "$u/f"
id3="$( (set +u; NIGHTSHIFT_WORKTREES="$TMP" NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1; worktree_content_id "$u") )"
printf 'a\r\nb\r\n' > "$u/f"
id4="$( (set +u; NIGHTSHIFT_WORKTREES="$TMP" NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1; worktree_content_id "$u") )"
[ -n "$id3" ] && [ "$id3" != "$id4" ] || fail "an LF->CRLF rewrite under eol=lf was not detected"

echo "test-fix-stage-provisioning: ok"
