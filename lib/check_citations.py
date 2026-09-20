#!/usr/bin/env python3
"""Refuse a reflection finding whose evidence does not resolve — no model, no network.

Stage 2 of ADR 0035. A generating model proposed findings about the working day; this decides which
of them carried their evidence, before a reviewer or a human spends attention on them. The failure
it exists for is measured, not imagined: the prototype quoted an agent as saying "Otto fetcht nicht"
when the transcript said the opposite, and built a rule proposal on it.

WHAT THIS ESTABLISHES, AND WHAT IT DOES NOT. It establishes quotation fidelity: the cited turn
exists, and the quoted words are in it. It establishes nothing about meaning. The same prototype
produced a quote that matched its source exactly and still supported the opposite of the rule built
on it, because a qualifying clause had been elided. So a resolved citation is a PRECONDITION for a
finding, never evidence for it — judging whether the evidence supports the claim is stage 3's job,
and this tool hands stage 3 the flags it needs to do that.

INPUT is the findings JSON from the generator, plus the extracted turns they cite:

    {"findings": [
      {"id": "f1",
       "title": "...",
       "quotes":   [{"turn": "8897bab3:21919764", "text": "hat nightshift gearbeitet?"}],
       "ordering": [{"before": "8897bab3:21919764", "after": "8897bab3:4c1d0a91"}],
       ...}]}

RULES, each one a decision recorded here because both the generator prompt and this checker encode
it:

  * A quote resolves when its cited turn exists and its text appears in that turn's body after
    normalisation — whitespace runs collapsed, typographic quotes and dashes folded to ASCII. Case
    is significant: a model that changes case is paraphrasing.
  * ELISION IS ALLOWED AND ALWAYS FLAGGED. `...` or `…` splits the quote into fragments, each of
    which must appear, in order. The check passes and the finding carries `elided: true` into
    stage 3, because dropping a clause is how an exact quote becomes a false one.
  * An ORDERING assertion resolves when both turns exist and the `before` turn really precedes the
    `after` turn. Within one session that is the recorded order. Across sessions it needs both
    timestamps; without them the assertion is refused rather than guessed.
  * THE UNIT OF REJECTION IS THE FINDING. One unresolved quote drops the finding that made it, not
    the quote alone and not the run — a finding stands or falls with its evidence.
  * A finding with no quotes at all is dropped. That is the whole point of the stage.

OUTPUT is the same structure, split, so stage 3 reads `kept` and a human can audit `dropped`:

    check_citations.py --findings F --turns T [T...] [--out O] [--print]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime

TURN_RE = re.compile(r"^\[turn (\S+) (human|agent) (\S*)\]$")
ELLIPSIS = re.compile(r"\s*(?:\.\.\.|…)\s*")

# Typographic characters a model reproduces differently than the source wrote them. Folding these
# is not leniency about content — it is refusing to fail a quote over a quotation mark.
FOLD = {
    "‘": "'", "’": "'", "‚": "'", "‛": "'",
    "“": '"', "”": '"', "„": '"', "‟": '"',
    "–": "-", "—": "-", "−": "-", " ": " ",
}


def normalise(s: str) -> str:
    for a, b in FOLD.items():
        s = s.replace(a, b)
    return " ".join(s.split())


def load_turns(paths):
    """Parse extract_session.py output into {turn_id: {...}}, preserving per-session order."""
    turns = {}
    order = {}
    for path in paths:
        with open(path, errors="replace") as fh:
            cur = None
            for line in fh:
                m = TURN_RE.match(line.rstrip("\n"))
                if m:
                    tid, role, ts = m.group(1), m.group(2), m.group(3)
                    session = tid.split(":", 1)[0]
                    seq = order.setdefault(session, 0)
                    order[session] = seq + 1
                    cur = {"id": tid, "role": role, "ts": ts, "session": session,
                           "seq": seq, "lines": []}
                    turns[tid] = cur
                elif cur is not None:
                    cur["lines"].append(line.rstrip("\n"))
    for t in turns.values():
        t["body"] = normalise("\n".join(t["lines"]))
    return turns


def check_quote(quote, turns):
    """-> (ok, reason, elided). `reason` is empty when ok."""
    tid = quote.get("turn")
    text = quote.get("text")
    if not tid or not isinstance(text, str) or not text.strip():
        return False, "quote is missing a turn id or its text", False
    turn = turns.get(tid)
    if turn is None:
        return False, f"cited turn {tid} does not exist", False
    parts = ELLIPSIS.split(text)
    fragments = [normalise(f) for f in parts if normalise(f)]
    if not fragments:
        return False, "quote is empty after normalisation", False
    # The flag is set by the PRESENCE of an omission marker, not by the fragment count. A trailing
    # elision — "Mit [ref] adressiert ..." — leaves exactly one fragment, and that is the shape the
    # prototype's worst finding had: the dropped clause was the one saying the recommendation does
    # not work. Counting fragments would have called that quote unelided and waved it through.
    elided = len(parts) > len(fragments) or len(fragments) > 1
    pos = 0
    for frag in fragments:
        found = turn["body"].find(frag, pos)
        if found < 0:
            where = "in that order " if elided else ""
            return False, f"quoted text does not appear {where}in turn {tid}", elided
        pos = found + len(frag)
    return True, "", elided


def check_ordering(claim, turns):
    a, b = claim.get("before"), claim.get("after")
    if not a or not b:
        return False, "ordering claim is missing a turn id"
    ta, tb = turns.get(a), turns.get(b)
    if ta is None:
        return False, f"cited turn {a} does not exist"
    if tb is None:
        return False, f"cited turn {b} does not exist"
    if ta["session"] == tb["session"]:
        if ta["seq"] < tb["seq"]:
            return True, ""
        return False, f"{a} does not precede {b} — the transcript has it the other way round"
    if not ta["ts"] or not tb["ts"]:
        return False, f"{a} and {b} are in different sessions and carry no timestamps to order them"
    timestamps = []
    for ts in (ta["ts"], tb["ts"]):
        try:
            value = ts[:-1] + "+00:00" if ts[-1:] in ("Z", "z") else ts
            timestamps.append(datetime.fromisoformat(value))
        except (TypeError, ValueError):
            return False, f"{a} and {b} are in different sessions and carry invalid timestamps"
    try:
        precedes = timestamps[0] < timestamps[1]
    except TypeError:
        return False, f"{a} and {b} carry incomparable timestamps"
    if precedes:
        return True, ""
    return False, f"{a} does not precede {b} by timestamp"


# The fields the generate prompt requires. Checking them here rather than trusting the prompt is
# the difference between a contract and a request: a finding missing its recommendation is not a
# finding a human can act on, and it would otherwise travel all the way to the operator as one.
REQUIRED = ("id", "title", "observation", "diagnosis", "recommendation")


def check_finding(finding, turns, seen_ids=None):
    """-> (kept_finding_or_None, reasons). A finding stands or falls with its evidence."""
    reasons = []
    missing = [k for k in REQUIRED if not str(finding.get(k) or "").strip()]
    if missing:
        reasons.append(f"finding is missing required field(s): {', '.join(missing)}")
    fid = str(finding.get("id") or "").strip()
    if seen_ids is not None and fid:
        if fid in seen_ids:
            reasons.append(f"duplicate finding id {fid!r} — ids must be unique within a run")
        seen_ids.add(fid)
    quotes = finding.get("quotes") or []
    if not quotes:
        return None, reasons + ["finding cites no evidence"]
    elided = False
    for q in quotes:
        ok, reason, was_elided = check_quote(q, turns)
        elided = elided or was_elided
        if not ok:
            reasons.append(reason)
    for claim in finding.get("ordering") or []:
        ok, reason = check_ordering(claim, turns)
        if not ok:
            reasons.append(reason)
    if reasons:
        return None, reasons
    kept = dict(finding)
    kept["elided"] = elided
    return kept, []


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--findings", required=True, help="generator output (JSON)")
    ap.add_argument("--turns", required=True, nargs="+", help="extract_session.py output")
    ap.add_argument("--out", help="write the split result here (default: stdout)")
    ap.add_argument("--print", action="store_true", dest="show",
                    help="also print a one-line summary per finding to stderr")
    args = ap.parse_args(argv)

    try:
        with open(args.findings, errors="replace") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"check_citations: cannot read findings: {exc}", file=sys.stderr)
        return 2

    findings = doc.get("findings") if isinstance(doc, dict) else doc
    if not isinstance(findings, list):
        print("check_citations: findings file has no 'findings' list", file=sys.stderr)
        return 2

    turns = load_turns(args.turns)
    if not turns:
        print("check_citations: no turns loaded — nothing could resolve", file=sys.stderr)
        return 2

    kept, dropped, seen_ids = [], [], set()
    for f in findings:
        if not isinstance(f, dict):
            dropped.append({"finding": f, "reasons": ["finding is not an object"]})
            continue
        k, reasons = check_finding(f, turns, seen_ids)
        if k is None:
            dropped.append({"finding": f, "reasons": reasons})
        else:
            kept.append(k)

    result = {"kept": kept, "dropped": dropped,
              "counts": {"in": len(findings), "kept": len(kept), "dropped": len(dropped)}}
    text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text + "\n")
    else:
        print(text)

    if args.show:
        for d in dropped:
            fid = (d["finding"] or {}).get("id", "?") if isinstance(d["finding"], dict) else "?"
            print(f"dropped {fid}: {'; '.join(d['reasons'])}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
