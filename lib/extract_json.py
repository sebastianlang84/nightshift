#!/usr/bin/env python3
"""Print the first balanced, parseable top-level JSON object on stdin.

Stage models are told to emit JSON only, but often wrap it in prose or code
fences; this pulls the object out robustly. No JSON is a failed stage, never a
synthetic clean/abandon verdict."""
import json
import sys


def main() -> None:
    text = sys.stdin.read()
    start = text.find("{")
    while start != -1:
        depth = 0
        in_str = esc = False
        next_start = start + 1
        for i in range(start, len(text)):
            c = text[i]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    cand = text[start:i + 1]
                    try:
                        json.loads(cand)
                    except Exception:
                        # The outer candidate is complete but malformed. Its nested objects are not
                        # independent stage verdicts; accepting one changes the schema and launders
                        # a partial answer. Resume only AFTER the broken candidate.
                        next_start = i + 1
                        break
                    sys.stdout.write(cand)
                    return
        start = text.find("{", next_start)
    print("no parseable JSON from stage", file=sys.stderr)
    raise SystemExit(1)


if __name__ == "__main__":
    main()
