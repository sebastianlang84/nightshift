#!/usr/bin/env python3
"""Produce deterministic structural evidence for the knowledge review lens.

The probe never executes code from the target repository. It checks the portable parts of an
OKF v0.2 bundle and generic Markdown graph hygiene, then emits JSON for Explore to interpret.
Semantic duplication and contradictions remain model work; parseable structure does not prove
that two claims agree.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import Counter
from datetime import date
from pathlib import Path, PurePosixPath
from urllib.parse import unquote

SUPPORTED_OKF_VERSION = "0.2"
OKF_SPEC = "https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md"
RESERVED = {"index.md", "log.md"}
STATUS_VALUES = {"draft", "stable", "deprecated"}
TOP_KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):(?:\s*(.*))?$")
LINK_RE = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
FOOTNOTE_RE = re.compile(r"\[\^([^\]]+)\]")
WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")
DATE_HEADING_RE = re.compile(r"^##\s+(\S.*)$", re.MULTILINE)
ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def tracked_markdown(repo: Path) -> list[PurePosixPath]:
    proc = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z", "--", "*.md"],
        check=False,
        capture_output=True,
    )
    if proc.returncode:
        raise RuntimeError("cannot enumerate tracked Markdown files")
    return sorted(
        PurePosixPath(raw.decode("utf-8", errors="surrogateescape"))
        for raw in proc.stdout.split(b"\0")
        if raw
    )


def frontmatter(text: str) -> tuple[list[str] | None, str, int]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, text, 1
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            return lines[1:idx], "\n".join(lines[idx + 1 :]), idx + 2
    return None, text, 1


def top_fields(lines: list[str]) -> tuple[dict[str, str], list[str]]:
    fields: dict[str, str] = {}
    duplicates: list[str] = []
    for line in lines:
        if not line or line.lstrip().startswith("#") or line[:1].isspace():
            continue
        match = TOP_KEY_RE.match(line)
        if not match:
            continue
        key, value = match.group(1), (match.group(2) or "").strip()
        if key in fields:
            duplicates.append(key)
        fields[key] = value.strip("'\"")
    return fields, duplicates


def nested_block(lines: list[str], key: str) -> list[str]:
    start = None
    for idx, line in enumerate(lines):
        if line.startswith(f"{key}:"):
            start = idx + 1
            break
    if start is None:
        return []
    out: list[str] = []
    for line in lines[start:]:
        if line and not line[:1].isspace():
            break
        out.append(line)
    return out


def mapping_has(value: str, block: list[str], key: str) -> bool:
    if re.search(rf"(?:^|[,{{]\s*){re.escape(key)}\s*:\s*[^,}}]+", value):
        return True
    return any(re.match(rf"^\s+{re.escape(key)}\s*:\s*\S", line) for line in block)


def source_entries(lines: list[str]) -> list[dict[str, str]]:
    block = nested_block(lines, "sources")
    entries: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in block:
        stripped = line.strip()
        if stripped.startswith("- "):
            if current is not None:
                entries.append(current)
            current = {}
            payload = stripped[2:].strip()
            if payload.startswith("{") and payload.endswith("}"):
                for part in payload[1:-1].split(","):
                    key, sep, value = part.partition(":")
                    if sep:
                        current[key.strip()] = value.strip().strip("'\"")
            else:
                key, sep, value = payload.partition(":")
                if sep:
                    current[key.strip()] = value.strip().strip("'\"")
        elif current is not None:
            match = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", stripped)
            if match:
                current[match.group(1)] = match.group(2).strip().strip("'\"")
    if current is not None:
        entries.append(current)
    return entries


def line_number(text: str, needle: str) -> int:
    pos = text.find(needle)
    return 1 if pos < 0 else text.count("\n", 0, pos) + 1


def target_path(source: PurePosixPath, raw: str) -> PurePosixPath | None:
    target = unquote(raw.split("#", 1)[0].strip())
    if not target or target.startswith(("http://", "https://", "mailto:", "#")):
        return None
    if target.startswith("/"):
        parts = PurePosixPath(target[1:]).parts
    else:
        parts = (source.parent / target).parts
    clean: list[str] = []
    for part in parts:
        if part in ("", "."):
            continue
        if part == "..":
            if clean:
                clean.pop()
            continue
        clean.append(part)
    result = PurePosixPath(*clean)
    if result.suffix == "":
        result /= "index.md"
    return result


def main(repo_arg: str) -> None:
    repo = Path(repo_arg).resolve()
    files = tracked_markdown(repo)
    tracked = set(files)
    texts = {
        path: (repo / Path(*path.parts)).read_text(encoding="utf-8", errors="replace")
        for path in files
    }
    diagnostics: list[dict[str, object]] = []

    def add(severity: str, code: str, path: PurePosixPath, message: str, needle: str = "") -> None:
        diagnostics.append(
            {
                "severity": severity,
                "code": code,
                "file": str(path),
                "line": line_number(texts.get(path, ""), needle) if needle else 1,
                "message": message,
            }
        )

    root_index = texts.get(PurePosixPath("index.md"), "")
    index_fm, _, _ = frontmatter(root_index)
    index_fields, _ = top_fields(index_fm or [])
    version = index_fields.get("okf_version")
    profile = f"okf-{version}" if version else "markdown-wiki"
    okf = version is not None
    if okf and version != SUPPORTED_OKF_VERSION:
        add(
            "warning",
            "unsupported_okf_version",
            PurePosixPath("index.md"),
            f"probe implements OKF {SUPPORTED_OKF_VERSION}, bundle declares {version}",
            "okf_version",
        )

    inbound: Counter[PurePosixPath] = Counter()
    for path, text in texts.items():
        fm_lines, body, _ = frontmatter(text)
        is_reserved = path.name in RESERVED
        if path.name == "index.md":
            if path != PurePosixPath("index.md") and fm_lines is not None:
                add("error", "reserved_frontmatter", path, "non-root index.md must not have frontmatter")
            if path == PurePosixPath("index.md") and fm_lines is not None:
                fields, _ = top_fields(fm_lines)
                extra = sorted(set(fields) - {"okf_version"})
                if extra:
                    add("error", "root_index_frontmatter", path, f"root index frontmatter has non-OKF keys: {', '.join(extra)}")
        elif path.name == "log.md":
            if fm_lines is not None:
                add("error", "reserved_frontmatter", path, "log.md must not have frontmatter")
            headings = DATE_HEADING_RE.findall(text)
            for heading in headings:
                if not ISO_DATE_RE.fullmatch(heading):
                    add("error", "invalid_log_date", path, f"log date heading is not YYYY-MM-DD: {heading}", f"## {heading}")
            for heading, count in Counter(headings).items():
                if count > 1:
                    add("warning", "duplicate_log_date", path, f"log date heading appears {count} times: {heading}", f"## {heading}")
        elif okf:
            if fm_lines is None:
                add("error", "missing_frontmatter", path, "OKF concept has no closed YAML frontmatter block")
            else:
                fields, duplicates = top_fields(fm_lines)
                for key in duplicates:
                    add("error", "duplicate_frontmatter_key", path, f"duplicate top-level key: {key}", f"{key}:")
                if not fields.get("type"):
                    add("error", "missing_type", path, "OKF concept needs a non-empty type", "---")
                status = fields.get("status")
                if status and status not in STATUS_VALUES:
                    add("warning", "invalid_status", path, f"status is outside OKF v0.2: {status}", "status:")
                stale = fields.get("stale_after")
                if stale:
                    try:
                        stale_date = date.fromisoformat(stale)
                    except ValueError:
                        add("warning", "invalid_stale_after", path, f"stale_after is not YYYY-MM-DD: {stale}", "stale_after:")
                    else:
                        if date.today() >= stale_date:
                            add("warning", "stale_concept", path, f"concept is stale since {stale}", "stale_after:")
                generated = fields.get("generated", "")
                if "generated" in fields:
                    block = nested_block(fm_lines, "generated")
                    for key in ("by", "at"):
                        if not mapping_has(generated, block, key):
                            add("warning", "incomplete_generated", path, f"generated is missing {key}", "generated:")
                entries = source_entries(fm_lines)
                ids = {entry.get("id", "") for entry in entries if entry.get("id")}
                for entry in entries:
                    if not entry.get("resource"):
                        add("warning", "source_missing_resource", path, "sources entry has no resource", "sources:")
                for footnote in sorted(set(FOOTNOTE_RE.findall(body)) - ids):
                    add("warning", "unresolved_source_id", path, f"footnote '{footnote}' has no matching sources[].id", f"[^{footnote}]")
                if fields.get("type") == "Attested Computation":
                    if not fields.get("runtime"):
                        add("error", "computation_missing_runtime", path, "Attested Computation requires runtime", "type:")
                    for key in ("executor", "attester"):
                        value = fields.get(key, "")
                        if key not in fields or not mapping_has(value, nested_block(fm_lines, key), "resource"):
                            add("warning", f"computation_missing_{key}", path, f"Attested Computation has no {key}.resource", "type:")
                    if "computation" not in fields and not re.search(r"^# Computation\s*$", body, re.MULTILINE):
                        add("warning", "computation_body_missing", path, "Attested Computation has neither computation path nor # Computation body", "type:")

        for raw in LINK_RE.findall(body if fm_lines is not None else text):
            target = target_path(path, raw)
            if target is None:
                continue
            if target in tracked:
                inbound[target] += 1
            else:
                add("warning", "broken_markdown_link", path, f"relative Markdown target does not exist: {target}", raw)
        for wiki in WIKILINK_RE.findall(body if fm_lines is not None else text):
            add("warning", "nonstandard_wikilink", path, f"wiki-link is not a portable Markdown link: {wiki}", f"[[{wiki}]]")

    for path in files:
        if path.name not in RESERVED and inbound[path] == 0:
            add("warning", "orphan_concept", path, "concept has no inbound Markdown link")

    diagnostics.sort(key=lambda row: (str(row["file"]), int(row["line"]), str(row["code"])))
    errors = sum(row["severity"] == "error" for row in diagnostics)
    warnings = sum(row["severity"] == "warning" for row in diagnostics)
    print(
        json.dumps(
            {
                "profile": profile,
                "okf_version": version,
                "supported_okf_version": SUPPORTED_OKF_VERSION,
                "spec": OKF_SPEC,
                "summary": {
                    "markdown_files": len(files),
                    "concepts": sum(path.name not in RESERVED for path in files),
                    "errors": errors,
                    "warnings": warnings,
                    # This probe deliberately avoids a YAML dependency and therefore reports the
                    # portable structure it can prove, not full OKF conformance. A bundle-local
                    # linter may enforce a stricter parser and house policy.
                    "portable_structure_clean": (errors == 0) if okf else None,
                },
                "diagnostics": diagnostics,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: knowledge_probe.py REPO")
    try:
        main(sys.argv[1])
    except (OSError, RuntimeError) as exc:
        raise SystemExit(f"knowledge probe failed: {exc}") from exc
