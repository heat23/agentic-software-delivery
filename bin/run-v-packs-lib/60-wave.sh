# run-v-packs-lib/60-wave.sh — wave orchestration: the heartbeat line, one parallel pass over a wave
# (run_pass_wave), the wave drain loop (drain_wave), the per-wave landing barrier (land_wave), and the
# out-of-order single-wave advisory (warn_skipped_lower_waves).
#
# SOURCED (never executed) by ~/.local/bin/run-v-packs via its lib seam. Do NOT add `set` flags or a
# shebang: this file inherits the runner's `set -uo pipefail` and its bash (4+ after the runner's 3.2
# re-exec, or stock 3.2 when a test sources it) — it must parse and run under BOTH, same as the runner.
# The three top-level assignments below (PASS_RL / HAD_TIMEOUT / RUN_SEEN_HASHES) are this group's OWN
# run-state, moved with it; they run at source time exactly as they did inline (before main()), and
# plain assignment (not :=) is deliberate — each run starts these at their zero state.
# Calls lib siblings late-bound at call time — run_pack/_adopt_orphans (50), verdict/_timeout_kind/
# capture_telemetry (30), _archive_finished_pack/reset_epoch/_land_and_reconcile/_unlanded_branches/
# reconcile_* (40), has_pending_landing (20), pack_name/count_*/list_*/waves_present/human_time AND the
# nominally-internal _wave_norm (10 — warn_skipped_lower_waves normalizes wave tokens with it directly;
# QA-001 pins only fns main() reaches by name, but the structure test's seam-parity pins _wave_norm
# itself, so a silent drop still bites there) — and reads runner globals (JOBS, ONCE, ARCHIVE,
# PACK_ABS, LOG_DIR, DONE_DIR, NEEDS_DIR, REPO, V_*).
# land_wave also assigns main()'s dynamically-scoped locals _drain_out/_drain_last (set by
# _land_and_reconcile in its call chain). Calls NO function that stays inline in the runner.
_hb(){ echo "  … $(date '+%H:%M:%S') working — $(jobs -rp | wc -l | tr -d ' ') session(s) active · $(count_done) done · $(count_left) left"; }

# ── run one parallel pass over a single wave; archive clean finishers; set PASS_RL ─
PASS_RL=0
HAD_TIMEOUT=0   # T-ACT: set when any pack this run was watchdog-killed — drives the pre-drain settle window
RUN_SEEN_HASHES=""  # FND-DUP: pack-body sha1s dispatched THIS run (cross-wave — an identical prompt is a dup wherever it sits)
run_pass_wave(){ # $1=wave number — launch ≤JOBS in parallel; ARCHIVE EACH PACK THE MOMENT IT FINISHES (incremental)
  PASS_RL=0; local w="$1" packs=() f name; while IFS= read -r f; do [ -n "$f" ] && packs+=("$f"); done < <(list_packs_in_wave "$w")
  local total="${#packs[@]}"; [ "$total" -gt 0 ] || return 0
  echo "── wave $w: running ${total} pack(s), ≤${JOBS} at a time (each archived the moment it finishes) ──"
  local i=0 ndisp=0 notask=0 progress=0 j pids=() _pv _pv2 _zsid _zend   # pids[] parallels packs[]; plain array assign for portability
  local seen_slugs="" _dup_slug _dup_hash   # FND-DUP: wave-scoped task-name set (same name in a LATER wave may be a different task)
  while [ "$ndisp" -lt "$total" ]; do
    # 1) launch while a slot is free and packs remain. Truncate the log SYNCHRONOUSLY before the fork so nothing
    #    downstream can read a prior pass's stale result before run_pack overwrites it.
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -lt "$JOBS" ] && [ "$i" -lt "$total" ]; do
      f="${packs[$i]}"; name="$(pack_name "$f")"
      # FND-DUP (forensic 2026-07-03): DUPLICATE-DISPATCH guard. A Jul-3 production fleet ran ONE
      # third-party-adapter task in ≥6 concurrent sessions (redundant gauntlets, 0 landings, a
      # 6-way manual reconciliation) because nothing de-duplicated dispatch. Two keys: (a) wave-stripped
      # pack basename within THIS wave (two w<N>-<same-task> files), (b) body sha1 across the WHOLE run
      # (identical prompt under any filename). Later copies are PARKED to .needs-review/ — never deleted;
      # an intentional re-run is one `mv` back after the first copy lands. Per-run memory only, so a
      # re-run of an archived pack in a FUTURE invocation is not treated as a duplicate.
      _dup_slug="${name##*/}"; _dup_slug="$(printf '%s' "$_dup_slug" | sed -E 's/^w(ave)?-?[0-9]+[-_]//')"
      _dup_hash="$(shasum "$f" 2>/dev/null | awk '{print $1}')"
      # F2-1 (adversarial review 2026-07-03, empirically repro'd): every seen-key carries the OWNING
      # pack name — a KEPT pack (partial/no-task/ratelimit/error verdicts are retried by design) is
      # re-presented by the next drain_wave pass with its own unchanged slug+hash, and must NOT be
      # parked as its own duplicate (that silently broke resume: a rate-limited pack was abandoned
      # instead of resumed). A duplicate is the same key under a DIFFERENT pack file only.
      # F2-2: an empty stripped slug (e.g. a mis-named 'w3-.txt') never matches (awk s!="" via -v s).
      _dup_hit=""
      [ -n "$_dup_slug" ] && _dup_hit="$(printf '%s\n' "$seen_slugs" | awk -F'\t' -v s="$_dup_slug" -v n="$name" '$1==s && $2!=n{print "y"; exit}')"
      if [ -z "$_dup_hit" ] && [ -n "$_dup_hash" ]; then
        _dup_hit="$(printf '%s\n' "$RUN_SEEN_HASHES" | awk -F'\t' -v h="$_dup_hash" -v n="$name" '$1==h && $2!=n{print "y"; exit}')"
      fi
      if [ -n "$_dup_hit" ]; then
        echo "  ⏭ DUPLICATE-DISPATCH: $name repeats a pack already dispatched this run (same task name in this wave, or identical body, under a different pack file) — parked → .needs-review/, NOT launched; the first copy owns the task. Intentional re-run? mv it back after the first copy lands."
        [ "$ARCHIVE" = 1 ] && mv -f "$f" "$NEEDS_DIR/" 2>/dev/null
        pids[$i]=""; i=$((i+1)); ndisp=$((ndisp+1)); progress=1
        continue
      fi
      [ -n "$_dup_slug" ] && seen_slugs="${seen_slugs}
