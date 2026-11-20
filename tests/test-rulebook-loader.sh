#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# lib/rulebook.sh carries every rulebook value from the parser's JSON into Bash by name. A ship-gate
# command must reach the gate byte for byte, whatever shell characters it holds, and a rulebook that
# does not parse must still stop each of the three tools that read it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-rulebook-loader: $*" >&2; exit 1; }
export NIGHTSHIFT_STATE_DIR="$TMP/state" NIGHTSHIFT_RUNS_DIR="$TMP/runs"
export NIGHTSHIFT_DIGEST_DIR="$TMP/digests" NIGHTSHIFT_WORKTREES="$TMP/worktrees"
mkdir -p "$TMP/state" "$TMP/runs" "$TMP/digests" "$TMP/worktrees"

# Double quote, single quote, $HOME, a backslash and two spaces, as an unquoted YAML scalar (the
# subset decodes no escapes, so a quoted one could not hold the backslash).
cat > "$TMP/rulebook.yaml" <<'EOF'
branch_prefix: nightshift/
repos:
  - path: /srv/loader-target
    mode: branch-fix
    base: main
    test_cmd: printf '%s|' "it's" '$HOME' $HOME a\b "two  spaces"
EOF
expected="$(sed -n 's/^    test_cmd: //p' "$TMP/rulebook.yaml")"
[ -n "$expected" ] || fail "fixture has no test_cmd"

# What the Runner hands its gate (run_test_gate runs `bash -c "$(repo_test_cmd "$repo")"`).
actual="$(RULEBOOK="$TMP/rulebook.yaml" NIGHTSHIFT_HOME="$ROOT" NIGHTSHIFT_SOURCED=1 bash -c '
  source "$1"; load_rulebook; repo_test_cmd "$(repo_id /srv/loader-target)"' _ "$ROOT/bin/nightshift.sh")"
[ "$actual" = "$expected" ] || fail "test_cmd changed on its way to the gate: [$actual] != [$expected]"

# The loader on its own keeps every value, including the empty ones.
NIGHTSHIFT_HOME="$ROOT" bash -c '
  set -euo pipefail
  source "$1/lib/rulebook.sh"; rulebook_load "$2"
  [ "$RB_REPOS" = 1 ] && [ "${RB[repos.0.test_cmd]}" = "$3" ] && [ "${RB[repos.0.findings]+set}" = set ] \
    && [ -z "${RB[repos.0.findings]}" ] && [ "${RB[branch_prefix]}" = nightshift/ ]' \
  _ "$ROOT" "$TMP/rulebook.yaml" "$expected" || fail "rulebook_load lost or changed a value"

# A parse error stops each reader with its own message and a non-zero status.
cat > "$TMP/bad.yaml" <<'EOF'
repos:
  - path: /srv/loader-target
    mode: brnach-fix
EOF
expect_abort() { # label message command...
  local label="$1" message="$2"; shift 2
  if RULEBOOK="$TMP/bad.yaml" NIGHTSHIFT_AGENT=mock "$@" >"$TMP/out" 2>"$TMP/err"; then
    fail "$label ran on an unparseable rulebook"
  fi
  grep -Fq "$message" "$TMP/err" || { cat "$TMP/err" >&2; fail "$label aborted without '$message'"; }
  grep -Fq "unknown mode 'brnach-fix'" "$TMP/err" || { cat "$TMP/err" >&2; fail "$label hid the parser's reason"; }
}
expect_abort runner "rulebook parse failed ($TMP/bad.yaml) — aborting run" "$ROOT/bin/nightshift.sh"
expect_abort harvest "rulebook parse failed ($TMP/bad.yaml) — aborting harvest" "$ROOT/bin/harvest.sh"
expect_abort review "rulebook parse failed ($TMP/bad.yaml) — aborting review" "$ROOT/bin/review-branch.sh"

# A tab in a ship-gate command is legal shell and reaches the gate unchanged; so do leading and
# trailing spaces inside a quoted value.
printf 'repos:\n  - path: /srv/loader-tab\n    mode: branch-fix\n    test_cmd: printf "%%s\\n" a\tb\n  - path: /srv/loader-quoted\n    mode: branch-fix\n    test_cmd: "  make  test  "\nagent:\n  claude_model: "  spaced model  "\n' \
  > "$TMP/tab.yaml"
