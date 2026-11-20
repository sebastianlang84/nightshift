#!/usr/bin/env python3
"""The run ledger (state/ledger.jsonl): its rules, its one writer and its readers.

The ledger is append-only JSON lines, one row per event, and an external job reads it, so a row
written here is byte for byte what `jq -nc` wrote before: key order, compact separators, raw UTF-8
except the escapes jq makes (control characters and DEL), invalid UTF-8 replaced the way jq does.

Two ways to read it:
- `read_values` / `iter_values` read it the way `jq` did: a stream of JSON values in which blank
  lines are allowed and a malformed value is an error. Field access (`field`) fails on a row that
  is not an object or null, as jq does. A failure raises `LedgerError`; the CLI exits non-zero with
  a message on stderr (2 for a missing file, 5 for a parse or type error, as jq), so each Bash
  caller's existing fallback still decides.
- `read_rows_skipping_bad` is the line reader the probes and the status report used, which skips
  lines that are not JSON. Each caller passes its own policy.

Ledger order is append order; nothing here orders rows by timestamp. Where a question depends on
jq's ordering (`group_by`), `jq_key` gives jq's total order over null/bool/number/string/array/object.

The ledger is read and written only through this module: bin/nightshift.sh, bin/harvest.sh and
lib/digest.sh call the CLI, one command per question; the probes and the status report import it.
Questions that look alike but answer differently (several "open" definitions, raw vs realpath
repos) are separate commands on purpose.

CLI: python3 lib/ledger.py [--ledger PATH] <command> [args]; PATH defaults to $LEDGER. The Bash
`ledger` helpers import the module and call `cli` instead of running this file, so a call costs
Python's start-up and not a recompile of the module: some reads run once per finding.
"""

import json
import math
import os
import re
import sys
from collections import Counter
from os.path import basename

TERMINAL_VERDICT_ORDER = ("merged", "dropped", "resolved", "wontfix")
TERMINAL_VERDICTS = frozenset(TERMINAL_VERDICT_ORDER)
MERGE_RATE_VERDICT_ORDER = ("merged", "dropped")
MERGE_RATE_VERDICTS = frozenset(MERGE_RATE_VERDICT_ORDER)
# What the digest lists under "Considered but not shipped".
CONSIDERED_OUTCOMES = ("abandoned", "push-failed", "commit-failed", "tests-failed",
                       "gate-blocked", "worktree-tampered", "stage-failed")
# The outcomes that count as one pass of a lens (ADR 0015, ADR 0039).
PASS_OUTCOMES = ("empty", "finding", "shipped", "abandoned")
# What `harvest.sh verdict` accepts, in the order its usage text lists them.
MANUAL_VERDICTS = TERMINAL_VERDICT_ORDER + ("open",)
SCHEMA_VERSION = 2
ADOPTED_SUMMARY = "adopted orphan branch (lost shipped row restored)"


class LedgerError(Exception):
    """A read failed where jq would have failed; `code` is jq's exit status for it."""

    def __init__(self, message, code=5):
        super().__init__(message)
        self.code = code


# ------------------------------------------------------------------ jq value semantics ----

