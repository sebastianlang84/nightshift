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
# Transcript trees that hold automated runs rather than conversations. The reflection asks how a
# working DAY went, and only a session with a person in it can answer that — so what belongs here is
# whatever produces transcripts nobody had a conversation in:
#
#   subagents/      a subagent repeats its parent's material under a second id;
#   peer-debates/   two models arguing with each other on a fixed brief. On 2026-09-21 these were 21
#                   of the day's 32 transcripts, so reading them does not merely add noise — it
#                   crowds real sessions out past `--max-sessions` while the report still counts
#                   them as sessions read.
#
# Override with NIGHTSHIFT_REFLECT_EXCLUDE, a space-separated list of shell patterns matched against
# the whole path. An empty value reads everything.
#
# `*peer-debates*` carries no slashes on purpose: Claude Code names a project directory after the
# working directory with every slash turned into a dash, so `~/peer-debates/<topic>` arrives as
# `-home-llmadmin-peer-debates-<topic>` and a slash-anchored pattern matches nothing.
read -r -a EXCLUDE <<< "${NIGHTSHIFT_REFLECT_EXCLUDE-*/subagents/* *peer-debates*}"

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

# `set -u` turns a missing option value into "unbound variable", which names the shell's problem
# rather than the caller's. Check the arity first so `--day` with nothing after it says what it
# wanted.
need() { [ $# -ge 2 ] || { echo "reflect: $1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --day)          need "$@"; DAY="$2"; shift 2 ;;
    --out)          need "$@"; OUT="$2"; shift 2 ;;
    --model)        need "$@"; GEN_MODEL="$2"; shift 2 ;;
    --judge-model)  need "$@"; JUDGE_MODEL="$2"; shift 2 ;;
    --session-glob) need "$@"; SESSION_GLOB="$2"; shift 2 ;;
    --max-sessions) need "$@"; MAX_SESSIONS="$2"; shift 2 ;;
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
# The cap is checked after a session is appended, so 0 would still select one. Refusing is the
# honest reading: nobody asks for a reflection over no sessions.
[ "$MAX_SESSIONS" -ge 1 ] || { echo "reflect: --max-sessions must be at least 1" >&2; exit 2; }

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
# Selection is by FILE MODIFICATION TIME, which is when the conversation was last written, not
# necessarily when it happened: copying an old transcript today puts it in today's material, and a
# session spanning midnight lands whole in the day it was last written to. The report says so, so a
# reader can tell what the day in its title covers.
#
# Three things here are deliberate, and each one closes a way to lose evidence silently:
#
#   -type f          a symlink named `*.jsonl` would otherwise pull in a file from anywhere;
#   -printf …\0      a path may contain a newline, which a line-oriented reader splits in two;
#   no 2>/dev/null   an unreadable subtree makes `find` exit non-zero, and that has to stop the run
#                    rather than quietly shorten the day.
#
# The window itself is half-open, [00:00:00 of the day, 00:00:00 of the next), and it is compared in
# Python against the float timestamp. `find -newermt` is strictly-greater-than, so the pair
# `-newermt @start ! -newermt @end` silently drops a file stamped exactly at midnight and one
# stamped in the last fractional second of the day.
: > "$WORK/candidates"
if [ -d "$CLAUDE_PROJECTS" ]; then
  find "$CLAUDE_PROJECTS" -maxdepth 2 -type f -name '*.jsonl' -printf '%T@\t%p\0' \
    >> "$WORK/candidates" || die "could not list $CLAUDE_PROJECTS"
fi
if [ -d "$CODEX_SESSIONS" ]; then
  find "$CODEX_SESSIONS" -type f -name '*.jsonl' -printf '%T@\t%p\0' \
    >> "$WORK/candidates" || die "could not list $CODEX_SESSIONS"
fi

# `python3 -` reads its PROGRAM from stdin, so the candidate list travels as a path, not on stdin.
python3 - "$DAY" "$WORK/candidates" > "$WORK/selected" <<'PY' || die "could not select the day"
import datetime, sys
start = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d")
lo = start.timestamp()
hi = (start + datetime.timedelta(days=1)).timestamp()
rows = []
for rec in open(sys.argv[2], errors="replace").read().split("\0"):
    if not rec:
        continue
    ts, _, path = rec.partition("\t")
    try:
        t = float(ts)
    except ValueError:
        continue
    if lo <= t < hi:
        rows.append((t, path))
