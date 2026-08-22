#!/usr/bin/env python3
"""Print the first balanced, parseable top-level JSON object on stdin.

Stage models are told to emit JSON only, but often wrap it in prose or code
fences; this pulls the object out robustly. No JSON is a failed stage, never a
synthetic clean/abandon verdict.

One class of malformation is repaired rather than refused: a closer that does
not match the bracket it closes (`{ … ]`). See `repair_closers` for why that
one is safe and why nothing else is (ADR 0030).

Candidates are TOP-LEVEL objects only. An object that never closes ends the
search rather than handing the next `{` a turn: that next brace is nested
inside the unfinished one, and returning it would answer the stage with a
fragment of a reply the model never completed.
"""
import json
import sys

# A repaired candidate is only trustworthy while the damage is a slip. Past a
# couple of swapped closers the output is garbled enough that "the model meant
# this" stops being a reading and starts being a guess.
MAX_SWAPS = 2
CLOSER = {"{": "}", "[": "]"}


def scan(text, start, repair=False):
    """Return (candidate, swaps, end) for the object opening at `start`.

    Walks the string with a stack of open brackets, skipping string literals
    and their escapes. `candidate` is None when the object never closes.
    With `repair`, a closer that contradicts the stack is rewritten to the one
    its opener demands; without it, the text is reproduced verbatim.
    """
    stack, out, swaps = [], [], 0
    in_str = esc = False
    for i in range(start, len(text)):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            out.append(c)
            continue
        if c == '"':
            in_str = True
        elif c in "{[":
            stack.append(c)
        elif c in "}]":
            if not stack:
                break                      # a closer with nothing open: not our object
            want = CLOSER[stack.pop()]
            if c != want:
                if not repair:
                    out.append(c)          # reproduce the damage; the caller will see it
                    continue
                c = want
                swaps += 1
                if swaps > MAX_SWAPS:
                    return None, swaps, i
            out.append(c)
            if not stack:
                return "".join(out), swaps, i
            continue
        out.append(c)
    return None, swaps, len(text)


def repair_closers(text, start):
    """Second pass over a candidate that scanned complete but did not parse.

    The only edit is swapping a closer for the one its own opener demands. The
    model closed every bracket it opened and named one of them wrong — the
    nesting it intended is unambiguous, so the swap recovers its answer rather
    than inventing one. Truncated output is deliberately NOT completed: a
    missing closer means the model never finished, and appending one would
    fabricate the part it did not say.
    """
    cand, swaps, _ = scan(text, start, repair=True)
    if cand is None or swaps == 0:
        return None, 0
    try:
        json.loads(cand)
    except Exception:
        return None, swaps
    return cand, swaps


def main() -> None:
    text = sys.stdin.read()
    start = text.find("{")
    first_complete = -1
    while start != -1:
        cand, _, end = scan(text, start)
        if cand is None:
            break                          # nothing from here on ever closes
        try:
            json.loads(cand)
        except Exception:
            # The outer candidate is complete but malformed. Its nested objects are not
            # independent stage verdicts; accepting one changes the schema and launders
            # a partial answer. Remember it for the repair pass, then resume only AFTER it.
            if first_complete < 0:
                first_complete = start
            start = text.find("{", end + 1)
            continue
        sys.stdout.write(cand)
        return

    if first_complete >= 0:
        cand, swaps = repair_closers(text, first_complete)
        if cand is not None:
            # Loud on purpose: the artifact that reaches the ledger is not byte-for-byte
            # what the model wrote, and the night log says so.
            print(f"json-repair: swapped {swaps} mismatched closer(s) to parse the stage object",
                  file=sys.stderr)
            sys.stdout.write(cand)
            return

    print("no parseable JSON from stage", file=sys.stderr)
    raise SystemExit(1)


if __name__ == "__main__":
    main()
