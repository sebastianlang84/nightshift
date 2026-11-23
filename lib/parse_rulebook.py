#!/usr/bin/env python3
"""Minimal YAML-subset parser for the nightshift rulebook.

Handles exactly the shape we control: top-level `branch_prefix`, the `limits:`, `recon:` and `agent:`
maps, and the `dimensions:` and `repos:` lists. Not a general YAML parser on purpose (no deps).

`load(path)` validates the file and returns it as a dict with every default applied; run as a script
it prints that dict as one JSON object. `--pairs` is the form `lib/rulebook.sh` reads for Bash
instead (see pairs()). Every scalar is a string, an optional value that is absent is "", and lists
are JSON arrays:

    {"branch_prefix": "nightshift/",
     "limits": {"max_open_branches": "2", "max_branches_per_run": "", ...},
     "recon": {"enabled": "true", "ttl_days": "7"},
     "agent": {"primary": "", "claude_model": "", "codex_model": "", "review_model": "", "advisors": [], ...},
     "dimensions": ["correctness", ...],
     "repos": [{"path": "/srv/x", "mode": "branch-fix", "base": "", "findings": "",
                "dimensions": ["docs"], "test_net": "false", "test_robind": "",
                "protected_paths": ["hooks/"], "test_cmd": "make test"}]}

An invalid rulebook raises SystemExit with the reason, so the script exits 1 and prints nothing on
stdout.

Usage: parse_rulebook.py [--pairs] RULEBOOK"""
import json
import posixpath
import re
import sys
from pathlib import Path

# Every mapping section's key set is CLOSED: a key outside it can only be a typo, and tolerating one
# silently reverts that knob to its default (a misspelled `test_cmd` would leave a repo ungated).
LIMIT_KEYS = (
    "max_open_branches",
    "max_branches_per_run",
    "max_fix_iterations",
    "max_files_per_change",
    "max_lines_per_change",
    "max_run_minutes",
    "test_timeout_seconds",
    "test_memory_mb",
    "test_max_procs",
    "test_fsize_mb",
    "max_findings_per_item",
    "max_verifies_per_run",
)
RECON_KEYS = ("enabled", "ttl_days")
AGENT_KEYS = (
    "primary",
    "claude_model",
    "claude_effort",
    "codex_model",
    "codex_effort",
    "review_model",
    "advisors",
)
# Adapters the Runner implements (ADR 0045). `primary` and every `advisors` entry must name one;
# anything else, a removed adapter included, is refused.
ADAPTERS = ("claude", "codex", "mock")
EFFORTS = {
    "claude_effort": ("low", "medium", "high", "xhigh", "max"),
    "codex_effort": ("minimal", "low", "medium", "high", "xhigh", "max", "ultra"),
}
# load() reads only these top-level sections. A typo here would otherwise be ignored and
# every setting beneath it would silently revert to its default.
TOP_LEVEL_KEYS = ("branch_prefix", "limits", "recon", "agent", "dimensions", "repos")
REPO_KEYS = ("path", "mode", "base", "findings", "dimensions", "test_net", "test_robind", "protected_paths", "test_cmd")
# The modes the Runner implements; any other value aborts (see the validation in load()).
REPO_MODES = ("findings-only", "branch-fix")
# A dimension is serviceable when prompts/dimensions/<id>.md exists — the built-in catalog and the
# custom lenses ADR 0010 allows alike. Any other id would be recorded as serviced with no lens prompt.
LENS_DIR = Path(__file__).resolve().parent.parent / "prompts" / "dimensions"
LENSES = tuple(sorted(f.name[:-3] for f in LENS_DIR.glob("*.md") if f.is_file() and len(f.name) > 3))


def val(raw: str) -> str:
    """Take a scalar value, dropping any trailing inline `# comment`."""
    return raw.split(" #", 1)[0].strip()


