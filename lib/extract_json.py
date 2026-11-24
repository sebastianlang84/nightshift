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
import re
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
            if (len(stack) == 1 and c != CLOSER[stack[0]]
                    and text[i + 1 :].lstrip().startswith(",")):
                # An outer mismatch followed by more members (`{"a":1],"b":2}`) is not a
                # misspelled final closer: repairing it would discard the rest and manufacture
                # valid JSON, and popping the opener would let a nested pair end the candidate.
                # The opener stays open and the stray closer keeps the candidate from parsing,
                # so a verdict after it is still found.

                if repair:
                    return None, (swaps, commas), i
                out.append(c)
                continue
            want = CLOSER[stack.pop()]
            if c != want:
                if not repair:
                    out.append(c)          # reproduce the damage; the caller will see it
                    if not stack:
                        return "".join(out), (swaps, commas), i
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


ESCAPE = re.compile(r'\\(["\\/bfnrt]|u[0-9a-fA-F]{4})')
LITERAL = re.compile(r"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null")


def lenient_tokens(region):
    """The keys and scalar values of a malformed object, in order, as ('s', text) or ('l', literal).

    A quote ends a string only where JSON could continue after it (`:`, `,`, `}`, `]`, the end, or
    the next string after a dropped comma), so an unescaped inner quote stays inside its string.
    """
    tokens, i, n = [], 0, len(region)
    while i < n:
        c = region[i]
        if c == '"':
            j, raw = i + 1, []
            while j < n:
                if region[j] == "\\" and j + 1 < n:
                    raw.append(region[j:j + 2])
                    j += 2
                    continue
                if region[j] == '"' and region[j + 1:].lstrip()[:1] in ("", ":", ",", "}", "]", '"'):
                    break
                raw.append(region[j])
                j += 1
            raw = "".join(raw)
            try:
                text = json.loads(f'"{raw}"')
            except Exception:
                text = ESCAPE.sub(lambda m: json.loads(f'"{m.group(0)}"'), raw)
            tokens.append(("s", text))
            i = j + 1
            continue
        m = LITERAL.match(region, i)
        if m and not (i and (region[i - 1].isalnum() or region[i - 1] == ".")):
            tokens.append(("l", m.group(0)))
            i = m.end()
            continue
        i += 1
    return tokens


def strict_tokens(cand):
    """The keys and scalar values of a parsed object, in order; numbers keep their literal text."""
    tokens = []
    literal = {True: "true", False: "false", None: "null"}

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                tokens.append(("s", k))
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
        elif isinstance(node, str):
            tokens.append(("s", node))
        elif isinstance(node, tuple):              # a number, kept as written
            tokens.append(("l", node[0]))
        else:
            tokens.append(("l", literal[node]))

    walk(json.loads(cand, parse_int=lambda t: (t,), parse_float=lambda t: (t,)))
    return tokens


def unstated(cand, original):
    """Return how `cand` departs from the malformed object in `original`, or None.

    A correction call (ADR 0046) may fix syntax only, so its keys and scalar values must be those
    of the original object, in the same order: nothing added, dropped, changed or moved. Strings
    also match with quotes and backslashes removed on both sides, since the slip may be in their
    escaping. The original object is the longest complete one that does not parse.
    """
    region, start = None, original.find("{")
    while start != -1:
        obj, _, end = scan(original, start)
        if obj is None:
            break
        try:
            json.loads(obj)
        except Exception:
            if region is None or len(obj) > len(region):
                region = obj
        start = original.find("{", end + 1)
    if region is None:
        return "the original answer has no malformed object"
    want, got = lenient_tokens(region), strict_tokens(cand)

    def same(a, b):
        if a[0] != b[0]:
            return False
        if a[1] == b[1]:
            return True
        strip = str.maketrans("", "", '"\\')
        return a[0] == "s" and a[1].translate(strip) == b[1].translate(strip)

    for k, (w, g) in enumerate(zip(want, got)):
        if not same(w, g):
            return f"{g[1][:60]!r} where it has {w[1][:60]!r} (token {k + 1})"
    if len(got) != len(want):
        return f"{len(got)} keys and values where it has {len(want)}"
    return None


def emit(cand, against):
    if against is not None:
        missing = unstated(cand, against)
        if missing:
            print(f"no parseable JSON from stage: the correction departs from the original answer: "
                  f"{missing}", file=sys.stderr)
            raise SystemExit(1)
    sys.stdout.write(cand)


def main() -> None:
    # --against FILE: the stdin is a correction of FILE's answer (ADR 0046); its keys and values must
    # be those of FILE's malformed object.
    against = None
    if sys.argv[1:2] == ["--against"] and len(sys.argv) == 3:
        with open(sys.argv[2], encoding="utf-8", errors="replace") as f:
            against = f.read()
    text = sys.stdin.read()
    start = text.find("{")
    malformed = []
    # Why extraction failed, for the night log and for the Runner's one correction call (ADR 0046).
    # An object that never closes outranks every other reason: the Runner sends no truncated answer.
    # Otherwise the longest malformed object is named, since that is the verdict, not a `${HOME}`.
    reason, longest = "the answer holds no JSON object", -1
    while start != -1:
        cand, _, end = scan(text, start)
        if cand is None:
            reason = f"the object at character {start} never closes"
            break                          # nothing from here on ever closes
        try:
            json.loads(cand)
        except Exception as exc:
            if end - start > longest:
                longest = end - start
                reason = f"the object at character {start} does not parse: {exc}"
            # The outer candidate is complete but malformed. Its nested objects are not
            # independent stage verdicts; accepting one changes the schema and launders
            # a partial answer. Remember it for the repair pass, then resume only AFTER it.
            malformed.append(start)
            start = text.find("{", end + 1)
            continue
        emit(cand, against)
        return

    # Every malformed candidate gets its turn, in order. Prose before the verdict can
    # hold a balanced brace pair of its own (`${HOME}`, `{x}`) that no repair turns
    # into JSON; letting that fragment take the only turn would refuse the verdict
    # behind it for a slip the repair exists to mend.
    for complete in malformed:
        cand, (swaps, commas) = repair_syntax(text, complete)
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
            emit(cand, against)
            return

    print(f"no parseable JSON from stage: {reason}", file=sys.stderr)
    raise SystemExit(1)


if __name__ == "__main__":
    main()
