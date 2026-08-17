#!/usr/bin/env bash
set -euo pipefail

# An outage must stay visible in the digest until a night actually completes — and the night that
# completes must report the gap once, on its way out.
#
# Regression for 2026-08-08..11: four consecutive nights aborted on `Not logged in`. Every layer
# worked as designed — exit 3, `Failed with result 'exit-code'`, an ABORTED line in each digest —
# yet the outage was invisible the morning after, because `systemctl status` shows only the last
# run and the healthy night of 08-12 reset the unit to green. Four lost nights survived only in
# the journal and in four digests nobody re-reads.
#
# Asserted here: the streak counts up while the outage lasts, the first completed night names the
# gap and the last date the fleet was actually serviced, and a night with no outage behind it says
# nothing at all (the line must not become background noise).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests"

# aborted_streak() reads DIGEST_DIR and $NIGHT only, so drive it directly instead of paying for
# four end-to-end nights. The ABORTED marker it greps for is the one write_digest emits.
abort_line='- **ABORTED: the `claude` agent could not run** — claude has no usable credentials (stage explore). Nothing below reflects the state of the code.'
mk() { # night aborted|ok
  { echo "# nightshift digest — $1"; echo
    [ "$2" = aborted ] && echo "$abort_line"
    echo "- agent: \`claude\` · shipped this run: 0"
  } > "$TMP/digests/$1.md"
}

streak() { # night -> "count newest oldest last_ok"
  NIGHT="$1" DIGEST_DIR="$TMP/digests" \
  NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" \
  bash -c 'source "$0" >/dev/null 2>&1; NIGHT="'"$1"'" DIGEST_DIR="'"$TMP"'/digests"; aborted_streak' "$ROOT/bin/nightshift.sh"
}

mk 2026-08-07 ok
mk 2026-08-08 aborted
mk 2026-08-09 aborted
mk 2026-08-10 aborted
mk 2026-08-11 aborted

# 1. Mid-outage: every aborted night behind tonight is counted, back to the last one that finished.
got="$(streak 2026-08-12)"
[ "$got" = "4 2026-08-11 2026-08-08 2026-08-07" ] \
  || { echo "mid-outage streak wrong: got '$got'" >&2; exit 1; }

# 2. The count stops at the last completed night — an older outage is somebody else's history.
mk 2026-08-05 aborted
mk 2026-08-06 aborted
got="$(streak 2026-08-12)"
[ "$got" = "4 2026-08-11 2026-08-08 2026-08-07" ] \
  || { echo "streak crossed a completed night: got '$got'" >&2; exit 1; }

# 3. A quiet fleet says nothing. The line only earns its place when a night was actually lost.
mk 2026-08-12 ok
got="$(streak 2026-08-13)"
[ "${got%% *}" = 0 ] || { echo "streak reported an outage after a clean night: got '$got'" >&2; exit 1; }

# 4. Nights with no digest at all (host off, timer disarmed) are not outages — counting them would
#    fire on every return from a break and train the reader to skip the line.
rm -f "$TMP/digests"/*.md
mk 2026-08-01 ok
got="$(streak 2026-08-20)"
[ "${got%% *}" = 0 ] || { echo "a gap with no digests was counted as an outage: got '$got'" >&2; exit 1; }

# 5. End to end: a real aborted night renders the streak line, not just the count.
mkdir -p "$TMP/bin"
git init -q --bare "$TMP/repo.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" remote add origin "$TMP/repo.git"
printf '# Demo\n\nThis is teh demo.\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 3
  max_findings_per_item: 1
  max_branches_per_run: 1
  max_fix_iterations: 1
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo
    mode: branch-fix
    base: main
    test_cmd: true
EOF

cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo 'Not logged in · Please run /login'
exit 1
EOF
chmod +x "$TMP/bin/claude"

rm -f "$TMP/digests"/*.md
yesterday="$(date -d 'yesterday' +%F)"
mk "$yesterday" aborted

set +e
PATH="$TMP/bin:/usr/bin:/bin" \
RULEBOOK="$TMP/rulebook.yaml" \
NIGHTSHIFT_AGENT=claude \
NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e
[ "$rc" -eq 3 ] || { echo "expected exit 3 (aborted night), got $rc" >&2; cat "$TMP/err" >&2; exit 1; }

digest="$TMP/digests/$(date +%F).md"
[ -f "$digest" ] || { echo "no digest for tonight" >&2; ls "$TMP/digests" >&2; exit 1; }
grep -q '^- \*\*2 nights in a row have not completed\*\*' "$digest" \
  || { echo "digest does not carry the outage streak" >&2; cat "$digest" >&2; exit 1; }
grep -q 'last completed run: none on record' "$digest" \
  || { echo "digest does not report the missing last-completed run" >&2; cat "$digest" >&2; exit 1; }

echo "test-digest-outage-streak: ok"
