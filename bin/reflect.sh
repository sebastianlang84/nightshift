#!/usr/bin/env bash
# nightshift reflection runner — read a day of agent sessions, propose rulebook changes (ADR 0035).
#
# NOT part of the night loop and deliberately NOT on a timer: the operator starts it. Its input is
# text quoted out of repositories the agents were reading, and the night loop's stages may commit
# and push, so the two are kept apart — see docs/design/reflection-confinement.md.
#
# The pipeline, and why it has five steps rather than one:
#
#   1 extract   each transcript -> turns with stable ids           lib/extract_session.py
#   2 generate  a cheap model proposes findings, each with a quote prompts/reflection/generate.md
#   3 check     every quote is resolved against the turn it names  lib/check_citations.py
#   4 assemble  survivors + surrounding turns + session inventory  lib/build_judge_input.py
#   5 judge     a model asks whether the quote still means that    prompts/reflection/judge.md
#
# Step 3 exists because the prototype quoted an agent as saying the opposite of what the transcript
# said and proposed a rule change on it. Step 5 exists because step 3 cannot catch a quote that is
# exact and still false to its source — an elided clause. No stage both produces a finding and is
# the last word on it.
#
# The report is a proposal. Applying anything in it stays a human act.
#
#   reflect.sh [--day YYYY-MM-DD] [--out FILE] [--model ID] [--judge-model ID]
#              [--session-glob GLOB] [--max-sessions N] [--keep] [--dry-run]
set -euo pipefail

NIGHTSHIFT_HOME="${NIGHTSHIFT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$NIGHTSHIFT_HOME/lib"
PROMPTS="$NIGHTSHIFT_HOME/prompts/reflection"

CLAUDE_PROJECTS="${NIGHTSHIFT_REFLECT_CLAUDE_DIR:-$HOME/.claude/projects}"
CODEX_SESSIONS="${NIGHTSHIFT_REFLECT_CODEX_DIR:-$HOME/.codex/sessions}"
REPORT_DIR="${NIGHTSHIFT_REFLECT_DIR:-$NIGHTSHIFT_HOME/reflections}"

# The generating model is the cheap one on purpose: it reads the whole day, and the citation check
# below is what makes a cheap reader safe to trust. The judge sees a fraction of the material.
GEN_PROVIDER="${NIGHTSHIFT_REFLECT_PROVIDER:-pidso-proxy}"
GEN_MODEL="${NIGHTSHIFT_REFLECT_MODEL:-z-ai/glm-5.3-flash}"
JUDGE_PROVIDER="${NIGHTSHIFT_REFLECT_JUDGE_PROVIDER:-$GEN_PROVIDER}"
JUDGE_MODEL="${NIGHTSHIFT_REFLECT_JUDGE_MODEL:-$GEN_MODEL}"

# Rulebooks and skills the reflection reads to judge whether a proposed rule already exists. A
# missing one is skipped, not fatal: this list spans machines.
RULEBOOKS_DEFAULT=(
  "$HOME/.claude/CLAUDE.md"
  "$HOME/nightshift/AGENTS.md"
  "$HOME/partflow/AGENTS.md"
  "$HOME/llmstack/AGENTS.md"
  "$HOME/a2a/AGENTS.md"
)

DAY="$(date -d yesterday +%F 2>/dev/null || date +%F)"
OUT=""
SESSION_GLOB=""
MAX_SESSIONS="${NIGHTSHIFT_REFLECT_MAX_SESSIONS:-12}"
KEEP=0
DRY=0

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --day)          DAY="$2"; shift 2 ;;
    --out)          OUT="$2"; shift 2 ;;
    --model)        GEN_MODEL="$2"; shift 2 ;;
    --judge-model)  JUDGE_MODEL="$2"; shift 2 ;;
    --session-glob) SESSION_GLOB="$2"; shift 2 ;;
    --max-sessions) MAX_SESSIONS="$2"; shift 2 ;;
    --keep)         KEEP=1; shift ;;
    --dry-run)      DRY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$DAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "reflect: --day must be YYYY-MM-DD, got '$DAY'" >&2; exit 2 ;;
esac
case "$MAX_SESSIONS" in
  ''|*[!0-9]*) echo "reflect: --max-sessions must be a number" >&2; exit 2 ;;
esac

