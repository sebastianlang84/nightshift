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
     "agent": {"primary": "", "claude_model": "", "review_model": "", "advisors": ["claude"]},
     "dimensions": ["correctness", ...],
     "repos": [{"path": "/srv/x", "mode": "branch-fix", "base": "", "findings": "",
                "dimensions": ["docs"], "test_net": "false", "test_robind": "",
                "protected_paths": ["hooks/"], "test_cmd": "make test"}]}

An invalid rulebook raises SystemExit with the reason, so the script exits 1 and prints nothing on
stdout.

Usage: parse_rulebook.py [--pairs] RULEBOOK"""
import json
import posixpath
import sys
from pathlib import Path

# Every mapping section's key set is CLOSED: load() reads exactly
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
    "review_model",
    "advisors",
)
# Adapters the Runner implements (ADR 0044). `primary` and every `advisors` entry name one of these;
# anything else — a removed adapter included — is a typo, and tolerating it would run the night on
# something the host never asked for.
ADAPTERS = ("claude", "mock")
# load() reads only these top-level sections. A typo here would otherwise be ignored and
# every setting beneath it would silently revert to its default.
TOP_LEVEL_KEYS = ("branch_prefix", "limits", "recon", "agent", "dimensions", "repos")
REPO_KEYS = ("path", "mode", "base", "findings", "dimensions", "test_net", "test_robind", "protected_paths", "test_cmd")
# The modes the Runner actually implements. A repo whose mode is not in here is a typo, not a
# feature request — see the validation below for why that must abort rather than be skipped.
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

    `val()` splits on ` #` before it knows whether it is inside quotes, which
    truncates `"gpt-5 #2"` to `"gpt-5`. Only a `# comment` may follow the closing
    quote: anything else would be dropped, and `test_cmd: "cd" sub && make test`
    would become a ship gate that runs a bare `cd` and always passes. That and an
    unterminated quote are typos, not values — say so."""
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
            # YAML permits sequence items at the same indentation as their section key:
            # `repos:\n- path: …`. Keep the active sequence section for that standard shape;
            # resetting it here used to accept the file while silently emitting an empty fleet.
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
                    # `limits: 5`, a flow `limits: {…}` or a bare `limits` used to set no section,
                    # so every line under it was dropped without a word — the knob silently reverted.
                    raise SystemExit(f"section '{top_level_key}' must be a bare `{top_level_key}:` header")
                else:
                    # Dispatch on the key, not the raw header: `limits :` is the same key, and
                    # matching the literal `limits:` left its entries unread.
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
    if not max_open.isdecimal() or int(max_open) < 1:
        raise SystemExit("limits.max_open_branches must be a positive integer")
    lim["max_open_branches"] = max_open
    # Kept empty when absent: here the rulebook beats the env (precedence: rulebook ->
    # NIGHTSHIFT_MAX_RUN_BRANCHES -> default), and bin/nightshift.sh only reaches the env
    # once the rulebook value is empty, so a parser default would silently disable the
    # override. Precedence order, not whether an env override exists, decides this: limits
    # whose env override wins over the rulebook (test_timeout_seconds, test_memory_mb,
    # test_max_procs, test_fsize_mb, max_verifies_per_run) keep a parser default safely.
    # max_run_minutes is also left empty, for its own reason (see its comment below).
    max_run_branches = limits.get("max_branches_per_run", "")
    if max_run_branches and (
        not max_run_branches.isdecimal() or int(max_run_branches) < 1
    ):
        raise SystemExit("limits.max_branches_per_run must be a positive integer")
    lim["max_branches_per_run"] = max_run_branches
    # A hand-set 0 would make the fix<->review loop never run — every finding then
    # abandons silently. Require >= 1 so the misconfig fails loudly (with the runner's
    # fail-closed parse handling) instead of doing nothing.
    mfi = limits.get("max_fix_iterations", "3")
    if not mfi.isdecimal() or int(mfi) < 1:
        raise SystemExit("limits.max_fix_iterations must be a positive integer")
    lim["max_fix_iterations"] = mfi
    # These values are prompt guidance, but zero or non-numeric input still makes that guidance
    # useless or contradictory. Reject it here rather than passing malformed limits to a stage.
    mfc = limits.get("max_files_per_change", "15")
    if not mfc.isdecimal() or int(mfc) < 1:
        raise SystemExit("limits.max_files_per_change must be a positive integer")
    lim["max_files_per_change"] = mfc
    mlc = limits.get("max_lines_per_change", "400")
    if not mlc.isdecimal() or int(mlc) < 1:
        raise SystemExit("limits.max_lines_per_change must be a positive integer")
    lim["max_lines_per_change"] = mlc
    # Wall-clock spend budget for the whole night (ADR 0013). Empty = no time cap (bash applies the
    # NIGHTSHIFT_MAX_RUN_SECONDS env override first). Validate a present value as a positive integer.
    mrm = limits.get("max_run_minutes", "")
    if mrm and (not mrm.isdecimal() or int(mrm) < 1):
        raise SystemExit("limits.max_run_minutes must be a positive integer")
    lim["max_run_minutes"] = mrm
    # Wall-clock ceiling for ONE repo's `test_cmd` (ADR 0022). A hanging suite must not eat the
    # night, so the gate always runs under a timeout. Default 600s; a hand-set 0 would make every
    # gated run time out instantly and silently ship nothing, so require a positive integer.
    tts = limits.get("test_timeout_seconds", "600")
    if not tts.isdecimal() or int(tts) < 1:
        raise SystemExit("limits.test_timeout_seconds must be a positive integer")
    lim["test_timeout_seconds"] = tts
    # Resource ceilings for the sandboxed gate (ADR 0026), applied as rlimits inside the sandbox.
    # `test_memory_mb` is RLIMIT_DATA — the heap. NOT RLIMIT_AS: a WASM runtime reserves
    # multi-GB of address space it never touches, so an address-space cap large enough for a real
    # JS suite bounds nothing at all (measured: vitest fails at 16 GiB). 0 = no cap.
    tmb = limits.get("test_memory_mb", "4096")
    if not tmb.isdecimal():
        raise SystemExit("limits.test_memory_mb must be a non-negative integer")
    lim["test_memory_mb"] = tmb
    # RLIMIT_NPROC. The kernel charges this to the ACCOUNT, not to the sandbox, so a value below the
    # host's idle process count makes every gate fail to fork. 0 = no process cap.
    tmp_ = limits.get("test_max_procs", "2048")
    if not tmp_.isdecimal():
        raise SystemExit("limits.test_max_procs must be a non-negative integer")
    lim["test_max_procs"] = tmp_
    # RLIMIT_FSIZE. The worktree and the scratch HOME are on real disk, so without this a suite can
    # fill the filesystem — the one host-DoS route the tmpfs caps do not cover. 0 = no cap.
    tfs = limits.get("test_fsize_mb", "2048")
    if not tfs.isdecimal():
        raise SystemExit("limits.test_fsize_mb must be a non-negative integer")
    lim["test_fsize_mb"] = tfs
    # Findings emitted per repo per pass. Default 1 keeps a rulebook that omits the key at the
    # pre-v2 single-finding behavior; the live rulebook sets it explicitly (ADR 0011).
    # A hand-set 0 forces n_find=0 in the Runner (MAX_FINDINGS=0 → repo_findings 0 → the
    # `n_find -le 0` guard), so every repo without a per-repo override silently no-ops; a
    # non-numeric value detonates later in bash integer arithmetic. Require a positive
    # integer so the misconfig fails loudly, matching every sibling limit above.
    mfp = limits.get("max_findings_per_item", "1")
    if not mfp.isdecimal() or int(mfp) < 1:
        raise SystemExit("limits.max_findings_per_item must be a positive integer")
    lim["max_findings_per_item"] = mfp
    # Open findings the verify phase may re-check per night — one read-only stage call each, so
    # this is the ceiling on what closing the finding loop can cost. 0 is a legitimate value
    # ("never spend a model on closure"); the free deterministic probe runs either way. A
    # non-numeric value would detonate in bash arithmetic — fail loudly like every sibling.
    mvr = limits.get("max_verifies_per_run", "5")
    if not mvr.isdecimal():
        raise SystemExit("limits.max_verifies_per_run must be a non-negative integer")
    lim["max_verifies_per_run"] = mvr
    # Recon stage: on by default. This is a closed boolean domain: accepting YAML-ish synonyms
    # such as `no` while bash only recognises the literal `false` silently leaves Recon enabled.
    renabled = recon.get("enabled", "true")
    if renabled not in ("true", "false"):
        raise SystemExit("recon.enabled must be true or false")
    out["recon"] = {"enabled": renabled}
    # A malformed ttl_days silently became 0 in bash arithmetic → the cache was never fresh →
    # recon re-ran every pass. Require a positive integer so the misconfig fails loudly instead.
    ttl = recon.get("ttl_days", "7")
    if not ttl.isdecimal() or int(ttl) < 1:
        raise SystemExit("recon.ttl_days must be a positive integer")
    out["recon"]["ttl_days"] = ttl
    # Which MODEL a stage runs on (ADR 0020). The host declares it here because stage isolation
    # (ADR 0019) drops the CLI's `user` settings scope, so a machine-wide pin in
    # ~/.claude/settings.json no longer reaches a stage. OMITTING the key means "let the CLI resolve
    # its own default"; writing the key with no value is a half-finished edit, and treating that as
    # "no model" would silently run the night on something else. Model ID *syntax* stays
    # unvalidated — it belongs to the CLI vendor and any pattern here would go stale.
    # `review_model` is the model the Review stage and the branch advice request instead (ADR 0044);
    # omitted, they run on `claude_model` like every other stage.
    agent_out: dict = {}
    out["agent"] = agent_out
    for key in ("claude_model", "review_model"):
        model = agent.get(key, "")
        if key in agent and not model:
            raise SystemExit(
                f"agent.{key} is empty — give it a value, or omit the key entirely"
            )
        agent_out[key] = model
    # Which adapter runs the night. Omitted = whatever $NIGHTSHIFT_AGENT says, which is the
    # pre-existing behaviour; the env var still wins when explicitly set, so a one-off hand run needs
    # no rulebook edit. Declared here for the same reason the models are (ADR 0020): the host owns
    # this file, and which agent ran the night is governance, not an invocation detail.
    primary = agent.get("primary", "")
    if "primary" in agent and not primary:
        raise SystemExit("agent.primary is empty - name an adapter, or omit the key entirely")
    if primary and primary not in ADAPTERS:
        raise SystemExit(
            f"agent.primary: unknown adapter {primary!r} - "
            f"expected one of {', '.join(sorted(ADAPTERS))}"
        )
    agent_out["primary"] = primary
    # Which adapters give every open branch its nightly merge/fix/reject recommendation (ADR 0038).
    # A comma-separated scalar (block-style only, like a repo's `dimensions`). Omitted = no branch
    # review. Each entry names an ADAPTER and is validated like `primary`; a duplicate would ask
    # the same model twice, which is one opinion billed as two. `mock` alone may repeat: it is the
    # test adapter, and each of its slots stands in for a distinct model.
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
        if findings and (not findings.isdecimal() or int(findings) < 1):
            raise SystemExit(
                f"repo {path}: findings must be a positive integer"
            )
        # The Runner's select_order() skips any repo whose mode it does not recognise, WITHOUT a log
        # line — so `mode: brnach-fix` silently removed the repo from every night and the operator's
        # only clue was that it never appeared in a digest again. Closed key sets already protect
        # every other knob from a typo (LIMIT_KEYS/RECON_KEYS/AGENT_KEYS/REPO_KEYS); the mode VALUE
        # was the one place a typo still degraded the run quietly. Fail closed, same as the keys.
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
        # ADR 0026 closes the ungated ship path that ADR 0022 §4 left open. A `branch-fix` repo
        # pushes machine-written code that a human is invited to merge, and the Review stage only
        # ever proves the FINDING is fixed — never that nothing else broke. Shipping with no suite
        # at all was a silent gap: `shipping UNGATED` scrolled past in a log nobody reads at 04:00.
        # A repo with no runnable suite is not a repo nightshift may write branches for; say so with
        # `mode: findings-only`, which reports without ever pushing. Refuse the silence instead.
        if mode == "branch-fix" and not test_cmd:
            raise SystemExit(
                f"repo {r.get('path', '')}: mode branch-fix requires a test_cmd (ADR 0026) — "
                "give the repo its ship gate, or set mode: findings-only"
            )
        # Whether that gate's sandbox gets network egress (ADR 0026). Default false: `npm ci` and
        # `uv run --with-requirements` need it, most suites do not, and the flag makes the repos
        # that do an explicit, per-repo host decision rather than a fleet-wide default.
        test_net = r.get("test_net", "false")
        if test_net not in ("true", "false"):
            raise SystemExit(
                f"repo {r.get('path', '')}: test_net must be true or false, got {test_net!r}"
            )
        # Extra paths bound READ-ONLY into THIS repo's gate sandbox (ADR 0026), `:`-separated like the
        # host-wide NIGHTSHIFT_TEST_SANDBOX_ROBIND. Per repo because the usual case is one repo's
        # dependency on a local checkout (`git+file:///…`), and the host-wide knob would show that
        # checkout to every other repo's suite too. Absolute paths only: a relative one would resolve
        # against whatever directory the Runner happens to be in.
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