rows.sort(key=lambda r: -r[0])
sys.stdout.write("".join(p + "\0" for _, p in rows))
PY

mapfile -d '' -t SESSIONS < "$WORK/selected"
if [ "${#SESSIONS[@]}" -eq 0 ]; then
  die "no sessions modified on $DAY under $CLAUDE_PROJECTS or $CODEX_SESSIONS"
fi

# Filter first, cap second, and keep both counts. A cap applied while filtering would spend slots
# on transcripts that are never eligible, and "12 of 20" would then be counting different things on
# either side of the "of".
ELIGIBLE_LIST=()
for s in "${SESSIONS[@]}"; do
  skip=0
  for pat in "${EXCLUDE[@]}"; do
    case "$s" in $pat) skip=1; break ;; esac
  done
  [ "$skip" -eq 1 ] && continue
  if [ -n "$SESSION_GLOB" ]; then
    case "$s" in $SESSION_GLOB) ;; *) continue ;; esac
  fi
  ELIGIBLE_LIST+=("$s")
done
[ "${#ELIGIBLE_LIST[@]}" -gt 0 ] || die "every session on $DAY was filtered out"

FILTERED=()
for s in "${ELIGIBLE_LIST[@]}"; do
  FILTERED+=("$s")
  [ "${#FILTERED[@]}" -ge "$MAX_SESSIONS" ] && break
done

ELIGIBLE="${#ELIGIBLE_LIST[@]}"
SELECTED="${#FILTERED[@]}"
log "day $DAY: $SELECTED of $ELIGIBLE eligible session(s)"

MANIFEST="$WORK/manifest.json"
SIDS=()
EMPTY_SIDS=()
TURN_FILES=()
for s in "${FILTERED[@]}"; do
  sid="$(python3 "$LIB/extract_session.py" --print-session-id "$s")" \
    || die "could not derive a session id for $s"
  [ -n "$sid" ] || die "empty session id for $s"
  # Two transcripts whose ids collide would share one turn file: the second extraction overwrites
  # the first, the manifest names the id twice, and one session's evidence is gone with nothing
  # saying so. Refusing is the only honest answer — a reflection that silently read 11 of 12
  # sessions is worse than one that did not run.
  for prev in ${SIDS[@]+"${SIDS[@]}"}; do
    [ "$prev" = "$sid" ] && die "session id '$sid' is used by two transcripts; one of them is $s"
  done
  SIDS+=("$sid")

  # A session that yields no turns still belongs in the manifest: "the generator saw nothing here"
  # and "the generator was never given this" are different facts, and only the manifest keeps them
  # apart once the turn files are the only evidence left. Exit 3 is that first fact and nothing
  # else — any other failure means the transcript was not read, which is not something to record as
  # an empty session and walk past.
  rc=0
  python3 "$LIB/extract_session.py" "$s" > "$WORK/turns/$sid.turns" 2>"$WORK/turns/$sid.err" || rc=$?
  case "$rc" in
    0) TURN_FILES+=("$WORK/turns/$sid.turns") ;;
    3) log "  $sid: read, no turns in it"
       EMPTY_SIDS+=("$sid")
       rm -f "$WORK/turns/$sid.turns" ;;
    *) sed 's/^/  /' "$WORK/turns/$sid.err" >&2 || true
       die "extracting $s failed (exit $rc) — the day would be missing that session's evidence" ;;
  esac
done

python3 - "$DAY" "$ELIGIBLE" "$MANIFEST" "${SIDS[@]}" <<'PY' || die "could not write the manifest"
import json, sys
day, eligible, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sids = sys.argv[4:]
assert len(sids) == len(set(sids)), "duplicate session id reached the manifest"
json.dump({"day": day, "eligible": eligible, "sessions": sids}, open(out, "w"))
PY
[ "${#TURN_FILES[@]}" -gt 0 ] || die "no session on $DAY produced any turns"

RULEBOOKS=()
for f in "${RULEBOOKS_DEFAULT[@]}"; do [ -f "$f" ] && RULEBOOKS+=("$f"); done
log "${#TURN_FILES[@]} transcript(s) extracted, ${#RULEBOOKS[@]} rulebook(s)"

