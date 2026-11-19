#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# ADR 0027/0037: the ship gate never runs on what a Fix stage left behind in the worktree.
#
# Asserted through the real claude adapter, with only the CLI binary faked (the fake writes into the
# worktree the way a Fix stage's Write tool would):
#   1. an ignored file the Fix stage leaves behind is purged before the gate, so the gate does not
#      run on dependencies a stage could have written;
#   2. ignored files the purge cannot remove refuse the item instead of reaching the gate;
#   3. a file a stage wrote into a submodule path, which no git listing shows, refuses the item;
#   4. the worktree content id the gate compares is a byte comparison, so a rewrite under an
#      unchanged status, or one git's eol normalisation hides, is caught.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { echo "test-pre-gate-purge: $*" >&2; exit 1; }

# The ship gate's sandbox needs bwrap and user namespaces; without them the suite opts out the
# documented way, and every assertion below still holds.
command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / true 2>/dev/null \
  || export NIGHTSHIFT_TEST_SANDBOX=none

mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt=$(cat)
emit() { jq -nc --arg r "$1" '{type:"result",subtype:"success",is_error:false,result:$r,usage:{output_tokens:1}}'; }
case "$prompt" in
  *"EXPLORE stage"*)
    # The depth receipt (ADR 0029) must name every tracked path in a repo this small.
    files="$(git -c core.quotePath=false ls-files | jq -R . | jq -sc .)"
    checks="$(git -c core.quotePath=false ls-files | sed 's/^/checked /' | jq -R . | jq -sc .)"
    emit "$(jq -nc --argjson f "$files" --argjson c "$checks" '{found:true,coverage:{files:$f,entrypoints:["README -> rendered documentation"],checks:$c,invariants:{config_domain:"not-applicable: no config",semantic_sets:"not-applicable: no sets",artifact_identity:"checked: one README artifact",failure_translation:"checked: explicit result JSON",lifecycle:"not-applicable: no lifecycle"},unresolved:[]},findings:[{file:"README.md",type:"typo",line_window:"L1-L3",claim:"README contains teh",verify:"search README for teh",verifiability:"static",disposition:"fix",summary:"fix typo",fingerprint:"README.md:typo:L1-L3",rank:1,confidence:1.0}]}')" ;;
  *"FIX stage"*)
    case "${POISON:-}" in
      file)   mkdir -p deps && echo poisoned > deps/poisoned ;;
      locked) mkdir -p deps/locked && echo x > deps/locked/f && chmod 555 deps/locked ;;
      submodule) echo 'poisoned' > vendör/index.js ;;
      submodule-locked) echo 'poisoned' > vendör/index.js && chmod 000 vendör ;;
      parent-locked) mkdir -p lib/vendored && echo 'poisoned' > lib/vendored/index.js && chmod 000 lib ;;
    esac
    sed -i 's/teh/the/' README.md
    emit 'Fixed the typo in README.md.' ;;
  *"REVIEW stage"*)
    emit '{"verdict":"ship","proof":"verified","evidence":"README now contains the","reason":"minimal typo fix"}' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/claude"

# $1 case, $2 poison mode for the Fix stage
run_night() {
  local d="$TMP/$1"
  mkdir -p "$d/state" "$d/runs" "$d/digests" "$d/worktrees"
  git init -q --bare "$d/remote.git"
  git init -q -b main "$d/repo"
  git -C "$d/repo" remote add origin "$d/remote.git"
  printf '# Demo\n\nThis is teh demo.\n' > "$d/repo/README.md"
  printf 'deps/\n' > "$d/repo/.gitignore"
  printf 'MIT\n' > "$d/repo/LICENSE"
  git -C "$d/repo" -c user.name=test -c user.email=test@localhost add -A
  # A submodule path (gitlink) with no submodule behind it: every worktree gets it as an empty
  # directory, and neither `git clean` nor `ls-files` ever looks inside it.
  [ "$2" = parent-locked ] && git -C "$d/repo" update-index --add --cacheinfo \
    "160000,0123456789012345678901234567890123456789,lib/vendored"
  case "$2" in submodule*) git -C "$d/repo" update-index --add --cacheinfo \
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
    # Green only on a purged tree: anything under deps/ means the gate inherited a stage's files.
    # The base pre-check (ADR 0041) runs in a base-gate-* worktree before the mock Fix repairs `teh`.
    echo '    test_cmd: case "$PWD" in */base-gate-*) exit 0 ;; esac; test ! -e deps && grep -q "This is the demo" README.md'
  } > "$d/rulebook.yaml"
  : > "$d/probe"
  PATH="$TMP/bin:/usr/bin:/bin" RULEBOOK="$d/rulebook.yaml" \
  NIGHTSHIFT_AGENT=claude NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$d/state" NIGHTSHIFT_RUNS_DIR="$d/runs" \
  NIGHTSHIFT_DIGEST_DIR="$d/digests" NIGHTSHIFT_WORKTREES="$d/worktrees" \
  PROBE="$d/probe" POISON="$2" \
    "$ROOT/bin/nightshift.sh" >"$d/out" 2>"$d/err" || true
}
shipped() { git --git-dir="$TMP/$1/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*' | grep -q .; }

# --- 1. a poisoned deps/ the Fix stage left is purged before the gate ---
run_night purged file
d="$TMP/purged"
[ ! -s "$d/probe" ] || fail "the Fix stage saw: $(cat "$d/probe")"
shipped purged || { cat "$d/err" >&2; fail "the gate did not pass on the purged tree"; }
git --git-dir="$d/remote.git" show "$(git --git-dir="$d/remote.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/*'):README.md" \
  | grep -q 'This is the demo.' || fail "the shipped branch does not carry the fix"

# --- 2. ignored files the purge cannot remove refuse the item ---
run_night locked locked
d="$TMP/locked"
grep -q 'ignored files survived the pre-gate cleanup' "$d/err" || { cat "$d/err" >&2; fail "an unremovable ignored file was not refused"; }
shipped locked && fail "an item whose ignored files could not be purged must not ship"
jq -e 'select(.outcome=="gate-blocked")' "$d/state/ledger.jsonl" >/dev/null \
  || fail "the refusal is not recorded as gate-blocked"

# --- 3. a file written into a submodule path is refused: the purge cannot see it, the suite can ---
run_night submodule submodule
d="$TMP/submodule"
grep -q 'ignored files survived the pre-gate cleanup' "$d/err" || { cat "$d/err" >&2; fail "a file inside a submodule path was not refused"; }
shipped submodule && fail "an item with a stage-written file in a submodule path must not ship"
# … also when the path is non-ASCII (git prints it quoted) and the stage made it unreadable.
run_night submodule-locked submodule-locked
d="$TMP/submodule-locked"
grep -q 'ignored files survived the pre-gate cleanup' "$d/err" || { cat "$d/err" >&2; fail "an unreadable submodule path was not refused"; }
shipped submodule-locked && fail "an item with an unreadable submodule path must not ship"
# … and when it is a nested submodule path whose PARENT the stage made unsearchable, which makes the
# path itself look absent.
run_night parent-locked parent-locked
d="$TMP/parent-locked"
grep -q 'ignored files survived the pre-gate cleanup' "$d/err" || { cat "$d/err" >&2; fail "an unsearchable parent of a submodule path was not refused"; }
shipped parent-locked && fail "an item with an unsearchable directory must not ship"

# --- 4. the worktree content id compares content, not status lines ---
# A file the Fix stage edited is already ` M`; rewriting it again leaves `git status` unchanged, so
# only a content comparison can notice.
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

echo "test-pre-gate-purge: ok"
