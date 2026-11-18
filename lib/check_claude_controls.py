#!/usr/bin/env python3
"""Refuse candidate-owned Claude startup code before a CLI loads it.

Inspect either a worktree or a committed tree, without executing repository code.
Symlink control paths are refused even when unchanged: their targets are outside
the set of paths a plain control-file diff can protect.
"""

import json
from pathlib import Path
import stat
import subprocess
import sys


CONTROL_PATHS = (".claude", ".claude/settings.json", ".claude/settings.local.json", ".mcp.json")


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


def check_worktree(root):
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
        check_config(name, path.read_text(encoding="utf-8"))


def git(root, *args):
    return subprocess.run(["git", "-C", root, *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def check_tree(root, tip):
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
        check_config(name, git(root, "cat-file", "blob", oid).decode("utf-8"))


def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "worktree":
            check_worktree(sys.argv[2])
        elif len(sys.argv) == 4 and sys.argv[1] == "tree":
            check_tree(sys.argv[2], sys.argv[3])
        else:
            raise ValueError("usage: check_claude_controls.py worktree ROOT | tree ROOT TIP")
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"Claude control files refused: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
