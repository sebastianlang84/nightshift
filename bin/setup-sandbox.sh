#!/usr/bin/env bash
# Create a throwaway target repo (+ a local bare remote) with a planted, obvious
# improvement, and write a rulebook.yaml pointing nightshift at it. Zero risk to
# real repos — everything lives under ./sandbox.
set -euo pipefail

HOME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$HOME_DIR/sandbox"

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
    return "hello " + name
EOF

git -c user.name=demo -c user.email=demo@localhost add -A
git -c user.name=demo -c user.email=demo@localhost commit -q -m "initial demo project"
git push -q -u origin main

cat > "$HOME_DIR/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_branches_per_night: 2
  max_open_branches: 10
  max_files_per_change: 5
  max_lines_per_change: 150
repos:
  - path: $SB/target
    mode: branch-fix
EOF

echo "sandbox ready: $SB"
echo "rulebook.yaml -> $HOME_DIR/rulebook.yaml (points at the sandbox)"
