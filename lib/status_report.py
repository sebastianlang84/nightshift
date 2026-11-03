#!/usr/bin/env python3
"""Operator status: what nightshift found or changed per repo, how far each item got, and what
clutter is left behind — read-only, no model, no network beyond `git fetch --prune`.

Sources, each the authority for its part:

    state/ledger.jsonl            what a night shipped, surfaced or gave up on, and its verdict
    merge-job state.json          the ADR 0040 job's judgement of a branch commit (reviewed, merged,
                                  conflict, red tests, FIX/REJECT, no agreement) and its kb task
    git (origin and local)        whether a branch still exists and whether base contains it

Usage: status_report.py [--days N] [--no-fetch]
The rulebook comes from $RULEBOOK (default <home>/rulebook.yaml), the ledger from
$NIGHTSHIFT_STATE_DIR (default <home>/state), the merge job's state from
$NIGHTSHIFT_MERGE_STATE (default ~/.agents/state/nightshift-merge/state.json).
"""
import argparse
import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

HOME = Path(os.environ.get('NIGHTSHIFT_HOME') or Path(__file__).resolve().parent.parent)
STATE_DIR = Path(os.environ.get('NIGHTSHIFT_STATE_DIR') or HOME / 'state')
MERGE_STATE = Path(os.environ.get('NIGHTSHIFT_MERGE_STATE')
                   or Path.home() / '.agents/state/nightshift-merge/state.json')
# The merge job's /var/tmp/nightshift-merge holds review transcripts and test logs on purpose.
SCRATCH_DIRS = [os.environ.get('NIGHTSHIFT_WORKTREES', '/var/tmp/nightshift-worktrees')]
JOB_RESULT = {
    'merged': 'reviewed, merged',
    'conflict': 'reviewed: merge conflict',
    'red': 'reviewed: tests red on the merge',
    'fix': 'reviewed: needs a correction',
    'reject': 'reviewed: rejected',
    'noagree': 'reviewed: reviewers disagree',
}


def git(repo, *args):
    r = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True)
    return r.returncode, r.stdout


def rulebook():
    path = Path(os.environ.get('RULEBOOK') or HOME / 'rulebook.yaml')
    if not path.exists():
        path = HOME / 'rulebook.example.yaml'
    out = subprocess.run([sys.executable, str(HOME / 'lib/parse_rulebook.py'), str(path)],
                         capture_output=True, text=True, check=True).stdout
    prefix, repos = 'nightshift/', []
    for line in out.splitlines():
        f = line.split('\t')
        if f[0] == 'prefix' and len(f) > 1 and f[1]:
            prefix = f[1]
        elif f[0] == 'repo':
            kv = dict(x.split('=', 1) for x in f[1:] if '=' in x)
            repos.append((os.path.realpath(kv['path']), kv.get('base', '')))
    return prefix, repos


