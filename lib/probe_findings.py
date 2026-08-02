#!/usr/bin/env python3
"""Deterministic freshness probe for open findings — no model, no network, never writes the ledger.

A `finding` row is a human-owned TODO: it has no branch and no sha, so the reconcile loop in
harvest.sh (which tests a branch sha against base) can never give it a verdict. Left alone it
shows up as "TODO" forever — in the digest, in the dashboard, and in the explore prompt's
known-work block.

This probe supplies the one signal the system already has: `code_sig` (ADR 0014), the hash of the
finding's target files at the moment it was recorded. Recomputing it against today's HEAD splits
the open findings into three honest states:

    untouched     — signature unchanged: the target code was never touched, so the finding
                    cannot have been fixed. Certainly still open.
    code_changed  — signature differs: something under the finding changed. It MIGHT be fixed;
                    only a real check can tell (that is the verify stage's job).
    unknown       — no baseline signature (pre-ADR-0014 rows), unreadable repo, or a fingerprint
                    that carries no file targets. Never guessed at.

Output is a derived SNAPSHOT (state/findings-probe.json), not ledger events: the probe observes,
it never claims a verdict. The one thing it carries across runs is each item's `verify` block —
an earned model result — which is kept only while the signature it was made against still holds.

    probe_findings.py --ledger L --out S [--print]
    probe_findings.py record-verify --out S --item ID --sig SIG --result open|resolved [--reason R]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

SCHEMA_VERSION = 1
TERMINAL = {"merged", "resolved", "wontfix", "dropped"}


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def read_ledger(path: str) -> list[dict]:
    """Parse the append-only ledger, skipping unparsable lines (the endpoint and the digest
    tolerate schema drift; a probe must not be the one thing that hard-fails on it)."""
    rows: list[dict] = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows


def open_findings(rows: list[dict]) -> list[dict]:
    """`finding` rows with no TERMINAL verdict, newest row per identity.

    A verdict matches its finding by `item`, or — for a verdict recorded against the identity
    rather than the work item — by fingerprint within the same repo. Fingerprints are only
    repo-unique (the same path exists in several repos), so the repo must match too."""
    cleared_items: set[str] = set()
    cleared_fps: set[tuple[str, str]] = set()
    for r in rows:
        if r.get("outcome") != "verdict" or r.get("verdict") not in TERMINAL:
            continue
        item = r.get("item")
        if isinstance(item, str) and item:
            cleared_items.add(item)
        fp, repo = r.get("fingerprint"), r.get("repo")
        if isinstance(fp, str) and fp and isinstance(repo, str) and repo:
            cleared_fps.add((repo, fp))

    out: list[dict] = []
    for r in rows:
        if r.get("outcome") != "finding":
            continue
        item = str(r.get("item") or "")
        fp = str(r.get("fingerprint") or "")
        repo = str(r.get("repo") or "")
        if item in cleared_items or (repo, fp) in cleared_fps:
            continue
        out.append(r)
    return out


def targets(fingerprint: str) -> list[str]:
    """Target files of a finding, recovered from its identity.

    ADR 0014 builds the fingerprint as `sorted(files):type:anchor`, and the ledger row keeps no
    separate file list — the first segment is the only place the paths survive. Paths never
    contain ':' (the joiner), so splitting on the first ':' is exact."""
    head = fingerprint.split(":", 1)[0]
    return sorted({f for f in head.split(",") if f})


def dimension(row: dict) -> str:
    """The review lens. Explicit field on post-ADR-0010 rows; older ones only carry it inside the
    fingerprint's middle segment (`<paths>:<dim>:<anchor>`), which is what the dashboard reads too."""
    for field in ("dimension", "type"):
        val = row.get(field)
        if isinstance(val, str) and val:
            return val
    parts = str(row.get("fingerprint") or "").split(":")
    return parts[1] if len(parts) >= 3 and parts[1] else ""


def path_like(name: str) -> bool:
    """Does this segment plausibly name a file? Only consulted when NOTHING resolved at HEAD: a
    last-resort fingerprint can be free-form model prose, which hashes to `absent:` for every
    entry and would otherwise read as a permanent false 'code_changed'."""
    return "/" in name or "." in name


def code_sig(repo: str, files: list[str]) -> tuple[str, int] | None:
    """Recompute ADR 0014's content signature at HEAD -> (signature, files that resolved).

    None when the repo cannot be read at all — an unreachable repo must yield `unknown`, never a
    false 'changed' (fail closed). Deliberately mirrors the Runner's `code_sig()` byte for byte,
    including the `absent:<path>` placeholder, so the two signatures are comparable."""
    if not files:
        return None
    if subprocess.run(["git", "-C", repo, "rev-parse", "--git-dir"],
                      capture_output=True).returncode != 0:
        return None
    blobs, resolved = [], 0
    for f in files:
        p = subprocess.run(["git", "-C", repo, "rev-parse", f"HEAD:{f}"],
                           capture_output=True, text=True)
        if p.returncode == 0:
            blobs.append(p.stdout.strip())
            resolved += 1
        else:
            blobs.append(f"absent:{f}")
    return hashlib.sha1(("\n".join(blobs) + "\n").encode()).hexdigest()[:12], resolved


