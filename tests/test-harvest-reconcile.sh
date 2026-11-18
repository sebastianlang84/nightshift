#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# harvest reconcile correctness (ADR 0016):
#  A) a squash/rebase merge (branch's patch replayed as a NEW commit on base, branch then
#     deleted from origin) must reconcile to `merged`, not a false `dropped`. The recorded
#     sha is not an ancestor of base, so the ancestor test alone misses it; patch-equivalence
#     (git cherry) must catch it — with NO gh and NO network (pr_url null).
#  B) an unreachable repo/remote must FAIL CLOSED: reconcile writes no terminal verdict at
#     all (never a false `dropped` from an errored probe).
#  C) a repo that IS reachable (fetch succeeds) whose per-branch `ls-remote` probe errors must
#     fail closed the same way — `skip`, no verdict — and must NOT abort the run: every other
#     shipped branch still reconciles. This is the last rung of the ladder, the only one that
#     can fail on its own, and it is first in the ledger here so that a regression costs A its
#     verdict too (the harvest died mid-loop, taking the orphan sweep and the probe with it).
#  D) once A's original commit becomes unreadable, no PR evidence must mean `skip`, preserving
#     its machine `merged` verdict. Authoritative PR states must still resolve missing objects.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state"
LEDGER="$TMP/state/ledger.jsonl"
GC="git -c user.name=test -c user.email=test@localhost"

# --- repo A: squash-merge scenario -------------------------------------------------
git init -q --bare "$TMP/remoteA.git"
git init -q -b main "$TMP/repoA"
git -C "$TMP/repoA" remote add origin "$TMP/remoteA.git"
printf 'line1\n' > "$TMP/repoA/f.txt"
$GC -C "$TMP/repoA" add -A && $GC -C "$TMP/repoA" commit -q -m initial
git -C "$TMP/repoA" push -q -u origin main
# the shipped fix, on its own one-commit branch
BR_A="nightshift/fix-a"
git -C "$TMP/repoA" checkout -q -b "$BR_A"
printf 'line2-fixed\n' >> "$TMP/repoA/f.txt"
$GC -C "$TMP/repoA" commit -q -am "fix A"
SHA_A="$(git -C "$TMP/repoA" rev-parse HEAD)"
git -C "$TMP/repoA" push -q -u origin "$BR_A"
# squash/rebase merge: base first advances with an unrelated commit (so the replayed patch
# gets a DIFFERENT parent -> a different sha, never an ancestor), then the fix's patch lands
# as a NEW commit carrying the same patch-id; finally the branch is deleted from origin.
git -C "$TMP/repoA" checkout -q main
printf 'unrelated\n' > "$TMP/repoA/other.txt"
$GC -C "$TMP/repoA" add -A && $GC -C "$TMP/repoA" commit -q -m "unrelated base advance"
$GC -C "$TMP/repoA" cherry-pick "$SHA_A" >/dev/null
[ "$(git -C "$TMP/repoA" rev-parse HEAD)" != "$SHA_A" ] || { echo "setup bug: squash sha collided with branch sha" >&2; exit 1; }
git -C "$TMP/repoA" push -q origin main
git -C "$TMP/repoA" push -q origin --delete "$BR_A"

# --- repo B: unreachable remote scenario -------------------------------------------
git init -q --bare "$TMP/remoteB.git"
git init -q -b main "$TMP/repoB"
git -C "$TMP/repoB" remote add origin "$TMP/remoteB.git"
printf 'x\n' > "$TMP/repoB/g.txt"
$GC -C "$TMP/repoB" add -A && $GC -C "$TMP/repoB" commit -q -m initial
git -C "$TMP/repoB" push -q -u origin main
BR_B="nightshift/fix-b"
git -C "$TMP/repoB" checkout -q -b "$BR_B"
printf 'y\n' >> "$TMP/repoB/g.txt"
$GC -C "$TMP/repoB" commit -q -am "fix B"
SHA_B="$(git -C "$TMP/repoB" rev-parse HEAD)"
git -C "$TMP/repoB" push -q -u origin "$BR_B"
# now make the remote unreachable (repo still on disk, its origin is gone)
rm -rf "$TMP/remoteB.git"

# --- repo C: reachable remote, but the branch probe itself errors -------------------
git init -q --bare "$TMP/remoteC.git"
git init -q -b main "$TMP/repoC"
git -C "$TMP/repoC" remote add origin "$TMP/remoteC.git"
printf 'p\n' > "$TMP/repoC/h.txt"
$GC -C "$TMP/repoC" add -A && $GC -C "$TMP/repoC" commit -q -m initial
git -C "$TMP/repoC" push -q -u origin main
BR_C="nightshift/fix-c"
git -C "$TMP/repoC" checkout -q -b "$BR_C"
printf 'q\n' >> "$TMP/repoC/h.txt"
$GC -C "$TMP/repoC" commit -q -am "fix C"
SHA_C="$(git -C "$TMP/repoC" rev-parse HEAD)"
git -C "$TMP/repoC" push -q -u origin "$BR_C"
git -C "$TMP/repoC" checkout -q main
# The stub is what makes C's probe — and ONLY C's probe — fail: a real ls-remote against a live
# local remote cannot be made to error, yet in production this rung fails routinely (a network or
# auth blip mid-run, after the repo's fetch already succeeded). Every other invocation, including
# the orphan sweep's `ls-remote <prefix>*`, is delegated to the real git untouched.
mkdir -p "$TMP/bin"
REAL_GIT="$(command -v git)"
cat > "$TMP/bin/git" <<EOF
#!/usr/bin/env bash
lsr=0; brc=0
for a in "\$@"; do
  [ "\$a" = ls-remote ] && lsr=1
  [ "\$a" = "$BR_C" ] && brc=1