def jq_type(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    return "array" if isinstance(value, list) else "object"


def jq_key(value):
    """Sort and equality key in jq's order: null < false < true < numbers < strings < arrays <
    objects; objects compare their sorted keys, then the values under them. Python's own
    comparison raises on None < str and treats True == 1."""
    if value is None:
        return (0,)
    if value is False:
        return (1,)
    if value is True:
        return (2,)
    if isinstance(value, (int, float)):
        return (3, float(value))
    if isinstance(value, str):
        return (4, value)
    if isinstance(value, list):
        return (5, tuple(jq_key(v) for v in value))
    keys = tuple(sorted(value))
    return (6, keys, tuple(jq_key(value[k]) for k in keys))


def alt(value, default):
    """jq's `value // default`: null and false fall back."""
    return default if value is None or value is False else value


def field(row, key):
    """jq's `.key`: an object gives its value, null gives null, anything else is an error."""
    if isinstance(row, dict):
        return row.get(key)
    if row is None:
        return None
    raise LedgerError(f'Cannot index {jq_type(row)} with "{key}"')


_ESCAPES = {c: "\\u%04x" % c for c in range(0x20)}
_ESCAPES.update({0x08: "\\b", 0x09: "\\t", 0x0A: "\\n", 0x0C: "\\f", 0x0D: "\\r",
                 0x22: '\\"', 0x5C: "\\\\", 0x7F: "\\u007f"})


def _number(value):
    if isinstance(value, int):
        return str(value)
    if value != value:
        return "null"
    if value in (float("inf"), float("-inf")):
        return ("-" if value < 0 else "") + "1.7976931348623157e+308"
    return repr(value)


def dumps(value):
    """Compact JSON as `jq -c` prints it."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return _number(value)
    if isinstance(value, str):
        return '"' + value.translate(_ESCAPES) + '"'
    if isinstance(value, list):
        return "[" + ",".join(dumps(v) for v in value) + "]"
    return "{" + ",".join(dumps(k) + ":" + dumps(v) for k, v in value.items()) + "}"


def truthy(value):
    """jq's truth: everything but null and false."""
    return value is not None and value is not False


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def add(*values):
    """jq's left-associative `a + b + ...`: null is the identity; strings, arrays and objects
    join, numbers sum, any other pairing fails."""
    result = values[0]
    for value in values[1:]:
        if value is None:
            continue
        if result is None:
            result = value
        elif isinstance(result, str) and isinstance(value, str):
            result += value
        elif _is_number(result) and _is_number(value):
            result += value
        elif isinstance(result, list) and isinstance(value, list):
            result = result + value
        elif isinstance(result, dict) and isinstance(value, dict):
            result = {**result, **value}
        else:
            raise LedgerError(f"{jq_type(result)} ({dumps(result)}) and {jq_type(value)} "
                              f"({dumps(value)}) cannot be added")
    return result


def array_index(haystack, needle):
    """jq's `haystack | index(needle)` on an array: the first position where `needle` starts (an
    array needle as a contiguous run, anything else as one element), or None."""
    run = needle if isinstance(needle, list) else [needle]
    if not run:
        return None
    want = [jq_key(v) for v in run]
    for i in range(len(haystack) - len(run) + 1):
        if [jq_key(v) for v in haystack[i:i + len(run)]] == want:
            return i
    return None


def group_by(values, key):
    """jq's `group_by(key)`: groups in jq's order of the key, each in input order."""
    groups = {}
    for value in values:
        groups.setdefault(jq_key(key(value)), []).append(value)
    return [groups[k] for k in sorted(groups)]


def unique(values):
    """jq's `unique`: jq order, keeping the first of equal values (an object keeps the key order
    it was first seen with, which `tojson` then shows)."""
    first = {}
    for value in values:
        first.setdefault(jq_key(value), value)
    return [first[k] for k in sorted(first)]


def tostring(value):
    """jq's string interpolation `\\(value)`: strings as they are, anything else as JSON."""
    return value if isinstance(value, str) else dumps(value)


def join(values, sep):
    """jq 1.7 `join`: null is empty, numbers and booleans are printed, arrays/objects fail."""
    parts = []
    for value in values:
        if value is None:
            parts.append("")
        elif isinstance(value, str):
            parts.append(value)
        elif isinstance(value, (bool, int, float)):
            parts.append(dumps(value))
        else:
            raise LedgerError(f"string and {jq_type(value)} cannot be added")
    return sep.join(parts)


def dumps_pretty(value, depth=0):
    """JSON as `jq` prints it without -c: two-space indent, `"key": value`, `[]`/`{}` when empty."""
    pad = "  " * (depth + 1)
    if isinstance(value, list) and value:
        return ("[\n" + ",\n".join(pad + dumps_pretty(v, depth + 1) for v in value)
                + "\n" + "  " * depth + "]")
    if isinstance(value, dict) and value:
        return ("{\n" + ",\n".join(pad + dumps(k) + ": " + dumps_pretty(v, depth + 1)
                                   for k, v in value.items())
                + "\n" + "  " * depth + "}")
    return dumps(value)


def raw_output(value):
    """One value as `jq -r` prints it: a string as it is, anything else as pretty JSON."""
    return value if isinstance(value, str) else dumps_pretty(value)


def jq_max(values, key=lambda v: v):
    """jq's `max_by(key)` (and `max`): the LAST of the maximal values in jq's order, which matters
    for equal values that print differently (1 and 1.0); None when there are none."""
    best, best_key, seen = None, None, False
    for value in values:
        k = jq_key(key(value))
        if not seen or k >= best_key:
            best, best_key, seen = value, k, True
    return best


def head_slice(value, end):
    """jq's `.[0:end]`: strings (by code point) and arrays are cut, null stays null, others fail."""
    if value is None:
        return None
    if isinstance(value, (str, list)):
        return value[0:end]
    raise LedgerError(f"Cannot index {jq_type(value)} with object")


_TSV = str.maketrans({"\\": "\\\\", "\t": "\\t", "\n": "\\n", "\r": "\\r"})


def tsv(values):
    """jq's `@tsv` of an array: null and NaN empty, booleans and numbers printed, strings with
    backslash, tab, newline and CR escaped; an array or object fails."""
    parts = []
    for value in values:
        if value is None:
            parts.append("")
        elif isinstance(value, str):
            parts.append(value.translate(_TSV))
        elif isinstance(value, (bool, int, float)):
            parts.append("" if value != value else dumps(value))
        else:
            raise LedgerError(f"{jq_type(value)} ({dumps(value)}) is not valid in a csv row")
    return "\t".join(parts)


# utf8_coding_length / utf8_first_codepoint of jq's src/jv_unicode.c
_CONT = -1
_LENGTH = [1] * 0x80 + [_CONT] * 0x40 + [0] * 2 + [2] * 30 + [3] * 16 + [4] * 5 + [0] * 11
_FIRST = (0, 0, 0x80, 0x800, 0x10000)


def jq_decode(data):
    """Decode bytes as jq does (jvp_utf8_next): each invalid sequence becomes ONE U+FFFD, and a
    sequence cut off by the end of the input swallows the rest of it. Python's 'replace' differs."""
    try:
        return data.decode("utf-8")   # strict decoding rejects exactly what the loop below replaces
    except UnicodeDecodeError:
        pass
    out, i, end = [], 0, len(data)
    while i < end:
        first = data[i]
        length = _LENGTH[first]
        if first < 0x80:
            out.append(chr(first))
            i += 1
            continue
        if length in (0, _CONT):
            out.append("�")
            i += 1
            continue
        if i + length > end:
            out.append("�")
            break
        codepoint = first & (0xFF >> (length + 1))
        for k in range(1, length):
            ch = data[i + k]
            if _LENGTH[ch] != _CONT:
                codepoint, length = -1, k
                break
            codepoint = (codepoint << 6) | (ch & 0x3F)
        if (codepoint < _FIRST[length] or 0xD800 <= codepoint <= 0xDFFF
                or codepoint > 0x10FFFF):
            codepoint = -1
        out.append("�" if codepoint < 0 else chr(codepoint))
        i += length
    return "".join(out)


def arg(value):
    """A command-line argument as jq's `--arg` sees it."""
    return jq_decode(os.fsencode(value))


# --------------------------------------------------------------------------- readers ----

_SURROGATE = re.compile("[\ud800-\udfff]")
# Decoded text holds no surrogates, so only a \uD800-\uDFFF escape can produce one.
_SURROGATE_ESCAPE = re.compile(r"\\u[dD][89a-fA-F]")
_CONSTANTS = {"NaN": float("nan"), "Infinity": sys.float_info.max,
              "-Infinity": -sys.float_info.max}


def _has_lone_surrogate(value):
    stack = [value]
    while stack:
        v = stack.pop()
        if isinstance(v, str):
            if _SURROGATE.search(v):
                return True
        elif isinstance(v, list):
            stack.extend(v)
        elif isinstance(v, dict):
            stack.extend(v)
            stack.extend(v.values())
    return False


def iter_values(path):
    """Yield the ledger's JSON values in order, as `jq` reads the file; raise LedgerError where jq
    stops (a missing file before the first value, a malformed one at that point)."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as e:
        raise LedgerError(f"Could not open {path}: {e.strerror}", 2) from None
    text = jq_decode(data)
    if text.startswith("﻿"):
        text = text[1:]
    decoder = json.JSONDecoder(parse_constant=_CONSTANTS.__getitem__)
    escapes = _SURROGATE_ESCAPE.search(text) is not None
    i, end = 0, len(text)
    while True:
        while i < end and text[i] in " \t\n\r":
            i += 1
        if i >= end:
            return
        try:
            value, i = decoder.raw_decode(text, i)
        except json.JSONDecodeError as e:
            raise LedgerError(f"parse error: {e.msg} at line {e.lineno}, column {e.colno}") from None
        except (ValueError, RecursionError) as e:
            raise LedgerError(f"parse error: {e}") from None
        if escapes and _has_lone_surrogate(value):
            raise LedgerError("parse error: Invalid \\uXXXX\\uXXXX surrogate pair escape")
        yield value


def read_values(path):
    """The whole ledger as `jq -s` slurps it: a list of values, or LedgerError."""
    return list(iter_values(path))


def read_rows_skipping_bad(path, *, encoding="utf-8", errors="strict", strip=True,
                           dicts_only=False, missing_ok=False):
    """Line reader that SKIPS lines which are not JSON. Only for the probes and the status report,
    which have always tolerated drift this way; each passes the exact policy it had."""
    try:
        fh = open(path, encoding=encoding, errors=errors)
    except FileNotFoundError:
        if missing_ok:
            return []
        raise
    rows = []
    with fh:
        for line in fh:
            if strip:
                line = line.strip()
                if not line:
                    continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if dicts_only and not isinstance(row, dict):
                continue
            rows.append(row)
    return rows


# ---------------------------------------------------------------------- shared rules ----

def verdict_item_key(row):
    """Scope verdicts to their repo and distinguish adoptions written with the legacy item."""
    item, repo, branch = row.get("item"), row.get("repo"), row.get("branch")
    if branch and item in ("orphan-adopt", f"orphan-adopt:{repo}:{branch}"):
        return ("adoption", repo, branch)
    if item and item != "orphan-adopt":
        return ("item", repo, item)
    return None


def repo_labels(repos):
    """Use checkout names where unique and full ledger paths where needed."""
    names = {repo: basename(repo) for repo in repos}
    counts = Counter(names.values())
    return {repo: name if counts[name] == 1 else repo for repo, name in names.items()}


def latest_branch_verdicts(rows):
    """Last-appended verdict per non-null (repo, branch), never ordered by timestamp."""
    latest = {}
    for row in rows:
        if (row.get("outcome") == "verdict"
                and row.get("repo") is not None and row.get("branch") is not None):
            latest[(row["repo"], row["branch"])] = row
    return latest


def adopted_item_id(row):
    """Git ref names cannot contain a colon, so the last colon separates repo and branch."""
    return f"orphan-adopt:{tostring(field(row, 'repo'))}:{tostring(field(row, 'branch'))}"


def is_adoption(row):
    item = field(row, "item")
    return alt(field(row, "branch"), "") != "" and (
        item == "orphan-adopt" or item == adopted_item_id(row))


def _latest_by(rows, keep, key):
    """`map(select(keep)) | group_by(key) | map(last)` with jq's group order."""
    groups = {}
    for row in rows:
        if keep(row):
            groups[jq_key(key(row))] = row
    return [groups[k] for k in sorted(groups)]


def latest_branch_verdict_list(rows):
    """jq's `latest_branch_verdicts`: the last-appended verdict per non-null (repo, branch), as a
    list in group_by order. Equality and order are jq's, unlike `latest_branch_verdicts`."""
    return _latest_by(
        rows,
        lambda r: (field(r, "outcome") == "verdict" and field(r, "repo") is not None
                   and field(r, "branch") is not None),
        lambda r: [field(r, "repo"), field(r, "branch")])


def latest_fingerprint_verdicts(rows, identity):
    """jq's `latest_fingerprint_verdicts(identity)`; callers keep their own scope rules."""
    return _latest_by(
        rows, lambda r: field(r, "outcome") == "verdict" and field(r, "fingerprint") is not None,
        identity)


def unretracted_rows(rows):
    """jq's `unretracted_rows`: drop every row whose item a `retracted` row names."""
    void = {jq_key(field(r, "item")) for r in rows if field(r, "outcome") == "retracted"}
    return [r for r in rows if jq_key(field(r, "item")) not in void]


def open_findings(rows):
    """Return the newest currently-open `finding` row per identity.

    The ledger is an event stream, so order matters. A terminal verdict closes the finding that
    precedes it; a later `open` verdict or a newly emitted finding reopens the identity. The latter
    is ADR 0014 invalidation in action: changed target code makes a resolved identity eligible again.
    `wontfix` alone stays permanent, but only once the identity has been seen as a finding: a
    verdict for an identity not yet seen is dropped.

    A verdict matches by repo-scoped fingerprint where available, else by its exact item id for
    legacy rows. Fingerprints are not globally unique across repos."""
    states = {}
    item_keys = {}

    for order, row in enumerate(rows):
        outcome = row.get("outcome")
        item = str(row.get("item") or "")
        repo = str(row.get("repo") or "")
        fingerprint = str(row.get("fingerprint") or "")
        key = None
        if repo and fingerprint:
            key = ("fingerprint", repo, fingerprint)
        elif item:
            key = item_keys.get(item, ("item", item))

        if outcome == "finding":
            if key is None:
                continue
            if item:
                item_keys[item] = key
            state = states.setdefault(key, {"open": False, "wontfix": False})
            if not state["wontfix"]:
                state.update(row=row, open=True, order=order)
            continue

        if outcome != "verdict":
            continue
        if item and item in item_keys:
            key = item_keys[item]
        if key is None or key not in states:
            continue
        state = states[key]
        verdict = row.get("verdict")
        if verdict == "wontfix":
            state.update(open=False, wontfix=True)
        elif verdict in TERMINAL_VERDICTS:
            state["open"] = False
        elif verdict == "open" and not state["wontfix"]:
            state["open"] = True

    active = (state for state in states.values() if state.get("open") and state.get("row"))
    return [state["row"] for state in sorted(active, key=lambda state: int(state["order"]))]


# ------------------------------------------------------------------ harvest questions ----

def last_branch_verdict(rows, repo, branch):
    """The last-appended verdict row for exactly this raw (repo, branch), or None. The repo is the
    ledger string, not a realpath."""
    for row in latest_branch_verdict_list(rows):
        if row.get("repo") == repo and row.get("branch") == branch:
            return row
    return None


def branch_verdict_lines(rows):
    """Latest verdict per (repo, branch) as `repo␟branch␟verdict␟source`, in group_by order, for
    pairs whose repo and branch are neither null, false nor "" (unlike `last_branch_verdict`, which
    keeps an empty branch). Lazy: a value jq's join rejects stops the output at that row."""
    for row in latest_branch_verdict_list(rows):
        if alt(row.get("repo"), "") != "" and alt(row.get("branch"), "") != "":
            yield join([row.get("repo"), row.get("branch"), alt(row.get("verdict"), ""),
                        alt(row.get("source"), "")], "\x1f")


def known_branch_lines(rows):
    """`repo␟branch` for every row of any outcome whose repo and branch are not null, false or "",
    duplicates included, in append order. Lazy, so output stops at the row jq stopped at."""
    for row in rows:
        if alt(field(row, "repo"), "") != "" and alt(field(row, "branch"), "") != "":
            yield join([row["repo"], row["branch"]], "\x1f")


def reconcile_lines(rows):
    """`item␟repo␟fingerprint␟branch␟sha␟pr_url` for EVERY shipped row with non-null branch and sha
    (not one per branch: an adopted and an original row for one branch both appear)."""
    shipped = [r for r in rows if field(r, "outcome") == "shipped"
               and field(r, "branch") is not None and field(r, "sha") is not None]

    def lines():
        for r in shipped:
            yield join([r.get("item"), r.get("repo"), r.get("fingerprint"), alt(r.get("branch"), ""),
                        alt(r.get("sha"), ""), alt(r.get("pr_url"), "")], "\x1f")
    return lines()


def unretracted_empty_rows(rows, night):
    """`empty` rows of this night whose item no `retracted` row names yet."""
    done = {jq_key(field(r, "item")) for r in rows if field(r, "outcome") == "retracted"}
    return [r for r in rows if field(r, "night") == night and field(r, "outcome") == "empty"
            and jq_key(field(r, "item")) not in done]


def verdict_matches(candidates, scope, selector):
    """The candidate rows `harvest.sh verdict` may target, each with `selector` (its adoption id
    for an adopted shipped row, else its item) and `adoption` set.
    scope: adopted -> adopted shipped rows by adoption id; fingerprint -> by fingerprint;
    anything else -> by item, branch or fingerprint."""
    matches = []
    for row in candidates:
        adoption = field(row, "outcome") == "shipped" and is_adoption(row)
        row = dict(row)
        row["selector"] = adopted_item_id(row) if adoption else row.get("item")
        row["adoption"] = adoption
        if scope == "adopted":
            hit = adoption and row["selector"] == selector
        elif scope == "fingerprint":
            hit = row.get("fingerprint") == selector
        else:
            hit = selector in (row.get("item"), row.get("branch"), row.get("fingerprint"))
        if hit:
            matches.append(row)
    return matches


def stream_values(path, each):
    """Run `each` on every ledger value as a streaming `jq` (no -s) runs its program, and return
    whether the run failed. That jq reports a value its program fails on (a row it cannot index,
    a string it cannot add), goes on with the next value, and fails only if the LAST value failed;
    a parse error ends the stream there (LedgerError). `each` must not output before it can fail."""
    failed = False
    for value in iter_values(path):
        try:
            each(value)
        except LedgerError as e:
            sys.stderr.write(f"ledger.py: {e}\n")
            failed = True
            continue
        failed = False
    return failed


def work_rows(path):
    """Shipped and finding rows in append order, as the streaming `jq -c 'select(...)'` gave them,
    and whether the run failed (see `stream_values`)."""
    rows = []

    def each(value):
        if field(value, "outcome") in ("shipped", "finding"):
            rows.append(value)
    return rows, stream_values(path, each)


# ------------------------------------------------------------------- digest questions ----
# Each answers one lib/digest.sh section with the bytes its jq program printed. The digest drops
# stderr and keeps its `|| true` / `|| echo` fallbacks, so what matters is whether jq failed and,
# for the programs that print several values, what it printed before failing.

def night_count(rows, night, outcome):
    """How many rows of this night have this outcome (slurped)."""
    return sum(1 for r in rows if field(r, "night") == night and field(r, "outcome") == outcome)


def night_line(row, section, night):
    """One line of tonight's Shipped / Findings / Considered section as the streaming jq printed
    it, or None for a row outside the section. A value `+` rejects (a number, boolean, array or
    object where a string is concatenated; null adds nothing) fails the row; see `stream_values`."""
    if field(row, "night") != night:
        return None
    outcome = field(row, "outcome")
    if section == "shipped" and outcome == "shipped":
        pr_url = row.get("pr_url")
        return add("- ", "**[unverified]** " if row.get("proof") == "unproven" else "",
                   row.get("repo"), " → `", alt(row.get("branch"), ""), "` — ",
                   alt(row.get("summary"), row.get("fingerprint")),
                   add("  ([open PR](", pr_url, "))") if truthy(pr_url) else "")
    if section == "findings" and outcome == "finding":
        return add("- ", row.get("repo"), " — ", alt(row.get("summary"), row.get("fingerprint")),
                   "  (", row.get("fingerprint"), ")")
    if section == "considered" and outcome in CONSIDERED_OUTCOMES:
        return add("- ", row.get("repo"), " — ", outcome, ": ",
                   alt(row.get("summary"), row.get("fingerprint")))
    return None


def interrupted_lines(rows, night):
    """The interrupted digest's three sections over this night's rows, lazily: a slurped jq
    program that prints value by value, so a line it cannot build ends the output there. Unlike
    `night_line`: `.summary // .fingerprint // ""`, no [unverified] marker and no PR link."""
    tonight = [r for r in rows if field(r, "night") == night]

    def text(r):
        return alt(r.get("summary"), alt(r.get("fingerprint"), ""))
    yield "## Shipped"
    for r in tonight:
        if r.get("outcome") == "shipped":
            yield add("- ", r.get("repo"), " → `", alt(r.get("branch"), ""), "` — ", text(r))
    yield ""
    yield "## Findings (surfaced — reported, not touched)"
    for r in tonight:
        if r.get("outcome") == "finding":
            yield add("- ", r.get("repo"), " — ", text(r))
    yield ""
    yield "## Considered but not shipped"
    for r in tonight:
        if r.get("outcome") in CONSIDERED_OUTCOMES:
            yield add("- ", r.get("repo"), " — ", r.get("outcome"), ": ", text(r))


def _percent(part, whole):
    return math.floor(100 * part / whole)


def _verdict_index(rows, verdicts):
    """jq's `latest_branch_verdicts | map(select(.verdict as $v | VERDICTS | index($v)))
    | INDEX([.repo,.branch] | tojson)`: keyed by the tojson TEXT, so an object repo matches only
    with the same key order, while the grouping before it uses jq equality."""
    return {dumps([r.get("repo"), r.get("branch")]): r for r in latest_branch_verdict_list(rows)
            if array_index(verdicts, r.get("verdict")) is not None}


def _verdict_of(index, repo, branch):
    return field(index.get(dumps([repo, branch])), "verdict")


def _shipped_branch_rows(rows):
    return [r for r in rows if field(r, "outcome") == "shipped"
            and field(r, "repo") is not None and field(r, "branch") is not None]


def harvest_scoreboard(rows):
    """The all-time harvest line over unique shipped (repo, branch), raw repo strings; None when
    nothing shipped."""
    v = _verdict_index(rows, TERMINAL_VERDICT_ORDER)
    ship = unique([{"repo": r.get("repo"), "branch": r.get("branch")}
                   for r in _shipped_branch_rows(rows)])
    verdicts = [_verdict_of(v, b["repo"], b["branch"]) for b in ship]
    m, d = verdicts.count("merged"), verdicts.count("dropped")
    s = sum(1 for x in verdicts if x in ("resolved", "wontfix"))
    n = len(ship)
    if n == 0:
        return None
    return (f"- harvest (all-time): shipped {n} · merged {m} · dropped {d}"
            + (f" · resolved/wontfix {s}" if s > 0 else "")
            + f" · open {n - m - d - s}"
            + (f" · merge-rate {_percent(m, m + d)}%" if m + d > 0 else ""))


def exclusion_suggestions(rows, window=3):
    """(repo, dimension) whose last `window` unretracted passes were all out-of-scope empties."""
    passes = [r for r in unretracted_rows(rows)
              if field(r, "dimension") is not None and field(r, "outcome") in PASS_OUTCOMES]
    hits = [g[-window:] for g in group_by(passes, lambda r: [r.get("repo"), r.get("dimension")])]
    hits = [g for g in hits if len(g) == window and all(
        r.get("outcome") == "empty" and r.get("scope") == "out_of_scope" for r in g)]
    if not hits:
        return None
    return "\n## Suggested rulebook exclusions (ADR 0015)\n" + "\n".join(
        f"- `{tostring(g[0].get('repo'))}` × `{tostring(g[0].get('dimension'))}` — {window} "
        "consecutive out-of-scope passes; consider dropping this lens for this repo in "
        "rulebook.yaml `dimensions:`" for g in hits)


_FINDING_SUFFIX = re.compile("-f[0-9]+$")


def pass_id(item):
    """jq's `.item | sub("-f[0-9]+$"; "")`: a finding row's explore item. `$` also matches before
    a final newline, as in Oniguruma's Perl syntax; a non-string item fails."""
    if not isinstance(item, str):
        raise LedgerError(f"{jq_type(item)} ({dumps(item)}) cannot be matched, as it is not a string")
    return _FINDING_SUFFIX.sub("", item, count=1)


def empty_rate(rows):
    """Per dimension: distinct unretracted passes and how many of them were empty."""
    passes = [{"d": r.get("dimension"), "p": pass_id(r.get("item")), "e": r.get("outcome") == "empty"}
              for r in unretracted_rows(rows)
              if field(r, "dimension") is not None and field(r, "item") is not None
              and field(r, "outcome") in PASS_OUTCOMES]
    groups = group_by(passes, lambda p: p["d"])
    if not groups:
        return None
    lines = []
    for g in groups:
        n = len({p["p"] for p in g})
        e = len({p["p"] for p in g if p["e"]})
        lines.append(f"- {tostring(g[0]['d'])}: passes {n} · nothing found {e} ({_percent(e, n)}%)")
    return "\n## Nothing found, by dimension (all-time)\n" + "\n".join(lines)


MERGE_RATE_SLICES = (("dimension", "dimension"), ("verifiability", "verifiability"),
                     ("proof", "proof"), ("type", "finding type"))


def merge_rate_sections(rows):
    """One section per slice of shipped rows: unique branches per value of the SHIPPED row's field
    (a branch shipped twice with different values counts in both) and their latest merged/dropped
    verdict. jq built all four before printing any, so this is all or nothing too."""
    v = _verdict_index(rows, MERGE_RATE_VERDICT_ORDER)
    shipped = _shipped_branch_rows(rows)
    sections = []
    for key, name in MERGE_RATE_SLICES:
        lines = []
        for g in group_by(shipped, lambda r: alt(r.get(key), "—")):
            br = unique([{"repo": r.get("repo"), "branch": r.get("branch")} for r in g])
            verdicts = [_verdict_of(v, b["repo"], b["branch"]) for b in br]
            m, d = verdicts.count("merged"), verdicts.count("dropped")
            lines.append(f"- {tostring(alt(g[0].get(key), '—'))}: shipped {len(br)} · merged {m}"
                         f" · dropped {d}" + (f" · rate {_percent(m, m + d)}%" if m + d > 0 else ""))
        if lines:
            sections.append(f"\n## Merge-rate by {name} (all-time)\n" + "\n".join(lines))
    return sections


def digest_open_findings(rows):
    """The digest's carry-forward list, unlike `open_findings`: the newest `finding` per
    (repo, fingerprint) with both non-null (no item fallback, shipped rows not counted), dropped
    if any verdict on that pair was wontfix, else open when its latest verdict is `open` or older
    than the finding. Verdicts are matched by tojson text, findings come out in group order."""
    ordered = [add(r, {"__order": i}) for i, r in enumerate(rows)]
    verdicts = [r for r in ordered if r.get("outcome") == "verdict"
                and r.get("repo") is not None and r.get("fingerprint") is not None]
    identity = lambda r: [r.get("repo"), r.get("fingerprint")]  # noqa: E731
    ignored = {dumps(identity(r)) for r in verdicts if r.get("verdict") == "wontfix"}
    latest = {dumps(identity(r)): r for r in latest_fingerprint_verdicts(verdicts, identity)}
    findings = [r for r in ordered if r.get("outcome") == "finding"
                and r.get("repo") is not None and r.get("fingerprint") is not None]
    lines = []
    for work in (g[-1] for g in group_by(findings, identity)):
        key = dumps(identity(work))
        if key in ignored:
            continue
        verdict = latest.get(key) or {}
        if alt(verdict.get("verdict"), "") == "open" or alt(verdict.get("__order"), -1) < work["__order"]:
            lines.append(add("- ", work.get("repo"), " — ",
                             alt(work.get("summary"), work.get("fingerprint")), "  (",
                             work.get("fingerprint"), ", since ", work.get("night"), ")"))
    return "\n".join(lines)


# ------------------------------------------------------------------- runner questions ----
# Each answers one bin/nightshift.sh read with the bytes its jq program printed; the runner keeps
# its own guards and fallbacks (`|| true`, `|| return 0`, `date -d`, the index loops).

def _with_order(rows):
    """jq's `to_entries | map(.value + {__order: .key})`: a null row becomes {__order}, any other
    non-object fails."""
    return [add(r, {"__order": i}) for i, r in enumerate(rows)]


def fingerprint_suppressed(rows, repo, fingerprint, code_sig, outcomes):
    """Whether this repo-scoped fingerprint is suppressed (ADR 0014): ANY wontfix verdict on it,
    or ANY row in `outcomes` whose code_sig is absent, "" or equal to `code_sig`. Order is
    ignored (a later `open` does not lift a wontfix) and retractions are not consulted. A row
    with repo null counts when every non-null owner of the fingerprint is this repo."""
    owners = unique([field(r, "repo") for r in rows
                     if field(r, "fingerprint") == fingerprint and field(r, "repo") is not None])
    sole = [jq_key(o) for o in owners] == [jq_key(repo)]
    mine = [r for r in rows if field(r, "fingerprint") == fingerprint
            and (field(r, "repo") == repo or (field(r, "repo") is None and sole))]
    permanent = any(r.get("outcome") == "verdict" and r.get("verdict") == "wontfix" for r in mine)
    known = any(array_index(outcomes, r.get("outcome")) is not None
                and alt(r.get("code_sig"), "") in ("", code_sig) for r in mine)
    return permanent or known


def known_work(rows, repo, limit=40):
    """The Explore prompt's still-open work for this repo: the newest finding OR shipped row per
    fingerprint (strict repo), unless a verdict in scope was ever wontfix, open when its latest
    verdict is `open` or older than the row. Verdicts are in scope by repo or, with repo null,
    when the fingerprint's only non-null owner is this repo. A non-string fingerprint on a latest
    verdict or on a surviving work row fails the whole answer, as jq's object lookup did."""
    ordered = _with_order(rows)
    owners = {}
    for r in ordered:
        if r.get("repo") is not None:
            owners.setdefault(jq_key(r.get("fingerprint")), set()).add(jq_key(r.get("repo")))
    sole = {jq_key(repo)}
    verdicts = [v for v in ordered if v.get("outcome") == "verdict" and v.get("fingerprint") is not None
                and (v.get("repo") == repo
                     or (v.get("repo") is None and owners.get(jq_key(v.get("fingerprint"))) == sole))]
    ignored = unique([v.get("fingerprint") for v in verdicts if v.get("verdict") == "wontfix"])
    latest = {}
    for v in latest_fingerprint_verdicts(verdicts, lambda r: r.get("fingerprint")):
        key = v.get("fingerprint")
        if not isinstance(key, str):
            raise LedgerError(f"Cannot use {jq_type(key)} ({dumps(key)}) as object key")
        latest[key] = v
    work = [r for r in ordered if r.get("repo") == repo
            and r.get("outcome") in ("finding", "shipped") and r.get("fingerprint") is not None]
    work = [g[-1] for g in group_by(work, lambda r: r.get("fingerprint"))]
    work = [w for w in work if array_index(ignored, w.get("fingerprint")) is None]
    still_open = []
    for w in work:
        fp = w.get("fingerprint")
        if not isinstance(fp, str):
            raise LedgerError(f"Cannot index object with {jq_type(fp)}")
        verdict = latest.get(fp) or {}
        if (alt(verdict.get("verdict"), "") == "open"
                or alt(verdict.get("__order"), -1) < w["__order"]):
            still_open.append(w)
    return "\n".join(add("- ", w["fingerprint"], " — ", alt(w.get("summary"), ""))
                     for w in still_open[:limit])


def recent_decisions(rows, repo, limit=20):
    """The last `limit` fingerprints (strict repo, "" included) whose LAST row of any outcome is
    `abandoned` or a non-open verdict, as the search-history prompt object; not retraction-aware."""
    ordered = [r for r in _with_order(rows)
               if r.get("repo") == repo and r.get("fingerprint") is not None]
    decided = []
    for events in group_by(ordered, lambda r: r.get("fingerprint")):
        last = events[-1]
        if not (last.get("outcome") == "abandoned"
                or (last.get("outcome") == "verdict" and last.get("verdict") != "open")):
            continue
        summaries = [s for s in (alt(e.get("summary"), None) for e in events)
                     if s is not None and s != ""]
        decided.append({"fingerprint": last.get("fingerprint"),
                        "status": alt(last.get("verdict"), last.get("outcome")),
                        "ts": last.get("ts"), "__order": last["__order"],
                        "summary": head_slice(alt(summaries[-1] if summaries else None, ""), 300),
                        "reason": head_slice(alt(last.get("reason"), ""), 300)})
    decided.sort(key=lambda d: d["__order"])
    for d in decided:
        del d["__order"]
    return {"recent_decisions": decided[-limit:]}


def last_service_ts(rows, repo):
    """The jq-greatest `ts` of this repo's unretracted rows with an outcome other than verdict,
    excluding orphan adoptions (empty and failure outcomes count). The max compares the values
    as jq does, so timestamp strings compare as text; None when there is none."""
    return jq_max([field(r, "ts") for r in unretracted_rows(rows)
                   if field(r, "repo") == repo and field(r, "outcome") is not None
                   and field(r, "outcome") != "verdict" and field(r, "source") != "orphan-adopt"])


_DATE_FALLBACK = {}


def _date_fallback(ts):
    """One memoized `date -d` per DISTINCT string Python does not parse the way date does."""
    if ts not in _DATE_FALLBACK:
        import subprocess
        try:
            out = subprocess.run(["date", "-d", ts, "+%s"], capture_output=True, text=True,
                                 check=True).stdout.strip()
            _DATE_FALLBACK[ts] = int(out)
        except (OSError, ValueError, subprocess.CalledProcessError):
            _DATE_FALLBACK[ts] = 0
    return _DATE_FALLBACK[ts]


def parse_epoch(ts):
    """ISO-8601 -> epoch seconds as `date -d TS +%s` gives it; 0 for empty or unparsable.

    A trailing `Z` is UTC. Anything `fromisoformat` refuses (a nanosecond fraction, a basic-format
    stamp) falls back to `date -d`, as do naive local stamps (Python and GNU date pick different
    sides of a DST fold) and negative epochs (`int()` truncates toward zero, `date` floors)."""
    from datetime import datetime
    s = ts.strip()
    if not s:
        return 0
    iso = s[:-1] + "+00:00" if s[-1] in "Zz" else s
    try:
        parsed = datetime.fromisoformat(iso)
        if parsed.tzinfo is None:
            return _date_fallback(s)
        epoch = parsed.timestamp()
        if epoch < 0:
            return _date_fallback(s)
        return int(epoch)
    except (ValueError, OverflowError, OSError):
        return _date_fallback(s)


def epoch_field(line, field_no):
    """Field `field_no` (1-based) of a TSV line as an epoch; an empty field stays empty (the
    index loop skips it) and an unparsable one scores 0 for its own row."""
    cols = line.split("\t")
    if field_no <= len(cols) and cols[field_no - 1].strip():
        cols[field_no - 1] = str(parse_epoch(cols[field_no - 1]))
    return "\t".join(cols)


def dimension_epoch_lines(rows):
    """The rows the epoch index is built from, as `@tsv` lines with the ts field as an epoch:
    one `svc` row per (repo, dimension) with the jq-greatest ts over finding|shipped|abandoned
    (text comparison of the stamps, not retraction-aware, `empty` excluded), then one `ship`
    row per shipped row (the index takes the max over these epochs). Lazy: a value @tsv
    rejects ends the output at that row, as jq's stream did."""
    keyed = [r for r in rows if field(r, "repo") is not None and field(r, "dimension") is not None]
    service = [r for r in keyed if r.get("outcome") in ("finding", "shipped", "abandoned")]
    out = [["svc", m.get("repo"), m.get("dimension"), m.get("ts")]
           for m in (jq_max(g, lambda r: r.get("ts"))
                     for g in group_by(service, lambda r: [r.get("repo"), r.get("dimension")]))]
    out += [["ship", r.get("repo"), r.get("dimension"), r.get("ts")]
            for r in keyed if r.get("outcome") == "shipped"]
    for values in out:
        yield epoch_field(tsv(values), 4)


_SIBLING = re.compile(r"^(item-[0-9]+)-f[0-9]+$")


def median_gap_lines(lines):
    """"repo<TAB>ts<TAB>item" lines -> one "repo<TAB>n<TAB>median" per repo, in first-seen order.

    `n` counts Explore passes with a parsed timestamp: item-<epoch>-fN siblings are one pass at
    their earliest valid epoch, other item ids stay as they are, and a row without an item counts
    on its own. Epoch 0 is not a service; fewer than two passes give median 0. The bootstrap and
    the floor stay in the runner, where the dimension count lives."""
    per_repo = {}
    for row, line in enumerate(lines):
        cols = line.split("\t")
        repo = cols[0]
        if not repo:
            continue
        services = per_repo.setdefault(repo, {})
        ts = cols[1] if len(cols) > 1 else ""
        item = cols[2] if len(cols) > 2 else ""
        e = parse_epoch(ts)
        if e > 0:
            service = _SIBLING.sub(r"\1", item) if item else row
            services[service] = min(e, services.get(service, e))
    result = []
    for repo, services in per_repo.items():
        eps = sorted(services.values())
        gaps = sorted(b - a for a, b in zip(eps, eps[1:]))
        n = len(gaps)
        if n == 0:
            median = 0
        elif n % 2:
            median = gaps[(n - 1) // 2]
        else:
            median = (gaps[n // 2 - 1] + gaps[n // 2]) // 2
        result.append("%s\t%d\t%d" % (repo, len(eps), median))
    return result


def service_gap_lines(rows):
    """The gap index: per repo, distinct unretracted passes (finding|shipped|abandoned|empty) and
    the median gap between them. Raises like jq's stream, but only after printing what the old
    converter printed for the rows before the failing one."""
    lines = []
    try:
        for r in unretracted_rows(rows):
            if field(r, "repo") is not None and field(r, "outcome") in PASS_OUTCOMES:
                lines.append(tsv([r.get("repo"), r.get("ts"), r.get("item")]))
    except LedgerError:
        _lines(median_gap_lines(lines))
        raise
    return median_gap_lines(lines)


def settled_branches(rows):
    """`repo<TAB>branch` lines of the pairs whose last-appended verdict is terminal (raw repo
    strings, an empty branch kept)."""
    return join([add(r.get("repo"), "\t", r.get("branch")) for r in latest_branch_verdict_list(rows)
                 if array_index(list(TERMINAL_VERDICT_ORDER), r.get("verdict")) is not None], "\n")


def last_shipped_context(rows, repo, branch):
    """The branch advisor's context from the LAST shipped row for this raw (repo, branch)."""
    hits = [r for r in rows if field(r, "outcome") == "shipped"
            and field(r, "repo") == repo and field(r, "branch") == branch]
    row = hits[-1] if hits else {}
    return {k: alt(row.get(k), "") for k in ("summary", "fingerprint", "type", "dimension")}


# --------------------------------------------------------------------------- writers ----

def _null(value):
    return None if value == "" else value


def append(path, row):
    """Append one row with ONE write() on an O_APPEND descriptor: a manual harvest can run beside
    the night and there is no ledger lock, so a row must never be split or read back first."""
    data = (dumps(row) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o666)
    try:
        written = os.write(fd, data)
    finally:
        os.close(fd)
    if written != len(data):
        raise OSError(f"short write to {path}: {written} of {len(data)} bytes")


def run_row(night, ts, item, repo, fingerprint, branch, sha, outcome, summary="", pr_url="",
            proof="", verifiability="", dimension="", type_="", code_sig="", scope=""):
    """A runner outcome row (finding, shipped, empty, the failure outcomes). No schema_version;
    the fingerprint and summary keep "" while the optional columns turn it into null."""
    return {"night": night, "item": item, "repo": repo, "fingerprint": fingerprint,
            "branch": _null(branch), "sha": _null(sha), "pr_url": _null(pr_url),
            "proof": _null(proof), "verifiability": _null(verifiability),
            "dimension": _null(dimension), "type": _null(type_), "code_sig": _null(code_sig),
            "scope": _null(scope), "outcome": outcome, "summary": summary, "ts": ts}


def finding_verdict_row(night, ts, item, repo, fingerprint, verdict, reason=""):
    """The verify stage's machine verdict on a finding; the fingerprint keeps ""."""
    return {"night": night, "item": item, "repo": repo, "fingerprint": fingerprint,
            "branch": None, "sha": None, "outcome": "verdict", "verdict": verdict,
            "reason": _null(reason), "source": "auto-verify", "ts": ts,
            "schema_version": SCHEMA_VERSION}


def verdict_row(night, ts, item, repo, fingerprint, branch, sha, verdict, reason="", source=""):
    """A harvest verdict (manual, or reconcile with no source); night is the calendar day."""
    return {"night": night, "item": item, "repo": repo, "fingerprint": _null(fingerprint),
            "branch": _null(branch), "sha": _null(sha), "outcome": "verdict", "verdict": verdict,
            "reason": _null(reason), "source": _null(source), "ts": ts,
            "schema_version": SCHEMA_VERSION}


def adoption_row(night, ts, repo, branch, sha):
    """The synthetic shipped row for an orphan branch (ADR 0018); `item` is the last key."""
    row = {"night": night, "repo": repo, "fingerprint": None, "branch": branch,
           "sha": _null(sha), "pr_url": None, "outcome": "shipped", "source": "orphan-adopt",
           "adopted": True, "summary": ADOPTED_SUMMARY, "ts": ts,
           "schema_version": SCHEMA_VERSION}
    row["item"] = adopted_item_id(row)
    return row


def retraction_row(night, ts, item, repo, dimension, retracted_night, reason=""):
    """Withdraws one `empty` row as evidence; night is the calendar day of the retraction."""
    return {"night": night, "item": item, "repo": repo, "fingerprint": None, "branch": None,
            "sha": None, "outcome": "retracted", "retracts": "empty",
            "retracted_night": retracted_night, "dimension": _null(dimension),
            "reason": _null(reason), "source": "manual", "ts": ts,
            "schema_version": SCHEMA_VERSION}


# ------------------------------------------------------------------------------- CLI ----

USAGE = """usage: ledger.py [--ledger PATH] <command> [args]   (PATH defaults to $LEDGER)
writers (timestamps come from the caller; missing trailing arguments are ""):
  append-run NIGHT TS ITEM REPO FP BRANCH SHA OUTCOME [SUMMARY PR_URL PROOF VERIFIABILITY
             DIMENSION TYPE CODE_SIG SCOPE]
  append-finding-verdict NIGHT TS ITEM REPO FP VERDICT [REASON]
  append-verdict NIGHT TS ITEM REPO FP BRANCH SHA VERDICT [REASON SOURCE]
  adopt-orphan NIGHT TS REPO BRANCH SHA
  append-retraction NIGHT TS ITEM REPO DIMENSION RETRACTED_NIGHT [REASON]
readers:
  validate [--require-truthy-last]   jq empty / jq -e . (also fails when empty or last is null/false)
  verdict-names [SEP]                the verdicts `harvest.sh verdict` accepts
  last-branch-verdict REPO BRANCH    "verdict<TAB>source" of the latest verdict for that raw pair
  branch-verdicts                    repo␟branch␟verdict␟source per pair with non-empty repo/branch
  known-branches                     repo␟branch of every row with non-empty repo and branch
  reconcile-rows                     item␟repo␟fp␟branch␟sha␟pr_url of every shipped row with branch+sha
  unretracted-empty NIGHT            JSON array of that night's empty rows not yet retracted
  verdict-matches SCOPE SELECTOR     JSON array of rows `harvest.sh verdict` may target
digest sections (markdown lines; nothing when the section is empty):
  night-count NIGHT OUTCOME          number of that night's rows with that outcome
  night-section SECTION NIGHT        streamed lines of that night: shipped | findings | considered
  interrupted-summary NIGHT          the interrupted digest's Shipped/Findings/Considered sections
  harvest-scoreboard                 the all-time shipped/merged/dropped/open line
  exclusion-suggestions              (repo, dimension) with 3 consecutive out-of-scope passes
  empty-rate                         passes and empty passes per dimension
  merge-rate                         merge-rate by dimension, verifiability, proof, finding type
  open-findings-digest               open findings of all nights (an empty line when none)
runner questions:
  fingerprint-suppressed REPO FP CODE_SIG OUTCOMES_JSON
                                     prints true/false; exit 0 when suppressed, 1 when not
  known-work REPO                    "- fp — summary" lines of still-open work (at most 40)
  recent-decisions REPO              {"recent_decisions": [...]} pretty-printed, the last 20
  last-service-ts REPO               the greatest ts of the repo's service rows (nothing if none)
  dimension-epochs                   svc|ship<TAB>repo<TAB>dimension<TAB>epoch rows for the epoch index
  service-gaps                       repo<TAB>passes<TAB>median gap rows for the gap index
  settled-branches                   repo<TAB>branch of every pair whose latest verdict is terminal
  last-shipped REPO BRANCH           {summary,fingerprint,type,dimension} of the last shipped row
"""

_WRITERS = {
    "append-run": (run_row, 16),
    "append-finding-verdict": (finding_verdict_row, 7),
    "append-verdict": (verdict_row, 10),
    "adopt-orphan": (adoption_row, 5),
    "append-retraction": (retraction_row, 7),
}


def _out(text):
    sys.stdout.buffer.write(text.encode("utf-8"))


def _lines(lines):
    for line in lines:
        _out(line + "\n")


def _slurp_command(path, run):
    """Run a `jq -s` question. jq 1.7 still runs the program on [] when the file is missing, and
    then exits 2; a parse or type error fails before any output."""
    try:
        rows = read_values(path)
    except LedgerError as e:
        if e.code != 2:
            raise
        run([])
        raise
    run(rows)


def main(argv):
    path = os.environ.get("LEDGER")
    if len(argv) >= 2 and argv[0] == "--ledger":
        path, argv = argv[1], argv[2:]
    if not argv or argv[0] in ("-h", "--help"):
        _out(USAGE)
        return 0 if argv else 2
    command, args = argv[0], [arg(a) for a in argv[1:]]

    if command == "verdict-names":
        _out((args[0] if args else " ").join(MANUAL_VERDICTS) + "\n")
        return 0
    if not path:
        sys.stderr.write("ledger.py: no ledger path (set LEDGER or pass --ledger)\n")
        return 2

    if command in _WRITERS:
        build, arity = _WRITERS[command]
        args = (args + [""] * arity)[:arity]
        append(path, build(*args))
        return 0

    if command == "validate":
        truthy_last = args[:1] == ["--require-truthy-last"]
        last, seen = None, False
        for last in iter_values(path):
            seen = True
        if truthy_last and not seen:
            return 4
        if truthy_last and (last is None or last is False):
            return 1
        return 0
    if command == "verdict-matches":
        scope, selector = (args + ["", ""])[:2]
        failed = False
        if scope == "findings":
            candidates = open_findings(
                read_rows_skipping_bad(path, errors="replace", dicts_only=True))
        else:
            candidates, failed = work_rows(path)
        _out(dumps(verdict_matches(candidates, scope, selector)) + "\n")
        return 5 if failed else 0
    if command == "night-section":
        section, night = (args + ["", ""])[:2]

        def each(value):
            line = night_line(value, section, night)
            if line is not None:
                _out(line + "\n")
        return 5 if stream_values(path, each) else 0

    if command == "last-branch-verdict":
        repo, branch = (args + ["", ""])[:2]

        def run(rows):
            row = last_branch_verdict(rows, repo, branch) or {}
            _out(f"{tostring(alt(row.get('verdict'), ''))}\t{tostring(alt(row.get('source'), ''))}\n")
        _slurp_command(path, run)
        return 0
    if command == "fingerprint-suppressed":
        repo, fingerprint, code_sig, outcomes = (args + ["", "", "", "[]"])[:4]
        try:
            outcomes = json.loads(outcomes)
        except ValueError:
            sys.stderr.write("ledger.py: OUTCOMES_JSON is not JSON\n")
            return 2
        answer = []

        def run(rows):
            answer.append(fingerprint_suppressed(rows, repo, fingerprint, code_sig, outcomes))
            _out(dumps(answer[-1]) + "\n")
        _slurp_command(path, run)
        return 0 if answer[-1] else 1
    slurped = {
        "branch-verdicts": lambda rows: _lines(branch_verdict_lines(rows)),
        "known-branches": lambda rows: _lines(known_branch_lines(rows)),
        "reconcile-rows": lambda rows: _lines(reconcile_lines(rows)),
        "unretracted-empty": lambda rows: _out(
            dumps(unretracted_empty_rows(rows, (args + [""])[0])) + "\n"),
        "night-count": lambda rows: _out(f"{night_count(rows, *(args + ['', ''])[:2])}\n"),
        "interrupted-summary": lambda rows: _lines(interrupted_lines(rows, (args + [""])[0])),
        "harvest-scoreboard": lambda rows: _lines(filter(None, [harvest_scoreboard(rows)])),
        "exclusion-suggestions": lambda rows: _lines(filter(None, [exclusion_suggestions(rows)])),
        "empty-rate": lambda rows: _lines(filter(None, [empty_rate(rows)])),
        "merge-rate": lambda rows: _lines(merge_rate_sections(rows)),
        "open-findings-digest": lambda rows: _out(digest_open_findings(rows) + "\n"),
        "known-work": lambda rows: _out(known_work(rows, (args + [""])[0]) + "\n"),
        "recent-decisions": lambda rows: _out(
            dumps_pretty(recent_decisions(rows, (args + [""])[0])) + "\n"),
        "last-service-ts": lambda rows: _lines(
            raw_output(ts) for ts in [last_service_ts(rows, (args + [""])[0])] if truthy(ts)),
        "dimension-epochs": lambda rows: _lines(dimension_epoch_lines(rows)),
        "service-gaps": lambda rows: _lines(service_gap_lines(rows)),
        "settled-branches": lambda rows: _out(settled_branches(rows) + "\n"),
        "last-shipped": lambda rows: _out(
            dumps(last_shipped_context(rows, *(args + ["", ""])[:2])) + "\n"),
    }
    if command in slurped:
        _slurp_command(path, slurped[command])
        return 0
    sys.stderr.write(f"ledger.py: unknown command {command!r}\n{USAGE}")
    return 2


def cli(argv):
    """`main` with a failed read turned into jq's exit status and a message on stderr."""
    try:
        return main(argv)
    except LedgerError as e:
        sys.stdout.flush()
        sys.stderr.write(f"ledger.py: {e}\n")
        return e.code


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
