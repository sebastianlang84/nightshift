#!/usr/bin/env python3
"""Batch ISO-8601 -> epoch for the ledger-derived indexes: ONE process, not one `date` fork per row.

The ledger is append-only and never pruned, so any aggregate that forks `date -d` per matching row
costs more every night the fleet runs — the exact per-row-fork cost `LEDGER_EPOCH_INDEX` was
introduced to remove, and which its own rebuild loop (plus `median_gap`) still paid. Both callers
hand their rows to this script instead; the whole conversion is one fork, whatever the ledger's size.

Two subcommands, one per caller:

    ledger_epochs.py tsv-epochs --field N   stdin TSV -> the same TSV with field N replaced by an
                                            epoch   (refresh_ledger_epoch_index)
    ledger_epochs.py median-gaps            stdin "repo<TAB>ts" -> "repo<TAB>n<TAB>median"
                                            per repo (refresh_ledger_gap_index)

Parsing keeps the exact three-way outcome the shell loops were written against, because both
callers distinguish them:

    empty field   -> empty output field / row dropped   (the old `[ -n "$ts" ] || continue`)
    unparsable    -> 0                                  (the old `date -d ... || echo 0`)
    parsed        -> integer seconds, truncated         (the old `date -d ... +%s`)

An unparsable timestamp must score 0 for THAT row alone — never abort the batch and never shift the
following rows — since a zero is meaningful to both callers (no service, no evidence override). A
naive timestamp is read as local time and a trailing `Z` as UTC, which is what `date -d` did; for
anything `fromisoformat` refuses (a nanosecond fraction, a basic-format stamp, a hand-edited row)
we fall back to one memoized `date -d` fork for that distinct string, so no format that used to
parse silently becomes a 0. That fallback is the rare path: nightshift writes `date -Iseconds`.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from datetime import datetime

_FALLBACK: dict[str, int] = {}


def _date_fallback(ts: str) -> int:
    """One memoized `date -d` per DISTINCT unparsable string — the compatibility escape hatch."""
    if ts not in _FALLBACK:
        try:
            out = subprocess.run(
                ["date", "-d", ts, "+%s"], capture_output=True, text=True, check=True,
            ).stdout.strip()
            _FALLBACK[ts] = int(out)
        except (OSError, ValueError, subprocess.CalledProcessError):
            _FALLBACK[ts] = 0
    return _FALLBACK[ts]


def parse_epoch(ts: str) -> int:
    """ISO-8601 -> epoch seconds; 0 for empty or unparsable (callers treat 0 as "no timestamp")."""
    s = ts.strip()
    if not s:
        return 0
    iso = s[:-1] + "+00:00" if s[-1] in "Zz" else s
    try:
        return int(datetime.fromisoformat(iso).timestamp())
    except (ValueError, OverflowError, OSError):
        return _date_fallback(s)


def tsv_epochs(field: int) -> None:
    """Rewrite field `field` (1-based) of each TSV line as an epoch, leaving every other field —
    and the line count, and the line order — untouched, so the reading loop still aligns."""
    for line in sys.stdin:
        cols = line.rstrip("\n").split("\t")
        if field <= len(cols) and cols[field - 1].strip():
            cols[field - 1] = str(parse_epoch(cols[field - 1]))
        sys.stdout.write("\t".join(cols) + "\n")


def median_gaps() -> None:
    """stdin "repo<TAB>ts" -> one "repo<TAB>n<TAB>median" row per repo seen.

    `n` counts the repo's PARSED service timestamps and `median` is the median interval between
    consecutive ones, both exactly as the old sort/awk pipeline computed them: epoch 0 (empty or
    unparsable) is not a service, duplicates are kept (they contribute a zero-length gap), and
    fewer than two epochs yields median 0. The 60d bootstrap and the `median <= 0` floor stay in
    the caller, which is where the dimension count D that selects between them lives.
    """
    per_repo: dict[str, list[int]] = {}
    for line in sys.stdin:
        repo, _, ts = line.rstrip("\n").partition("\t")
        if not repo:
            continue
        eps = per_repo.setdefault(repo, [])
        e = parse_epoch(ts)
        if e > 0:
            eps.append(e)
    for repo, eps in per_repo.items():
        eps.sort()
        gaps = sorted(b - a for a, b in zip(eps, eps[1:]))
        n = len(gaps)
        if n == 0:
            median = 0
        elif n % 2:
            median = gaps[(n - 1) // 2]
        else:
            median = (gaps[n // 2 - 1] + gaps[n // 2]) // 2
        sys.stdout.write("%s\t%d\t%d\n" % (repo, len(eps), median))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("tsv-epochs", help="replace a TSV field's ISO timestamp with an epoch")
    p.add_argument("--field", type=int, required=True, help="1-based field index to convert")
    sub.add_parser("median-gaps", help="per-repo count and median inter-service interval")
    args = ap.parse_args()
    if args.cmd == "tsv-epochs":
        if args.field < 1:
            ap.error("--field must be >= 1")
        tsv_epochs(args.field)
    else:
        median_gaps()
    return 0


if __name__ == "__main__":
    sys.exit(main())
