#!/usr/bin/env python3
"""Refuse candidate-owned Claude startup code before a CLI loads it.

Inspect either a worktree or a committed tree, without executing repository code.
Symlink control paths are refused even when unchanged: their targets are outside
the set of paths a plain control-file diff can protect.
"""

import argparse
import json
from pathlib import Path
import stat
import subprocess
import sys


CONTROL_PATHS = (".claude", ".claude/settings.json", ".claude/settings.local.json", ".mcp.json")
SETTINGS_SCOPES = {".claude/settings.json": "project", ".claude/settings.local.json": "local"}


def parse_setting_sources(value):
    if value == "":
        return []
    scopes = [scope.strip() for scope in value.split(",")]
    if any(scope not in ("user", "project", "local") for scope in scopes):
        raise ValueError(f"invalid NIGHTSHIFT_CLAUDE_SETTING_SOURCES value {value!r}. "
                         "Expected a comma-separated list of user, project, local or an empty value")
    return scopes


def check_config(path, text):
    config = json.loads(text)
    if not isinstance(config, dict):
        raise ValueError(f"{path}: expected a JSON object")
    # Allow only inert preferences and empty hook/server maps. A denylist of command
    # settings misses env-based execution, plugins, or future executable settings.
    for key, value in config.items():
        if key in ("model", "$schema") and isinstance(value, str):
            continue
        if key in ("hooks", "mcpServers") and value == {}:
            continue
        raise ValueError(f"{path}: candidate-controlled {key}")


def check_worktree(root, content_paths):
    for name in CONTROL_PATHS:
        path = Path(root) / name
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            continue
        if name == ".claude" and stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode) or name == ".claude":
            raise ValueError(f"{name}: symlink or non-regular control path")
        if name in content_paths:
            check_config(name, path.read_text(encoding="utf-8"))


def git(root, *args):
    return subprocess.run(["git", "-C", root, *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def check_tree(root, tip, content_paths):
    entries = git(root, "ls-tree", "-z", tip, "--", *CONTROL_PATHS)
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode("ascii").split()
        name = raw_name.decode("utf-8")
        # The .claude pathspec can also emit ordinary children such as agents/.
        if name not in CONTROL_PATHS:
            continue
        if name == ".claude" and mode == "040000" and kind == "tree":
            continue
        if mode not in ("100644", "100755") or kind != "blob" or name == ".claude":
            raise ValueError(f"{name}: symlink or non-regular control path")
        if name in content_paths:
            check_config(name, git(root, "cat-file", "blob", oid).decode("utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sources", default="", help="Claude setting sources (empty loads all scopes)")
    parser.add_argument("--print-sources", action="store_true", help="print the canonical sources on success")
    parser.add_argument("mode", choices=("worktree", "tree"))
    parser.add_argument("root")
    parser.add_argument("tip", nargs="?")
    args = parser.parse_args()
    if (args.mode == "tree") != (args.tip is not None):
        parser.error("tree mode requires TIP and worktree mode takes only ROOT")

    try:
        scopes = parse_setting_sources(args.sources)
        content_paths = {".mcp.json"}
        content_paths.update(
            name for name, scope in SETTINGS_SCOPES.items() if not scopes or scope in scopes
        )
        if args.mode == "worktree":
            check_worktree(args.root, content_paths)
        else:
            check_tree(args.root, args.tip, content_paths)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"Claude control files refused: {exc}", file=sys.stderr)
        return 1
    if args.print_sources:
        print(",".join(scopes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