${_dup_slug}	${name}"
      [ -n "$_dup_hash" ] && RUN_SEEN_HASHES="${RUN_SEEN_HASHES}
${_dup_hash}	${name}"
      : > "$LOG_DIR/$name.log" 2>/dev/null || true; rm -f "$LOG_DIR/$name.log.timedout" 2>/dev/null || true
      echo "▶ $(date '+%H:%M:%S') launch $name"
      run_pack "$f" & pids[$i]="$!"; i=$((i+1))
    done
    # 2) reap: dispose every launched pack that has FINISHED. Finished = its run_pack job is gone, OR (a defensive
    #    cross-check for bash builds whose SIGCHLD zombie-reaping lags) the log already carries a terminal state —
    #    a real result event or our timeout sidecar — which proves claude is done even if an unreaped zombie still
    #    reports "alive" to kill -0. Keying off job exit (not only a log grep) also disposes a crash that wrote no
    #    result (verdict → incomplete → kept), never an infinite wait. Archiving HERE — not at pass-end — banks a
    #    fast pack immediately, so it is never held hostage by a slow/wedged sibling, and .done/ grows live.
    for (( j=0; j<i; j++ )); do
      [ -n "${pids[$j]:-}" ] || continue                # not launched, or already disposed
      f="${packs[$j]}"; name="$(pack_name "$f")"
      if kill -0 "${pids[$j]}" 2>/dev/null; then        # pid still reported alive — running, OR an unreaped zombie
        { [ -f "$LOG_DIR/$name.log.timedout" ] || { _rl="$(grep -E '"type":[[:space:]]*"result"' "$LOG_DIR/$name.log" 2>/dev/null | tail -1)"; [ -n "$_rl" ] && printf '%s' "$_rl" | jq -e '.type=="result"' >/dev/null 2>&1; }; } || continue   # no terminal state → truly still running
      fi
      wait "${pids[$j]}" 2>/dev/null || true            # reap the finished subshell (returns at once — it is done)
      _pv="$(verdict "$name")"
      # Z-SETTLE (2026-07-12 forensic): a /v session that backgrounds its gauntlet exits while its
      # detached gate subagents are still flushing — the fork's OP_TELEMETRY ledger landed 2 SECONDS after
      # the reap here classified the pack `inconclusive` (0 parent turns, no ledger yet) and parked it as
      # fork-work needing a human, when with the ledger the SAME log reads `partial` → auto-retried with the
      # RETRY-CONTINUITY worktree adoption. So: before disposing an `inconclusive` whose result shows real
      # fork output (≥V_FORK_WORK_MIN_OUT tokens), wait briefly for that sid's ledger to appear, then
      # re-classify. Gated on the repo actually using the .v/artifacts convention (test fixtures don't) and
      # skippable via V_PACK_ZERO_TURN_SETTLE=0. Live path only — orphan adoption re-verdicts long after any
      # flush window, so it needs no settle. KNOWN TRADEOFF (CODEX-003, 2026-07-12 review): this poll blocks
      # the shared reap loop, so under -j>1 a settle can delay reaping/launching siblings by up to the settle
      # window. Accepted: the trigger is rare (real 0-turn strand with ≥1K output tokens), bounded (180s vs a
      # ~1h pack re-run), and the fairness cost only defers dispatch, never loses work.
      if [ "$_pv" = inconclusive ] && [ -d "$REPO/.v/artifacts" ] \
         && [ "${V_PACK_ZERO_TURN_SETTLE:-180}" -gt 0 ] 2>/dev/null \
         && [ "$(_result_out_tokens "$name")" -ge "${V_FORK_WORK_MIN_OUT:-1000}" ] 2>/dev/null; then
        _zsid="$(sid_of "$name")"
        if [ -n "$_zsid" ] && [ ! -f "$REPO/.v/artifacts/OP_TELEMETRY_${_zsid}.json" ]; then
          echo "  ⏳ $name: clean exit at 0 parent turns but $(_result_out_tokens "$name") output tokens — settling ≤${V_PACK_ZERO_TURN_SETTLE:-180}s for the fork's OP_TELEMETRY ledger to flush before classifying"
          _zend=$(( $(date +%s) + ${V_PACK_ZERO_TURN_SETTLE:-180} ))
          while [ "$(date +%s)" -lt "$_zend" ] && [ ! -f "$REPO/.v/artifacts/OP_TELEMETRY_${_zsid}.json" ]; do sleep "${_ZS_POLL:-5}"; done
          _pv2="$(verdict "$name")"
          if [ "$_pv2" != "$_pv" ]; then
            echo "  ↻ $name: fork ledger flushed during the settle — reclassified 'inconclusive' → '$_pv2' (the 0-turn park would have been a race)"
            _pv="$_pv2"
          fi
        fi
      fi
      case "$_pv" in
        # done/noop/inconclusive/timeout all MOVE the pack file — disposal logic lives in the shared
        # _archive_finished_pack (2026-07-04) so crash-recovery orphan adoption (_adopt_orphans) can never
        # diverge from the live reap loop on what counts as done/parked/kept.
        done|noop|readonly-done|inconclusive|timeout) progress=1; _archive_finished_pack "$name" "$f" ;;
        partial)   echo "  ⚠ PARTIAL: $name ran but did NOT attest the full gauntlet (review/verify/QA likely skipped) — KEPT, will re-run; see $LOG_DIR/$name.log" ;;
        no-task)   notask=$((notask+1)); echo "  ↻ no-task: $name — /v booted with an empty task — KEPT, will re-run" ;;
        ratelimit) PASS_RL=1; echo "  ⏸ rate-limit: $name (kept for resume)" ;;
        error)     echo "  ✗ error: $name (kept — see $LOG_DIR/$name.log)" ;;
        *)         echo "  ? incomplete: $name (kept — see $LOG_DIR/$name.log)" ;;
      esac
      capture_telemetry "$name"   # additive, non-blocking: log this pack's session by explicit SID (no model tokens)
      pids[$j]=""; ndisp=$((ndisp+1))
    done
    # 3) still working? heartbeat (now shows .done growing live) + a short wait so we reap within ~20s of a finish.
    [ "$ndisp" -lt "$total" ] && { _hb; sleep "${_REAP_POLL:-20}"; }
  done
  # Each pack runs under a unique pinned --session-id + pre-seeded task, which prevents the cross-session
  # task-clobber. So if MANY packs still boot empty in one pass, it is NOT that clobber — more likely quota
  # throttling or a transient. Say so (they're KEPT + retried regardless).
  if [ "$JOBS" -gt 1 ] && [ "$notask" -ge 2 ] && [ "$progress" = 0 ]; then
    echo "  ⓘ $notask packs booted with an EMPTY task this pass. Each runs under a unique pinned session-id, so this is"
    echo "     NOT cross-session clobbering — likely quota/transient. They're KEPT and retried; try --serial if it persists."
  fi
}

