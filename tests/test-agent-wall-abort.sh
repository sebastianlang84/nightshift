#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# An agent CLI that cannot reach its model must ABORT the night, exactly like one that cannot
# authenticate (ADR 0023): nothing it returned is evidence about the code. The test is the same for
# every adapter — a stage that failed quickly with no tokens counted, twice in a row — because each
# CLI reports a spent quota in its own shape and changes it between versions. Both Claude shapes seen
# so far are replayed here verbatim: the `rate_limit_event` of 2026-08-21 (exit 0, no result) and the
# 429 `is_error` result of 2026-10-31. The Codex shape of 2026-10-28 is in test-agent-wall-reviewer.sh.
#
# Asserted: the night stops after the second wall instead of spending the fleet, the reason reaches
# the log and the digest with a remedy that covers a spent quota, and nothing derived is recorded —
# not even from the first wall, before the rule has made the agent fatal.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/worktrees"

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

# The stub prints the file named by $CLAUDE_REPLY and exits with $CLAUDE_RC.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat "$CLAUDE_REPLY"
exit "${CLAUDE_RC:-0}"
EOF
chmod +x "$TMP/bin/claude"

# Verbatim from runs/2026-08-21: an event array whose rate_limit_info is `rejected`, no result, exit 0.
cat > "$TMP/2026-08-21.json" <<'JSON'
[{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1787293200,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false},"uuid":"5c5265a5-d702-4c78-95ae-99dc972b40c1"},
 {"type":"system","subtype":"init","tools":["Glob","Grep","Read"]}]
JSON
# From runs/2026-10-31 (fields trimmed): a failed result with a 429 and zero usage.
cat > "$TMP/2026-10-31.json" <<'JSON'
{"type":"result","subtype":"success","is_error":true,"num_turns":1,"duration_api_ms":0,"api_error_status":429,"api_error_origin":"first_party","api_error":"usage_limit_reached","terminal_reason":"api_error","result":"You've hit your 5-hour limit · resets 6:20am (Europe/Berlin)","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"modelUsage":{}}
JSON

night() { # reply_file rc -> exit status of one night against the stub; log in $TMP/err
  rm -rf "$TMP/state" "$TMP/runs" "$TMP/digests"
  mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests"
  local rc=0
  PATH="$TMP/bin:/usr/bin:/bin" CLAUDE_REPLY="$1" CLAUDE_RC="$2" \
  RULEBOOK="$TMP/rulebook.yaml" \
  NIGHTSHIFT_AGENT=claude \
  NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$TMP/out" 2>"$TMP/err" || rc=$?
  return $rc
}

for shape in "2026-08-21 0" "2026-10-31 1"; do
  set -- $shape
  rc=0; night "$TMP/$1.json" "$2" || rc=$?

  # 1. The night aborts, so the launcher and systemd both see a failed unit.
  [ "$rc" -eq 3 ] || { echo "$1: expected exit 3 (aborted night), got $rc" >&2; cat "$TMP/err" >&2; exit 1; }

  # 2. The reason names an agent that could not run, not parsing: on 2026-08-21 the log blamed the
  #    model's output for an account condition, and the morning could not tell the two apart.
  grep -q 'FATAL: claude could not reach its model 2 stages in a row' "$TMP/err" \
    || { echo "$1: log does not name the wall" >&2; cat "$TMP/err" >&2; exit 1; }

  # 3. Nothing derived was recorded: an account that cannot answer is not a claim about the code.
  #    The first wall is a Recon, whose failure would otherwise be negative-cached for six hours.
  [ -z "$(find "$TMP/state/recon" -name '*.json' 2>/dev/null)" ] \
    || { echo "$1: a recon cache was written despite the agent being unusable" >&2; exit 1; }
  if [ -f "$TMP/state/ledger.jsonl" ]; then
    n=$(jq -s '[.[]|select(.outcome=="empty")]|length' "$TMP/state/ledger.jsonl")
    [ "$n" -eq 0 ] || { echo "$1: $n forged 'empty' ledger rows written" >&2; exit 1; }
  fi
  [ -z "$(find "$TMP/state/dim-scans" -type f 2>/dev/null)" ] \
    || { echo "$1: dimension rotation advanced on a stage that never ran" >&2; exit 1; }

  # 4. Two invocations, then stop. The defect being fixed is precisely that the night kept going.
  stages=$(jq -s 'length' "$TMP/state/runs.jsonl")
  [ "$stages" -eq 2 ] || { echo "$1: expected 2 stage invocations before the abort, got $stages" >&2; exit 1; }

  # 5. The digest says the night is not evidence about the code, and its remedy covers a spent quota
  #    as well as a lost login — the CLI may well be logged in.
  digest="$(find "$TMP/digests" -name '*.md' | head -1)"
  [ -n "$digest" ] || { echo "$1: no digest written" >&2; exit 1; }
  grep -q 'ABORTED' "$digest" || { echo "$1: digest does not announce the abort" >&2; cat "$digest" >&2; exit 1; }
  grep -q 'is logged in and has quota left' "$digest" \
    || { echo "$1: digest remedy does not cover a spent quota" >&2; cat "$digest" >&2; exit 1; }
done

# 6. A night whose stages complete is not touched by the rule, whatever events the CLI adds: 167 of
#    the stage outputs on this machine carry an ALLOWED rate_limit_event.
cat > "$TMP/healthy.json" <<'JSON'
[{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1787293200,"rateLimitType":"five_hour"}},
 {"type":"result","result":"{\"found\":false,\"findings\":[],\"scope\":\"in_scope_no_findings\",\"coverage\":{\"files\":[\"README.md\"],\"entrypoints\":[\"none\"],\"checks\":[\"a\",\"b\",\"c\"],\"invariants\":{\"config_domain\":\"not-applicable: none\",\"semantic_sets\":\"not-applicable: none\",\"artifact_identity\":\"not-applicable: none\",\"failure_translation\":\"not-applicable: none\",\"lifecycle\":\"not-applicable: none\"},\"unresolved\":[]}}"}]
JSON
rc=0; night "$TMP/healthy.json" 0 || rc=$?
[ "$rc" -ne 3 ] || { echo "a healthy night was aborted" >&2; cat "$TMP/err" >&2; exit 1; }
if grep -q 'could not reach its model' "$TMP/err"; then
  echo "a healthy night was reported as a wall" >&2; exit 1
fi

echo "test-agent-wall-abort: ok"
