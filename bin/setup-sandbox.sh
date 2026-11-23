#!/usr/bin/env bash
# Create a throwaway target repo (+ a local bare remote) with a planted, obvious
# improvement, and write a rulebook.yaml pointing nightshift at it. Zero risk to
# real repos — everything lives under ./sandbox (or the directory named as $1).
#
#   setup-sandbox.sh [dir]    # default: $NIGHTSHIFT_HOME/sandbox
set -euo pipefail

HOME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="${1:-$HOME_DIR/sandbox}"

# A caller-named sandbox meets an `rm -rf` below, so it must be absolute and empty or absent; only
# the default path, this script's own dir, is rebuilt unconditionally.
if [ "$#" -gt 0 ]; then
  case "$SB" in /*) ;; *) echo "sandbox dir must be an absolute path: $SB" >&2; exit 2 ;; esac
  if [ -n "$(ls -A "$SB" 2>/dev/null)" ]; then
    echo "refusing to wipe non-empty $SB — name a fresh directory" >&2; exit 2
  fi
fi

rm -rf "$SB"
mkdir -p "$SB"

git init -q --bare "$SB/remote.git"
git init -q -b main "$SB/target"
cd "$SB/target"
git remote add origin "$SB/remote.git"

cat > README.md <<'EOF'
# demo project

This is teh demo project used to exercise nightshift end to end.
It has teh occasional typo that a steward could quietly fix overnight.
EOF

cat > app.py <<'EOF'
def greet(name):
    # retrun the greeting
    return "hello " + name
EOF

# The gate imports this module, and an un-ignored __pycache__ would count as the suite altering the
# reviewed tree, which ADR 0027 refuses to ship: the dry-run would never reach the push.
cat > .gitignore <<'EOF'
__pycache__/
EOF

git -c user.name=demo -c user.email=demo@localhost add -A
git -c user.name=demo -c user.email=demo@localhost commit -q -m "initial demo project"
git push -q -u origin main

# Write the rulebook INTO the sandbox — never clobber the live $HOME_DIR/rulebook.yaml (which
# points at the real repos). Run nightshift against it with RULEBOOK + isolated state dirs.
cat > "$SB/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 5
  max_findings_per_item: 2
recon:
  enabled: true
  ttl_days: 7
dimensions:
  - correctness
  - docs
repos:
  - path: $SB/target
    mode: branch-fix
    # A branch-fix repo must declare a ship gate (ADR 0026) — the parse aborts without one. The demo
    # project has no suite, so this is the smallest command that runs: it exercises the sandboxed
    # gate path end to end while gating nothing, which is honest for a throwaway sandbox and would
    # not be for a real repo.
    test_cmd: python3 -c "import app; assert app.greet('x') == 'hello x'"
EOF

echo "sandbox ready: $SB"
echo "rulebook  -> $SB/rulebook.yaml (points at the sandbox; live rulebook untouched)"
echo
echo "run it isolated with the mock adapter:"
echo "  NIGHTSHIFT_AGENT=mock RULEBOOK=$SB/rulebook.yaml \\"
echo "    NIGHTSHIFT_STATE_DIR=$SB/state NIGHTSHIFT_RUNS_DIR=$SB/runs \\"
echo "    NIGHTSHIFT_DIGEST_DIR=$SB/digests NIGHTSHIFT_WORKTREES=$SB/wt \\"
echo "    bash $HOME_DIR/bin/nightshift.sh"