# ── drain a single wave to completion (or stop on stall / rate-limit cap) ──────
# returns 0 = wave fully drained;  1 = could not finish (stall / cap) — caller stops before dependent waves
drain_wave(){ local w="$1" passes=0 rl_waits=0 stalls=0 before secs re now until_h end
  while :; do
    before="$(list_packs_in_wave "$w" | grep -c .)"   # wave-LOCAL remaining (not global .done — a prior wave's
    [ "$before" -eq 0 ] && return 0                    # archived packs must not look like "progress" for this wave)
    passes=$((passes+1)); [ "$passes" -gt 100 ] && { echo "⚠ wave $w: stopping after 100 passes (safety cap)"; return 1; }
    run_pass_wave "$w"
    if [ "$PASS_RL" = 1 ]; then
      rl_waits=$((rl_waits+1)); [ "$rl_waits" -gt 18 ] && { echo "⚠ wave $w: still session/usage-limited after 18 waits (~6h) — stopping. Re-run once your limit resets."; return 1; }
      re="$(reset_epoch)"; now="$(date +%s)"
      if [ -n "$re" ] && [ "$re" -gt "$now" ]; then
        secs=$(( re - now + 30 )); until_h="$(human_time "$re")"
      else
        secs=1200   # no known block-reset → poll every 20 min (each pre-reset retry is an instant no-op)
        until_h="$(find "$LOG_DIR" -name '*.log' -exec grep -hoiE 'resets [0-9]{1,2}:?[0-9]* ?[ap]m[^"]{0,24}|try again at [0-9]{1,2}:?[0-9]* ?[ap]m' {} + 2>/dev/null | head -1)"; [ -n "$until_h" ] || until_h="when your limit resets"
      fi
      # CAP the wait at 20 min and POLL: never blind-wait a whole computed window. A stale/weekly/wrong reset
      # time (or a limit that clears EARLY) must not strand the run — retry every ≤20 min; a still-limited retry
      # is an instant no-op, and the run resumes within 20 min of the limit actually clearing. The rl_waits>18
      # cap (~6h of polling) then stops + tells you to re-run, rather than idling for days.
      [ "$secs" -gt 1200 ] && secs=1200
      echo "⏸ session/usage limit reached (est. reset $until_h) — polling every ~20 min until it clears (Ctrl-C is safe; re-running resumes)."
      end=$(( $(date +%s) + secs )); while [ "$(date +%s)" -lt "$end" ]; do echo "  ⏸ $(date '+%H:%M:%S') waiting (retry in $(( (end - $(date +%s))/60 ))m; est. reset $until_h)…"; sleep 120; done
      continue
    fi
    [ "$ONCE" = 1 ] && return 0
    if [ "$(list_packs_in_wave "$w" | grep -c .)" -ge "$before" ]; then   # wave didn't shrink this pass = no progress
      stalls=$((stalls+1))
      [ "$stalls" -ge 2 ] && { echo "⚠ wave $w: $(list_packs_in_wave "$w" | grep -c .) pack(s) did NOT attest the full gauntlet after retries (partial/error, not rate-limit) — KEPT for inspection. See $LOG_DIR/; if /v won't finish one headless, run it interactively."; return 1; }
    else stalls=0; fi
  done
}

