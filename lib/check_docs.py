#!/usr/bin/env python3
"""Fails when the docs make a checkable claim about the repo that is no longer true.

Docs rot in one specific, mechanical way: they name a thing — a file, an ADR, a line — and that
thing moves or disappears. Prose drift needs a reader; *this* kind needs a `test -e`. Nightshift
has shipped exactly these as findings (`risk-analysis.md` citing `nightshift.sh:176` after the
flag moved to 186; the prototype Files table omitting `lib/extract_json.py`), which is proof the
class is real and proof it is worth catching before a human is spent on it.

Four claims are checked, all with the same shape — the doc says X exists, so X must exist:

  1. relative markdown links            [text](docs/design/foo.md)
  2. ADR references in prose            "ADR 0022"          -> docs/adr/0022-*.md
  3. backticked in-repo paths           `bin/harvest.sh`    (source dirs only)
  4. file:line citations                `nightshift.sh:186` -> file has >= 186 lines

Deliberately NOT checked: whether the prose is *right*. A line citation that still resolves may
still describe the wrong code. This tool refuses only what it can refuse without a judgement call —
everything softer is a job for a reader, and a linter that guesses is a linter people switch off.

Usage: check_docs.py [repo_root]   ->   exit 0 clean, 1 with one finding per line on stdout.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# Only directories whose contents are tracked source. `state/`, `runs/`, `digests/` and
# `worktrees/` are runtime state: they are gitignored, absent in a fresh clone, and naming one in
# prose is not a claim that it exists right now.
SOURCE_DIRS = ("bin", "lib", "prompts", "hooks", "tests", "docs")

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
ADR = re.compile(r"\bADR\s+(\d{4})\b")
PATH = re.compile(r"`((?:%s)/[A-Za-z0-9_./*{},-]+)`" % "|".join(SOURCE_DIRS))
CITE = re.compile(r"`([A-Za-z0-9_./-]+\.(?:sh|py|md|yaml|yml)):(\d+)(?:-[A-Za-z]?\d+)?`")


def tracked_markdown(root: Path) -> list[Path]:
    """Every tracked .md file. Tracked, not globbed: a scratch note in the tree is not a doc."""
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "*.md"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    return [root / p for p in out]


def expand(pattern: str) -> list[str]:
    """`prompts/{recon,fix}.md` -> two paths. One brace group is all the docs actually use."""
    m = re.search(r"\{([^}]*)\}", pattern)
    if not m:
        return [pattern]
    return [pattern[: m.start()] + alt + pattern[m.end():] for alt in m.group(1).split(",")]


def exists(root: Path, rel: str) -> bool:
    """A glob counts as satisfied if it matches anything — `prompts/dimensions/*.md` is a claim
    about the directory's contents, not about one file."""
    if "*" in rel or "?" in rel:
        try:
            return any(root.glob(rel))
        except (ValueError, IndexError):
            return False
    return (root / rel).exists()


def check(root: Path) -> list[str]:
    findings: list[str] = []
    adr_dir = root / "docs" / "adr"
    for doc in tracked_markdown(root):
        rel_doc = doc.relative_to(root)
        try:
            lines = doc.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError) as exc:  # a doc we cannot read is a finding, not a crash
            findings.append(f"{rel_doc}: unreadable ({exc})")
            continue

        for n, line in enumerate(lines, 1):
            where = f"{rel_doc}:{n}"

            # 1. links — resolved relative to the FILE, which is what a reader's click does.
            for target in LINK.findall(line):
                if target.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                path = target.split("#", 1)[0]
                if not path:
                    continue
                if not (doc.parent / path).exists():
                    findings.append(f"{where}: dead link -> {target}")

            # 2. ADR references — the number must resolve to exactly one ADR file.
            for num in ADR.findall(line):
                if not list(adr_dir.glob(f"{num}-*.md")):
                    findings.append(f"{where}: ADR {num} referenced but docs/adr/{num}-*.md is missing")

            # 3. backticked in-repo paths.
            for raw in PATH.findall(line):
                for cand in expand(raw):
                    if not exists(root, cand):
                        findings.append(f"{where}: names `{cand}`, which does not exist")

            # 4. file:line citations — the file must exist AND be long enough to have that line.
            for name, num in CITE.findall(line):
                matches = [p for p in root.rglob(name.split("/")[-1]) if p.is_file()] \
                    if "/" not in name else ([root / name] if (root / name).exists() else [])
                matches = [p for p in matches if ".git" not in p.parts]
                if not matches:
                    continue  # not a repo file (an example, another project) — not our claim to check
                if len(matches) > 1:
                    continue  # ambiguous basename; refusing on a guess is worse than not checking
                target = matches[0]
                try:
                    count = sum(1 for _ in target.open("rb"))
                except OSError:
                    continue
                if int(num) > count:
                    findings.append(
                        f"{where}: cites {name}:{num}, but that file has only {count} lines"
                    )
    return findings


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    findings = check(root)
    for f in findings:
        print(f)
    if findings:
        print(f"\n{len(findings)} stale doc reference(s).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
