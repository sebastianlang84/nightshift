#!/usr/bin/env python3
"""Compact one agent session transcript into citable turns — no model, no network, read-only.

The reflection job (ADR 0035) reads a day of Claude Code and Codex sessions and proposes changes to
the rulebooks. A proposal is only worth acting on if its evidence can be checked, so the unit this
emits is a TURN WITH A STABLE IDENTIFIER, and every finding downstream has to cite one.

"Stable" means derived from the source, never from position in the output. A turn keeps its id when
the compaction rules change, when neighbouring turns are filtered out, or when the file is
re-extracted next week — so a citation recorded last night still resolves tonight. Claude Code gives
each transcript line a `uuid`; Codex gives each a monotonic `ordinal`. Both are properties of the
recorded session, so both survive anything this script does. The id is `<session>:<native>`, with the
native part shortened to 8 characters and lengthened on collision.

What survives compaction, and why:

    human turns      verbatim, never truncated. A correction from the operator is the one signal in
                     a transcript that no model authored, so it is the one that must arrive intact.
    agent prose      truncated. It is the agent's own account of what it did, which is evidence of
                     what it *said*, never of what happened.
    tool calls       name plus a short argument hint. Enough to see a detour or a repeated failure.
    tool results     dropped. This is a real limit and ADR 0035 records it: any finding about what a
                     command actually returned is unsupportable from this output. Keeping them
                     reintroduces both the size problem and the secrets problem, so the decision is
                     deferred rather than made here by accident.

Output is a text format with one header line per turn, which both a model and `check_citations.py`
read. One artifact, so the generator and the checker cannot drift apart:

    [turn <id> <role> <iso-timestamp>]
    <body>
      tool <Name>: <argument hint>

    extract_session.py TRANSCRIPT [--max-prose N] [--session-id ID]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

PROSE_MAX = 700
ARG_MAX = 120
ID_LEN = 8

# The keys a tool call carries that say something about intent. First hit wins.
ARG_KEYS = ("skill", "command", "file_path", "description", "pattern", "path", "query", "prompt")


def _short(native: str, used: dict) -> str:
    """Shorten a native id, lengthening it only far enough to stay unique in this session."""
    for n in range(ID_LEN, len(native) + 1):
        cand = native[:n]
        if used.get(cand, native) == native:
            used[cand] = native
            return cand
    used[native] = native
    return native


def _text(content) -> str:
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text", ""))
    return "\n".join(out)


def _hint(inp: dict) -> str:
    if not isinstance(inp, dict):
        return ""
    for k in ARG_KEYS:
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            return " ".join(v.split())[:ARG_MAX]
    return ""


def claude_turns(path, session, prose_max):
    """Yield turns from a Claude Code transcript. `origin.kind == human` is what marks a person."""
    used = {}
    for raw in open(path, errors="replace"):
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        kind = d.get("type")
        if kind not in ("user", "assistant"):
            continue
        native = d.get("uuid") or ""
        if not native:
            continue
        msg = d.get("message") or {}
        stamp = d.get("timestamp", "")
        if kind == "user":
            if (d.get("origin") or {}).get("kind") != "human":
                continue  # a tool result wearing the user role
            body = _text(msg.get("content")).strip()
            if body:
                yield {"id": f"{session}:{_short(native, used)}", "role": "human",
                       "ts": stamp, "body": body, "tools": []}
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        prose = _text(content).strip()
        tools = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                tools.append((b.get("name") or "?", _hint(b.get("input"))))
        if not prose and not tools:
            continue
        yield {"id": f"{session}:{_short(native, used)}", "role": "agent", "ts": stamp,
               "body": prose[:prose_max], "tools": tools}


def codex_turns(path, session, prose_max):
    """Yield turns from a Codex rollout. `ordinal` is the stable identity there."""
    used = {}
    for raw in open(path, errors="replace"):
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        if d.get("type") != "response_item":
            continue
        p = d.get("payload") or {}
        native = str(d.get("ordinal", ""))
        if not native:
            continue
        stamp = d.get("timestamp", "")
        kind = p.get("type")
        if kind == "message":
            role = p.get("role")
            if role not in ("user", "assistant"):
                continue  # developer/system turns are injected instructions, not conversation
            body = "\n".join(
                b.get("text", "") for b in (p.get("content") or [])
                if isinstance(b, dict) and b.get("type") in ("input_text", "output_text")
            ).strip()
            if not body:
                continue
            if role == "user":
                # Codex delivers harness instructions through the user role too; they are wrapped
                # in tags and are not something a person typed.
                if body.startswith("<") or "instructions>" in body[:40]:
                    continue
                yield {"id": f"{session}:{_short(native, used)}", "role": "human",
                       "ts": stamp, "body": body, "tools": []}
            else:
                yield {"id": f"{session}:{_short(native, used)}", "role": "agent",
                       "ts": stamp, "body": body[:prose_max], "tools": []}
        elif kind in ("function_call", "local_shell_call"):
            name = p.get("name") or "shell"
            arg = p.get("arguments") or p.get("action") or ""
            yield {"id": f"{session}:{_short(native, used)}", "role": "agent", "ts": stamp,
                   "body": "", "tools": [(name, " ".join(str(arg).split())[:ARG_MAX])]}


def render(turns) -> str:
    out = []
    for t in turns:
        out.append(f"[turn {t['id']} {t['role']} {t['ts']}]")
        if t["body"]:
            out.append(t["body"])
        for name, hint in t["tools"]:
            out.append(f"  tool {name}: {hint}" if hint else f"  tool {name}")
        out.append("")
    return "\n".join(out)


def detect_format(path: str) -> str:
    """Tell the two harnesses apart by what the file says, not by where it sits.

    A path test (`/.codex/` in the name) breaks the moment a transcript is copied, which is exactly
    what a test fixture does. Codex marks every line with a `payload`; Claude Code marks its own
    with a `message` and a `uuid`.
    """
    with open(path, errors="replace") as fh:
        for raw in fh:
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            if "payload" in d or d.get("type") in ("session_meta", "response_item", "event_msg"):
                return "codex"
            if "message" in d or d.get("type") in ("user", "assistant"):
                return "claude"
    return "claude"


def default_session_id(path: str) -> str:
    """A short, stable handle for the session — the filename carries it in both harnesses."""
    stem = os.path.basename(path)
    for suffix in (".jsonl",):
        if stem.endswith(suffix):
            stem = stem[: -len(suffix)]
    m = re.search(r"([0-9a-f]{8})(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", stem)
    if m:
        return m.group(1)
    return re.sub(r"[^0-9A-Za-z]+", "-", stem)[:24].strip("-") or "session"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("transcript")
    ap.add_argument("--max-prose", type=int, default=PROSE_MAX,
                    help=f"truncate agent prose at N characters (default {PROSE_MAX})")
    ap.add_argument("--session-id", default=None,
                    help="override the session handle that prefixes every turn id")
    ap.add_argument("--print-session-id", action="store_true",
                    help="print the session handle this transcript would get, and exit")
    args = ap.parse_args(argv)

    # The runner needs the handle BEFORE it has any turns — a transcript that yields nothing still
    # belongs in the session manifest, and it can only be named there if the name is derivable
    # without reading a turn. Deriving it here keeps one definition of that name.
    if args.print_session_id:
        print(args.session_id or default_session_id(args.transcript))
        return 0

    if not os.path.exists(args.transcript):
        print(f"extract_session: no such transcript: {args.transcript}", file=sys.stderr)
        return 2

    session = args.session_id or default_session_id(args.transcript)
    reader = codex_turns if detect_format(args.transcript) == "codex" else claude_turns
    turns = list(reader(args.transcript, session, args.max_prose))
    if not turns:
        print(f"extract_session: no turns in {args.transcript}", file=sys.stderr)
        return 1
    sys.stdout.write(render(turns))
    return 0


if __name__ == "__main__":
    sys.exit(main())