grep -q $'a\tb' "$TMP/tab.yaml" || fail "fixture lost its tab"
gate_cmd() { # rulebook repo -> what repo_test_cmd hands the gate; the trailing . keeps $() from trimming
  RULEBOOK="$1" NIGHTSHIFT_HOME="$ROOT" NIGHTSHIFT_SOURCED=1 bash -c '
    source "$1"; load_rulebook; repo_test_cmd "$(repo_id "$2")"; printf .' _ "$ROOT/bin/nightshift.sh" "$2"
}
want="$(sed -n 's/^    test_cmd: //p' "$TMP/tab.yaml" | head -1)"
got="$(gate_cmd "$TMP/tab.yaml" /srv/loader-tab)"
[ "${got%.}" = "$want"$'\n' ] || fail "a tab in test_cmd changed on its way to the gate: [${got%.}]"
got="$(gate_cmd "$TMP/tab.yaml" /srv/loader-quoted)"
[ "${got%.}" = $'  make  test  \n' ] || fail "spaces inside a quoted test_cmd were lost: [${got%.}]"
model="$(RULEBOOK="$TMP/tab.yaml" NIGHTSHIFT_HOME="$ROOT" NIGHTSHIFT_SOURCED=1 bash -c '
  source "$1"; load_rulebook; printf "[%s]" "$RB_CLAUDE_MODEL"' _ "$ROOT/bin/nightshift.sh")"
[ "$model" = "[  spaced model  ]" ] || fail "spaces inside a quoted model were lost: $model"

# The loader refuses a pair stream that stops early, and one from a parser that then fails.
stub_home() { # name python-body
  mkdir -p "$TMP/$1/lib"
  printf 'import sys\n%s\n' "$2" > "$TMP/$1/lib/parse_rulebook.py"
}
stub_home complete 'sys.stdout.buffer.write(b"1\0branch_prefix\0nightshift/\0")'
stub_home truncated 'sys.stdout.buffer.write(b"2\0branch_prefix\0nightshift/\0")'
stub_home failing 'sys.stdout.buffer.write(b"1\0branch_prefix\0nightshift/\0"); sys.exit(3)'
load_with() { # stub home -> the loaded branch_prefix, or a non-zero status
  NIGHTSHIFT_HOME="$TMP/$1" bash -c '
    set -euo pipefail; source "$1"; rulebook_load /dev/null; printf "%s" "${RB[branch_prefix]}"' \
    _ "$ROOT/lib/rulebook.sh" 2>/dev/null
}
[ "$(load_with complete)" = nightshift/ ] || fail "the stub stream itself does not load"
! load_with truncated >/dev/null || fail "a truncated pair stream was accepted"
! load_with failing >/dev/null || fail "a stream from a failing parser was accepted"

# The cron launcher falls back to claude when the rulebook does not parse. Honouring
# `agent.primary: mock`, and the fallback for a rulebook without the key, are in
# test-rulebook-validation.sh.
cron_env="$(sed -n '1,/^# Make the tools nightshift invokes findable/p' "$ROOT/bin/nightshift-cron.sh")"
cron_env+=$'\nprintf "%s" "${NIGHTSHIFT_AGENT:-<unset>}"'
[ "$(env -u NIGHTSHIFT_AGENT NIGHTSHIFT_HOME="$ROOT" RULEBOOK="$TMP/bad.yaml" bash -c "$cron_env" 2>/dev/null)" = claude ] \
  || fail "the cron launcher did not fall back to claude on an unparseable rulebook"

# `schedule.sh dry-run` refuses a live rulebook that does not parse. It reads the rulebook next to
# itself, so it runs from a copy; systemctl is stubbed because `--user` ignores XDG_CONFIG_HOME.
H="$TMP/schedhome"
mkdir -p "$H/bin" "$H/lib" "$H/prompts" "$TMP/stubs" "$TMP/schedtmp"
cp "$ROOT/bin/schedule.sh" "$H/bin/"
printf '#!/usr/bin/env bash\nmkdir -p "$1"\n' > "$H/bin/setup-sandbox.sh"
cp "$ROOT/lib/rulebook.sh" "$ROOT/lib/parse_rulebook.py" "$H/lib/"
cp -r "$ROOT/prompts/dimensions" "$H/prompts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/stubs/systemctl"
chmod +x "$TMP/stubs/systemctl"
dry_run() { # rulebook
  cp "$1" "$H/rulebook.yaml"
  env PATH="$TMP/stubs:$PATH" HOME="$TMP/schedtmp" XDG_CONFIG_HOME="$TMP/schedtmp/.config" \
    TMPDIR="$TMP/schedtmp" bash "$H/bin/schedule.sh" dry-run >"$TMP/sched.out" 2>&1
}
! dry_run "$TMP/bad.yaml" || fail "schedule.sh dry-run accepted an unparseable live rulebook"
grep -q "the live rulebook.yaml does not parse" "$TMP/sched.out" \
  || { cat "$TMP/sched.out" >&2; fail "schedule.sh refused without its message"; }
dry_run "$TMP/rulebook.yaml" || true   # the copy has no launcher; only the check's verdict matters
grep -q "live rulebook.yaml parses" "$TMP/sched.out" \
  || { cat "$TMP/sched.out" >&2; fail "schedule.sh refused a valid live rulebook"; }

echo "test-rulebook-loader: ok"
