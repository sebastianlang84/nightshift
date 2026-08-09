#!/usr/bin/env python3
"""Minimal YAML-subset parser for the nightshift rulebook — emits tagged TSV for bash.

Handles exactly the shape we control: top-level `branch_prefix`, a `limits:` map,
and a `repos:` list of `{path, mode}`. Not a general YAML parser on purpose (no deps)."""
import sys

# Every mapping section's key set is CLOSED: the emitters at the bottom of main() read exactly
# these keys and nothing else, so a key outside the set can only be a typo — and tolerating one is
# silent, which is the worst way for governance to fail. `max_open_branchs: 12` leaves the ONLY
# throughput cap at its default 2; `test-cmd:` on a repo leaves `test_cmd` empty, so that repo ships
# UNGATED past its ADR 0022 ship gate; `ttl-days:` or a misspelled `enabled` quietly re-enables recon
# or resets its TTL. Reject the complement instead — the standard `agent:` has always applied.
LIMIT_KEYS = (
    "max_open_branches",
    "max_branches_per_run",
    "max_fix_iterations",
    "max_files_per_change",
    "max_lines_per_change",
    "max_run_minutes",
    "test_timeout_seconds",
    "max_findings_per_item",
    "max_verifies_per_run",
)
RECON_KEYS = ("enabled", "ttl_days")
AGENT_KEYS = ("claude_model", "codex_model")
REPO_KEYS = ("path", "mode", "base", "findings", "dimensions", "test_cmd")


def val(raw: str) -> str:
    """Take a scalar value, dropping any trailing inline `# comment`."""
    return raw.split(" #", 1)[0].strip()


def quoted_val(raw: str) -> str:
    """Scalar that may be quoted, so its value may legitimately contain `#`.

    `val()` splits on ` #` before it knows whether it is inside quotes, which
    truncates `"gpt-5 #2"` to `"gpt-5`. Anything after the closing quote is a
    comment. An unterminated quote is a typo, not a value — say so."""
    s = raw.strip()
    if s[:1] in ("'", '"'):
        end = s.find(s[0], 1)
        if end == -1:
            raise SystemExit(f"unterminated quoted value: {s}")
        return s[1:end]
    return val(raw)


def put(
    target: dict[str, str],
    section: str,
    s: str,
    allowed: tuple[str, ...],
    read=val,
) -> None:
    """Record one `key: value` line of a mapping section, refusing anything off its key set.

    A missing colon, an unknown key, or the same key twice are all misconfigs, and every one of
    them has the same silent outcome if waved through: the knob falls back to the parser's default
    and the night runs on governance the human did not write. Fail loudly instead."""
    k, sep, v = s.partition(":")
    key = k.strip()
    if not sep:
        raise SystemExit(f"{section}: expected `key: value`, got: {s}")
    if key not in allowed:
        raise SystemExit(f"{section}: unknown key '{key}' (expected one of: {', '.join(allowed)})")
    if key in target:
        raise SystemExit(f"{section}: duplicate key '{key}'")
    target[key] = read(v)


