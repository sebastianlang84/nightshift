#!/usr/bin/env bash
# Create a throwaway target repo (+ a local bare remote) with a planted, obvious
# improvement, and write a rulebook.yaml pointing nightshift at it. Zero risk to
# real repos — everything lives under ./sandbox (or the directory named as $1).
#
#   setup-sandbox.sh [dir]    # default: $NIGHTSHIFT_HOME/sandbox
set -euo pipefail

HOME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="${1:-$HOME_DIR/sandbox}"

# A caller-named sandbox (schedule.sh dry-run passes a fresh mktemp dir) meets an `rm -rf` two lines
# down, so a mistyped path would delete an operator's directory. The default path keeps its old
# behaviour — it is this script's own dir and gets rebuilt on every run — but an explicit one may
# only be absolute and empty/absent.
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

# The gate below imports this module, and CPython writes __pycache__ next to it. Un-ignored, that
# counts as the suite modifying the worktree, and ADR 0027 refuses to ship a tree the suite altered
# after review saw it — so the dry-run would exercise everything except the push. Every real repo in
# the fleet already ignores this; the demo project has to as well, or it teaches the wrong shape.
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
echo "run it isolated (mock or claude):"
echo "  NIGHTSHIFT_AGENT=mock RULEBOOK=$SB/rulebook.yaml \\"
echo "    NIGHTSHIFT_STATE_DIR=$SB/state NIGHTSHIFT_RUNS_DIR=$SB/runs \\"
echo "    NIGHTSHIFT_DIGEST_DIR=$SB/digests NIGHTSHIFT_WORKTREES=$SB/wt \\"
echo "    bash $HOME_DIR/bin/nightshift.sh"
