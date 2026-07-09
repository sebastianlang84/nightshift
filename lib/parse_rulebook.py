#!/usr/bin/env python3
"""Minimal YAML-subset parser for the nightshift rulebook — emits TSV for bash.

Handles exactly the shape we control: top-level `branch_prefix`, a `limits:` map,
and a `repos:` list of `{path, mode}`. Not a general YAML parser on purpose (no deps)."""
import sys


def val(raw: str) -> str:
    """Take a scalar value, dropping any trailing inline `# comment`."""
    return raw.split(" #", 1)[0].strip()


def main(path: str) -> None:
    prefix = "nightshift/"
    limits: dict[str, str] = {}
    repos: list[dict[str, str]] = []
    cur: dict[str, str] | None = None
    section: str | None = None

    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip() or line.strip().startswith("#"):
                continue
            indent = len(line) - len(line.lstrip(" "))
            s = line.strip()
            if indent == 0:
                section = None
                if s.startswith("branch_prefix:"):
                    prefix = val(s.split(":", 1)[1])
                elif s.rstrip() == "limits:":
                    section = "limits"
                elif s.rstrip() == "repos:":
                    section = "repos"
            elif section == "limits":
                k, _, v = s.partition(":")
                limits[k.strip()] = val(v)
            elif section == "repos":
                if s.startswith("- "):
                    if cur:
                        repos.append(cur)
                    cur = {}
                    s = s[2:].strip()
                    if s:
                        k, _, v = s.partition(":")
                        cur[k.strip()] = val(v)
                elif cur is not None:
                    k, _, v = s.partition(":")
                    cur[k.strip()] = val(v)
        if cur:
            repos.append(cur)

    print(f"prefix\t{prefix}")
    print(f"max_open\t{limits.get('max_open_branches', '10')}")
    # Emitted empty when absent so bash can apply the env override before its default
    # (precedence: rulebook -> NIGHTSHIFT_MAX_RUN_BRANCHES -> default). The others have
    # no env counterpart, so the parser owns their defaults directly.
    print(f"max_branches_per_run\t{limits.get('max_branches_per_run', '')}")
    print(f"max_fix_iterations\t{limits.get('max_fix_iterations', '3')}")
    print(f"max_files\t{limits.get('max_files_per_change', '15')}")
    print(f"max_lines\t{limits.get('max_lines_per_change', '400')}")
    for r in repos:
        print(f"repo\t{r.get('path', '')}\t{r.get('mode', 'findings-only')}")


if __name__ == "__main__":
    main(sys.argv[1])
