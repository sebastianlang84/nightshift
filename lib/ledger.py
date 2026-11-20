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

bin/harvest.sh reads and writes only through this module; bin/nightshift.sh writes through it.
The runner's and the digest's remaining reads still use lib/ledger.jq; keep its verdict sets and
definitions in step with the ones here until they are ported.

CLI: python3 lib/ledger.py [--ledger PATH] <command> [args]; PATH defaults to $LEDGER.
"""

import json
import os
import re
import sys
from collections import Counter
from os.path import basename

TERMINAL_VERDICT_ORDER = ("merged", "dropped", "resolved", "wontfix")
TERMINAL_VERDICTS = frozenset(TERMINAL_VERDICT_ORDER)
MERGE_RATE_VERDICTS = frozenset({"merged", "dropped"})
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
        if _has_lone_surrogate(value):
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


def work_rows(path):
    """Shipped and finding rows in append order, as the streaming `jq -c 'select(...)'` gave them,
    and whether the run failed. That jq reported a row it cannot index (a number, string, array or
    boolean), went on with the next row, and failed only if the LAST row was such a row; a parse
    error fails the whole read (LedgerError)."""
    rows, failed = [], False
    for value in iter_values(path):
        try:
            outcome = field(value, "outcome")
        except LedgerError as e:
            sys.stderr.write(f"ledger.py: {e}\n")
            failed = True
            continue
        failed = False
        if outcome in ("shipped", "finding"):
            rows.append(value)
    return rows, failed


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

    if command == "last-branch-verdict":
        repo, branch = (args + ["", ""])[:2]

        def run(rows):
            row = last_branch_verdict(rows, repo, branch) or {}
            _out(f"{tostring(alt(row.get('verdict'), ''))}\t{tostring(alt(row.get('source'), ''))}\n")
        _slurp_command(path, run)
        return 0
    slurped = {
        "branch-verdicts": lambda rows: _lines(branch_verdict_lines(rows)),
        "known-branches": lambda rows: _lines(known_branch_lines(rows)),
        "reconcile-rows": lambda rows: _lines(reconcile_lines(rows)),
        "unretracted-empty": lambda rows: _out(
            dumps(unretracted_empty_rows(rows, (args + [""])[0])) + "\n"),
    }
    if command in slurped:
        _slurp_command(path, slurped[command])
        return 0
    sys.stderr.write(f"ledger.py: unknown command {command!r}\n{USAGE}")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except LedgerError as e:
        sys.stdout.flush()
        sys.stderr.write(f"ledger.py: {e}\n")
        sys.exit(e.code)