if [ "$DRY" -eq 1 ]; then
  echo "would reflect on $DAY ($SELECTED of $ELIGIBLE eligible session(s)):"
  for i in "${!FILTERED[@]}"; do printf '  %s  %s\n' "${SIDS[$i]}" "${FILTERED[$i]}"; done
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

NEUTRAL="$WORK/neutral"; mkdir -p "$NEUTRAL"

# --- the hull (docs/design/reflection-confinement.md) -------------------------
# The two model calls are where the day's text meets something it can steer, so they run inside the
# bwrap hull the pi Fix stage already uses (pi_sandbox_argv, ADR 0032): no $HOME, no SSH key, no `gh`
# credential, no docker socket; writable only the neutral cwd and a throwaway agent dir holding links
# to pi's credential and catalogs. The payload file is the one thing each call is given to read — the
# transcripts themselves are not bound at all. The extraction, the citation check and the assembly
# before and after run no model: text in a transcript is data to them, not instructions.
#
# Fails CLOSED, as the design requires: no bwrap, no model call. NIGHTSHIFT_REFLECT_SANDBOX=none is
# the opt-out, and it says so on every run.
HULL=()
PI_EXTRA=()
if [ "${NIGHTSHIFT_REFLECT_SANDBOX:-bwrap}" = none ]; then
  log "hull DISABLED by NIGHTSHIFT_REFLECT_SANDBOX=none — the model calls run under the full account"