def main(path: str) -> None:
    prefix = "nightshift/"
    limits: dict[str, str] = {}
    recon: dict[str, str] = {}
    agent: dict[str, str] = {}
    repos: list[dict[str, str]] = []
    dims: list[str] = []
    cur: dict[str, str] | None = None
    section: str | None = None

    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip() or line.strip().startswith("#"):
                continue
            # Indentation is what assigns a line to a section, and it is counted in SPACES. A
            # tab-indented line measures as indent 0, so it would be read as a new top-level key and
            # its section silently lost every entry. Refuse it instead of misreading it.
            if "\t" in line[: len(line) - len(line.lstrip())]:
                raise SystemExit(f"indent with spaces, not tabs: {line.strip()}")
            indent = len(line) - len(line.lstrip(" "))
            s = line.strip()
            # A section header carries no payload, so everything from the first `#` is a comment.
            # Comparing the raw line instead silently demoted `repos: # the fleet` to "no section",
            # which dropped every entry under it without a word.
            head = s.split("#", 1)[0].rstrip()
            if indent == 0:
                section = None
                if s.startswith("branch_prefix:"):
                    prefix = val(s.split(":", 1)[1])
                elif head == "limits:":
                    section = "limits"
                elif head == "recon:":
                    section = "recon"
                elif head == "agent:":
                    section = "agent"
                elif head == "dimensions:":
                    section = "dimensions"
                elif head == "repos:":
                    section = "repos"
            elif section == "limits":
                put(limits, "limits", s, LIMIT_KEYS)
            elif section == "recon":
                put(recon, "recon", s, RECON_KEYS)
            elif section == "agent":
                # A model id may legitimately be quoted (and contain a `#`), so this section — and
                # only this one — reads its scalars with quoted_val.
                put(agent, "agent", s, AGENT_KEYS, quoted_val)
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
                        put(cur, "repos", s, REPO_KEYS)
                elif cur is not None:
                    put(cur, "repos", s, REPO_KEYS)
        if cur:
            repos.append(cur)

    # The pre-push hook appends `*` to this value. Without a trailing slash, a
    # prefix such as `m` also authorizes `main`; require a distinct branch
    # namespace and reject whitespace that would corrupt the TSV transport.
    if (
        not prefix.endswith("/")
        or prefix.startswith("/")
        or "//" in prefix
        or any(ch.isspace() for ch in prefix)
    ):
        raise SystemExit(
            "branch_prefix must name a dedicated namespace ending in '/'"
        )

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
    # Wall-clock ceiling for ONE repo's `test_cmd` (ADR 0022). A hanging suite must not eat the
    # night, so the gate always runs under a timeout. Default 600s; a hand-set 0 would make every
    # gated run time out instantly and silently ship nothing, so require a positive integer.
    tts = limits.get("test_timeout_seconds", "600")
    if not tts.isdecimal() or int(tts) < 1:
        raise SystemExit("limits.test_timeout_seconds must be a positive integer")
    print(f"test_timeout_seconds\t{tts}")
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
    # Open findings the verify phase may re-check per night — one read-only stage call each, so
    # this is the ceiling on what closing the finding loop can cost. 0 is a legitimate value
    # ("never spend a model on closure"); the free deterministic probe runs either way. A
    # non-numeric value would detonate in bash arithmetic — fail loudly like every sibling.
    mvr = limits.get("max_verifies_per_run", "5")
    if not mvr.isdecimal():
        raise SystemExit("limits.max_verifies_per_run must be a non-negative integer")
    print(f"max_verifies_per_run\t{mvr}")
    # Recon stage: on by default; cache invalidated on HEAD change or after ttl_days.
    print(f"recon_enabled\t{recon.get('enabled', 'true')}")
    # A malformed ttl_days silently became 0 in bash arithmetic → the cache was never fresh →
    # recon re-ran every pass. Require a positive integer so the misconfig fails loudly instead.
    ttl = recon.get("ttl_days", "7")
    if not ttl.isdecimal() or int(ttl) < 1:
        raise SystemExit("recon.ttl_days must be a positive integer")
    print(f"recon_ttl_days\t{ttl}")
    # Which MODEL a stage runs on (ADR 0020). The host declares it here because stage isolation
    # (ADR 0019) drops the CLI's `user` settings scope, so a machine-wide pin in
    # ~/.claude/settings.json no longer reaches a stage. OMITTING the key means "let the CLI resolve
    # its own default"; writing the key with no value is a half-finished edit, and treating that as
    # "no model" would silently run the night on something else. Model ID *syntax* stays
    # unvalidated — it belongs to the CLI vendor and any pattern here would go stale — but a tab
    # would corrupt the TSV transport to bash.
    for key in ("claude_model", "codex_model"):
        model = agent.get(key, "")
        if key in agent and not model:
            raise SystemExit(
                f"agent.{key} is empty — give it a model id, or omit the key entirely"
            )
        if "\t" in model:
            raise SystemExit(f"agent.{key} must not contain a tab")
        print(f"{key}\t{model}")
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
        # test_cmd is optional: empty means "no ship gate" (ADR 0022). It rides the same TSV as
        # every other repo field and MUST stay last — a command legitimately contains spaces, and
        # bash's `read` soaks the remainder into the final variable. A tab would split it in two.
        test_cmd = r.get("test_cmd", "")
        if "\t" in test_cmd:
            raise SystemExit(
                f"repo {r.get('path', '')}: test_cmd must not contain a tab"
            )
        print(
            "repo"
            f"\tpath={r.get('path', '')}"
            f"\tmode={r.get('mode', 'findings-only')}"
            f"\tbase={r.get('base', '')}"
            f"\tfindings={findings}"
            f"\tdimensions={r.get('dimensions', '')}"
            f"\ttest_cmd={test_cmd}"
        )


if __name__ == "__main__":
    main(sys.argv[1])
