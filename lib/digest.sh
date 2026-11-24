#!/usr/bin/env bash
# Sourced by bin/nightshift.sh after its path globals are initialized.

# ------------------------------------------------------------------- digest ----

# Every ledger read below goes through lib/ledger.py: one command per section, printing what its
# jq program printed and failing where it failed, so each `|| true` / `|| echo` fallback still decides.
# The module is imported, not run as a file, so Python reuses its cached bytecode; -I keeps the
# caller's cwd and PYTHON* variables out of the import path. The runner reads through this too.
ledger() {
  python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger; sys.exit(ledger.cli(sys.argv[2:]))' \
    "$NIGHTSHIFT_HOME/lib" --ledger "$LEDGER" "$@"
}

# An aborted night fails the unit (ADR 0023), but `systemctl status` shows only the last run, so
# the streak of aborted nights is carried INTO the digest until a night completes and reports it.
# Only nights with a digest count: a missing date may be a deliberate pause, and a false "nights
# lost" after every break would train the reader to skip the line.
aborted_streak() { # -> "<count> <newest-aborted> <oldest-aborted> <last-completed|->"; nights before $NIGHT
  local f b count=0 newest="-" oldest="-" last_ok="-"
  while IFS= read -r f; do
    b="$(basename "$f" .md)"
    [[ "$b" < "$NIGHT" ]] || continue
    if grep -q '^- \*\*ABORTED:' "$f" 2>/dev/null; then
      count=$((count + 1)); oldest="$b"; [ "$newest" = - ] && newest="$b"
    elif grep -q '^- \*\*PAUSED:' "$f" 2>/dev/null && ! grep -q '^- agent:' "$f" 2>/dev/null; then
      # A night the launcher's quota check paused (ADR 0044) is a deliberate pause, not a lost
      # night and not a serviced one: skipped like a missing date.
      continue
    else
      last_ok="$b"; break
    fi
  done < <(find "$DIGEST_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | sort -r)
  printf '%s %s %s %s\n' "$count" "$newest" "$oldest" "$last_ok"
}

write_digest() { # made open status [advice]
  local made="$1" open="$2" status="$3" advice="${4:-}" f="$DIGEST_DIR/$NIGHT.md" runs dur
  {
    echo "# nightshift digest — $NIGHT"
    echo
    local fcount=0
    [ -f "$LEDGER" ] && fcount=$(ledger night-count "$NIGHT" finding 2>/dev/null || echo 0)
    echo "- agent: \`$NIGHTSHIFT_AGENT\` · shipped this run: ${made} · surfaced (findings): ${fcount} · open (awaiting a merge decision): ${open}/${MAX_OPEN} (cap)"
    # A repo whose suite is red on its unchanged base was skipped before Explore (base_precheck). It
    # stays blocked until someone repairs the suite, so it leads the digest.
    local b brepo bsha bstate blog
    for b in ${BLOCKED_BASES[@]+"${BLOCKED_BASES[@]}"}; do
      IFS=$'\t' read -r brepo bsha bstate blog <<< "$b"
      if [ "$bstate" = red ]; then
        echo "- **Blocked: $(basename "$brepo")** — its suite is red on the unchanged base \`${bsha:0:12}\`, so nightshift skipped it tonight; repair the suite (\`$blog\`)."
      else
        echo "- **Blocked: $(basename "$brepo")** — the ship gate cannot run on its base \`${bsha:0:12}\`, so nightshift skipped it tonight (\`$blog\`)."
      fi
    done
    [ "$status" = ceiling ] && echo "- **Stopped: run ceiling reached** (\`max_branches_per_run: ${MAX_RUN_BRANCHES:-?}\`) — no further branch was opened this run; any remaining work waits for the next night."
    [ "$status" = branch_inventory_unavailable ] && echo "- **Stopped: origin branch inventory unavailable.** The open-branch cap could not be checked."
    [ "$status" = budget ] && echo "- **Stopped: time budget exhausted** (\`${MAX_RUN_SECONDS:-?}s\`) — the night ended on the spend cap, not for lack of work."
    # An aborted night must say so, or its digest reads like a clean fleet. Name the agent that died
    # (run_agent records it) and the remedy; one that could not reach its model may be logged in
    # with its quota spent, so name both.
    if [ "$status" = agent_unavailable ]; then
      local dead="${AGENT_FATAL_AGENT:-$NIGHTSHIFT_AGENT}" remedy
      case "$AGENT_FATAL" in
        *" could not reach its model "*)
          remedy="check that the \`$dead\` CLI is logged in and has quota left — the stage's raw output in the night log says which — and run the night again" ;;
        *) remedy="re-authenticate the \`$dead\` CLI and run the night again" ;;
      esac
      echo "- **ABORTED: the \`$dead\` agent could not run** — ${AGENT_FATAL:-no usable credentials}. Nothing below reflects the state of the code: $remedy. No recon caches or \`empty\` rows were written."
    fi
    # Outage continuity — see aborted_streak(). Printed on BOTH paths: while the outage lasts it
    # counts up, and the night that finally completes reports the gap once before it disappears.
    local n_ab newest oldest last_ok span
    read -r n_ab newest oldest last_ok <<< "$(aborted_streak)"
    if [ "${n_ab:-0}" -gt 0 ]; then
      [ "$oldest" = "$newest" ] && span="$newest" || span="$oldest … $newest"
      [ "$last_ok" = - ] && last_ok="none on record"
      if [ "$status" = agent_unavailable ]; then
        echo "- **$((n_ab + 1)) nights in a row have not completed** ($oldest onward) — last completed run: ${last_ok}."
      else
        echo "- **$n_ab earlier night(s) did not complete** ($span) — tonight is the first to finish since; the fleet was last serviced ${last_ok}."
      fi
    fi
    if [ -f "$RUNSLOG" ]; then
      runs=$(grep -c "\"night\":\"$NIGHT\"" "$RUNSLOG" || true)
      dur=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n)|.duration_s]|add // 0' "$RUNSLOG")
      echo "- runs tonight: ${runs} stage-invocations, ${dur}s total"
      # Stages that never finished cost tokens and record no verdict, so they are counted here.
      # A `repair-<stage>` row is the one JSON correction call for an unparsed answer (ADR 0046). A
      # corrected answer did record its verdict, so its stage's failed row is not counted as lost.
      local nfail nrep nrec
      nfail=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n and .exit!=0)]|length' "$RUNSLOG" 2>/dev/null || echo 0)
      read -r nrep nrec <<< "$(jq -rs --arg n "$NIGHT" \
        '[.[]|select(.night==$n and ((.stage // "") | tostring | startswith("repair-")))]
         | "\(length) \(map(select(.exit==0))|length)"' "$RUNSLOG" 2>/dev/null || echo "0 0")"
      nrep=${nrep:-0} nrec=${nrec:-0}
      [ "$nrep" -gt 0 ] && echo "- JSON correction calls: ${nrec} of ${nrep} unparsed answers became valid JSON"
      nfail=$(( ${nfail:-0} - nrec ))
      [ "${nfail:-0}" -gt 0 ] && echo "- **${nfail} stage-invocation(s) did not complete** — those lenses recorded no verdict and did not advance; grep the night log for \`FAILED\`."
    fi
    # Whether merged fixes held 30 days later (ADR 0043), from the snapshot harvest refreshed at the
    # start of this night. A merge rate counts what the reviewers accepted; this counts what stayed.
    [ -f "$SURVIVAL_SNAPSHOT" ] && jq -r '
      [.repos | to_entries[] | select(.value.measured > 0)
        | "\(.key) \(.value.held)/\(.value.measured)"
          + (if .value.reverted > 0 then " (\(.value.reverted) reverted)" else "" end)] as $r
      | ([.repos[] | .removed] | add // 0) as $gone
      | select($r | length > 0)
      | "- fixes that held \(.window_days) days after merge: \($r | join(" · "))"
          + (if $gone > 0 then " — \($gone) whose code was later removed are not counted" else "" end)
    ' "$SURVIVAL_SNAPSHOT" 2>/dev/null || true
    # Harvest scoreboard (all-time verdicts). The terminal set comes from lib/ledger.py (ADR 0025):
    # resolved/wontfix count as decided, not open; the merge-rate stays merged/(merged+dropped).
    [ -f "$LEDGER" ] && ledger harvest-scoreboard 2>/dev/null || true
    # Coverage matrix (ADR 0010): days since nightshift last serviced each (repo × dimension).
    # Makes the rotation observable — a large number or — flags a long-overdue lens.
    if [ "${#DIMENSIONS[@]}" -gt 0 ] && [ "${#REPO_PATHS[@]}" -gt 0 ]; then
      local nowe rp d e; nowe=$(date +%s)
      echo; echo "## Coverage — days since last serviced (— = never)"; echo
      { printf '| repo |'; for d in "${DIMENSIONS[@]}"; do printf ' %s |' "$d"; done; printf '\n'
        printf '|---|'; for d in "${DIMENSIONS[@]}"; do printf '%s' '---|'; done; printf '\n'
        for rp in "${REPO_PATHS[@]}"; do
          printf '| %s |' "$(basename "$rp")"
          for d in "${DIMENSIONS[@]}"; do
            e=$(last_dim_epoch "$rp" "$d")
            if [ "$e" -gt 0 ]; then printf ' %s |' "$(( (nowe - e) / 86400 ))"; else printf ' — |'; fi
          done
          printf '\n'
        done
      }
    fi
    # ADR 0015: rulebook-exclusion suggestions after 3 consecutive out-of-scope Explore passes for a
    # (repo, dim). Only suggested: the human owns the rulebook. Driven by Explore's conclusion, never
    # by recon repeating itself.
    [ -f "$LEDGER" ] && ledger exclusion-suggestions 2>/dev/null || true
    # ADR 0039: "nothing found" is a result, not a failure. Show how often each lens reports it, so a
    # lens that never comes back empty is visible as one that may be manufacturing findings. A pass is
    # one explore item; its finding rows carry the item id plus an -fN suffix. `harvest.sh retract`
    # names only `empty` rows by their exact item, so the retraction filter never meets an -fN id.
    [ -f "$LEDGER" ] && ledger empty-rate 2>/dev/null || true
    # ADR 0015: rulebook/recon contradictions. A lens the human narrowed OUT of a repo's configured
    # set that recon still sees signal for — a hand-exclusion never re-evaluates on its own, so flag it.
    if [ "${#REPO_PATHS[@]}" -gt 0 ]; then
      local contra="" rp cfg d y cache
      for rp in "${REPO_PATHS[@]}"; do
        cache="$(recon_cache_path "$rp")"; [ -f "$cache" ] || continue
        cfg=" $(repo_dimensions "$rp") "
        for d in "${DIMENSIONS[@]}"; do
          case "$cfg" in *" $d "*) continue ;; esac
          y=$(jq -r --arg d "$d" '.dimensions[$d].yield // "low"' "$cache" 2>/dev/null || echo low)
          case "$y" in high|normal) contra+="- \`$(basename "$rp")\` excludes \`$d\`, but recon rates it $y-yield here"$'\n' ;; esac
        done
      done
      [ -n "$contra" ] && printf '\n## Rulebook/recon contradictions (ADR 0015)\n%s' "$contra"
    fi
    # Merge rate by dimension, verifiability, proof and finding type (ADR 0010): which lenses and
    # kinds of change humans merge. Empty slices are omitted.
    [ -f "$LEDGER" ] && ledger merge-rate 2>/dev/null || true
    echo
    # Backpressure ADDS a banner and never replaces the body: at the cap the human needs `## Shipped`
    # to know which branches to harvest (ADR 0004's digest contract).
    if [ "$status" = "backpressure" ]; then
      echo "**FULL STOP — open-branch cap reached.** Harvest (merge/delete) some \`${BRANCH_PREFIX}\` branches to resume."
      echo
    fi
    echo "## Shipped"
    [ -f "$LEDGER" ] && ledger night-section shipped "$NIGHT" 2>/dev/null || true
    echo
    echo "## Findings (surfaced — reported, not touched)"
    [ -f "$LEDGER" ] && ledger night-section findings "$NIGHT" 2>/dev/null || true
    echo
    echo "## Considered but not shipped"
    [ -f "$LEDGER" ] && ledger night-section considered "$NIGHT" 2>/dev/null || true
    echo
    # Tonight's agent notes about the HARNESS (collect_agent_note). Shown to the human only, never
    # read back into a stage.

    if [ -f "$AGENT_NOTE_FILE" ] && grep -q "^## $NIGHT · " "$AGENT_NOTE_FILE" 2>/dev/null; then
      echo "## Notes from the agents (about the harness, not the code)"
      # From the first heading of tonight to the last line before the next night's heading.
      awk -v n="## $NIGHT · " '
        index($0, n) == 1 { on = 1 }
        on && /^## / && index($0, n) != 1 { on = 0 }
        on && !/^<!-- note:/ { print }
      ' "$AGENT_NOTE_FILE"
      echo
      echo "_Full history: \`$AGENT_NOTE_FILE\`._"
      echo
    fi
    # Carry-forward (ADR 0014): every surfaced finding whose latest lifecycle event leaves it open.
    # A new finding after resolved/dropped/merged is a reopened identity; wontfix remains permanent.
    echo "## Open findings (all nights — awaiting a human)"
    [ -f "$LEDGER" ] && ledger open-findings-digest 2>/dev/null || true
    [ -n "$advice" ] && printf '%s\n' "$advice"
  } > "$f"
  log "digest -> $f"
}

