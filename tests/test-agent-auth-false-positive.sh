#!/usr/bin/env bash
set -euo pipefail

# The credential check must read what the CLI says about ITSELF, never what the model wrote.
#
# Regression for the night of 2026-08-24. An explore lens reviewed nightshift's own infra and read
# bin/nightshift.sh — including the line that self-heals a stale symlink after `codex login` — so
# AGENT_AUTH_RE matched the repo's source and the night aborted with "no usable credentials" after
# a single stage, while .usage_explore recorded 29,600 output tokens and $3.32 spent. The lens had
# in fact worked for seven minutes and produced a finding; what killed it first was a trailing
# comma in its JSON, which failed the parse and armed the latent false positive. The signature sits
# in 33 of 197 archived raw streams, so any stage that fails to parse for any reason can trip it.
#
# Asserted here, in the order the two defects compound: a trailing comma is repaired instead of
# discarding the lens; and a stage that DOES fail to parse no longer reads the model's prose about
# credentials as the CLI's own diagnosis.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

git init -q --bare "$TMP/repo-a.git"
git init -q -b main "$TMP/repo-a"
git -C "$TMP/repo-a" remote add origin "$TMP/repo-a.git"
printf '# Demo\n\nThis is a demo.\n' > "$TMP/repo-a/README.md"
git -C "$TMP/repo-a" -c user.name=test -c user.email=test@localhost add README.md
git -C "$TMP/repo-a" -c user.name=test -c user.email=test@localhost commit -q -m initial
git -C "$TMP/repo-a" push -q -u origin main

cat > "$TMP/rulebook.yaml" <<EOF
branch_prefix: nightshift/
limits:
  max_open_branches: 3
  max_findings_per_item: 1
  max_branches_per_run: 1
  max_fix_iterations: 1
recon:
  enabled: false
dimensions:
  - correctness
repos:
  - path: $TMP/repo-a
    mode: branch-fix
    test_cmd: true
    base: main
EOF

run_night() { # out_prefix
  set +e
  PATH="$TMP/bin:/usr/bin:/bin" \
  RULEBOOK="$TMP/rulebook.yaml" \
  NIGHTSHIFT_AGENT=claude \
  NIGHTSHIFT_CODEMAP=0 NIGHTSHIFT_OPEN_PR=0 \
  NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs" \
  NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees" \
  "$ROOT/bin/nightshift.sh" >"$1.out" 2>"$1.err"
  echo $?
  set -e
}

