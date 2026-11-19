"""Shared ledger rules; keep the verdict sets in sync with ledger.jq."""

TERMINAL_VERDICTS = frozenset({"merged", "dropped", "resolved", "wontfix"})
MERGE_RATE_VERDICTS = frozenset({"merged", "dropped"})


def verdict_item_id(row):
    """The scoped ID for a legacy adoption, or the item ID already present on the row."""
    item = row.get("item")
    if item != "orphan-adopt":
        return item
    repo, branch = row.get("repo"), row.get("branch")
    if repo and branch:
        # Keep the format in sync with adopted_item_id in ledger.jq.
        return f"orphan-adopt:{repo}:{branch}"
    return None


def latest_branch_verdicts(rows):
    """Last-appended verdict per non-null (repo, branch), never ordered by timestamp."""
    latest = {}
    for row in rows:
        if (row.get("outcome") == "verdict"
                and row.get("repo") is not None and row.get("branch") is not None):
            latest[(row["repo"], row["branch"])] = row
    return latest