# ── W-LAND WAVE LANDING BARRIER (2026-07-02): a wave is not done until its work is ON MAIN. ──
# Waves order EXECUTION only; a pack archives on GAUNTLET_ATTESTED even when its merge-back FND-3-
# deferred (main carried a live sibling's WIP — the COMMON case under -jN). So wave N+1 sessions used
# to branch off a main missing wave N's commits — the broken-dependency class wave ordering exists to
# prevent, recreated one layer down — and the 99-* VERIFY pack judged a main missing everything still
# stranded on branches (the old flow drained only ONCE, at end-of-run, AFTER verify). After each wave
# drains, run the SAME safe landing machinery as end-of-run (_land_and_reconcile — PID-gated,
# verdict-gated, zero new merge logic), then GATE the next wave on:
#   (a) no pack parked in .needs-review/ — an unverified park is an unmet dependency; the per-wave
#       reconciles just moved every park whose work is PROVABLY on main, so whatever remains is
#       genuinely unproven (fail-closed, and resume-safe: a park left by an EARLIER run blocks too);
#   (b) no worktree branch with commits off main — EXCEPT a LIVE-owner branch (an interactive
#       sibling's in-flight session; its work was never a wave input, and blocking on it would
#       deadlock the fleet against its operator).
# Bounded retry ONLY while every blocking branch is `deferred` (self-resolving: main carried live WIP
# at drain time, and a retry that lands one can also sid-reconcile a parked pack); held / failed /
# wgate / unknown never self-resolve → stop immediately. Returns 0 = landed (or landing disabled);
# 1 = caller must stop before dependent waves. No new knobs: V_PACK_DRAIN=0 (the existing drain
# opt-out) disables the barrier together with the drain it depends on.
land_wave(){ # $1 = the wave that just drained (or the literal `pre-run` for the resume gate below)
  { [ "${V_PACK_DRAIN:-1}" = 1 ] && [ -f "$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh" ]; } || return 0
  local w="$1" lbl tries=0 needs unlanded blocking vd br nb
  case "$w" in pre-run) lbl="pre-run backlog" ;; *) lbl="wave $w" ;; esac
  while :; do
    _land_and_reconcile
    needs="$(count_needs)"
    unlanded="$(_unlanded_branches)"
    blocking="$(printf '%s\n' "$unlanded" | awk -F'\t' 'NF && $1!="live"')"
    if [ "${needs:-0}" -eq 0 ] && [ -z "$blocking" ]; then
      [ -z "$unlanded" ] || echo "  ⏳ $lbl: $(printf '%s\n' "$unlanded" | grep -c .) LIVE-owner branch(es) left to their own sessions (not wave work — they land via their own merge-back)"
      echo "✓ $lbl landed — all wave work is on main"
      return 0
    fi
    if [ -n "$blocking" ] && printf '%s\n' "$blocking" | awk -F'\t' '$1!="deferred"{bad=1} END{exit bad?1:0}'; then
      tries=$((tries+1))
      # V_PACK_LAND_RETRIES (2026-07-04, default raised 2→4): bounded patience for a wave blocked ONLY on
      # self-resolving `deferred` merges (main carried live sibling WIP at drain time) — so an operator
      # doesn't have to manually re-invoke run-v-packs just to get another landing attempt once that WIP
      # clears. Still bounded (never unbounded polling) and still ONLY for the deferred verdict — held/
      # failed/wgate/unknown blockers fall straight through to the ✗ report below regardless of tries.
      if [ "$tries" -le "${V_PACK_LAND_RETRIES:-4}" ]; then
        # _LAND_RETRY_SEC is an INTERNAL test seam (like _REAP_POLL/_AUTOGEN) — deliberately absent
        # from --help and the env-var table; do not promote it to operator surface (QA-LOW 2026-07-02).
        echo "  ⏸ $lbl: $(printf '%s\n' "$blocking" | grep -c .) merge(s) deferred on live sibling WIP — retrying the drain in $(( ${_LAND_RETRY_SEC:-60} ))s (retry $tries/${V_PACK_LAND_RETRIES:-4})"
        sleep "${_LAND_RETRY_SEC:-60}"; continue
      fi
    fi
    # RC-2 (resilience, 2026-07-07): a PRE-RUN / resume barrier can DEADLOCK the whole pipeline on
    # a PREVIOUS run's TERMINAL leftover — a strand whose owning session ENDED and whose verdict can never
    # self-resolve (held / failed / wgate / unknown), or a parked pack the runner never re-runs. Observed:
    # one ungauntleted, session-ended strand blocked EVERY subsequent run forever, with no path forward but
    # manual git surgery. But the runner CANNOT tell an independent prior-run leftover from an earlier
    # wave's held work that a LATER queued wave depends on — blindly proceeding reopens the resume-hole the
    # barrier exists to close (wave-2 built on a main missing wave-1's work; the I4 contract below). So the
    # DEFAULT still BLOCKS. `V_QUARANTINE_TERMINAL=1` is the operator's explicit escape for when they KNOW
    # the leftover is an independent branch, NOT a dependency of the queued waves: it QUARANTINES the
    # TERMINAL blockers (report loudly, leave intact) and PROCEEDS. Only `pre-run` (wave barriers stay
    # strict even with the flag); only TERMINAL blockers (`deferred` is transient — the retry loop owns it,
    # never quarantined, so a live sibling's in-flight merge is never skipped).
    if [ "$w" = "pre-run" ] && [ "${V_QUARANTINE_TERMINAL:-0}" = 1 ] \
       && ! printf '%s\n' "$blocking" | awk -F'\t' '$1=="deferred"{f=1} END{exit f?0:1}'; then
      echo "⚠ $lbl: V_QUARANTINE_TERMINAL=1 — QUARANTINING previous-run TERMINAL leftovers (session ended; verdict held/failed/needs-manual) and PROCEEDING. They are left INTACT on their branches; finish or land them separately. (Unset the flag to restore the default hard block, which guards against later waves building on a main missing an earlier wave's held work.)"
      [ "${needs:-0}" -gt 0 ] && echo "    ⏭ ${needs} parked pack(s) in .needs-review/ — quarantined (the runner never re-runs a parked pack; finish it interactively when ready)."
      printf '%s\n' "$blocking" | while IFS=$'\t' read -r vd br nb; do
        [ -n "$br" ] || continue
        echo "    ⏸ QUARANTINED $br — ${nb:-?} commit(s) not on main (verdict: $vd) — land it separately (complete its gauntlet, then v-merge-back.sh), or delete the branch if abandoned."
      done
      return 0
    fi
    echo "✗ $lbl did NOT fully land on main:"
    [ "${needs:-0}" -gt 0 ] && echo "    ⏭ ${needs} pack(s) parked in .needs-review/ — unverified work is an unmet dependency for later waves. Verify each: already on main → mv it to .done/; genuinely unfinished → run it interactively."
    printf '%s\n' "$blocking" | while IFS=$'\t' read -r vd br nb; do
      [ -n "$br" ] || continue
      echo "    ✗ $br — ${nb:-?} commit(s) not on main (drain verdict: $vd — full remediation in the summary below)"
    done
    return 1
  done
}