done
[ "\$lsr\$brc" = 11 ] && exit 128
# Simulate A's shipped object becoming unavailable without pruning the fixture repository.
if [ "\${HIDE_SHA_A:-0}" = 1 ]; then
  for a in "\$@"; do
    case "\$a" in "$SHA_A"|"${SHA_A}^{commit}") exit 128 ;; esac
  done
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/bin/git"

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
recon:
  enabled: false
dimensions:
  - docs
repos:
  - path: $TMP/repoA
    mode: branch-fix
    test_cmd: true
  - path: $TMP/repoB
    mode: branch-fix
    test_cmd: true
  - path: $TMP/repoC
    mode: branch-fix
    test_cmd: true
EOF

ship() { # repo branch sha [pr_url]
  jq -nc --arg repo "$1" --arg br "$2" --arg sha "$3" --arg pr "${4:-}" \
    '{night:"2026-07-13",item:("item-"+$br),repo:$repo,fingerprint:($repo+":x:L1"),
      branch:$br,sha:$sha,outcome:"shipped",summary:"x",pr_url:($pr|if .=="" then null else . end),
      proof:"verified",verifiability:"static",dimension:"docs",type:"bug",
      schema_version:2}' >> "$LEDGER"
}
ship "$TMP/repoC" "$BR_C" "$SHA_C"   # first on purpose — see C) above
ship "$TMP/repoA" "$BR_A" "$SHA_A"
ship "$TMP/repoB" "$BR_B" "$SHA_B"

PATH="$TMP/bin:$PATH" \
STATE_DIR="$TMP/state" LEDGER="$LEDGER" RULEBOOK="$TMP/rulebook.yaml" \
  bash "$ROOT/bin/harvest.sh" > "$TMP/harvest.out" 2>&1 \
  || { echo "harvest exited non-zero" >&2; cat "$TMP/harvest.out" >&2; exit 1; }

lastv() { jq -rs --arg b "$1" '[.[]|select(.outcome=="verdict" and .branch==$b)]|last|.verdict // "NONE"' "$LEDGER"; }
countv() { jq -rs --arg b "$1" '[.[]|select(.outcome=="verdict" and .branch==$b)]|length' "$LEDGER"; }

va="$(lastv "$BR_A")"
[ "$va" = merged ] || { echo "A: squash-merge should reconcile to 'merged', got '$va'" >&2; cat "$TMP/harvest.out" >&2; exit 1; }

nb="$(countv "$BR_B")"
[ "$nb" = 0 ] || { echo "B: unreachable remote must write no verdict (fail closed), got $nb: $(jq -rs --arg b "$BR_B" '[.[]|select(.outcome=="verdict" and .branch==$b)]|last|.verdict' "$LEDGER")" >&2; cat "$TMP/harvest.out" >&2; exit 1; }

nc="$(countv "$BR_C")"
[ "$nc" = 0 ] || { echo "C: an errored ls-remote probe must write no verdict (fail closed), got $nc: $(lastv "$BR_C")" >&2; cat "$TMP/harvest.out" >&2; exit 1; }
grep -q "probe failed" "$TMP/harvest.out" \
  || { echo "C: the errored probe should be reported as a skip, not swallowed" >&2; cat "$TMP/harvest.out" >&2; exit 1; }

# A later harvest cannot re-evaluate the squash merge after its recorded object is gone.
# PR fixtures share that missing object; the gh stub gives deterministic state without network.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$3" in
  */MERGED) echo MERGED ;;
  */CLOSED) echo CLOSED ;;
  */OPEN)   echo OPEN ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
for st in MERGED CLOSED OPEN unavailable; do
  ship "$TMP/repoA" "$BR_A-pr-$st" "$SHA_A" "https://example.test/pull/$st"
done

HIDE_SHA_A=1 PATH="$TMP/bin:$PATH" \
STATE_DIR="$TMP/state" LEDGER="$LEDGER" RULEBOOK="$TMP/rulebook.yaml" \
  bash "$ROOT/bin/harvest.sh" > "$TMP/harvest-missing.out" 2>&1 \
  || { echo "harvest with missing commit exited non-zero" >&2; cat "$TMP/harvest-missing.out" >&2; exit 1; }

[ "$(lastv "$BR_A")" = merged ] && [ "$(countv "$BR_A")" = 1 ] \
  || { echo "D: missing commit must preserve the earlier machine merged verdict" >&2; cat "$TMP/harvest-missing.out" >&2; exit 1; }
grep -qE "$BR_A +merged +-> +skip" "$TMP/harvest-missing.out" \
  || { echo "D: missing commit without PR evidence must report skip" >&2; exit 1; }
[ "$(lastv "$BR_A-pr-MERGED")" = merged ] && [ "$(lastv "$BR_A-pr-CLOSED")" = dropped ] \
  || { echo "D: authoritative terminal PR states must resolve a missing commit" >&2; exit 1; }
[ "$(countv "$BR_A-pr-OPEN")" = 0 ] && grep -qE "$BR_A-pr-OPEN +.*-> +open" "$TMP/harvest-missing.out" \
  || { echo "D: authoritative OPEN must resolve a missing commit without a terminal verdict" >&2; exit 1; }
[ "$(countv "$BR_A-pr-unavailable")" = 0 ] && grep -qE "$BR_A-pr-unavailable +.*-> +skip" "$TMP/harvest-missing.out" \
  || { echo "D: missing commit with a failed PR probe must report skip without a verdict" >&2; exit 1; }

echo "test-harvest-reconcile: ok"
