#!/usr/bin/env python3
"""Validate the breadth evidence attached to an Explore verdict.

The model may still make a bad judgment; this gate only prevents an ungrounded or shallow response
from becoming durable evidence that a lens was serviced. Requirements scale down for tiny repos.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

CODE_INVARIANT_KEYS = {
    "config_domain",
    "semantic_sets",
    "artifact_identity",
    "failure_translation",
    "lifecycle",
}
KNOWLEDGE_INVARIANT_KEYS = {
    "canonicality",
    "consistency",
    "routing",
    "provenance_trust",
    "lifecycle_freshness",
}


def invariant_keys(dimension: str) -> set[str]:
    return KNOWLEDGE_INVARIANT_KEYS if dimension == "knowledge" else CODE_INVARIANT_KEYS


def fail(message: str) -> None:
    raise SystemExit(f"invalid Explore verdict: {message}")


def strings(value: object, field: str) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item.strip() for item in value
    ):
        fail(f"coverage.{field} must be an array of non-empty strings")
    return list(dict.fromkeys(item.strip() for item in value))


def main(repo_arg: str, verdict_arg: str, dimension: str = "") -> None:
    repo = Path(repo_arg).resolve()
    try:
        verdict = json.loads(Path(verdict_arg).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read JSON: {exc}")
    if not isinstance(verdict, dict):
        fail("top level must be an object")

    findings = verdict.get("findings")
    found = verdict.get("found")
    if not isinstance(found, bool) or not isinstance(findings, list):
        fail("found must be boolean and findings must be an array")
    if found != bool(findings):
        fail("found must agree with whether findings is empty")
    if not findings and verdict.get("scope") not in (
        "in_scope_no_findings",
        "out_of_scope",
    ):
        fail("an empty verdict needs a valid scope")

    coverage = verdict.get("coverage")
    if not isinstance(coverage, dict):
        fail("coverage must be an object")
    files = strings(coverage.get("files"), "files")
    entrypoints = strings(coverage.get("entrypoints"), "entrypoints")
    checks = strings(coverage.get("checks"), "checks")
    invariants = coverage.get("invariants")
    expected_invariants = invariant_keys(dimension)
    if not isinstance(invariants, dict) or set(invariants) != expected_invariants:
        fail(
            "coverage.invariants must contain exactly: "
            + ", ".join(sorted(expected_invariants))
        )
    for key, value in invariants.items():
        if not isinstance(value, str):
            fail(f"coverage.invariants.{key} needs checked: or not-applicable: evidence")
        prefix, separator, evidence = value.partition(":")
        if prefix not in ("checked", "not-applicable") or not separator or not evidence.strip():
            fail(f"coverage.invariants.{key} needs checked: or not-applicable: evidence")
    if not isinstance(coverage.get("unresolved"), list):
        fail("coverage.unresolved must be an array")

    proc = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z"],
        check=False,
        capture_output=True,
    )
    if proc.returncode:
        fail("cannot enumerate tracked files")
    tracked = {
        item.decode("utf-8", errors="surrogateescape")
        for item in proc.stdout.split(b"\0")
        if item
    }
    required_files = min(5, len(tracked))
    required_checks = min(3, len(tracked))
    if len(files) < required_files:
        fail(f"coverage.files needs {required_files} distinct tracked paths, got {len(files)}")
    unknown = sorted(set(files) - tracked)
    if unknown:
        fail(f"coverage.files contains paths that are not tracked files: {', '.join(unknown)}")
    if tracked and not entrypoints:
        fail("coverage.entrypoints needs at least one traced entrypoint or policy flow")
    if len(checks) < required_checks:
        fail(f"coverage.checks needs {required_checks} distinct checks, got {len(checks)}")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: validate_explore.py REPO VERDICT.json [DIMENSION]")
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else "")
