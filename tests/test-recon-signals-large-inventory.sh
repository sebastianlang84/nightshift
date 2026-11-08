#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/repo"

# Every positive signal sorts before enough filler to exceed a pipe buffer. With
# printf | grep -q, an early hit can SIGPIPE printf and become false under pipefail.
python3 - "$TMP/repo" <<'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1])
signals = {
    '.github/workflows/ci.yml': '',
    'compose.yaml': '',
    'docs/guide.md': '',
    'index.md': 'okf_version: 0.2\n',
    'package-lock.json': '{}',
    'tests/test_demo.py': '',
}
for name, content in signals.items():
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
(repo / 'zz-filler').mkdir()
for n in range(4000):
    (repo / 'zz-filler' / (f'{n:05d}-' + 'x' * 90 + '.txt')).touch()
PY
git -C "$TMP/repo" add .
bytes=$(git -C "$TMP/repo" ls-files | wc -c)
[ "$bytes" -gt 262144 ] || { echo "inventory fixture too small: $bytes" >&2; exit 1; }

signals=$(bash "$ROOT/lib/recon_signals.sh" "$TMP/repo")
jq -e '.has_docs and .has_knowledge and .has_tests and .has_ci and .has_compose
       and (.lockfiles == ["package-lock.json"])
       and (.languages == ["py"])
       and (.has_frontend == false) and (.has_dockerfile == false) and (.has_iac == false)' \
  <<<"$signals" >/dev/null || { echo "large inventory lost signals: $signals" >&2; exit 1; }

# A large inventory must still report absent signals as absent.
git -C "$TMP/repo" rm -q -r -f -- .github compose.yaml docs index.md package-lock.json tests
signals=$(bash "$ROOT/lib/recon_signals.sh" "$TMP/repo")
jq -e '([.has_docs,.has_knowledge,.has_tests,.has_ci,.has_compose,.has_frontend,
         .has_dockerfile,.has_iac] | all(. == false)) and .lockfiles == [] and .languages == []' \
  <<<"$signals" >/dev/null || { echo "large inventory invented signals: $signals" >&2; exit 1; }

echo "test-recon-signals-large-inventory: ok"
