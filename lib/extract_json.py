#!/usr/bin/env python3
"""Print the first balanced, parseable top-level JSON object on stdin.

Stage models are told to emit JSON only, but often wrap it in prose or code
fences; this pulls the object out robustly. Falls back to a safe default that
works for either stage (found:false / verdict:abandon)."""
import json
import sys


def main() -> None:
    text = sys.stdin.read()
    start = text.find("{")
    while start != -1:
        depth = 0
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
                        break
                    sys.stdout.write(cand)
                    return
        start = text.find("{", start + 1)
    sys.stdout.write('{"found": false, "verdict": "abandon", "reason": "no parseable JSON from stage"}')


if __name__ == "__main__":
    main()