# ── T4-F1 (2026-07-02 wave-4 forensic): warn when invoked from INSIDE a wave subdir while LOWER waves
# are still queued next to it. Wave ordering is enforced only across the packs the runner can SEE — a
# `run-v-packs .` from inside wave-4/ shows waves=[4] and silently skips wave-3 entirely (observed live:
# the GO/NO-GO verification wave ran against a codebase missing everything wave-3 was supposed to build;
# its NO-GO verdict was invalid-by-construction). Advisory only — never blocks (the operator may
# genuinely want a single wave); it just refuses to let the skip be SILENT.
warn_skipped_lower_waves(){
  # R3: parse wave prefixes through the SAME _wave_norm wave_of() uses — this safety-net used its own
  # case-sensitive duplicate, so a Wave-2/WAVE-2 dir the runner (tolerantly) treats as wave 2 was invisible
  # here, silently defeating the exact out-of-order warning this function exists to print. Iterate ALL
  # sibling dirs and filter by normalized prefix (the old wave-*/w* globs were case-sensitive too).
  local own parent d b p n m cnt msg=""
  own="$(_wave_norm "$(basename "$PACK_ABS")")"
  case "$own" in
    wave-[0-9]*|wave_[0-9]*) n="${own#wave}"; n="${n#[-_]}"; n="${n%%[^0-9]*}" ;;
    w[0-9]*)                 n="${own#w}";    n="${n%%[^0-9]*}" ;;
    *) return 0 ;;
  esac
  [ -n "$n" ] || return 0
  parent="$(dirname "$PACK_ABS")"
  for d in "$parent"/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    [ "$d" = "$PACK_ABS" ] && continue
    b="$(_wave_norm "$(basename "$d")")"
    case "$b" in
      wave-[0-9]*|wave_[0-9]*) m="${b#wave}"; m="${m#[-_]}"; m="${m%%[^0-9]*}" ;;
      w[0-9]*)                 m="${b#w}";    m="${m%%[^0-9]*}" ;;
      *) continue ;;
    esac
    [ -n "$m" ] && [ "$m" -lt "$n" ] 2>/dev/null || continue
    cnt=0
    for p in "$d"/*.txt "$d"/*.md; do [ -f "$p" ] && is_pack "$p" && cnt=$((cnt+1)); done
    [ "$cnt" -gt 0 ] && msg="${msg}${msg:+; }wave $m: $cnt queued pack(s) at $d"
  done
  [ -z "$msg" ] || {
    echo "⚠ WAVE ORDER: running wave $n from inside its subdir, but LOWER waves are still queued ($msg)."
    echo "  A wave run out of order executes on a BROKEN DEPENDENCY (observed: a GO/NO-GO verification wave judged features its earlier wave never built). Run from $parent to enforce ordering."
  }
  return 0
}
