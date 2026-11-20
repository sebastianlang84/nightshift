#!/usr/bin/env bash
unset GIT_CONFIG_COUNT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import itertools
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
# The entry-point scripts run by path, which puts lib/ on sys.path automatically.
sys.path.insert(0, str(root / 'lib'))
from ledger import (MERGE_RATE_VERDICTS, TERMINAL_VERDICTS, latest_branch_verdict_list,
                    latest_branch_verdicts, latest_fingerprint_verdicts)

assert TERMINAL_VERDICTS == {'merged', 'dropped', 'resolved', 'wontfix'}
assert MERGE_RATE_VERDICTS == {'merged', 'dropped'}

# Append order wins even over reversed/equal/missing timestamps; keys are repo-scoped.
rows = [
    dict(outcome='verdict', repo='a', branch='topic', verdict='merged', ts='2099'),
    dict(outcome='verdict', repo='b', branch='topic', verdict='dropped', ts='2099'),
    dict(outcome='verdict', repo='a', branch='topic', verdict='open', ts='2000'),
    dict(outcome='shipped', repo='a', branch='topic', verdict='merged', ts='2100'),
    dict(outcome='verdict', repo='b', branch='topic', verdict='resolved', ts='2099'),
    dict(outcome='verdict', repo=None, branch='topic', verdict='wontfix'),
    dict(outcome='verdict', repo='a', branch=None, verdict='wontfix'),
    dict(outcome='verdict', repo='a', verdict='wontfix'),
    dict(outcome='verdict', branch='topic', verdict='wontfix'),
    dict(outcome='verdict', repo='', branch='', verdict='wontfix'),
]
expected = [rows[-1], rows[2], rows[4]]
assert latest_branch_verdict_list(rows) == expected
assert latest_branch_verdicts(rows) == {(r['repo'], r['branch']): r for r in expected}
assert latest_branch_verdict_list([]) == []
assert latest_branch_verdicts([]) == {}

fingerprints = [
    dict(outcome='verdict', repo='a', fingerprint='f', verdict='resolved', ts='2099'),
    dict(outcome='verdict', repo='b', fingerprint='f', verdict='dropped', ts='2100'),
    dict(outcome='verdict', repo='a', fingerprint='f', verdict='open', ts='2000'),
    dict(outcome='finding', repo='a', fingerprint='f', ts='2101'),
    dict(outcome='verdict', repo='a', fingerprint=None, verdict='merged'),
]
by_fp = lambda r: r.get('fingerprint')  # noqa: E731
assert latest_fingerprint_verdicts(
    fingerprints, lambda r: [r.get('repo'), r.get('fingerprint')]) == [fingerprints[2], fingerprints[1]]
assert latest_fingerprint_verdicts(fingerprints, by_fp) == [fingerprints[2]]
assert latest_fingerprint_verdicts([], by_fp) == []

# Catch quoted set literals / jq predicates spanning nearby lines, plus bare shell/help lists.
# Individual verdict filters and display labels are deliberately allowed.
quoted = ''.join(r'''(?=.{0,180}["']''' + name + r'''["'])'''
                 for name in sorted(TERMINAL_VERDICTS))
bare = '|'.join(r'\b' + r'[\s,|/]+'.join(order) + r'\b'
                for order in itertools.permutations(sorted(TERMINAL_VERDICTS)))
pattern = r'''(?s)(?:''' + quoted + r'''["'](?:merged|dropped|resolved|wontfix)["']|''' + bare + ')'
scan = subprocess.run(
    ['rg', '-n', '-U', '--pcre2', '--glob', '!lib/ledger.py',
     pattern, 'bin', 'lib'], cwd=root, text=True, capture_output=True)
if scan.returncode != 1:
    sys.exit('Duplicated terminal verdict set or scan failure:\n' + scan.stdout + scan.stderr)
print('ledger rules: sets agree, append order preserved, no duplicated terminal sets')
PY