# systemd terminates the whole control group at its hard deadline. Do not start advice,
# fetches, worktree cleanup, or the normal coverage calculations while shutting down. Preserve
# the recorded results in a short atomic report; the ledger read has a five-second ceiling.
# An in-flight stage may have no runs.jsonl row yet, so explicitly call its outcome unknown.
interrupted_digest() { # signal exit-code; main's counters are dynamically scoped in Bash
  [ "$BASHPID" = "${runner_pid:-}" ] || return 0
  trap '' TERM INT PIPE
  set +e  # Reporting failure must not replace the signal's nonzero exit status.
  local signal="$1" rc="$2" tmp
  tmp=$(mktemp "$DIGEST_DIR/.interrupted.XXXXXX") || exit "$rc"
  {
    echo "# nightshift digest — $NIGHT"
    echo
    echo "- **ABORTED: interrupted by SIG$signal** — the run did not complete."
    echo "- agent: \`$NIGHTSHIFT_AGENT\` · shipped this run: ${made:-0} · last observed open: ${open:-unknown}/${MAX_OPEN} (cap)"
    echo "- The in-flight operation has no final verdict. Only persisted results are listed; worktrees are retained for inspection."
    echo
    if [ -f "$LEDGER" ]; then
      timeout --kill-after=1s 5s python3 "$NIGHTSHIFT_HOME/lib/ledger.py" --ledger "$LEDGER" \
        interrupted-summary "$NIGHT" || echo "Ledger summary unavailable or interrupted; inspect the persisted ledger and run artifacts."
    fi
  } > "$tmp"
  mv -f "$tmp" "$DIGEST_DIR/$NIGHT.md"
  log "night ABORTED: interrupted by SIG$signal — see $DIGEST_DIR/$NIGHT.md" || true
  exit "$rc"
}