def base_ref(repo, base):
    if base:
        return 'origin/' + base
    rc, out = git(repo, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    return out.strip() if rc == 0 and out.strip() else 'origin/main'


def contains(repo, base, sha):
    return bool(sha) and git(repo, 'merge-base', '--is-ancestor', sha, base)[0] == 0


def ledger():
    rows = []
    try:
        with open(STATE_DIR / 'ledger.jsonl') as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    except FileNotFoundError:
        pass
    return rows


def short(text, n=110):
    text = ' '.join((text or '').split())
    return text if len(text) <= n else text[:n - 1] + '…'


def tip(repo, branch):
    rc, out = git(repo, 'rev-parse', '-q', '--verify', 'refs/remotes/origin/%s^{commit}' % branch)
    return out.strip() if rc == 0 else ''


def finding_states(rows):
    """(plain state, settled?) of every finding row, keyed by its position in the ledger.

    A finding's identity is (repo, fingerprint), as in the digest's 'Open findings' and
    probe_findings.open_findings: ADR 0014 re-emits a still-open finding as a new row with a new
    item id, and verdicts land on the newest row. So only the newest row of an identity can be
    open; a verdict after it closes the identity, and wontfix closes it for good. Rows without a
    fingerprint fall back to their item id."""
    row_key, newest, item_keys, events = {}, {}, {}, {}
    for n, r in enumerate(rows):
        outcome = r.get('outcome')
        if outcome not in ('finding', 'verdict'):
            continue
        repo, fp, item = r.get('repo'), r.get('fingerprint'), r.get('item')
        if outcome == 'verdict' and item in item_keys:
            key = item_keys[item]
        elif repo and fp:
            key = ('fingerprint', repo, fp)
        elif item:
            key = ('item', item)
        else:
            continue
        if outcome == 'finding':
            row_key[n], newest[key] = key, n
            if item:
                item_keys[item] = key
        else:
            events.setdefault(key, []).append((n, r.get('verdict')))
    states = {}
    for n, key in row_key.items():
        ev = events.get(key, [])
        if newest[key] != n:
            states[n] = ('finding superseded: reported again on %s'
                         % rows[newest[key]].get('night', '?'), True)
        elif any(v == 'wontfix' for _, v in ev):
            states[n] = ('finding closed (wontfix)', True)
        elif ev and ev[-1][0] > n and ev[-1][1] in ('merged', 'resolved', 'dropped'):
            states[n] = ('finding closed (%s)' % ev[-1][1], True)
        else:
            states[n] = ('finding open, awaits a decision', False)
    return states


def item_state(row, verdicts, job, bases):
    """(plain state, settled?) of one ledger item other than a finding, most authoritative first."""
    repo, branch, outcome, sha = row['repo'], row.get('branch'), row['outcome'], row.get('sha')
    v = verdicts.get(row.get('item')) or verdicts.get((repo, branch, sha))
    if outcome == 'tests-failed':
        return 'not shipped: tests failed', True
    if outcome == 'abandoned':
        return 'not shipped: abandoned', True
    base = bases.get(repo)
    j = job.get('%s\t%s' % (repo, branch)) or {}
    head = tip(repo, branch)
    # The job's `merged` covers only the revision it judged: the item's own or the branch's current.
    job_merged = j.get('result') == 'merged' and j.get('sha') in (sha, head or None)
    if v == 'merged' or job_merged or (base and contains(repo, base, sha)):
        return 'merged', True
    # The runner's terminal set (refresh_settled_branches, ADR 0025): each frees the branch's slot.
    if v == 'resolved':
        return 'resolved', True
    if v in ('dropped', 'wontfix'):
        return 'dropped', True
    if j and j.get('sha') in (head or sha,):
        s = JOB_RESULT.get(j.get('result'), 'reviewed: ' + str(j.get('result')))
        return s + (' (kb #%s)' % j['kb'] if j.get('kb') else ''), False
    if not head:
        return 'branch gone, not merged', False
    if j:
        return 'changed since its review, not yet reviewed again', False
    return 'open, not yet reviewed', False


def overview(rows, job, bases, since):
    verdicts = {}
    for r in rows:
        if r.get('outcome') == 'verdict':
            if r.get('item'):
                verdicts[r['item']] = r.get('verdict')
            if r.get('branch'):
                verdicts[(r['repo'], r['branch'], r.get('sha'))] = r.get('verdict')
    findings = finding_states(rows)
    items = []
    for n, r in enumerate(rows):
        if r.get('outcome') not in ('shipped', 'finding', 'tests-failed', 'abandoned'):
            continue
        if r['outcome'] == 'finding':
            state, settled = findings.get(n, ('finding open, awaits a decision', False))
        else:
            state, settled = item_state(r, verdicts, job, bases)
        # Older items stay listed until they are settled: an open item is outstanding work.
        if r.get('night', '') >= since or not settled:
            items.append((r, state))
    print('## What nightshift found or changed since %s, plus everything still open (%d items)\n'
          % (since, len(items)))
    if not items:
        print('Nothing.\n')
        return
    print('| night | repo | kind | what | state |')
    print('|---|---|---|---|---|')
    kinds = {'shipped': 'fix', 'finding': 'finding', 'tests-failed': 'attempt',
             'abandoned': 'attempt'}
    for r, state in sorted(items, key=lambda x: (x[0].get('night', ''), x[0]['repo'])):
        print('| %s | %s | %s | %s | %s |' % (
            r.get('night', '?'), os.path.basename(r['repo']), kinds[r['outcome']],
            short(r.get('summary') or r.get('fingerprint')).replace('|', '/'), state))
    print()


def clutter(prefix, repos, rows, unfetched):
    settled = {}
    for r in rows:
        if r.get('outcome') == 'verdict' and r.get('branch'):
            settled[(r['repo'], r['branch'])] = (r.get('verdict'), r.get('sha'))
    found, registered = [], set()
    for repo, base in repos:
        name = os.path.basename(repo)
        if git(repo, 'rev-parse', '--git-dir')[0]:
            continue
        if repo in unfetched:
            found.append('%s: fetch failed, origin may be stale' % name)
        b = base_ref(repo, base)
        _, out = git(repo, 'for-each-ref', '--format=%(refname:short)',
                     'refs/remotes/origin/' + prefix)
        for ref in out.split():
            br = ref[len('origin/'):]
            if contains(repo, b, ref):
                found.append('%s: %s on origin is merged but not deleted' % (name, br))
            elif (settled.get((repo, br), (None, None))[0] in ('dropped', 'wontfix', 'resolved')
                  and settled[(repo, br)][1] == tip(repo, br)):
                found.append('%s: %s on origin was %s; deleting it needs the curator' % (
                    name, br, 'resolved' if settled[(repo, br)][0] == 'resolved' else 'dropped'))
        _, out = git(repo, 'for-each-ref', '--format=%(refname:short)', 'refs/heads/')
        local = [x for x in out.split() if x != b.split('/', 1)[-1]]
        merged = [x for x in local if contains(repo, b, x)]
        for x in local:
            if x.startswith(prefix):
                found.append('%s: local branch %s%s' % (
                    name, x, ' (merged)' if x in merged else ''))
        other = [x for x in merged if not x.startswith(prefix)]
        if other:
            found.append('%s: %d other local branches already merged into %s'
                         % (name, len(other), b))
        _, out = git(repo, 'worktree', 'list', '--porcelain')
        blocks = [blk for blk in out.strip().split('\n\n') if blk]
        registered.update(os.path.realpath(l.split(' ', 1)[1]) for blk in blocks
                          for l in blk.splitlines() if l.startswith('worktree '))
        trees = blocks[1:]
        live = 0
        for blk in trees:
            f = dict(l.split(' ', 1) if ' ' in l else (l, '') for l in blk.splitlines())
            path, head = f.get('worktree', '?'), f.get('branch', '').replace('refs/heads/', '')
            gone = not os.path.isdir(path)
            # --ignored: an ignored .env or local data is still something a removal would lose.
            rc, dirt = git(path, 'status', '--porcelain', '--ignored') if not gone else (1, '')
            lines = dirt.splitlines()
            merged_head = not gone and rc == 0 and contains(repo, b, f.get('HEAD', ''))
            if gone:
                why = 'is missing on disk (prunable)'
            elif merged_head and not lines:
                why = 'is clean and merged'
            elif merged_head and all(l.startswith('!! ') for l in lines):
                why = 'is merged; only ignored files remain, check them before removing'
            else:
                live += 1
                continue
            found.append('%s: worktree %s [%s] %s' % (name, path, head or 'detached', why))
        if live:
            found.append('%s: %d further worktrees with unmerged or uncommitted work (not clutter)'
                          % (name, live))
        _, out = git(repo, 'stash', 'list')
        n = len(out.splitlines())
        if n:
            found.append('%s: %d stash entries' % (name, n))
    for d in SCRATCH_DIRS:
        try:
            left = [e for e in os.listdir(d)
                    if os.path.realpath(os.path.join(d, e)) not in registered]
        except OSError:
            continue
        if left:
            found.append('%s: %d entries no managed repo knows as a worktree' % (d, len(left)))
    print('## Clutter (%d)\n' % len(found))
    for line in found or ['Nothing.']:
        print('- ' + line)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--days', type=int, default=7)
    ap.add_argument('--no-fetch', action='store_true')
    a = ap.parse_args()
    prefix, repos = rulebook()
    rows = ledger()
    try:
        job = json.loads(MERGE_STATE.read_text())
    except (OSError, json.JSONDecodeError):
        job = {}
    unfetched = set() if a.no_fetch else {
        repo for repo, _ in repos if git(repo, 'fetch', '--prune', '-q', 'origin')[0]}
    bases = {repo: base_ref(repo, base) for repo, base in repos}
    since = (dt.date.today() - dt.timedelta(days=a.days)).isoformat()
    overview(rows, job, bases, since)
    clutter(prefix, repos, rows, unfetched)


if __name__ == '__main__':
    main()