log() { printf '%s reflect: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf 'reflect: %s\n' "$*" >&2; exit 1; }

command -v pi >/dev/null || die "pi is not installed — the reflection has no model to call"
for f in "$LIB/extract_session.py" "$LIB/check_citations.py" "$LIB/build_judge_input.py" \
         "$PROMPTS/generate.md" "$PROMPTS/judge.md"; do
  [ -f "$f" ] || die "missing $f"
done

umask 077
WORK="$(mktemp -d)"
cleanup() { [ "$KEEP" -eq 1 ] && log "kept working directory: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/turns"

# --- 1. the day's sessions ----------------------------------------------------
# Modified-on-that-day, which is when the conversation happened. A session spanning midnight is
# picked up by the day it was last written to, and the judge is told the day it was given.
find_sessions() {
  local day_start day_end
  day_start="$(date -d "$DAY 00:00:00" +%s)"
  day_end="$(date -d "$DAY 23:59:59" +%s)"
  {
    [ -d "$CLAUDE_PROJECTS" ] && find "$CLAUDE_PROJECTS" -maxdepth 2 -name '*.jsonl' \
      -newermt "@$day_start" ! -newermt "@$day_end" -printf '%T@ %p\n' 2>/dev/null
    [ -d "$CODEX_SESSIONS" ] && find "$CODEX_SESSIONS" -name '*.jsonl' \
      -newermt "@$day_start" ! -newermt "@$day_end" -printf '%T@ %p\n' 2>/dev/null
  } | sort -rn | cut -d' ' -f2-
}

mapfile -t SESSIONS < <(find_sessions)
if [ "${#SESSIONS[@]}" -eq 0 ]; then
  die "no sessions modified on $DAY under $CLAUDE_PROJECTS or $CODEX_SESSIONS"
fi

# Subagent transcripts live one level below their parent and repeat its material; the parent's turns
# carry the conversation the operator actually had.
FILTERED=()
for s in "${SESSIONS[@]}"; do
  case "$s" in */subagents/*) continue ;; esac
  if [ -n "$SESSION_GLOB" ]; then
    case "$s" in $SESSION_GLOB) ;; *) continue ;; esac
  fi
  FILTERED+=("$s")
  [ "${#FILTERED[@]}" -ge "$MAX_SESSIONS" ] && break
done
[ "${#FILTERED[@]}" -gt 0 ] || die "every session on $DAY was filtered out"

log "day $DAY: ${#FILTERED[@]} session(s)"

MANIFEST="$WORK/manifest.json"
printf '{"day": "%s", "sessions": [' "$DAY" > "$MANIFEST"
first=1
TURN_FILES=()
for s in "${FILTERED[@]}"; do
  sid="$(python3 "$LIB/extract_session.py" --print-session-id "$s" 2>/dev/null || true)"
  [ -n "$sid" ] || sid="$(basename "$s" .jsonl | cut -c1-8)"
  # A session that yields no turns still belongs in the manifest: "the generator saw nothing here"
  # and "the generator was never given this" are different facts, and only the manifest keeps them
  # apart once the turn files are the only evidence left.
  if python3 "$LIB/extract_session.py" "$s" > "$WORK/turns/$sid.turns" 2>"$WORK/turns/$sid.err"; then
    TURN_FILES+=("$WORK/turns/$sid.turns")
  else
    log "  $sid: no turns extracted ($(tail -1 "$WORK/turns/$sid.err" 2>/dev/null || echo 'unknown'))"
    rm -f "$WORK/turns/$sid.turns"
  fi
  [ "$first" -eq 1 ] && first=0 || printf ', ' >> "$MANIFEST"
  printf '"%s"' "$sid" >> "$MANIFEST"
done
printf ']}\n' >> "$MANIFEST"
[ "${#TURN_FILES[@]}" -gt 0 ] || die "no session on $DAY produced any turns"

RULEBOOKS=()
for f in "${RULEBOOKS_DEFAULT[@]}"; do [ -f "$f" ] && RULEBOOKS+=("$f"); done
log "${#TURN_FILES[@]} transcript(s) extracted, ${#RULEBOOKS[@]} rulebook(s)"

if [ "$DRY" -eq 1 ]; then
  echo "would reflect on $DAY:"
  printf '  %s\n' "${FILTERED[@]}"
  echo "generate: $GEN_PROVIDER/$GEN_MODEL · judge: $JUDGE_PROVIDER/$JUDGE_MODEL"
  exit 0
fi

# --- 2. generate --------------------------------------------------------------
{
  cat "$PROMPTS/generate.md"
  printf '\n\n===== RULEBOOKS =====\n'
  for f in "${RULEBOOKS[@]}"; do
    printf '\n----- BEGIN %s -----\n' "$f"; cat "$f"; printf '\n----- END %s -----\n' "$f"
  done
  printf '\n\n===== TRANSCRIPTS FOR %s =====\n' "$DAY"
  for f in "${TURN_FILES[@]}"; do printf '\n'; cat "$f"; done
  printf '\n===== END =====\n'
} > "$WORK/generate-payload.md"

log "generate: $GEN_MODEL on $(wc -c < "$WORK/generate-payload.md") bytes"
NEUTRAL="$WORK/neutral"; mkdir -p "$NEUTRAL"
# -nc -ns: the reflection judges the rulebooks, so it must not also be steered by them. `< /dev/null`
# because pi waits on an inherited stdin and never sends the request without it.
( cd "$NEUTRAL" && pi -p -a -nt -nc -ns --no-session \
    --provider "$GEN_PROVIDER" --model "$GEN_MODEL" --thinking high \
    @"$WORK/generate-payload.md" "Follow the instructions in the attached file." \
    > "$WORK/generate.raw" 2>"$WORK/generate.err" < /dev/null ) \
  || die "the generate stage failed: $(tail -1 "$WORK/generate.err" 2>/dev/null)"

python3 "$LIB/extract_json.py" < "$WORK/generate.raw" > "$WORK/findings.json" 2>"$WORK/extract.err" \
  || die "the generate stage did not return usable JSON — raw answer in $WORK/generate.raw (use --keep)"
FOUND=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("findings") or []))' \
        "$WORK/findings.json" 2>/dev/null || echo 0)
log "generate: $FOUND finding(s) proposed"

# --- 3. check the citations ---------------------------------------------------
python3 "$LIB/check_citations.py" --findings "$WORK/findings.json" --turns "${TURN_FILES[@]}" \
  --out "$WORK/checked.json" --print > /dev/null 2>"$WORK/check.err" \
  || die "the citation check failed: $(tail -1 "$WORK/check.err" 2>/dev/null)"
KEPT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["counts"]["kept"])' "$WORK/checked.json")
DROPPED=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["counts"]["dropped"])' "$WORK/checked.json")
log "check: $KEPT carried their evidence, $DROPPED dropped"
[ -s "$WORK/check.err" ] && sed 's/^/  /' "$WORK/check.err" >&2

# --- 4. assemble what the judge reads ----------------------------------------
python3 "$LIB/build_judge_input.py" --checked "$WORK/checked.json" --turns "${TURN_FILES[@]}" \
  --manifest "$MANIFEST" ${RULEBOOKS[@]:+--rulebook "${RULEBOOKS[@]}"} --out "$WORK/judge-input.txt" \
  || die "could not assemble the judge's input"

# --- 5. judge -----------------------------------------------------------------
{ cat "$PROMPTS/judge.md"; printf '\n\n'; cat "$WORK/judge-input.txt"; } > "$WORK/judge-payload.md"
log "judge: $JUDGE_MODEL on $(wc -c < "$WORK/judge-payload.md") bytes"
( cd "$NEUTRAL" && pi -p -a -nt -nc -ns --no-session \
    --provider "$JUDGE_PROVIDER" --model "$JUDGE_MODEL" --thinking high \
    @"$WORK/judge-payload.md" "Follow the instructions in the attached file." \
    > "$WORK/judge.md" 2>"$WORK/judge.err" < /dev/null ) \
  || die "the judge stage failed: $(tail -1 "$WORK/judge.err" 2>/dev/null)"

# --- report -------------------------------------------------------------------
mkdir -p "$REPORT_DIR"
[ -n "$OUT" ] || OUT="$REPORT_DIR/$DAY.md"
{
  printf '# Reflection — %s\n\n' "$DAY"
  printf -- '- generate: `%s/%s` · judge: `%s/%s`\n' \
    "$GEN_PROVIDER" "$GEN_MODEL" "$JUDGE_PROVIDER" "$JUDGE_MODEL"
  printf -- '- %s finding(s) proposed · %s carried their evidence · %s dropped by the citation check\n' \
    "$FOUND" "$KEPT" "$DROPPED"
  printf -- '- sessions read: %s\n\n' "${#TURN_FILES[@]}"
  printf 'Every finding below cites a turn that was checked against the transcript. That makes the\n'
  printf 'quote real, not the conclusion right — read the judge on each one before changing a rule.\n\n'
  printf -- '---\n\n'
  cat "$WORK/judge.md"
  printf '\n\n---\n\n## Findings as proposed\n\n```json\n'
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); json.dump({"kept": d["kept"]}, sys.stdout, indent=2, ensure_ascii=False)' \
    "$WORK/checked.json"
  printf '\n```\n\n## Dropped by the citation check\n\n'
  python3 - "$WORK/checked.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if not d["dropped"]:
    print("None.")
for x in d["dropped"]:
    f = x.get("finding") or {}
    fid = f.get("id", "?") if isinstance(f, dict) else "?"
    print(f"- **{fid}** — {'; '.join(x.get('reasons') or [])}")
PY
} > "$OUT"

log "report: $OUT"
printf '%s\n' "$OUT"
