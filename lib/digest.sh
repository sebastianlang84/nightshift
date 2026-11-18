#!/usr/bin/env bash
# Sourced by bin/nightshift.sh after its path globals are initialized.

# ------------------------------------------------------------------- digest ----

# An aborted night exits 3 and systemd marks the unit failed (ADR 0023) — but `systemctl status`
# reports only the LAST run, so the next night that completes wipes the outage from the one place
# an operator would notice it without reading anything. Observed 2026-08-08..11: four consecutive
# nights died on `Not logged in`, each exited 3, each digest said ABORTED — and the healthy night
# of 08-12 turned the unit green again, leaving four lost nights visible only in the journal.
# So the streak is carried forward INTO the digest: the first digest that completes after an
# outage still names how many nights were lost and when the fleet was last actually serviced.
#
# Counts only nights that HAVE a digest. A missing date is a night that never started (host off,
# timer disarmed, holiday) — indistinguishable here from a deliberate pause, and a false "nights
# lost" on every return from a break would train the reader to skip the line.
aborted_streak() { # -> "<count> <newest-aborted> <oldest-aborted> <last-completed|->"; nights before $NIGHT
  local f b count=0 newest="-" oldest="-" last_ok="-"
  while IFS= read -r f; do
    b="$(basename "$f" .md)"
    [[ "$b" < "$NIGHT" ]] || continue
    if grep -q '^- \*\*ABORTED:' "$f" 2>/dev/null; then
      count=$((count + 1)); oldest="$b"; [ "$newest" = - ] && newest="$b"
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
    [ -f "$LEDGER" ] && fcount=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n and .outcome=="finding")]|length' "$LEDGER" 2>/dev/null || echo 0)
    echo "- agent: \`$RUN_AGENT_ROUTE\` · shipped this run: ${made} · surfaced (findings): ${fcount} · open (awaiting your verdict): ${open}/${MAX_OPEN} (cap)"
    [ "$status" = ceiling ] && echo "- **Stopped: run ceiling reached** (\`max_branches_per_run: ${MAX_RUN_BRANCHES:-?}\`) — no further branch was opened this run; any remaining work waits for the next night."
    [ "$status" = branch_inventory_unavailable ] && echo "- **Stopped: origin branch inventory unavailable.** The open-branch cap could not be checked."
    [ "$status" = budget ] && echo "- **Stopped: time budget exhausted** (\`${MAX_RUN_SECONDS:-?}s\`) — the night ended on the spend cap, not for lack of work."
    # An aborted night must announce itself in the ONE artifact the operator actually reads in the
    # morning. Without this the digest of a credential outage is indistinguishable from a clean
    # fleet: same "shipped: 0", same empty tables, no reason given.
    # Name the adapter that DIED, not the night's: a routed Codex reviewer runs under a `local`
    # NIGHTSHIFT_AGENT that is gone by now. And give the remedy for the cause run_agent found — an
    # agent that could not reach its model may be logged in with its quota spent, so name both.
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
      # Stages that never finished, counted from the exit codes runs.jsonl has always recorded but
      # nothing ever read back. They cost real tokens and produce no verdict, so the morning must see
      # them next to the shipped count instead of having to notice their absence.
      local nfail
      nfail=$(jq -s --arg n "$NIGHT" '[.[]|select(.night==$n and .exit!=0)]|length' "$RUNSLOG" 2>/dev/null || echo 0)
      [ "${nfail:-0}" -gt 0 ] && echo "- **${nfail} stage-invocation(s) did not complete** — those lenses recorded no verdict and did not advance; grep the night log for \`FAILED\`."
    fi
    # Harvest scoreboard (all-time, from bin/harvest verdict events): the human
    # feedback loop made visible. A branch with no terminal verdict counts as open. The terminal
    # set comes from lib/ledger.jq (ADR 0025): resolved/wontfix are decided too, so they are
    # counted on their own instead of as open; the merge-rate stays merged/(merged+dropped).
    [ -f "$LEDGER" ] && jq -L "$NIGHTSHIFT_HOME/lib" -rs '
      include "ledger";
      (latest_branch_verdicts
        | map(select(.verdict as $v | terminal_verdicts | index($v)))
        | INDEX([.repo,.branch] | tojson)) as $v
      | [.[]|select(.outcome=="shipped" and .repo!=null and .branch!=null)|{repo:.repo,branch:.branch}] | unique as $ship
      | ($ship|map(select($v[([.repo,.branch] | tojson)].verdict=="merged"))|length) as $m
      | ($ship|map(select($v[([.repo,.branch] | tojson)].verdict=="dropped"))|length) as $d
      | ($ship|map(select($v[([.repo,.branch] | tojson)].verdict as $x
                          | $x=="resolved" or $x=="wontfix"))|length) as $s
      | ($ship|length) as $n
      | ($n-$m-$d-$s) as $open
      | if $n==0 then empty else
          "- harvest (all-time): shipped \($n) · merged \($m) · dropped \($d)"
          + (if $s>0 then " · resolved/wontfix \($s)" else "" end)
          + " · open \($open)"
          + (if ($m+$d)>0 then " · merge-rate \((100*$m/($m+$d))|floor)%" else "" end)
        end' "$LEDGER" 2>/dev/null || true
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
    # ADR 0015: rulebook-exclusion suggestions. 3 consecutive out-of-scope passes for a (repo,dim) —
    # a full review through the lens that keeps concluding it has no surface here — is strong evidence
    # recon's low verdict is right. Recon can't exclude (it only reprioritizes); the human owns the
    # rulebook, so surface a suggestion rather than acting. Driven by Explore's own conclusion, not by
    # recon repeating itself (which would be a circular doom loop).
    [ -f "$LEDGER" ] && jq -rs '
      [.[]|select(.outcome=="retracted")|.item] as $void
      | [.[] | select(.dimension!=null and ([.item]|inside($void)|not)
                      and (.outcome=="empty" or .outcome=="finding" or .outcome=="shipped" or .outcome=="abandoned"))]
      | group_by([.repo,.dimension])
      | map(.[-3:])
      | map(select(length==3 and all(.[]; .outcome=="empty" and .scope=="out_of_scope")))
      | if length==0 then empty else
          "\n## Suggested rulebook exclusions (ADR 0015)\n"
          + (map("- `\(.[0].repo)` × `\(.[0].dimension)` — 3 consecutive out-of-scope passes; consider dropping this lens for this repo in rulebook.yaml `dimensions:`") | join("\n"))
        end' "$LEDGER" 2>/dev/null || true
    # ADR 0039: "nothing found" is a result, not a failure. Show how often each lens reports it, so a
    # lens that never comes back empty is visible as one that may be manufacturing findings. A pass is
    # one explore item; its finding rows carry the item id plus an -fN suffix. `harvest.sh retract`
    # names only `empty` rows by their exact item, so the retraction filter never meets an -fN id.
    [ -f "$LEDGER" ] && jq -rs '
      [.[]|select(.outcome=="retracted")|.item] as $void
      | [.[] | select(.dimension!=null and .item!=null and ([.item]|inside($void)|not)
                      and (.outcome=="empty" or .outcome=="finding" or .outcome=="shipped" or .outcome=="abandoned"))
             | {d:.dimension, p:(.item|sub("-f[0-9]+$";"")), e:(.outcome=="empty")}]
      | group_by(.d)
      | map({d:.[0].d, n:(map(.p)|unique|length), e:(map(select(.e)|.p)|unique|length)})
      | if length==0 then empty else
          "\n## Nothing found, by dimension (all-time)\n"
          + (map("- \(.d): passes \(.n) · nothing found \(.e) (\((100*.e/.n)|floor)%)") | join("\n"))
        end' "$LEDGER" 2>/dev/null || true
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
    # The merge-rate scoreboard: the tuning signal — which lenses (ADR 0010 Phase 4) and which KINDS
    # of change humans actually merge. Join the latest verdict per repo+branch back to the shipped row and
    # slice it by dimension, verifiability, proof, and finding type. Empty slices are omitted.
    # One parameterised `rate` for all four slices, so the four cannot drift apart.
    [ -f "$LEDGER" ] && jq -L "$NIGHTSHIFT_HOME/lib" -rs '
      include "ledger";
      def rate($key; $name):
        (latest_branch_verdicts
          | map(select(.verdict as $v | merge_rate_verdicts | index($v))) | INDEX([.repo,.branch] | tojson)) as $v
        | [.[]|select(.outcome=="shipped" and .repo!=null and .branch!=null)]
        | group_by(.[$key] // "—")
        | map({g:(.[0][$key] // "—"), br:(map({repo:.repo,branch:.branch})|unique)})
        | map({g:.g, n:(.br|length),
               m:(.br|map(select($v[([.repo,.branch] | tojson)].verdict=="merged"))|length),
               d:(.br|map(select($v[([.repo,.branch] | tojson)].verdict=="dropped"))|length)})
        | if length==0 then empty else
            "\n## Merge-rate by \($name) (all-time)\n"
            + (map("- \(.g): shipped \(.n) · merged \(.m) · dropped \(.d)"
                   + (if (.m+.d)>0 then " · rate \((100*.m/(.m+.d))|floor)%" else "" end)) | join("\n"))
          end ;
      [ rate("dimension";"dimension"), rate("verifiability";"verifiability"),
        rate("proof";"proof"), rate("type";"finding type") ] | .[]
      ' "$LEDGER" 2>/dev/null || true
    echo
    # Backpressure ADDS a banner; it never REPLACES the body. Hitting the open-branch cap is the
    # normal end of a productive night (default cap 2, and the cap is only reached BY shipping), so
    # this is exactly when the human most needs the sections below: the banner says "go harvest
    # branches", and `## Shipped` is what names them. Suppressing the body here also broke ADR
    # 0004's digest contract (report shipped AND considered-but-abandoned) and contradicted this
    # same file's own `shipped this run: N` header line.
    if [ "$status" = "backpressure" ]; then
      echo "**FULL STOP — open-branch cap reached.** Harvest (merge/delete) some \`${BRANCH_PREFIX}\` branches to resume."
      echo
    fi
    echo "## Shipped"
    [ -f "$LEDGER" ] && jq -r --arg n "$NIGHT" \
      'select(.night==$n and .outcome=="shipped") | "- " + (if .proof=="unproven" then "**[unverified]** " else "" end) + .repo + " → `" + (.branch // "") + "` — " + (.summary // .fingerprint) + (if .pr_url then "  ([open PR](" + .pr_url + "))" else "" end)' \
      "$LEDGER" 2>/dev/null || true
    echo
    echo "## Findings (surfaced — reported, not touched)"
    [ -f "$LEDGER" ] && jq -r --arg n "$NIGHT" \
      'select(.night==$n and .outcome=="finding") | "- " + .repo + " — " + (.summary // .fingerprint) + "  (" + .fingerprint + ")"' \
      "$LEDGER" 2>/dev/null || true
    echo
    echo "## Considered but not shipped"
    [ -f "$LEDGER" ] && jq -r --arg n "$NIGHT" \
      'select(.night==$n and (.outcome=="abandoned" or .outcome=="push-failed" or .outcome=="commit-failed" or .outcome=="tests-failed" or .outcome=="gate-blocked" or .outcome=="worktree-tampered" or .outcome=="stage-failed")) | "- " + .repo + " — " + .outcome + ": " + (.summary // .fingerprint)' \
      "$LEDGER" 2>/dev/null || true
    echo
    # What the agents said about the HARNESS rather than about the code (collect_agent_note). Only
    # tonight's notes; the file keeps every one. Shown to the human and to nobody else — these are
    # never read back into a stage, for the reason collect_agent_note gives.
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
    [ -f "$LEDGER" ] && jq -L "$NIGHTSHIFT_HOME/lib" -rs '
      include "ledger";
      to_entries | map(.value + {__order:.key}) as $rows
      | ([$rows[]|select(.outcome=="verdict" and .repo!=null and .fingerprint!=null)]) as $verdicts
      | ($verdicts | map(select(.verdict=="wontfix") | [.repo,.fingerprint] | tojson) | unique) as $ignored
      | ($verdicts | latest_fingerprint_verdicts([.repo,.fingerprint])
         | map({key:([.repo,.fingerprint] | tojson), value:.}) | from_entries) as $v
      | [$rows[]|select(.outcome=="finding" and .repo!=null and .fingerprint!=null)]
      | group_by([.repo, .fingerprint]) | map(max_by(.__order))
      | map(. as $work | ([.repo,.fingerprint] | tojson) as $key
          | select(($ignored | index($key)) == null)
          | select(($v[$key].verdict // "") == "open" or (($v[$key].__order // -1) < $work.__order)))
      | map("- " + .repo + " — " + (.summary // .fingerprint) + "  (" + .fingerprint + ", since " + .night + ")")
      | join("\n")' "$LEDGER" 2>/dev/null || true
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
  trap '' TERM INT
  set +e  # Reporting failure must not replace the signal's nonzero exit status.
  local signal="$1" rc="$2" tmp
  log "night ABORTED: interrupted by SIG$signal — preserving recorded results"
  tmp=$(mktemp "$DIGEST_DIR/.interrupted.XXXXXX") || exit "$rc"
  {
    echo "# nightshift digest — $NIGHT"
    echo
    echo "- **ABORTED: interrupted by SIG$signal** — the run did not complete."
    echo "- agent: \`$RUN_AGENT_ROUTE\` · shipped this run: ${made:-0} · last observed open: ${open:-unknown}/${MAX_OPEN} (cap)"
    echo "- The in-flight operation has no final verdict. Only persisted results are listed; worktrees are retained for inspection."
    echo
    if [ -f "$LEDGER" ]; then
      timeout --kill-after=1s 5s jq -rs --arg n "$NIGHT" '
        [.[] | select(.night==$n)] as $rows
        | "## Shipped", ($rows[] | select(.outcome=="shipped")
            | "- " + .repo + " → `" + (.branch // "") + "` — " + (.summary // .fingerprint // "")),
          "", "## Findings (surfaced — reported, not touched)",
          ($rows[] | select(.outcome=="finding")
            | "- " + .repo + " — " + (.summary // .fingerprint // "")),
          "", "## Considered but not shipped",
          ($rows[] | select(.outcome=="abandoned" or .outcome=="push-failed" or .outcome=="commit-failed"
              or .outcome=="tests-failed" or .outcome=="gate-blocked" or .outcome=="worktree-tampered" or .outcome=="stage-failed")
            | "- " + .repo + " — " + .outcome + ": " + (.summary // .fingerprint // ""))
      ' "$LEDGER" || echo "Ledger summary unavailable or interrupted; inspect the persisted ledger and run artifacts."
    fi
  } > "$tmp"
  mv -f "$tmp" "$DIGEST_DIR/$NIGHT.md"
  exit "$rc"
}