def classify(row: dict) -> tuple[str, str | None, str]:
    """-> (state, code_sig_now, note)."""
    repo = str(row.get("repo") or "")
    stored = str(row.get("code_sig") or "")
    files = targets(str(row.get("fingerprint") or ""))
    if not stored:
        return "unknown", None, "recorded before content signatures (ADR 0014) — no baseline"
    probed = code_sig(repo, files)
    if probed is None:
        return "unknown", None, "repo unreadable — not guessing"
    current, resolved = probed
    # A match is proof on its own: the same target list hashed to the same blobs the Runner saw.
    # Shape heuristics only get a say when nothing resolved, which is both what a deleted target
    # and what a prose fingerprint look like.
    if current == stored:
        return "untouched", current, ""
    if resolved == 0 and not any(path_like(f) for f in files):
        return "unknown", None, "fingerprint carries no file targets"
    return "code_changed", current, ""


def load_snapshot(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_snapshot(path: str, data: dict) -> None:
    """Atomic replace, world-readable: the dashboard container reads this file as another uid
    through a read-only mount, so a 0600 temp file would surface as an empty tab."""
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=False)
        fh.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def probe(ledger: str, out: str) -> dict:
    prev = {i.get("item"): i for i in load_snapshot(out).get("items", [])
            if isinstance(i, dict)}
    items = []
    for row in open_findings(read_ledger(ledger)):
        state, current, note = classify(row)
        item = str(row.get("item") or "")
        entry = {
            "item": item,
            "repo": str(row.get("repo") or ""),
            "fingerprint": str(row.get("fingerprint") or ""),
            "dimension": dimension(row),
            "summary": str(row.get("summary") or ""),
            "ts": str(row.get("ts") or ""),
            "code_sig": str(row.get("code_sig") or ""),
            "code_sig_now": current or "",
            "state": state,
            "note": note,
        }
        # Carry a prior verify result forward only while it still describes today's code. Once the
        # signature moves, that verdict was made against code that no longer exists — drop it and
        # let the item become a candidate again.
        old = prev.get(item) or {}
        verify = old.get("verify")
        if isinstance(verify, dict) and current and verify.get("sig") == current:
            entry["verify"] = verify
        items.append(entry)

    data = {
        "schema_version": SCHEMA_VERSION,
        "generated_ts": now_iso(),
        "items": items,
    }
    write_snapshot(out, data)
    return data


def record_verify(out: str, item: str, sig: str, result: str, reason: str) -> None:
    """Persist a verify-stage outcome into the snapshot. Not a ledger event: only a `resolved`
    result earns one, and the Runner writes that itself. A negative result is kept here so the
    same unchanged code is never re-verified night after night."""
    data = load_snapshot(out)
    items = data.get("items")
    if not isinstance(items, list):
        raise SystemExit(f"no probe snapshot to update at {out}")
    hit = next((i for i in items if isinstance(i, dict) and i.get("item") == item), None)
    if hit is None:
        raise SystemExit(f"item not in probe snapshot: {item}")
    hit["verify"] = {"result": result, "sig": sig, "ts": now_iso(),
                     "reason": reason or ""}
    data["items"] = items
    write_snapshot(out, data)


def print_table(data: dict) -> None:
    label = {"untouched": "untouched", "code_changed": "code changed", "unknown": "unknown"}
    items = data.get("items", [])
    for i in items:
        verify = i.get("verify") or {}
        suffix = f"  [verified: {verify['result']}]" if verify.get("result") else ""
        print(f"{label.get(i['state'], i['state']):<13} "
              f"{os.path.basename(i['repo']):<18} {i['fingerprint'][:58]:<58}"
              f"{suffix}")
    counts = {s: sum(1 for i in items if i["state"] == s)
              for s in ("untouched", "code_changed", "unknown")}
    print(f"\n{len(items)} open finding(s): {counts['untouched']} untouched · "
          f"{counts['code_changed']} code changed (recheck) · {counts['unknown']} unknown")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd")
    rv = sub.add_parser("record-verify", help="store a verify-stage result in the snapshot")
    rv.add_argument("--out", required=True)
    rv.add_argument("--item", required=True)
    rv.add_argument("--sig", required=True)
    rv.add_argument("--result", required=True, choices=("open", "resolved"))
    rv.add_argument("--reason", default="")
    ap.add_argument("--ledger")
    ap.add_argument("--out", dest="out_top")
    ap.add_argument("--print", dest="do_print", action="store_true")
    args = ap.parse_args(argv)

    if args.cmd == "record-verify":
        record_verify(args.out, args.item, args.sig, args.result, args.reason)
        return 0
    if not args.ledger or not args.out_top:
        ap.error("--ledger and --out are required")
    if not os.path.isfile(args.ledger):
        return 0                       # no ledger yet — nothing to probe, not an error
    data = probe(args.ledger, args.out_top)
    if args.do_print:
        print_table(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
