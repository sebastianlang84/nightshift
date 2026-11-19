#!/usr/bin/env python3
"""Did a merged fix stay? Deterministic, no model, no network, never writes the ledger.

A `merged` verdict says a fix entered the base; it does not say the fix was right. This probe
measures what happened to it afterwards, for every item whose latest verdict is `merged`:

    reverted   a later base commit says it reverts the fix's commit or the merge that brought it in
    added      lines the fix added
    kept       of those, lines the base still attributes to the fix (`git blame -M`)
    removed    most added lines sat in files deleted later: the code is gone, which says
               nothing about the fix, so it counts neither way
    held       not reverted, and at least half of the added lines in surviving files kept (a fix
               that only deletes lines is held unless reverted)

Each fix is measured on the base as it stood WINDOW days (default 30) after the verdict, once that
much time has passed; until then it is `pending`. A fix whose sha is gone or not contained in the
base is `unknown`, never guessed. A matured measurement uses a fixed cutoff commit, so it is cached
in the snapshot and not recomputed.

Output is a derived snapshot (state/fix-survival.json), like the findings probe beside it.

    probe_survival.py --ledger L --out S [--base REPO REF]... [--window DAYS] [--print]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

from ledger import repo_labels, verdict_item_key

SCHEMA_VERSION = 2   # 2: revert detection reads git's own revert line; items carry their base
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def git(repo: str, *args: str) -> subprocess.CompletedProcess:
    # Unquoted paths, and no decoding error on a Latin-1 diff: one odd file must not stop the probe.
    return subprocess.run(["git", "-C", repo, "-c", "core.quotePath=false", *args],
                          capture_output=True, text=True, errors="replace")


def resolve_base_ref(repo: str, configured: str) -> str | None:
    """The Runner's shared resolver (lib/base_resolution.sh), so every probe sees one base."""
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "base_resolution.sh")
    p = subprocess.run(["bash", "-c", 'source "$1"; resolve_base "$2" "$3"',
                        "survival-base", helper, repo, configured], capture_output=True, text=True)
    ref = p.stdout.strip()
    return ref if p.returncode == 0 and ref else None


def merged_items(ledger: str) -> list[dict]:
    """Latest verdict per item; keep those that are `merged` and carry a sha."""
    last: dict[tuple, dict] = {}
    with open(ledger, encoding="utf-8") as f:
        for line in f:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("outcome") == "verdict" and (key := verdict_item_key(row)):
                last[key] = row
    return [r for r in last.values() if r.get("verdict") == "merged" and r.get("sha")]


def added_ranges(repo: str, sha: str) -> dict[str, list[tuple[int, int]]]:
    """path at sha -> [(start, count)] of lines the commit added."""
    p = git(repo, "diff", "-U0", "--no-color", "--no-ext-diff", "-M", f"{sha}^", sha)
    if p.returncode != 0:
        return {}
    out: dict[str, list[tuple[int, int]]] = {}
    path = None
    for line in p.stdout.splitlines():
        if line.startswith("+++ "):
            # Git ends the header with a tab when the path holds a space.
            path = line[6:].rstrip("\t") if line.startswith("+++ b/") else None
        elif path and (m := HUNK.match(line)):
            count = int(m.group(2)) if m.group(2) is not None else 1
            if count:
                out.setdefault(path, []).append((int(m.group(1)), count))
    return out


def fate(repo: str, sha: str, cutoff: str, ranges: dict[str, list[tuple[int, int]]]) -> tuple[int, int]:
    """-> (kept, removed): added lines still attributed to the fix at cutoff (`git blame -M`, which
    follows moved lines), and added lines whose whole file was deleted by then. Deleted code says
    nothing about the fix; a feature that was removed later is not a fix that failed."""
    status: dict[str, str | None] = {}
    # Whole tree, not just the fix's paths: a path filter hides a rename's destination.
    p = git(repo, "diff", "--name-status", "-M", sha, cutoff)
    for line in p.stdout.splitlines():
        f = line.split("\t")
        if f[0] == "D" and f[1] in ranges:
            status[f[1]] = None
        elif f[0].startswith("R") and len(f) == 3 and f[1] in ranges:
            status[f[1]] = f[2]
    kept = removed = 0
    for path, rs in ranges.items():
        n = sum(c for _, c in rs)
        now = status.get(path, path)
        if now is None:
            removed += n
            continue
        b = git(repo, "blame", "-M", "--porcelain", cutoff, "--", now)
        own = sum(1 for line in b.stdout.splitlines() if line.startswith(sha + " "))
        kept += min(own, n)
    return kept, removed


# The line `git revert` writes, also for a merge (`..., reversing changes made to ...`).
REVERTS = re.compile(r"^This reverts commit ([0-9a-f]{7,40})", re.MULTILINE)


