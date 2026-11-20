#!/usr/bin/env bash
unset GIT_CONFIG_COUNT
set -euo pipefail

# lib/ledger.py is the ledger's writer and reader. Asserted on synthetic rows: the writers emit the
# bytes `jq -nc` wrote (key order, nulls, escapes, invalid UTF-8 replaced as jq does), appends stay
# whole under concurrency, each harvest query answers as its jq predecessor did, and reads fail
# where jq failed (missing file 2, malformed or un-indexable row 5) instead of skipping lines.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(root / "lib"))
import ledger as L

CLI = [sys.executable, str(root / "lib/ledger.py")]


def cli(path, *args, input_rows=None):
    p = subprocess.run(CLI + ["--ledger", str(path), *args], capture_output=True)
    return p.returncode, p.stdout, p.stderr


def ledger_file(name, lines):
    path = tmp / name
    path.write_bytes(b"".join((l if isinstance(l, bytes) else l.encode()) + b"\n" for l in lines))
    return path


# ---- writers: exact bytes ----
out = tmp / "w.jsonl"
assert cli(out, "append-run", "2026-01-01", "TS", "item-1", "/r", "", "", "", "empty", "",
           "", "", "", "deps", "", "", "out_of_scope")[0] == 0
assert out.read_bytes() == (
    b'{"night":"2026-01-01","item":"item-1","repo":"/r","fingerprint":"","branch":null,"sha":null,'
    b'"pr_url":null,"proof":null,"verifiability":null,"dimension":"deps","type":null,'
    b'"code_sig":null,"scope":"out_of_scope","outcome":"empty","summary":"","ts":"TS"}\n')
out.unlink()
cli(out, "append-finding-verdict", "N", "TS", "i", "/r", "", "resolved")
cli(out, "append-verdict", "D", "TS", "i", "/r", "", "", "", "merged")
cli(out, "adopt-orphan", "D", "TS", "/r", "nightshift/b", "")
cli(out, "append-retraction", "D", "TS", "i", "/r", "", "2026-01-01", "why")
assert out.read_text().splitlines() == [
    '{"night":"N","item":"i","repo":"/r","fingerprint":"","branch":null,"sha":null,"outcome":"verdict",'
    '"verdict":"resolved","reason":null,"source":"auto-verify","ts":"TS","schema_version":2}',
    '{"night":"D","item":"i","repo":"/r","fingerprint":null,"branch":null,"sha":null,"outcome":"verdict",'
    '"verdict":"merged","reason":null,"source":null,"ts":"TS","schema_version":2}',
    '{"night":"D","repo":"/r","fingerprint":null,"branch":"nightshift/b","sha":null,"pr_url":null,'
    '"outcome":"shipped","source":"orphan-adopt","adopted":true,'
    '"summary":"adopted orphan branch (lost shipped row restored)","ts":"TS","schema_version":2,'
    '"item":"orphan-adopt:/r:nightshift/b"}',
    '{"night":"D","item":"i","repo":"/r","fingerprint":null,"branch":null,"sha":null,"outcome":"retracted",'
    '"retracts":"empty","retracted_night":"2026-01-01","dimension":null,"reason":"why","source":"manual",'
    '"ts":"TS","schema_version":2}']

# Escapes and invalid UTF-8 exactly as jq's --arg and -c produce them.
weird = [b'q"\\/\t\n\x01\x1f\x7f', "é 😀".encode(), b"\xff\xc3(\xed\xa0\x80\xf4\x90\x80\x80ab\xf0a",
         b"x" * 300]
for value in weird:
    out.unlink(missing_ok=True)
    subprocess.run(CLI + ["--ledger", str(out), "append-verdict", "D", "TS", "i", "r", "", "", "", "open",
                          os.fsdecode(value)], check=True)
    want = subprocess.run(["jq", "-nc", "--arg", "v", os.fsdecode(value),
                           '{night:"D",item:"i",repo:"r",fingerprint:null,branch:null,sha:null,'
                           'outcome:"verdict",verdict:"open",reason:$v,source:null,ts:"TS",schema_version:2}'],
                          capture_output=True, check=True).stdout
    assert out.read_bytes() == want, (value, out.read_bytes(), want)

