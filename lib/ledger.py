"""Shared ledger rules; keep the verdict sets in sync with ledger.jq."""

from collections import Counter
from os.path import basename


TERMINAL_VERDICTS = frozenset({"merged", "dropped", "resolved", "wontfix"})
MERGE_RATE_VERDICTS = frozenset({"merged", "dropped"})


def verdict_item_key(row):
    """Scope verdicts to their repo and distinguish adoptions written with the legacy item."""
    item, repo, branch = row.get("item"), row.get("repo"), row.get("branch")
    if branch and item in ("orphan-adopt", f"orphan-adopt:{repo}:{branch}"):
        return ("adoption", repo, branch)
    if item and item != "orphan-adopt":
        return ("item", repo, item)
    return None


def repo_labels(repos):
    """Use checkout names where unique and full ledger paths where needed."""
    names = {repo: basename(repo) for repo in repos}
    counts = Counter(names.values())
    return {repo: name if counts[name] == 1 else repo for repo, name in names.items()}


def latest_branch_verdicts(rows):
    """Last-appended verdict per non-null (repo, branch), never ordered by timestamp."""
    latest = {}
    for row in rows:
        if (row.get("outcome") == "verdict"
                and row.get("repo") is not None and row.get("branch") is not None):
            latest[(row["repo"], row["branch"])] = row
    return latest
