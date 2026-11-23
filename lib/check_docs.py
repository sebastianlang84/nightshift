#!/usr/bin/env python3
"""Fails when the docs make a checkable claim about the repo that is no longer true.

Docs rot in one specific, mechanical way: they name a thing — a file, an ADR, a line — and that
thing moves or disappears. Prose drift needs a reader; *this* kind needs a `test -e`. Nightshift
has shipped exactly these as findings (`risk-analysis.md` citing `nightshift.sh:176` after the
flag moved to 186; the prototype Files table omitting `lib/extract_json.py`), which is proof the
class is real and proof it is worth catching before a human is spent on it.

Five claims are checked, all with the same shape — the doc says X exists, so X must exist:

  1. relative markdown links            [text](docs/design/foo.md)
  2. ADR references in prose            "ADR 0022"          -> docs/adr/0022-*.md
  3. backticked in-repo paths           `bin/harvest.sh`    (source dirs only)
  4. file:line citations                `nightshift.sh:186` -> file has >= 186 lines (and a range
                                        `:186-190` has >= 190)
  5. file:line citations in comments    as 4, backticks optional, on lines whose first non-blank
                                        is `#` in tracked *.sh / *.py files and extensionless
                                        scripts under bin/ lib/ hooks/ tests/ .githooks/; a cited
                                        basename that no tracked file has is a finding too
                                        (the same lines are also checked for claim 2)

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
SCRIPT_DIRS = ("bin", "lib", "hooks", "tests", ".githooks")
# A cited file is `name.ext`, or an extensionless script rooted in SCRIPT_DIRS (`hooks/pre-push`).
# Groups: file, first line, range end (absent for a single line).
CITE_BODY = (r"([A-Za-z0-9_./-]+\.(?:sh|py|md|yaml|yml)|(?:%s)/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*)"
             r":(\d+)(?:-[A-Za-z]?(\d+))?" % "|".join(re.escape(d) for d in SCRIPT_DIRS))
CITE = re.compile(r"`%s`" % CITE_BODY)
COMMENT_CITE = re.compile(r"(?<![A-Za-z0-9_./-])%s" % CITE_BODY)


def tracked(root: Path, *pathspecs: str) -> list[Path]:
    """Tracked, not globbed: a scratch note in the tree is not a doc."""
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--", *pathspecs],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    # Unstaged deletions are absent from the working tree but still present in the index.
    # References to deleted documents are checked in surviving documents below.
    return [root / p for p in out if (root / p).exists()]


def tracked_scripts(root: Path) -> list[Path]:
    """Tracked *.sh / *.py files, plus extensionless scripts under SCRIPT_DIRS."""
    return [p for p in tracked(root, "*.sh", "*.py", *SCRIPT_DIRS)
            if p.suffix in (".sh", ".py")
            or (not p.suffix and p.relative_to(root).parts[0] in SCRIPT_DIRS)]


def check_cite(root: Path, files: list[Path], where: str, name: str, nums: tuple[str, str],
               strict: bool) -> list[str]:
    """A file:line citation: the file must be tracked AND long enough to have every cited line.

    `files` is every tracked file; resolving against it, not the tree, keeps untracked copies (a
    sandbox, run output) from making a basename ambiguous. `strict` (source comments) also refuses
    a bare basename that names no tracked file: a comment cites this repo, so that is a deleted or
    renamed file. Prose may cite other projects, so there it is not our claim to check."""
    if "/" in name:
        matches = [p for p in files if p == root / name]
    else:
        matches = [p for p in files if p.name == name]
    if not matches:
        if strict or name.split("/")[0] in SOURCE_DIRS:
            return [f"{where}: cites {name}:{nums[0]}, which does not exist"]
        return []  # not a repo file (an example, another project) — not our claim to check
    if len(matches) > 1:
        return []  # ambiguous basename; refusing on a guess is worse than not checking
    try:
        count = sum(1 for _ in matches[0].open("rb"))
    except OSError:
        return []
    last = max(int(n) for n in nums if n)
    if last > count:
        return [f"{where}: cites {name}:{'-'.join(n for n in nums if n)}, "
                f"but that file has only {count} lines"]
    return []


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
    files = tracked(root)
    for doc in tracked(root, "*.md"):
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

            # 4. file:line citations.
            for name, *nums in CITE.findall(line):
                findings += check_cite(root, files, where, name, tuple(nums), strict=False)

    # 5. file:line citations (and ADR references, claim 2) in source comments. No file is exempt:
    # only `#` lines are read, so the examples in this checker's docstring and its test's quoted
    # fixtures never fire, while a real citation in their comments is checked like any other.
    for src in tracked_scripts(root):
        rel_src = src.relative_to(root)
        try:
            lines = src.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue  # not a text script; there is no comment to check
        for n, line in enumerate(lines, 1):
            if line.lstrip().startswith("#"):
                for num in ADR.findall(line):
                    if not list(adr_dir.glob(f"{num}-*.md")):
                        findings.append(f"{rel_src}:{n}: ADR {num} referenced but "
                                        f"docs/adr/{num}-*.md is missing")
                for name, *nums in COMMENT_CITE.findall(line):
                    findings += check_cite(root, files, f"{rel_src}:{n}", name, tuple(nums),
                                           strict=True)
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
