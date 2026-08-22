#!/usr/bin/env bash
set -euo pipefail

# An agent CLI that is out of quota must ABORT the night, exactly like one that cannot authenticate
# (ADR 0023). It is the same class of event — the agent could not run, so nothing it returned is
# evidence about the code — but it arrives in a shape the credential check does not see.
#
# Regression for the night of 2026-08-21: the five-hour window was spent, so the CLI exited ZERO,
# emitted no result object, and reported the rejection as a structured `rate_limit_event`. Every
# stage therefore failed one layer later, in the JSON extractor, and was logged as "no parseable
# JSON from stage" — a parse problem, which reads like a model that answered badly rather than an
# account that could not answer at all. The night walked into the same wall six times in 21 seconds.
#
# Asserted here: the rejection is recognised from the event STRUCTURE (not the CLI's prose, which is
# not stable across versions), the reset time reaches the operator, and the night stops at the first
# failing stage instead of spending the rest of the fleet.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

for r in repo-a repo-b; do
  git init -q --bare "$TMP/$r.git"
  git init -q -b main "$TMP/$r"
  git -C "$TMP/$r" remote add origin "$TMP/$r.git"
  printf '# Demo\n\nThis is teh demo.\n' > "$TMP/$r/README.md"
  git -C "$TMP/$r" -c user.name=test -c user.email=test@localhost add README.md
  git -C "$TMP/$r" -c user.name=test -c user.email=test@localhost commit -q -m initial
  git -C "$TMP/$r" push -q -u origin main
done

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 3
  max_findings_per_item: 1
  max_branches_per_run: 2
  max_fix_iterations: 1
recon:
  enabled: true
  ttl_days: 7
dimensions:
  - correctness
repos:
  - path: $TMP/repo-a
    mode: branch-fix
    test_cmd: true
    base: main
  - path: $TMP/repo-b
    mode: branch-fix
    test_cmd: true
    base: main
EOF

# The observed shape, verbatim from runs/2026-08-21: an event array whose rate_limit_info is
# `rejected`, no result object, and exit 0. `resetsAt` is 2026-08-21 06:20:00 UTC.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1787293200,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false},"uuid":"5c5265a5-d702-4c78-95ae-99dc972b40c1"},
 {"type":"system","subtype":"init","tools":["Glob","Grep","Read"]}]
JSON
exit 0
EOF
chmod +x "$TMP/bin/claude"

set +e
PATH="$TMP/bin:/usr/bin:/bin" \
RULEBOOK="$TMP/rulebook.yaml" \
NIGHTSHIFT_AGENT=claude \
NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e

# 1. The night aborts, so the launcher and systemd both see a failed unit.
[ "$rc" -eq 3 ] || { echo "expected exit 3 (aborted night), got $rc" >&2; cat "$TMP/err" >&2; exit 1; }

# 2. The reason names quota, not parsing. This is the whole point: on 2026-08-21 the log blamed the
#    model's output for an account condition, and the morning had no way to tell the two apart.
grep -q 'FATAL:.*out of quota' "$TMP/err" \
  || { echo "log does not name the quota rejection" >&2; cat "$TMP/err" >&2; exit 1; }

# 3. The reset time reaches the operator — without it the only remedy is guess-and-retry.
grep -q 'out of quota until 2026-08-21' "$TMP/err" \
  || { echo "log does not carry the reset time from resetsAt" >&2; cat "$TMP/err" >&2; exit 1; }

# 4. Nothing derived was recorded: an account with no quota left is not a claim about the code.
[ -z "$(find "$TMP/state/recon" -name '*.json' 2>/dev/null)" ] \
  || { echo "a recon cache was written despite the agent being out of quota" >&2; exit 1; }
if [ -f "$TMP/state/ledger.jsonl" ]; then
  n=$(jq -s '[.[]|select(.outcome=="empty")]|length' "$TMP/state/ledger.jsonl")
  [ "$n" -eq 0 ] || { echo "$n forged 'empty' ledger rows written" >&2; exit 1; }
fi
[ -z "$(find "$TMP/state/dim-scans" -type f 2>/dev/null)" ] \
  || { echo "dimension rotation advanced on a stage that never ran" >&2; exit 1; }

# 5. One invocation, then stop. The defect being fixed is precisely that the night kept going.
stages=$(jq -s 'length' "$TMP/state/runs.jsonl")
[ "$stages" -eq 1 ] || { echo "expected 1 stage invocation before the abort, got $stages" >&2; exit 1; }

# 6. The digest says the night is not evidence about the code.
digest="$(find "$TMP/digests" -name '*.md' | head -1)"
[ -n "$digest" ] || { echo "no digest written" >&2; exit 1; }
grep -q 'ABORTED' "$digest" || { echo "digest does not announce the abort" >&2; cat "$digest" >&2; exit 1; }

# 7. A rate_limit_event that was ALLOWED is a normal night and must not abort anything. 167 of the
#    stage outputs on this machine carry one; treating the event type as the signal would have
#    aborted every one of them.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1787293200,"rateLimitType":"five_hour"}},
 {"type":"result","result":"{\"found\":false,\"findings\":[],\"scope\":\"in_scope_no_findings\",\"coverage\":{\"files\":[\"README.md\"],\"entrypoints\":[\"none\"],\"checks\":[\"a\",\"b\",\"c\"],\"invariants\":{\"config_domain\":\"not-applicable: none\",\"semantic_sets\":\"not-applicable: none\",\"artifact_identity\":\"not-applicable: none\",\"failure_translation\":\"not-applicable: none\",\"lifecycle\":\"not-applicable: none\"},\"unresolved\":[]}}"}]
JSON
exit 0
EOF
chmod +x "$TMP/bin/claude"
rm -rf "$TMP/state" "$TMP/runs" "$TMP/digests"
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests"

set +e
PATH="$TMP/bin:/usr/bin:/bin" \
RULEBOOK="$TMP/rulebook.yaml" \
NIGHTSHIFT_AGENT=claude \
NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
"$ROOT/bin/nightshift.sh" >"$TMP/out2" 2>"$TMP/err2"
rc2=$?
set -e
[ "$rc2" -ne 3 ] || { echo "an ALLOWED rate_limit_event aborted the night" >&2; cat "$TMP/err2" >&2; exit 1; }
grep -q 'out of quota' "$TMP/err2" && { echo "an ALLOWED rate_limit_event was reported as quota exhaustion" >&2; exit 1; }

echo "test-agent-quota-abort: ok"