# Concurrent appends never interleave: one write() per row on O_APPEND.
out.unlink()
procs = [subprocess.Popen(CLI + ["--ledger", str(out), "append-run", "N", "TS", f"item-{i}", "/r", "f",
                                 "", "", "finding", "s" * 20000]) for i in range(16)]
assert all(p.wait() == 0 for p in procs)
lines = out.read_text().splitlines()
assert len(lines) == 16 and all(json.loads(l)["summary"] == "s" * 20000 for l in lines)

# ---- queries ----
A = "/srv/a"
rows = [
    {"item": "i1", "repo": A, "fingerprint": "f1", "branch": "nightshift/x", "sha": "s1", "outcome": "shipped"},
    {"item": "i2", "repo": A + "/", "fingerprint": None, "branch": "nightshift/x", "sha": "s2", "outcome": "shipped"},
    {"item": "i3", "repo": A, "branch": "", "sha": "s3", "outcome": "shipped"},
    {"item": "i4", "repo": A, "branch": "nightshift/nosha", "outcome": "shipped"},
    {"repo": "/srv/b", "branch": "nightshift/o", "sha": "s5", "outcome": "shipped", "item": "orphan-adopt:/srv/b:nightshift/o"},
    {"item": "i1", "repo": A, "branch": "nightshift/x", "outcome": "verdict", "verdict": "dropped", "source": "manual", "ts": "2099"},
    {"item": "i1", "repo": A, "branch": "nightshift/x", "outcome": "verdict", "verdict": "merged", "ts": "2000"},
    {"item": "i2", "repo": A + "/", "branch": "nightshift/x", "outcome": "verdict", "verdict": "open"},
    {"item": "i3", "repo": A, "branch": "", "outcome": "verdict", "verdict": "wontfix", "source": "manual"},
    {"night": "2026-01-06", "item": "e1", "repo": A, "outcome": "empty"},
    {"night": "2026-01-06", "item": "e2", "repo": A, "outcome": "empty"},
    {"night": "2026-01-07", "item": "e1", "outcome": "retracted"},
    {"item": "f9", "repo": A, "fingerprint": "fp9", "outcome": "finding"},
    None,
]
lg = ledger_file("q.jsonl", [json.dumps(r) for r in rows[:7]] + [""] + [json.dumps(r) for r in rows[7:]])
assert cli(lg, "last-branch-verdict", A, "nightshift/x")[:2] == (0, b"merged\t\n")
assert cli(lg, "last-branch-verdict", A, "")[:2] == (0, b"wontfix\tmanual\n")    # "" branch kept here
assert cli(lg, "last-branch-verdict", A, "nope")[:2] == (0, b"\t\n")
# group_by order (repo "/srv/a" < "/srv/a/"), "" branch dropped
assert cli(lg, "branch-verdicts")[:2] == (
    0, b"/srv/a\x1fnightshift/x\x1fmerged\x1f\n/srv/a/\x1fnightshift/x\x1fopen\x1f\n")
assert cli(lg, "known-branches")[1].decode().splitlines() == [
    f"{A}\x1fnightshift/x", f"{A}/\x1fnightshift/x", f"{A}\x1fnightshift/nosha", "/srv/b\x1fnightshift/o",
    f"{A}\x1fnightshift/x", f"{A}\x1fnightshift/x", f"{A}/\x1fnightshift/x"]
assert cli(lg, "reconcile-rows")[1].decode().splitlines() == [   # every shipped row with branch+sha
    f"i1\x1f{A}\x1ff1\x1fnightshift/x\x1fs1\x1f", f"i2\x1f{A}/\x1f\x1fnightshift/x\x1fs2\x1f",
    f"i3\x1f{A}\x1f\x1f\x1fs3\x1f", "orphan-adopt:/srv/b:nightshift/o\x1f/srv/b\x1f\x1fnightshift/o\x1fs5\x1f"]