else
  # A child shell sources the Runner for its functions (the same entry point the tests use), so
  # none of its names or its `log` leak into this script. NIGHTSHIFT_PI_SANDBOX is pinned: a
  # night-loop opt-out in the environment must not silently unhull the reflection.
  #
  # The credential is narrowed to the providers these two calls use (design decision 3: one named
  # credential). pi_stage_home links the operator's whole auth.json and models.json, which on a
  # typical host carry every provider's token; the stage home gets filtered COPIES instead, so the
  # hull binds no credential file of the operator's at all. The two host knobs that widen the gate's
  # bind set (NIGHTSHIFT_TEST_SANDBOX_ROBIND, NIGHTSHIFT_TEST_PATH) are dropped: this call needs
  # neither, and either could hand it a path the design keeps out.
  env -u NIGHTSHIFT_TEST_SANDBOX_ROBIND -u NIGHTSHIFT_TEST_PATH \
  NIGHTSHIFT_SOURCED=1 NIGHTSHIFT_PI_SANDBOX=bwrap NIGHTSHIFT_PI_STAGE_HOME="$WORK/pi-home" \
    bash -c '
      source "$1/bin/nightshift.sh"
      load_rulebook >/dev/null 2>&1 || true
      home="$(pi_stage_home)" || exit 1
      real="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
      for f in auth.json models.json; do
        rm -f "$home/$f"
        [ -e "$real/$f" ] || continue
        ( umask 077
          jq --arg a "$4" --arg b "$5" "
            def keep: with_entries(select(.key == \$a or .key == \$b));
            if \"$f\" == \"auth.json\" then keep
            else (if (.providers | type) == \"object\" then .providers |= keep else . end) end
          " "$real/$f" > "$home/$f" ) || { echo "could not narrow $f to the reflection providers" >&2; exit 1; }
      done
      pi_sandbox_argv "$2" "$home" "$3" || exit 1
      [ "${#TEST_SANDBOX_ARGV[@]}" -gt 0 ] || exit 1
      printf "%s\0" "${TEST_SANDBOX_ARGV[@]}" > "$3/hull.argv"
      printf "%s" "${NIGHTSHIFT_PI_EXTENSIONS-${RB_PI_EXTENSIONS:-}}" > "$3/hull.exts"
    ' _ "$NIGHTSHIFT_HOME" "$NEUTRAL" "$WORK" "$GEN_PROVIDER" "$JUDGE_PROVIDER" 2>"$WORK/hull.err" \
    || die "no hull for the model calls, so none is made: $(tail -1 "$WORK/hull.err" 2>/dev/null) $(cat "$WORK/fix.err" 2>/dev/null)"
  mapfile -d '' -t HULL < "$WORK/hull.argv"
  [ "${HULL[0]:-}" = bwrap ] || die "the hull did not come back as a bwrap command line"
  # The bind set is assembled by shared code that serves other callers, so it is checked here against
  # what this call must never see, whatever widened it (an extension whose package root turns out to
  # be the operator's pi directory is the realistic case). A bind of any of these, or of a directory
  # containing one, refuses the run.
  PROTECTED=("$CLAUDE_PROJECTS" "$CODEX_SESSIONS" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
             "$HOME/.ssh" "$HOME/.config/gh" "$HOME/.codex" "$HOME/.claude")
  for ((i = 0; i < ${#HULL[@]}; i++)); do
    case "${HULL[$i]}" in --bind|--ro-bind|--ro-bind-try|--bind-try) ;; *) continue ;; esac
    src="$(realpath -m -- "${HULL[$((i + 1))]}")"
    for p in "${PROTECTED[@]}"; do
      p="$(realpath -m -- "$p")"
      if [ "$p" = "$src" ] || [ "${p#"$src"/}" != "$p" ]; then
        die "the hull would bind $src, which exposes $p — refusing the model calls"
      fi
    done
  done
  # The throwaway agent dir has no extensions/ to discover, so an extension the provider needs (on a
  # gateway host, the one that stamps the device header — without it every call is a 403 that reads
  # like a revoked credential) is loaded back by path, exactly as pi_run does for a night stage.
  PI_EXTRA=(--no-extensions)
  IFS=, read -r -a exts < "$WORK/hull.exts" || true
  for ext in ${exts[@]+"${exts[@]}"}; do
    ext="$(printf '%s' "$ext" | tr -d '[:space:]')"
    [ -n "$ext" ] || continue
    [ -e "$ext" ] || die "declared pi extension not found: $ext"
    PI_EXTRA+=(-e "$(realpath -e "$ext")")
  done
  log "hull: model calls confined (bwrap, ${#HULL[@]} arguments)"
fi

in_hull() { # payload cmd... -> runs cmd, inside the hull when there is one, with payload readable
  local payload="$1"; shift
  if [ "${#HULL[@]}" -gt 0 ]; then
    "${HULL[@]}" --ro-bind "$payload" "$payload" "$@"
  else
    "$@"
  fi
}

log "generate: $GEN_MODEL on $(wc -c < "$WORK/generate-payload.md") bytes"
# -nc -ns: the reflection judges the rulebooks, so it must not also be steered by them. `< /dev/null`
# because pi waits on an inherited stdin and never sends the request without it.
( cd "$NEUTRAL" && in_hull "$WORK/generate-payload.md" pi -p -a -nt -nc -ns --no-session \
    ${PI_EXTRA[@]+"${PI_EXTRA[@]}"} \
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
( cd "$NEUTRAL" && in_hull "$WORK/judge-payload.md" pi -p -a -nt -nc -ns --no-session \
    ${PI_EXTRA[@]+"${PI_EXTRA[@]}"} \
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
  printf -- '- %s of %s eligible session(s) read — %s yielded turns, %s were read and held none\n\n' \
    "$SELECTED" "$ELIGIBLE" "${#TURN_FILES[@]}" "${#EMPTY_SIDS[@]}"

  printf 'Every finding below cites a turn that was checked against the transcript. That makes the\n'
  printf 'quote real, not the conclusion right — read the judge on each one before changing a rule.\n\n'

  # Naming the sessions is what makes the day's coverage checkable. A bare count cannot be checked
  # against anything: a reader cannot tell which conversations the reflection saw, nor that the cap
  # left some out. Sessions are chosen by file modification time, so that is stated too — it is not
  # the same thing as the day a conversation happened.
  printf '## Sessions read\n\n'
  printf 'Selected by file modification time on %s — a transcript last written that day, which for a\n' "$DAY"
  printf 'session spanning midnight is not the same as a conversation held that day.\n\n'
  for i in "${!FILTERED[@]}"; do
    note=""
    for e in ${EMPTY_SIDS[@]+"${EMPTY_SIDS[@]}"}; do
      [ "$e" = "${SIDS[$i]}" ] && note=" — read, no turns in it"
    done
    printf -- '- `%s` (%s)%s\n' "${SIDS[$i]}" "$(basename "${FILTERED[$i]}")" "$note"
  done
  if [ "$SELECTED" -lt "$ELIGIBLE" ]; then
    printf -- '\n%s further session(s) were modified on %s and NOT read — the `--max-sessions` cap is %s.\n' \
      "$((ELIGIBLE - SELECTED))" "$DAY" "$MAX_SESSIONS"
  fi
  printf -- '\n---\n\n'
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
