#!/usr/bin/env python3
"""Minimal YAML-subset parser for the nightshift rulebook — emits tagged TSV for bash.

Handles exactly the shape we control: top-level `branch_prefix`, a `limits:` map,
and a `repos:` list of `{path, mode}`. Not a general YAML parser on purpose (no deps)."""
import sys


def val(raw: str) -> str:
    """Take a scalar value, dropping any trailing inline `# comment`."""
    return raw.split(" #", 1)[0].strip()


def main(path: str) -> None:
    prefix = "nightshift/"
    limits: dict[str, str] = {}
    recon: dict[str, str] = {}
    repos: list[dict[str, str]] = []
    dims: list[str] = []
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
                elif s.rstrip() == "recon:":
                    section = "recon"
                elif s.rstrip() == "dimensions:":
                    section = "dimensions"
                elif s.rstrip() == "repos:":
                    section = "repos"
            elif section == "limits":
                k, _, v = s.partition(":")
                limits[k.strip()] = val(v)
            elif section == "recon":
                k, _, v = s.partition(":")
                recon[k.strip()] = val(v)
            elif section == "dimensions":
                if s.startswith("- "):
                    dims.append(val(s[2:]))
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
    print(f"max_open\t{limits.get('max_open_branches', '2')}")
    # Emitted empty when absent so bash can apply the env override before its default
    # (precedence: rulebook -> NIGHTSHIFT_MAX_RUN_BRANCHES -> default). The others have
    # no env counterpart, so the parser owns their defaults directly.
    print(f"max_branches_per_run\t{limits.get('max_branches_per_run', '')}")
    # A hand-set 0 would make the fix<->review loop never run — every finding then
    # abandons silently. Require >= 1 so the misconfig fails loudly (with the runner's
    # fail-closed parse handling) instead of doing nothing.
    mfi = limits.get("max_fix_iterations", "3")
    if not mfi.isdecimal() or int(mfi) < 1:
        raise SystemExit("limits.max_fix_iterations must be a positive integer")
    print(f"max_fix_iterations\t{mfi}")
    print(f"max_files\t{limits.get('max_files_per_change', '15')}")
    print(f"max_lines\t{limits.get('max_lines_per_change', '400')}")
    # Wall-clock spend budget for the whole night (ADR 0013). Empty = no time cap (bash applies the
    # NIGHTSHIFT_MAX_RUN_SECONDS env override first). Validate a present value as a positive integer.
    mrm = limits.get("max_run_minutes", "")
    if mrm and (not mrm.isdecimal() or int(mrm) < 1):
        raise SystemExit("limits.max_run_minutes must be a positive integer")
    print(f"max_run_minutes\t{mrm}")
    # Findings emitted per repo per pass. Default 1 keeps a rulebook that omits the key at the
    # pre-v2 single-finding behavior; the live rulebook sets it explicitly (ADR 0011).
    # A hand-set 0 forces n_find=0 in the Runner (MAX_FINDINGS=0 → repo_findings 0 → the
    # `n_find -le 0` guard), so every repo without a per-repo override silently no-ops; a
    # non-numeric value detonates later in bash integer arithmetic. Require a positive
    # integer so the misconfig fails loudly, matching every sibling limit above.
    mfp = limits.get("max_findings_per_item", "1")
    if not mfp.isdecimal() or int(mfp) < 1:
        raise SystemExit("limits.max_findings_per_item must be a positive integer")
    print(f"max_findings_per_item\t{mfp}")
    # Recon stage: on by default; cache invalidated on HEAD change or after ttl_days.
    print(f"recon_enabled\t{recon.get('enabled', 'true')}")
    # A malformed ttl_days silently became 0 in bash arithmetic → the cache was never fresh →
    # recon re-ran every pass. Require a positive integer so the misconfig fails loudly instead.
    ttl = recon.get("ttl_days", "7")
    if not ttl.isdecimal() or int(ttl) < 1:
        raise SystemExit("recon.ttl_days must be a positive integer")
    print(f"recon_ttl_days\t{ttl}")
    # Global review-dimension set; ORDER is the cold-start / tie priority in the Runner.
    for d in dims:
        print(f"dimension\t{d}")
    for r in repos:
        # base is optional: empty means "auto-detect" (base_ref) in the Runner.
        # findings is optional: empty means "inherit max_findings_per_item".
        # dimensions is optional (comma-separated scalar): empty means "inherit the global set".
        # Bash treats tab as IFS whitespace and collapses adjacent delimiters. Prefixing each
        # optional value with its key keeps every field non-empty (`base=`) and position-stable.
        findings = r.get("findings", "")
        if findings and (not findings.isdecimal() or int(findings) < 1):
            raise SystemExit(
                f"repo {r.get('path', '')}: findings must be a positive integer"
            )
        print(
            "repo"
            f"\tpath={r.get('path', '')}"
            f"\tmode={r.get('mode', 'findings-only')}"
            f"\tbase={r.get('base', '')}"
            f"\tfindings={findings}"
            f"\tdimensions={r.get('dimensions', '')}"
        )


if __name__ == "__main__":
    main(sys.argv[1])
