# Shared ledger rules; keep the verdict sets in sync with ledger.py.
def terminal_verdicts: ["merged", "dropped", "resolved", "wontfix"];
def merge_rate_verdicts: ["merged", "dropped"];

# Git ref names cannot contain a colon, so the last colon separates repo and branch.
def adopted_item_id: "orphan-adopt:\(.repo):\(.branch)";
def is_adoption:
  (.branch // "") != "" and (.item == "orphan-adopt" or .item == adopted_item_id);

# Ledger order is append order. group_by preserves it within each group; never sort by ts.
def latest_branch_verdicts:
  map(select(.outcome == "verdict" and .repo != null and .branch != null))
  | group_by([.repo, .branch]) | map(last);

# Callers retain their own repo/legacy identity scope and permanent-wontfix handling.
def latest_fingerprint_verdicts(identity):
  map(select(.outcome == "verdict" and .fingerprint != null))
  | group_by(identity) | map(last);

def unretracted_rows:
  [.[] | select(.outcome == "retracted") | .item] as $void
  | .[] | select(.item | IN($void[]) | not);