def reverted(repo: str, sha: str, cutoff: str) -> bool:
    """A later commit says it reverts the fix or the merge that brought it in (`git revert -m`)."""
    targets = [sha]
    merge = git(repo, "rev-list", "--first-parent", "--ancestry-path", f"{sha}..{cutoff}").stdout.split()
    # The merge that brought the fix in: the first first-parent commit after it, if that is a merge
    # whose first parent did not already contain the fix (else the fix came by fast-forward).
    if merge and len(git(repo, "rev-list", "--parents", "-n1", merge[-1]).stdout.split()) > 2 \
            and git(repo, "merge-base", "--is-ancestor", sha, f"{merge[-1]}^1").returncode != 0:
        targets.append(merge[-1])
    p = git(repo, "log", "--format=%B%x00", f"{sha}..{cutoff}")
    for msg in p.stdout.split("\x00"):
        for named in REVERTS.findall(msg):
            if any(t.startswith(named.lower()) for t in targets):
                return True
    return False


def measure(row: dict, base_ref: str | None, window: int, now: datetime) -> dict:
    repo, sha = row["repo"], row["sha"]
    rec = {"item": row["item"], "repo": repo, "branch": row.get("branch"),
           "sha": sha, "merged_seen": row.get("ts"),
           "base": base_ref, "fingerprint": row.get("fingerprint")}
    try:
        seen = datetime.fromisoformat(row["ts"])
    except (KeyError, TypeError, ValueError):
        return {**rec, "state": "unknown", "why": "verdict has no timestamp"}
    due = seen + timedelta(days=window)
    if now < due:
        return {**rec, "state": "pending", "due": due.isoformat()}
    if not base_ref:
        return {**rec, "state": "unknown", "why": "repo not in the rulebook or base unresolved"}
    if git(repo, "cat-file", "-e", f"{sha}^{{commit}}").returncode != 0:
        return {**rec, "state": "unknown", "why": "fix commit no longer in the repository"}
    cutoff = git(repo, "rev-list", "-1", "--first-parent", f"--before={due.isoformat()}",
                 base_ref).stdout.strip()
    if not cutoff or git(repo, "merge-base", "--is-ancestor", sha, cutoff).returncode != 0:
        return {**rec, "state": "unknown", "why": "fix not contained in the base at the cutoff"}
    ranges = added_ranges(repo, sha)
    added = sum(c for rs in ranges.values() for _, c in rs)
    kept, removed = fate(repo, sha, cutoff, ranges)
    rev = reverted(repo, sha, cutoff)
    common = {"window_days": window, "cutoff": cutoff, "added": added, "kept": kept,
              "removed": removed, "reverted": rev}
    live = added - removed
    if not rev and added and live * 2 < added:
        return {**rec, **common, "state": "removed"}
    held = not rev and (live == 0 or kept * 2 >= live)
    return {**rec, **common, "state": "measured", "held": held}


def summarize(items: list[dict]) -> dict:
    by: dict[str, dict] = {}
    for it in items:
        s = by.setdefault(it["repo"],
                          {"measured": 0, "held": 0, "reverted": 0, "added": 0, "kept": 0,
                           "pending": 0, "unknown": 0, "removed": 0})
        if it["state"] == "measured":
            s["measured"] += 1
            s["held"] += it["held"]
            s["reverted"] += it["reverted"]
            s["added"] += it["added"] - it["removed"]
            s["kept"] += it["kept"]
        else:
            s[it["state"]] += 1
    labels = repo_labels(by)
    return {labels[repo]: counts for repo, counts in by.items()}


def probe(ledger: str, out: str, bases: dict[str, str], window: int) -> dict:
    now = datetime.now(timezone.utc)
    cache: dict[tuple, dict] = {}
    try:
        with open(out, encoding="utf-8") as f:
            old = json.load(f)
        if old.get("schema_version") == SCHEMA_VERSION:
            cache = {(i.get("repo"), i.get("item"), i.get("sha"), i.get("merged_seen"), i.get("base")): i
                     for i in old.get("items", [])
                     if i.get("state") in ("measured", "removed") and i.get("window_days") == window}
    except (OSError, ValueError):
        pass
    refs: dict[str, str | None] = {}
    items = []
    for row in merged_items(ledger):
        repo = row["repo"]
        if repo not in refs:
            refs[repo] = resolve_base_ref(repo, bases[repo]) if repo in bases else None
        # A measurement depends on the fix commit and cutoff, so old snapshots without a
        # branch can be reused when the repository, verdict and current base all match.
        hit = cache.get((repo, row["item"], row["sha"], row.get("ts"), refs[repo]))
        if hit and refs[repo]:
            items.append({**hit, "branch": row.get("branch"), "fingerprint": row.get("fingerprint")})
            continue
        items.append(measure(row, refs[repo], window, now))
    snap = {"schema_version": SCHEMA_VERSION, "generated": now.isoformat(), "window_days": window,
            "repos": summarize(items), "items": items}
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(snap, f, indent=1)
    os.chmod(tmp, 0o644)
    os.replace(tmp, out)
    return snap


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--base", nargs=2, action="append", default=[], metavar=("REPO", "REF"))
    ap.add_argument("--window", type=int, default=30)
    ap.add_argument("--print", action="store_true")
    a = ap.parse_args(argv)
    snap = probe(a.ledger, a.out, {r: ref for r, ref in a.base}, a.window)
    if a.print:
        for repo, s in sorted(snap["repos"].items()):
            print(f"{repo}\theld {s['held']}/{s['measured']}\treverted {s['reverted']}"
                  f"\tlines kept {s['kept']}/{s['added']}\tcode removed {s['removed']}"
                  f"\tpending {s['pending']}\tunknown {s['unknown']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