rc, o, _ = cli(lg, "unretracted-empty", "2026-01-06")
assert rc == 0 and [r["item"] for r in json.loads(o)] == ["e2"]
assert cli(lg, "unretracted-empty", "2026-01-07")[1] == b"[]\n"
m = json.loads(cli(lg, "verdict-matches", "all", "nightshift/x")[1])
assert [(r["item"], r["selector"], r["adoption"]) for r in m] == [("i1", "i1", False), ("i2", "i2", False)]
m = json.loads(cli(lg, "verdict-matches", "adopted", "orphan-adopt:/srv/b:nightshift/o")[1])
assert [r["adoption"] for r in m] == [True]
m = json.loads(cli(lg, "verdict-matches", "findings", "fp9")[1])
assert [r["item"] for r in m] == ["f9"]
assert cli(lg, "verdict-names", " | ")[1] == b"merged | dropped | resolved | wontfix | open\n"

# ---- failures: as jq ----
missing = tmp / "missing.jsonl"
assert cli(missing, "known-branches")[0] == 2
assert cli(missing, "last-branch-verdict", "a", "b")[:2] == (2, b"\t\n")   # jq -s ran on [] first
bad = ledger_file("bad.jsonl", [json.dumps(rows[0]), '{"outcome":'])
for args in (["validate"], ["branch-verdicts"], ["known-branches"], ["unretracted-empty", "x"],
             ["verdict-matches", "all", "i1"]):
    rc, o, e = cli(bad, *args)
    assert rc == 5 and o == b"" and e, (args, rc, o)
num = ledger_file("num.jsonl", [json.dumps(rows[0]), "5", json.dumps(rows[4])])
assert cli(num, "validate")[0] == 0
assert cli(num, "branch-verdicts")[0] == 5
rc, o, _ = cli(num, "known-branches")              # lines before the bad row, then the error
assert rc == 5 and o == f"{A}\x1fnightshift/x\n".encode()
assert cli(num, "verdict-matches", "all", "i1")[0] == 0     # streamed: a bad row in the middle is skipped
assert cli(ledger_file("numlast.jsonl", [json.dumps(rows[0]), "5"]), "verdict-matches", "all", "i1")[0] == 5
obj = ledger_file("obj.jsonl", [json.dumps(rows[0]), json.dumps(dict(rows[1], repo={"x": 1})), json.dumps(rows[4])])
rc, o, _ = cli(obj, "reconcile-rows")
assert rc == 5 and o.decode().splitlines() == [f"i1\x1f{A}\x1ff1\x1fnightshift/x\x1fs1\x1f"]
assert cli(ledger_file("empty.jsonl", []), "validate")[0] == 0
assert cli(tmp / "empty.jsonl", "validate", "--require-truthy-last")[0] == 4
assert cli(ledger_file("lastnull.jsonl", [json.dumps(rows[0]), "null"]), "validate", "--require-truthy-last")[0] == 1
assert cli(ledger_file("surrogate.jsonl", ['{"item":"\\ud800"}']), "validate")[0] == 5

# ---- the ledger.jq definitions, while that file still exists ----
jqlib = root / "lib/ledger.jq"
if jqlib.exists():
    def jq(program, data):
        p = subprocess.run(["jq", "-L", str(root / "lib"), "-c", 'include "ledger"; ' + program],
                           input=json.dumps(data), text=True, capture_output=True, check=True)
        return json.loads(p.stdout)
    mixed = [dict(r) for r in rows if r] + [
        {"outcome": "verdict", "repo": 1, "branch": "b", "verdict": "x", "fingerprint": True},
        {"outcome": "verdict", "repo": True, "branch": "b", "verdict": "y", "fingerprint": 1},
        {"outcome": "verdict", "repo": "a", "branch": ["b"], "fingerprint": "f"},
        {"outcome": "retracted", "item": None}]
    assert L.latest_branch_verdict_list(mixed) == jq("latest_branch_verdicts", mixed)
    assert L.latest_fingerprint_verdicts(mixed, lambda r: r.get("fingerprint")) == jq(
        "latest_fingerprint_verdicts(.fingerprint)", mixed)
    assert L.latest_fingerprint_verdicts(mixed, lambda r: [r.get("repo"), r.get("fingerprint")]) == jq(
        "latest_fingerprint_verdicts([.repo,.fingerprint])", mixed)
    assert L.unretracted_rows(mixed) == jq("[unretracted_rows]", mixed)
    assert [L.is_adoption(r) for r in mixed] == jq("map(is_adoption)", mixed)
print("ledger module: writer bytes, whole appends, queries and jq failure behaviour hold")
PY