reset_state() { rm -rf "$TMP/state" "$TMP/runs" "$TMP/digests"; mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests"; }

# ---- 1. A trailing comma is a slip, not a lost lens -------------------------------------------
# The prose after the JSON is the shape that armed the false positive: the model discussing the
# repo's own credential handling. `"unresolved": [],\n }` is the malformation, verbatim in kind
# from the lost lens.
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[{"type":"assistant","message":{"content":[{"type":"text","text":"bin/nightshift.sh self-heals the symlink after `codex login`; an unauthorized push is refused."}]}},
 {"type":"result","subtype":"success","is_error":false,"usage":{"output_tokens":2400,"input_tokens":40},
  "result":"{\"found\": false,\n \"scope\": \"in_scope_no_findings\",\n \"findings\": [],\n \"coverage\": {\"files\": [\"README.md\"], \"entrypoints\": [\"none\"], \"checks\": [\"a\",\"b\",\"c\"], \"invariants\": {\"config_domain\": \"not-applicable: none\", \"semantic_sets\": \"not-applicable: none\", \"artifact_identity\": \"not-applicable: none\", \"failure_translation\": \"not-applicable: none\", \"lifecycle\": \"not-applicable: none\"}, \"unresolved\": [],\n },\n}\n\nI stopped short of a fix: `codex login` is mentioned only in a comment."}]
JSON
exit 0
STUB
chmod +x "$TMP/bin/claude"

rc=$(run_night "$TMP/a")
[ "$rc" -ne 3 ] || { echo "a trailing comma plus model prose about credentials aborted the night" >&2; cat "$TMP/a.err" >&2; exit 1; }
grep -q 'json-repair: dropped 2 trailing comma' "$TMP/a.err" \
  || { echo "the repair did not fire, or did not announce itself in the log" >&2; cat "$TMP/a.err" >&2; exit 1; }
grep -q 'no usable credentials' "$TMP/a.err" \
  && { echo "the repaired stage was still read as a credential failure" >&2; exit 1; }

# ---- 2. A stage that really cannot be parsed is still not a credential failure ------------------
# Truncated output: ADR 0030 refuses to complete it, so the stage fails and the credential check
# runs. The CLI's own verdict is `is_error: false` — it ran the session — and everything else in
# the stream is the model's words. No usage counters here, so the structural filter is what has to
# hold on its own.
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[{"type":"assistant","message":{"content":[{"type":"text","text":"Not logged in is the message the CLI prints; see /login in the runbook."}]}},
 {"type":"result","subtype":"success","is_error":false,
  "result":"{\"found\": true, \"findings\": [{\"file\": \"README.md\", \"summary\": \"truncated before the closer"}]
JSON
exit 0
STUB
chmod +x "$TMP/bin/claude"
reset_state
rc=$(run_night "$TMP/b")
[ "$rc" -ne 3 ] || { echo "model prose about credentials aborted the night as an auth failure" >&2; cat "$TMP/b.err" >&2; exit 1; }
grep -q 'no usable credentials' "$TMP/b.err" \
  && { echo "the model's own words were read as the CLI's credential diagnosis" >&2; cat "$TMP/b.err" >&2; exit 1; }
grep -q 'stage explore FAILED' "$TMP/b.err" \
  || { echo "the unparseable stage was not reported as a failure at all" >&2; cat "$TMP/b.err" >&2; exit 1; }

# ---- 3. A real credential failure still aborts, in both shapes it arrives in --------------------
# Structured: the CLI's result object says it failed. This is the half the filter must let through.
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Invalid API key · Please run /login"}]
JSON
exit 1
STUB
chmod +x "$TMP/bin/claude"
reset_state
rc=$(run_night "$TMP/c")
[ "$rc" -eq 3 ] || { echo "a structured credential failure no longer aborts the night (got $rc)" >&2; cat "$TMP/c.err" >&2; exit 1; }
grep -q 'FATAL:.*no usable credentials' "$TMP/c.err" \
  || { echo "the structured credential failure was not named" >&2; cat "$TMP/c.err" >&2; exit 1; }

# ---- 4. The token receipt refutes a credential failure on its own -------------------------------
# Adapter-independent, and the only cover codex has: its raw stream is passed through unfiltered
# because no codex night has ever run here to show its shape. A stage that spent tokens reached the
# API, so whatever else went wrong, authentication did not.
# shellcheck disable=SC1090
( NIGHTSHIFT_AGENT=codex NIGHTSHIFT_SOURCED=1 source "$ROOT/bin/nightshift.sh"
  printf 'error: not logged in\n' > "$TMP/u.raw"
  printf '{"output_tokens":null,"input_tokens":null,"cache_read_tokens":null}\n' > "$TMP/u.none"
  printf '{"output_tokens":2400,"input_tokens":40,"cache_read_tokens":91000}\n' > "$TMP/u.spent"
  agent_reached_the_api "$TMP/u.none"  && { echo "a usage record of all-null counters was read as a completed request" >&2; exit 1; }
  agent_reached_the_api "$TMP/u.spent" || { echo "a usage record with real counters was not read as a completed request" >&2; exit 1; }
  agent_credentials_failed /dev/null "$TMP/u.raw" \
    || { echo "codex's unfiltered stderr-shaped raw no longer reaches the signatures" >&2; exit 1; }
) || exit 1

echo "test-agent-auth-false-positive: ok"
