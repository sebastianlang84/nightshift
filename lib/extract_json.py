#!/usr/bin/env python3
"""Print the first balanced, parseable top-level JSON object on stdin.

Stage models are told to emit JSON only, but often wrap it in prose or code
fences; this pulls the object out robustly. No JSON is a failed stage, never a
synthetic clean/abandon verdict.

Two classes of malformation are repaired rather than refused: a closer that
does not match the bracket it closes (`{ … ]`), and a comma left standing
before a closer (`[1, 2, ]`). See `repair_syntax` for why those are safe and
why nothing else is (ADR 0030).

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
#
# Dropped commas carry no such ceiling, because they need no reading: a comma
# before a closer separates a value from nothing, so removing it cannot pick
# one meaning over another. JSON5, JavaScript and Python all accept it; only
# JSON does not.
MAX_SWAPS = 2
CLOSER = {"{": "}", "[": "]"}


def scan(text, start, repair=False):
    """Return (candidate, fixes, end) for the object opening at `start`.

    Walks the string with a stack of open brackets, skipping string literals
    and their escapes. `candidate` is None when the object never closes.
    `fixes` counts the edits made, as (swaps, commas).
    With `repair`, a closer that contradicts the stack is rewritten to the one
    its opener demands and a comma left standing before a closer is dropped;
    without it, the text is reproduced verbatim.
    """
    stack, out, swaps, commas = [], [], 0, 0
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
                    return None, (swaps, commas), i
            if repair:
                # A trailing separator. We are not inside a string here, so a comma at the
                # end of `out` can only be structural — a string's own comma would sit
                # behind its closing quote.
                j = len(out) - 1
                while j >= 0 and out[j] in " \t\r\n":
                    j -= 1
                if j >= 0 and out[j] == ",":
                    del out[j]
                    commas += 1
            out.append(c)
            if not stack:
                return "".join(out), (swaps, commas), i
            continue
        out.append(c)
    return None, (swaps, commas), len(text)


def repair_syntax(text, start):
    """Second pass over a candidate that scanned complete but did not parse.

    Two edits, both of which recover what the model wrote instead of adding to
    it. Swapping a closer for the one its own opener demands: the model closed
    every bracket it opened and named one of them wrong, so the nesting it
    intended is unambiguous. Dropping a comma that stands before a closer: it
    separates a value from nothing, and no value can be read out of it.

    Truncated output is deliberately NOT completed: a missing closer means the
    model never finished, and appending one would fabricate the part it did
    not say.
    """
    cand, fixes, _ = scan(text, start, repair=True)
    if cand is None or fixes == (0, 0):
        return None, fixes
    try:
        json.loads(cand)
    except Exception:
        return None, fixes
    return cand, fixes


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
        cand, (swaps, commas) = repair_syntax(text, first_complete)
        if cand is not None:
            # Loud on purpose: the artifact that reaches the ledger is not byte-for-byte
            # what the model wrote, and the night log says so.
            edits = []
            if swaps:
                edits.append(f"swapped {swaps} mismatched closer(s)")
            if commas:
                edits.append(f"dropped {commas} trailing comma(s)")
            print(f"json-repair: {' and '.join(edits)} to parse the stage object",
                  file=sys.stderr)
            sys.stdout.write(cand)
            return

    print("no parseable JSON from stage", file=sys.stderr)
    raise SystemExit(1)


if __name__ == "__main__":
    main()
