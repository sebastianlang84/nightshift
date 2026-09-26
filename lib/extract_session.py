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

    extract_session.py TRANSCRIPT [--max-prose N] [--session-id ID] [--print-session-id]

Exit codes: 0 wrote turns · 2 no such transcript · 3 the transcript held no turns · anything else
is a failure. 3 is separate on purpose — a session that was read and yielded nothing still belongs
in the reflection's session inventory, and a session that could not be read must stop the run.
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
EXIT_NO_TURNS = 3

# The keys a tool call carries that say something about intent. First hit wins.
ARG_KEYS = ("skill", "command", "file_path", "description", "pattern", "path", "query", "prompt")


def shorten_all(natives) -> dict:
    """Map every native id in a transcript to its short form, in one pass over the whole set.

    Shortening one id at a time, as they are emitted, makes the result depend on emission order: of
    two ids sharing a prefix the first emitted keeps 8 characters and the second grows to 9, so
    filtering the first out later shrinks the second back to 8 and a citation recorded against the
    old extraction stops resolving. That is exactly the stability the id is for.

    The input is therefore EVERY native id the file carries, including the lines compaction drops.
    Then no compaction rule can change the mapping, because the mapping never saw the rules.
    """
    ordered = list(dict.fromkeys(natives))
    out = {}
    for native in ordered:
        others = [o for o in ordered if o != native]
        for n in range(ID_LEN, len(native) + 1):
            cand = native[:n]
            if not any(o.startswith(cand) for o in others):
                out[native] = cand
                break
        else:
            # Another id has this one as a prefix, so no truncation is unique. Use it whole.
            out[native] = native
    return out


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


def claude_natives(path):
    """Every native id the file carries, dropped lines included — see `shorten_all`."""
    for raw in open(path, errors="replace"):
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("type") in ("user", "assistant") and d.get("uuid"):
            yield d["uuid"]


def claude_turns(path, session, prose_max, short):
    """Yield turns from a Claude Code transcript. `origin.kind == human` is what marks a person."""
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
                yield {"id": f"{session}:{short[native]}", "role": "human",
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
        yield {"id": f"{session}:{short[native]}", "role": "agent", "ts": stamp,
               "body": prose[:prose_max], "tools": tools}


def codex_natives(path):
    """Every native id the file carries, dropped lines included — see `shorten_all`."""
    for raw in open(path, errors="replace"):
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("type") == "response_item" and d.get("ordinal") is not None:
            yield str(d["ordinal"])


def codex_turns(path, session, prose_max, short):
    """Yield turns from a Codex rollout. `ordinal` is the stable identity there."""
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
                if "instructions>" in body[:40]:
                    continue
                yield {"id": f"{session}:{short[native]}", "role": "human",
                       "ts": stamp, "body": body, "tools": []}
            else:
                yield {"id": f"{session}:{short[native]}", "role": "agent",
                       "ts": stamp, "body": body[:prose_max], "tools": []}
        elif kind in ("function_call", "local_shell_call"):
            name = p.get("name") or "shell"
            arg = p.get("arguments") or p.get("action") or ""
            yield {"id": f"{session}:{short[native]}", "role": "agent", "ts": stamp,
                   "body": "", "tools": [(name, " ".join(str(arg).split())[:ARG_MAX])]}


# A body line that would be read back as structure. `check_citations.py` and `build_judge_input.py`
# both anchor a turn header at column 0, and `reflect.sh` fences its payload sections the same way.
STRUCTURE = re.compile(r"^(\[turn |=====|-----)")


def defang(body: str) -> str:
    """Indent any body line that would otherwise be read as structure rather than as content.

    A turn body is untrusted text. It is whatever an agent typed or whatever a repository put in
    front of one, quoted verbatim — and a human turn is never truncated, on purpose. So a file in
    some repository can contain a line shaped like `[turn abc123:def45678 human 2026-01-01T00:00:00Z]`
    and, once quoted into a session, that line arrives here.

    Written out unchanged it is indistinguishable from a real header: the parsers start a new turn on
    it, with an id the text chose. Choosing an id that already exists REPLACES the real turn — and
    then a quote "resolves" against text the same untrusted source supplied, which is the one thing
    the citation check exists to prevent.

    One leading space settles it, because every parser anchors at column 0. Nothing downstream
    notices: `check_citations.py` collapses whitespace before matching, so a quote of the line still
    resolves, and a reader still sees the line.
    """
    return "\n".join(" " + ln if STRUCTURE.match(ln) else ln for ln in body.split("\n"))


def render(turns) -> str:
    out = []
    for t in turns:
        out.append(f"[turn {t['id']} {t['role']} {t['ts']}]")
        if t["body"]:
            out.append(defang(t["body"]))
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
    codex = detect_format(args.transcript) == "codex"
    natives = codex_natives if codex else claude_natives
    reader = codex_turns if codex else claude_turns
    short = shorten_all(natives(args.transcript))
    turns = list(reader(args.transcript, session, args.max_prose, short))
    if not turns:
        # EXIT_NO_TURNS, not a general failure. A caller has to tell "this session was read and
        # held nothing worth quoting" from "reading it went wrong", because the first belongs in
        # the session inventory as an examined session and the second must stop the run. Any other
        # non-zero exit — a crash, an unreadable file — keeps its own meaning.
        print(f"extract_session: no turns in {args.transcript}", file=sys.stderr)
        return EXIT_NO_TURNS
    sys.stdout.write(render(turns))
    return 0


if __name__ == "__main__":
    sys.exit(main())
