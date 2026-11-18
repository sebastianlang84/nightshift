"""Shared ledger rules; keep the verdict sets in sync with ledger.jq."""

TERMINAL_VERDICTS = frozenset({"merged", "dropped", "resolved", "wontfix"})
MERGE_RATE_VERDICTS = frozenset({"merged", "dropped"})


def latest_branch_verdicts(rows):
    """Last-appended verdict per non-null (repo, branch), never ordered by timestamp."""
    latest = {}
    for row in rows:
        if (row.get("outcome") == "verdict"
                and row.get("repo") is not None and row.get("branch") is not None):
            latest[(row["repo"], row["branch"])] = row
    return latest