def quoted_val(raw: str) -> str:
    """Scalar that may be quoted, so its value may legitimately contain `#`.

    Only a `# comment` may follow the closing quote: anything else would be dropped, and
    `test_cmd: "cd" sub && make test` would become a gate that runs a bare `cd`. That and an
    unterminated quote are refused."""
    s = raw.strip()
    if s[:1] in ("'", '"'):
        end = s.find(s[0], 1)
        if end == -1:
            raise SystemExit(f"unterminated quoted value: {s}")
        # In a double-quoted YAML scalar every backslash starts an escape, and this subset
        # decodes none: `"true \" # x\" && false"` would end at the escaped quote and run
        # `true \`. Refuse rather than read a value YAML would read differently.
        if s[0] == '"' and "\\" in s[1:end + 1]:
            raise SystemExit(f"escape sequences in double-quoted values are not supported: {s}")
        # A comment needs whitespace before its `#`, as in val(): `"true"#x && false` is
        # not a comment, and dropping it would leave a gate that runs `true`.
        rest = s[end + 1 :]
        if rest.strip() and not (rest[:1] in " \t" and rest.lstrip().startswith("#")):
            raise SystemExit(f"unexpected text after closing quote: {s}")
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

    A missing colon, an unknown key or a duplicate key would otherwise leave the knob at its
    default, so each one fails loudly."""
    k, sep, v = s.partition(":")
    key = k.strip()
    if not sep:
        raise SystemExit(f"{section}: expected `key: value`, got: {s}")
    if key not in allowed:
        raise SystemExit(f"{section}: unknown key '{key}' (expected one of: {', '.join(allowed)})")
    if key in target:
        raise SystemExit(f"{section}: duplicate key '{key}'")
    target[key] = read(v)


def _int(value: str, minimum: int, message: str) -> str:
    """Return VALUE as a canonical decimal string, or exit with MESSAGE.

    Only ASCII digits count: `str.isdecimal()` also accepts digits such as fullwidth `１０`, which
    Bash's `-ge` cannot compare, so a cap would silently stop capping. The canonical form drops
    leading zeros, which Bash arithmetic would otherwise read as octal (`010` is 8, `08` aborts)."""
    if not re.fullmatch(r"[0-9]+", value) or int(value) < minimum:
        raise SystemExit(message)
    return str(int(value))


def load(path: str) -> dict:
    """Validate the rulebook at `path` and return it with defaults applied (shape: module docstring)."""
    prefix = "nightshift/"
    limits: dict[str, str] = {}
    recon: dict[str, str] = {}
    agent: dict[str, str] = {}
    repos: list[dict[str, str]] = []
    dims: list[str] = []
    cur: dict[str, str] | None = None
    section: str | None = None
    seen_top_level: set[str] = set()

    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip() or line.strip().startswith("#"):
                continue
            # Indentation is counted in SPACES; a tab-indented line would measure as indent 0 and
            # silently end its section, so it is refused.
            if "\t" in line[: len(line) - len(line.lstrip())]:
                raise SystemExit(f"indent with spaces, not tabs: {line.strip()}")
            indent = len(line) - len(line.lstrip(" "))
            s = line.strip()
            # A section header carries no payload, so everything from its first `#` is a comment
            # (`repos: # the fleet` is still the repos section).
            head = s.split("#", 1)[0].rstrip()
            # YAML permits sequence items at the same indentation as their section key
            # (`repos:\n- path: …`); such a line keeps the active sequence section.
            same_indent_item = (
                indent == 0
                and s.startswith("- ")
                and section in ("dimensions", "repos")
            )
            if indent == 0 and not same_indent_item:
                section = None
                top_level_key = s.split(":", 1)[0].strip()
                if top_level_key not in TOP_LEVEL_KEYS:
                    raise SystemExit(
                        f"unknown top-level key '{top_level_key}' "
                        f"(expected one of: {', '.join(TOP_LEVEL_KEYS)})"
                    )
                if top_level_key in seen_top_level:
                    raise SystemExit(f"duplicate top-level key '{top_level_key}'")
                seen_top_level.add(top_level_key)
                if top_level_key == "branch_prefix":
                    prefix = quoted_val(s.split(":", 1)[1])
                elif not head.endswith(":") or head[:-1].strip() != top_level_key:
                    # `limits: 5`, a flow `limits: {…}` or a bare `limits` would set no section and
                    # silently drop every line under it.
                    raise SystemExit(f"section '{top_level_key}' must be a bare `{top_level_key}:` header")
                else:
                    # Dispatch on the key, not the raw header: `limits :` is the same key.
                    section = top_level_key
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
                    dims.append(quoted_val(s[2:]))
            elif section == "repos":
                if s.startswith("- "):
                    if cur:
                        repos.append(cur)
                    cur = {}
                    s = s[2:].strip()
                    if s:
                        put(cur, "repos", s, REPO_KEYS, quoted_val)
                elif cur is not None:
                    put(cur, "repos", s, REPO_KEYS, quoted_val)
        if cur:
            repos.append(cur)

    if not repos:
        raise SystemExit("repos must contain at least one repository")

    # The pre-push hook appends `*` to this value. Without a trailing slash, a
    # prefix such as `m` also authorizes `main`; require a distinct branch
    # namespace. Whitespace is refused too: git forbids it in a ref name, so a prefix holding it could
    # never name a branch, and the hook's `prefix*` pattern would no longer be one word.
    if (
        not prefix.endswith("/")
        or prefix.startswith("/")
        or "//" in prefix
        or any(ch.isspace() for ch in prefix)
    ):
        raise SystemExit(
            "branch_prefix must name a dedicated namespace ending in '/'"
        )

    out: dict = {"branch_prefix": prefix}
    lim: dict[str, str] = {}
    out["limits"] = lim
    max_open = limits.get("max_open_branches", "2")
    lim["max_open_branches"] = _int(max_open, 1, "limits.max_open_branches must be a positive integer")
    # Kept empty when absent: here the rulebook beats the env (precedence: rulebook ->
    # NIGHTSHIFT_MAX_RUN_BRANCHES -> default), and bin/nightshift.sh only reaches the env
    # once the rulebook value is empty, so a parser default would silently disable the
    # override. Precedence order, not whether an env override exists, decides this: limits
    # whose env override wins over the rulebook (test_timeout_seconds, test_memory_mb,
    # test_max_procs, test_fsize_mb, max_verifies_per_run) keep a parser default safely.
    # max_run_minutes is also left empty, for its own reason (see its comment below).
    max_run_branches = limits.get("max_branches_per_run", "")
    if max_run_branches:
        max_run_branches = _int(
            max_run_branches, 1, "limits.max_branches_per_run must be a positive integer"
        )
    lim["max_branches_per_run"] = max_run_branches
    # A hand-set 0 would make the fix<->review loop never run and every finding abandon silently.
    mfi = limits.get("max_fix_iterations", "3")
    lim["max_fix_iterations"] = _int(mfi, 1, "limits.max_fix_iterations must be a positive integer")
    # These values are prompt guidance, but zero or non-numeric input still makes that guidance
    # useless or contradictory. Reject it here rather than passing malformed limits to a stage.
    mfc = limits.get("max_files_per_change", "15")
    lim["max_files_per_change"] = _int(mfc, 1, "limits.max_files_per_change must be a positive integer")
    mlc = limits.get("max_lines_per_change", "400")
    lim["max_lines_per_change"] = _int(mlc, 1, "limits.max_lines_per_change must be a positive integer")
    # Wall-clock spend budget for the whole night (ADR 0013). Empty = no time cap (bash applies the
    # NIGHTSHIFT_MAX_RUN_SECONDS env override first). Validate a present value as a positive integer.
    mrm = limits.get("max_run_minutes", "")
    if mrm:
        mrm = _int(mrm, 1, "limits.max_run_minutes must be a positive integer")
    lim["max_run_minutes"] = mrm
    # Wall-clock ceiling for ONE repo's `test_cmd` (ADR 0022), so a hanging suite cannot eat the
    # night. 0 would time out every gate and silently ship nothing.
    tts = limits.get("test_timeout_seconds", "600")
    lim["test_timeout_seconds"] = _int(tts, 1, "limits.test_timeout_seconds must be a positive integer")
    # Resource ceilings for the sandboxed gate (ADR 0026), applied as rlimits inside the sandbox.
    # `test_memory_mb` is RLIMIT_DATA, the heap, NOT RLIMIT_AS: WASM runtimes reserve address space
    # they never touch, so any workable RLIMIT_AS bounds nothing. 0 = no cap.
    tmb = limits.get("test_memory_mb", "4096")
    lim["test_memory_mb"] = _int(tmb, 0, "limits.test_memory_mb must be a non-negative integer")
    # RLIMIT_NPROC. The kernel charges this to the ACCOUNT, not to the sandbox, so a value below the
    # host's idle process count makes every gate fail to fork. 0 = no process cap.
    tmp_ = limits.get("test_max_procs", "2048")
    lim["test_max_procs"] = _int(tmp_, 0, "limits.test_max_procs must be a non-negative integer")
    # RLIMIT_FSIZE. The worktree and the scratch HOME are on real disk, so without this a suite can
    # fill the filesystem — the one host-DoS route the tmpfs caps do not cover. 0 = no cap.
    tfs = limits.get("test_fsize_mb", "2048")
    lim["test_fsize_mb"] = _int(tfs, 0, "limits.test_fsize_mb must be a non-negative integer")
    # Findings emitted per repo per pass (ADR 0011); default 1. A hand-set 0 would make every repo
    # without a per-repo override silently do nothing.
    mfp = limits.get("max_findings_per_item", "1")
    lim["max_findings_per_item"] = _int(mfp, 1, "limits.max_findings_per_item must be a positive integer")
    # Open findings the verify phase may re-check per night, one read-only stage call each. 0 is
    # legitimate ("never spend a model on closure"); the deterministic probe runs either way.
    mvr = limits.get("max_verifies_per_run", "5")
    lim["max_verifies_per_run"] = _int(
        mvr, 0, "limits.max_verifies_per_run must be a non-negative integer"
    )
    # Recon stage: on by default. This is a closed boolean domain: accepting YAML-ish synonyms
    # such as `no` while bash only recognises the literal `false` silently leaves Recon enabled.
    renabled = recon.get("enabled", "true")
    if renabled not in ("true", "false"):
        raise SystemExit("recon.enabled must be true or false")
    out["recon"] = {"enabled": renabled}
    # A ttl_days of 0 would make the recon cache never fresh, so recon would re-run every pass.
    ttl = recon.get("ttl_days", "7")
    out["recon"]["ttl_days"] = _int(ttl, 1, "recon.ttl_days must be a positive integer")
    # Which MODEL a stage runs on (ADR 0020); stage isolation (ADR 0019) hides a pin in
    # ~/.claude/settings.json. Omitting the key lets the CLI choose; an empty value is a half-finished
    # edit and is refused. Model id syntax is the vendor's and stays unvalidated.
    # `review_model` is what Review and the branch advice request instead (ADR 0044); omitted, they
    # use the selected adapter's model.
    agent_out: dict = {}
    out["agent"] = agent_out
    for key in ("claude_model", "codex_model", "review_model"):
        model = agent.get(key, "")
        if key in agent and not model:
            raise SystemExit(
                f"agent.{key} is empty — give it a value, or omit the key entirely"
            )
        agent_out[key] = model
    for key, choices in EFFORTS.items():
        effort = agent.get(key, "")
        if key in agent and effort not in choices:
            raise SystemExit(f"agent.{key}: expected one of {', '.join(choices)}, got {effort!r}")
        agent_out[key] = effort
    # Which adapter runs the night (ADR 0045). Omitted = whatever $NIGHTSHIFT_AGENT says; an
    # explicitly set NIGHTSHIFT_AGENT still wins, so a one-off hand run needs no rulebook edit.
    primary = agent.get("primary", "")
    if "primary" in agent and not primary:
        raise SystemExit("agent.primary is empty - name an adapter, or omit the key entirely")
    if primary and primary not in ADAPTERS:
        raise SystemExit(
            f"agent.primary: unknown adapter {primary!r} - "
            f"expected one of {', '.join(sorted(ADAPTERS))}"
        )
    agent_out["primary"] = primary
    # Which adapters give every open branch its nightly merge/fix/reject recommendation (ADR 0038):
    # a comma-separated scalar; omitted = no branch review. A duplicate would be one opinion billed
    # as two; only `mock` may repeat, since each test slot stands in for a distinct model.
    advisors_raw = agent.get("advisors", "")
    if "advisors" in agent and not advisors_raw:
        raise SystemExit("agent.advisors is empty — name one or more adapters, or omit the key entirely")
    advisors = [a.strip() for a in advisors_raw.split(",")] if advisors_raw else []
    for a in advisors:
        if a not in ADAPTERS:
            raise SystemExit(
                f"agent.advisors: unknown adapter {a!r} — "
                f"expected a comma-separated list of {', '.join(sorted(ADAPTERS))}"
            )
    real = [a for a in advisors if a != "mock"]
    if len(set(real)) != len(real):
        raise SystemExit("agent.advisors: an adapter is listed twice")
    agent_out["advisors"] = advisors
    # Global review-dimension set; ORDER is the cold-start / tie priority in the Runner.
    for d in dims:
        if d not in LENSES:
            raise SystemExit(
                f"dimensions: unknown lens {d!r} — "
                f"expected a lens file in {LENS_DIR}: {', '.join(LENSES)}"
            )
    out["dimensions"] = dims
    out["repos"] = []
    for r in repos:
        path = r.get("path", "")
        if not path or not path.startswith("/"):
            raise SystemExit(
                f"repo path must be absolute and non-empty, got {path!r}"
            )
        # base is optional: empty means "auto-detect" (base_ref) in the Runner.
        # findings is optional: empty means "inherit max_findings_per_item".
        # dimensions is optional (comma-separated scalar): empty means "inherit the global set".
        findings = r.get("findings", "")
        if findings:
            findings = _int(findings, 1, f"repo {path}: findings must be a positive integer")
        # The Runner's select_order() skips an unrecognised mode WITHOUT a log line, so a typo
        # would silently drop the repo from every night. Fail closed, same as the keys.
        mode = r.get("mode", "findings-only")
        if mode not in REPO_MODES:
            raise SystemExit(
                f"repo {r.get('path', '')}: unknown mode {mode!r} — "
                f"expected one of {', '.join(sorted(REPO_MODES))}"
            )
        repo_dimensions = [d.strip() for d in r.get("dimensions", "").split(",") if d.strip()]
        for dimension in repo_dimensions:
            if dimension not in LENSES:
                raise SystemExit(
                    f"repo {r.get('path', '')}: unknown lens {dimension!r} — "
                    f"expected a lens file in {LENS_DIR}: {', '.join(LENSES)}"
                )
        test_cmd = r.get("test_cmd", "")
        # No ungated ship path (ADR 0026): a `branch-fix` repo needs a suite, since Review only
        # proves the finding is fixed. A repo without one uses `mode: findings-only`.
        if mode == "branch-fix" and not test_cmd:
            raise SystemExit(
                f"repo {r.get('path', '')}: mode branch-fix requires a test_cmd (ADR 0026) — "
                "give the repo its ship gate, or set mode: findings-only"
            )
        # Whether that gate's sandbox gets vetted egress (ADR 0028): an explicit per-repo decision,
        # default false.
        test_net = r.get("test_net", "false")
        if test_net not in ("true", "false"):
            raise SystemExit(
                f"repo {r.get('path', '')}: test_net must be true or false, got {test_net!r}"
            )
        # Extra paths bound READ-ONLY into THIS repo's gate sandbox (ADR 0026), `:`-separated like
        # NIGHTSHIFT_TEST_SANDBOX_ROBIND; per repo so other suites do not see them. Absolute only: a
        # relative path would resolve against the Runner's cwd.

        test_robind = r.get("test_robind", "")
        for p in test_robind.split(":"):
            if p and not p.startswith("/"):
                raise SystemExit(
                    f"repo {r.get('path', '')}: test_robind entries must be absolute paths, got {p!r}"
                )
        # A tab is never part of a real path, and one typed for the separator would merge two
        # entries into a single path that binds nothing.
        if "\t" in test_robind:
            raise SystemExit(
                f"repo {r.get('path', '')}: test_robind must not contain a tab"
            )
        # Paths a merge must not take without a human (ADR 0042): comma-separated, relative to the
        # repo root; an entry ending in `/` covers a directory. The Runner does not read it; an
        # external merge job does (ADR 0040). Relative, normalised and tab-free, so a typo cannot reach
        # outside, and a tab typed for the comma cannot merge two entries into one that matches nothing.
        protected = []
        for raw in (x.strip() for x in r.get("protected_paths", "").split(",") if x.strip()):
            # One canonical spelling for consumers that compare against `git diff --name-only`.
            norm = posixpath.normpath(raw)
            if raw.startswith("/") or norm in (".", "..") or norm.startswith(("/", "../")) or "\t" in raw:
                raise SystemExit(
                    f"repo {r.get('path', '')}: protected_paths entries must be paths inside the repo, "
                    f"not its root, got {raw!r}"
                )
            protected.append(norm + ("/" if raw.endswith("/") else ""))
        out["repos"].append({
            "path": path,
            "mode": mode,
            "base": r.get("base", ""),
            "findings": findings,
            "dimensions": repo_dimensions,
            "test_net": test_net,
            "test_robind": test_robind,
            "protected_paths": protected,
            "test_cmd": test_cmd,
        })
    return out


def pairs(rulebook: dict) -> bytes:
    """The loaded rulebook as NUL-terminated items for Bash's `readarray -d ''`: first the number of
    pairs, then each string's dotted path and value (`limits.max_open_branches`, `repos.0.test_cmd`,
    `dimensions.2`, ...). NUL is the one byte a Bash string cannot hold, so it is the one delimiter
    no value can contain; a value that does hold one is refused rather than split."""
    items: list[str] = []

    def walk(prefix: str, node) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                walk(f"{prefix}{k}.", v)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(f"{prefix}{i}.", v)
        else:
            if "\0" in node:
                raise SystemExit(f"{prefix[:-1]}: a value must not contain a NUL byte")
            items.extend((prefix[:-1], node))

    walk("", rulebook)
    return "".join(f"{x}\0" for x in [str(len(items) // 2), *items]).encode()


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--pairs":
        sys.stdout.buffer.write(pairs(load(args[1])))
    elif len(args) == 1 and not args[0].startswith("--"):
        json.dump(load(args[0]), sys.stdout)
        sys.stdout.write("\n")
    else:
        raise SystemExit("usage: parse_rulebook.py [--pairs] RULEBOOK")
