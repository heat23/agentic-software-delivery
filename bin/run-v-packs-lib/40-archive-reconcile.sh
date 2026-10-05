# run-v-packs-lib/40-archive-reconcile.sh — dispose finished packs by verdict, rate-limit reset lookup,
# and the parked-pack/branch reconciliation layer (sid + proof reconciles, drain-verdict parsing, the
# PID-gated landing machinery, unlanded-branch census, merged-branch GC).
#
# SOURCED (never executed) by ~/.local/bin/run-v-packs via its lib seam. Do NOT add `set` flags or a
# shebang: this file inherits the runner's `set -uo pipefail` and its bash (4+ after the runner's 3.2
# re-exec, or stock 3.2 when a test sources it) — it must parse and run under BOTH, same as the runner.
# Two spans travelled together from the runner (they sat either side of the wave-orchestration group,
# which stays inline): (a) _archive_finished_pack + reset_epoch, (b) the reconcile/landing family.
# Calls lib siblings late-bound at call time — verdict/sid_of/capture_telemetry/_result_out_tokens
# (30-verdict.sh), pack_name/count_* (10-discovery.sh), _main_branch (20-git-landing.sh) — and reads
# globals set by the runner/tests before these run: REPO, LOG_DIR, PACK_ABS, DONE_DIR, NEEDS_DIR,
# HAD_TIMEOUT (mutated by _archive_finished_pack), V_* tunables, _drain_last/_drain_out. Calls NO
# function that stays inline in the runner (not even die()).
# ── dispose a FINISHED pack by its verdict (2026-07-04 hardening pass) ──────────────────────────────
# Factored out of run_pass_wave's reap loop so the two places that ever dispose a just-finished pack — the
# live reap loop below, AND crash-recovery orphan adoption (_adopt_orphans) — share ONE decision, never two
# hand-maintained copies (the exact contract-drift class _land_and_reconcile's own header comment already
# calls out and fixes elsewhere in this file). Only handles the 4 verdicts that MOVE a pack file out of the
# queue (done/noop/inconclusive/timeout); partial/no-task/ratelimit/error/incomplete are "KEPT, will re-run"
# and need no disposal — callers leave those to the normal next-pass retry, which requires touching nothing.
# Mutates globals HAD_TIMEOUT (timeout verdicts) exactly like the inline case statement used to.
_archive_finished_pack(){ # $1=name $2=pack-file-path
  local name="$1" f="$2" _vd _sid _artf _n _vreason
  _vd="$(verdict "$name")"
  # CRASH-AFTER-MERGE witness archive (F8, 2026-07-07): a session can COMMIT + MERGE its work to main (writing
  # the durable commits-<sid>.txt witness at merge time) and THEN crash/park before the runner sees a clean
  # `done` verdict — e.g. the /v session-log step crashes POST-merge (observed: a production session merged
  # its work, then SESSION_LOG_FAILED → the runner never archived the pack → re-dispatched it → the retry
  # parked at num_turns==0 → the landing barrier DEADLOCKED forever behind a pack whose work was already on
  # main). For any parking verdict, if THIS pack's OWN session landed a commit witness whose commits are ALL on
  # main, the work IS done regardless of the (num_turns-driven) verdict — archive it. Being on main already
  # implies it cleared v-merge-back's W-GATE (gauntlet-attested), so this cannot ship un-gated work; the
  # backstop below still refuses an explicit-FAIL. OWN-sid witness only ⇒ ZERO cross-session false-attribution
  # (unlike a fragile prior-attempt/log-scan link, which surfaces sibling sids). Opt out V_PACK_WITNESS_ARCHIVE=0.
  case "$_vd" in
    done|noop|readonly-done) : ;;   # already terminal-success paths handled below
    *)
      if [ "${V_PACK_WITNESS_ARCHIVE:-1}" = 1 ]; then
        local _wsid _wf="" _wd _wsha _wn=0 _wok=1 _wmb; _wsid="$(sid_of "$name")"; _wmb="$(_main_branch "$REPO")"
        [ -n "$_wsid" ] && for _wd in "$REPO/.v/tmp" "$REPO/.v/artifacts"; do
          [ -s "$_wd/commits-${_wsid}.txt" ] && { _wf="$_wd/commits-${_wsid}.txt"; break; }
        done
        if [ -n "$_wf" ] && _gauntlet_verdicts_not_failed "$_wsid" >/dev/null 2>&1; then
          while IFS= read -r _wsha; do
            _wsha="$(printf '%s' "$_wsha" | tr -dc '0-9a-f')"; [ -n "$_wsha" ] || continue
            case "$_wsha" in ????????????????????????????????????????) : ;; *) _wok=0; break ;; esac
            git -C "$REPO" cat-file -e "${_wsha}^{commit}" 2>/dev/null || { _wok=0; break; }
            git -C "$REPO" merge-base --is-ancestor "$_wsha" "$_wmb" 2>/dev/null || { _wok=0; break; }
            _wn=$((_wn+1))
          done < "$_wf"
          if [ "$_wok" = 1 ] && [ "$_wn" -gt 0 ]; then
            [ "${ARCHIVE:-1}" = 1 ] && mv -f "$f" "$DONE_DIR/" 2>/dev/null
            echo "  ✓ done (own session's committed work — $_wn commit(s), witness commits-${_wsid}.txt — is fully on $_wmb, though the verdict was '$_vd': landed, then crashed/parked before clean completion): $name → .done/"
            return 0
          fi
        fi
      fi ;;
  esac
  case "$_vd" in
    done)
      _sid="$(sid_of "$name")"
      # NO-HUMAN-4 (2026-07-04): FIRST, the independent verdict backstop — if this pack's OWN gate artifact
      # explicitly records FAIL, the GAUNTLET_ATTESTED log token is a lie (or the Stop hook failed open); never
      # archive it as production-ready. Checked BEFORE the existence gate because a provable-FAIL is a harder
      # signal than "artifacts missing". Blocks only on an explicit FAIL (see _gauntlet_verdicts_not_failed).
      if ! _vreason="$(_gauntlet_verdicts_not_failed "$_sid")"; then
        [ "${ARCHIVE:-1}" = 1 ] && mv -f "$f" "$NEEDS_DIR/" 2>/dev/null
        echo "  ⛔ FALSE-DONE BLOCKED: $name's log emitted GAUNTLET_ATTESTED but its own gate artifact FAILS — ${_vreason:-a verdict says FAIL}. NOT archiving as done (the log token is not proof; this is the runner's independent verdict backstop). Parked → .needs-review/. Log: $LOG_DIR/$name.log"
      elif _gauntlet_artifacts_verified "$_sid"; then
        [ "${ARCHIVE:-1}" = 1 ] && mv -f "$f" "$DONE_DIR/" 2>/dev/null
        echo "  ✓ done (gauntlet attested): $name → .done/"
      else
        [ "${ARCHIVE:-1}" = 1 ] && mv -f "$f" "$NEEDS_DIR/" 2>/dev/null
        echo "  ⚠ UNVERIFIED-DONE: $name's log claims GAUNTLET_ATTESTED but PRE_FLIGHT_REPORT/AGENT_REVIEW/VERIFY_DONE_REPORT for sid=${_sid:-?} were NOT found on disk (.v/artifacts/ or repo root) — NOT archiving as done. Parked → .needs-review/ for manual verification (already on main with real artifacts elsewhere → mv it to .done/ yourself). Log: $LOG_DIR/$name.log"
      fi ;;
    noop)
      [ "${ARCHIVE:-1}" = 1 ] && mv -f "$f" "$DONE_DIR/" 2>/dev/null
      echo "  ✓ already complete (/v verified the fix is already on main; no-op, nothing to gauntlet): $name → .done/" ;;
    readonly-done)
      # READ-ONLY verification pack completed (2026-07-07): the session self-attested a read-only completion
      # (V-COMPLETION-SELFCHECK: PASS, zero product-code writes + findings artifact). It ships no commit, so
      # there is nothing to land/merge — dispose exactly like `noop` (plain move to .done/, NO gauntlet-artifact
      # backstop: a read-only pack legitimately has no PRE_FLIGHT/AGENT_REVIEW/VERIFY_DONE set, so routing it
      # through the `done` branch's _gauntlet_artifacts_verified check would false-park it under V_PACK_VERIFY_ARTIFACTS=1).
      rm -f "$LOG_DIR/$name.log.readonly" 2>/dev/null || true
      [ "${ARCHIVE:-1}" = 1 ] && mv -f "$f" "$DONE_DIR/" 2>/dev/null
      echo "  ✓ read-only verification complete (self-check PASS, no product code / no commit — findings recorded for the next wave): $name → .done/" ;;
    inconclusive)
      [ "${ARCHIVE:-1}" = 1 ] && mv -f "$f" "$NEEDS_DIR/" 2>/dev/null
      case "$(_inconclusive_kind "$name")" in
        completed)
          echo "  ⏭ INCONCLUSIVE — COMPLETED (self-check PASS, 0 code turns): $name verified the work is already-done or merge-deferred. Parked → .needs-review/ (NOT re-run). Verify it's on main, then: mv .needs-review/$(basename "$f") .done/ . Log: $LOG_DIR/$name.log" ;;
        already-done)
          echo "  ⏭ INCONCLUSIVE — likely ALREADY-DONE: $name did 0 turns + no done/no-op token; /v says the work pre-exists. Parked → .needs-review/ (NOT re-run). Verify it's on main, then: mv .needs-review/$(basename "$f") .done/ . Log: $LOG_DIR/$name.log" ;;
        fork-work)
          echo "  ⏭ INCONCLUSIVE — FORK DID REAL WORK, parent closed at 0 turns: $name burned $(_result_out_tokens "$name") output tokens (deliverables may be ON DISK, uncommitted/ungauntleted) but the main loop never ran verify-done/commit/attest — typically a main-loop model that won't drive /v (pin one: --model sonnet / V_PACK_MODEL). Parked → .needs-review/ (NOT re-run). Inspect its files, then finish it interactively. Log: $LOG_DIR/$name.log" ;;
        *)
          echo "  ⏭ INCONCLUSIVE — headless /v STALLED: $name did 0 turns + no terminal token (parked on a background-task/Monitor notification that never fires under -p). Parked → .needs-review/ (NOT re-run). Run it interactively to finish. Log: $LOG_DIR/$name.log" ;;
      esac ;;
    timeout)
      HAD_TIMEOUT=1
      if [ "$(_timeout_kind "$name")" = active ]; then
        # T-RETRY (2026-07-04): a near-completion (ACTIVE) timeout is legitimately slow, not wedged — grant a
        # bounded number of automatic retries before parking, so a single close-to-finishing session doesn't
        # need a manual re-run. A WEDGED timeout NEVER gets this grace (a stuck dispatch just wedges again).
        _artf="$LOG_DIR/$name.log.activeretries"
        _n="$(cat "$_artf" 2>/dev/null | tr -dc '0-9')"; _n="${_n:-0}"
        if [ "$_n" -lt "${V_PACK_ACTIVE_RETRY:-1}" ]; then
          _n=$((_n+1)); printf '%s' "$_n" >"$_artf" 2>/dev/null || true
          echo "  ⏱ TIMEOUT (ACTIVE — near-completion, not wedged): $name hit the $((PACK_TIMEOUT/60))-min ceiling while still working. Auto-retrying ($_n/${V_PACK_ACTIVE_RETRY:-1}) instead of parking — KEPT, will re-run. Log: $LOG_DIR/$name.log"
          return 0   # KEPT for retry — do NOT move the pack file
        fi
        rm -f "$_artf" 2>/dev/null || true
        [ "${ARCHIVE:-1}" = 1 ] && mv -f "$f" "$NEEDS_DIR/" 2>/dev/null
        echo "  ⏱ TIMEOUT: $name hit the $((PACK_TIMEOUT/60))-min ceiling ACTIVELY WORKING $(( ${V_PACK_ACTIVE_RETRY:-1} + 1 )) time(s) in a row (auto-retries exhausted) — parked → .needs-review/. Any gauntlet artifacts it finished may still land via the end-of-run drain; otherwise raise --timeout <min> and re-run it, or run it interactively. Log: $LOG_DIR/$name.log"
      else
        rm -f "$LOG_DIR/$name.log.activeretries" 2>/dev/null || true
        [ "${ARCHIVE:-1}" = 1 ] && mv -f "$f" "$NEEDS_DIR/" 2>/dev/null
        echo "  ⏱ TIMEOUT: $name blew the $((PACK_TIMEOUT/60))-min ceiling and was killed (no log activity for ~$(( ${V_WEDGE_IDLE_SEC:-300}/60 ))+ min — likely WEDGED: a stuck subagent dispatch or rate-limit stall holding its slot; but a single long-running command that streams no events, e.g. a full test suite, ALSO looks idle here, so confirm before assuming stuck). Parked → .needs-review/ (NOT re-run, so it can't wedge the run again). If it was legitimately slow: raise --timeout <min> and re-run it, or run it interactively. Log: $LOG_DIR/$name.log"
      fi ;;
    *) return 1 ;;   # not a disposal verdict (partial/no-task/ratelimit/error/incomplete) — nothing to move
  esac
  return 0
}

# Latest reset time among ACTUAL blocks. CRITICAL: exclude `allowed`/`allowed_warning` events — those are not
# limit hits; their `resetsAt` is the (often days-away) WEEKLY-window boundary, and taking the MAX across them
# once made the runner blind-wait 3 days for a session limit that had already reset. Only events whose status is
# a real block count; if none, this returns empty and drain_wave falls back to a short poll (resume when clear).
reset_epoch(){ find "$LOG_DIR" -name '*.log' -exec grep -hE '"type":[[:space:]]*"rate_limit_event"' {} + 2>/dev/null | jq -rs 'map(.rate_limit_info) | map(select(((.status // "")|ascii_downcase|contains("allowed"))|not)) | map(.resetsAt // empty) | max // empty' 2>/dev/null; }

# ── F1 (2026-07-02): reconcile a parked pack whose fix landed via a LATER drain ────────────────
# WHY: a pack can report 0 turns + no terminal token (verdict()="inconclusive") and get parked to
# .needs-review/ even though its underlying worktree kept going (e.g. via a forked subagent, or a
# merge that got FND-3-deferred) and was later landed by v-drain-deferred-merges.sh. Nothing ever
# told run-v-packs the parked pack's fix is now on main, so a pack file (e.g. a docs-hardening pack)
# sat in .needs-review/ forever CONTRADICTING main (forensic 2026-07-01, R4 audit-fix-packs run: the
# landing was clean — all 6 packs on main — but the pack folder was never told).
# FIX: correlate by SESSION-ID, not content/filename guessing. Each pack's OWN pinned --session-id
# (passed at launch via run_pack) is echoed back verbatim as claude's `session_id` in that pack's own
# .runlogs/<name>.log result event — true even for a 0-turn inconclusive result (verdict() requires a
# valid result event just to REACH the inconclusive branch). That SAME pinned id is what /v embeds
# into the worktree it creates (CLAUDE_CODE_SESSION_ID), so it is also the sid
# v-drain-deferred-merges.sh reads from that worktree's .claude-session-lock and now reports back (as
# "(sid=<uuid>)" on its "✓ merged+cleaned:" line). A match is definitive: the SAME session that ran
# this pack is the one whose worktree the drain just landed.
# Scope: only ever touches files CURRENTLY parked in .needs-review/ — a queued/active pack is left to
# the normal run/verdict path; this only closes the specific "parked but actually done" gap.
reconcile_parked_by_sid(){ # $1 = the drain step's captured stdout+stderr
  local drain_out="${1:-}" landed_sids f base logf sid
  landed_sids="$(printf '%s\n' "$drain_out" | grep -oE '\(sid=[0-9a-fA-F-]+\)' | grep -oE '[0-9a-fA-F-]{8,}')"
  [ -n "$landed_sids" ] || return 0
  find "$NEEDS_DIR" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | while IFS= read -r f; do
    base="$(basename "$f")"; base="${base%.txt}"; base="${base%.md}"
    # the log's structured name may carry a wave-subfolder prefix the parked file lost when it was
    # flattened into .needs-review/ (mv preserves basename only) — search LOG_DIR for it by basename.
    # AR-1 (adversarial review): >1 same-named log across waves = ambiguous attribution → skip (fail-closed).
    if [ "$(find "$LOG_DIR" -type f -name "${base}.log" 2>/dev/null | grep -c .)" -gt 1 ]; then
      echo "  ⚠ parked pack $base: multiple same-named runlogs across waves — cannot attribute a session; NOT reconciling (verify manually)"
      continue
    fi
    logf="$(find "$LOG_DIR" -type f -name "${base}.log" 2>/dev/null | head -1)"
    [ -n "$logf" ] || continue
    sid="$(grep -E '"type":[[:space:]]*"result"' "$logf" 2>/dev/null | tail -1 | jq -r '.session_id // empty' 2>/dev/null)"
    [ -n "$sid" ] || continue
    if printf '%s\n' "$landed_sids" | grep -qxF "$sid"; then
      echo "  ⏭→✓ parked pack $base was landed by VERIFY/drain (sid=$sid) — reconciling .needs-review/ → .done/"
      mv -f "$f" "$DONE_DIR/" 2>/dev/null || echo "  ⚠ parked pack $base matches a landed sid ($sid) but could not be moved — reconcile manually: mv '$f' '$DONE_DIR/'"
    fi
  done
}

# ── F6 (2026-07-01 forensic): reconcile a parked pack whose committed work is PROVABLY all on main ──────
# WHY: reconcile_parked_by_sid only fires when THIS run's drain lands the worktree — a pack parked in an
# EARLIER run whose work landed in an earlier drain (worktree + branch long gone) never reconciles, so
# .needs-review/ nags forever about work that is fully on main (observed: 3 wave-1 packs parked
# whose branches fast-forward-merged within the hour; every later pass renagged them).
# HOW: correlate by the pack's OWN pinned session-id (present on EVERY event line of its runlog — even a
# timeout-killed log with no result event), then check the session's durable commit-witness
# <repo>/.v/artifacts/commits-<sid>.txt: if it lists ≥1 commit and EVERY listed sha exists AND is an
# ancestor of main, the session's committed work is fully landed → move the pack to .done/.
# FAIL-CLOSED by construction: a missing/empty witness, an unresolvable sha (e.g. the session rewrote
# history after the witness was written — observed live), or ANY non-ancestor sha → not moved. This can
# under-reconcile, never over-reconcile.
reconcile_parked_by_proof(){
  local f base logf nlog sid pf sha nsha all sid8 openbr main_branch; main_branch="$(_main_branch "$REPO")"
  find "$NEEDS_DIR" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | while IFS= read -r f; do
    base="$(basename "$f")"; base="${base%.txt}"; base="${base%.md}"
    # AR-1 (adversarial review, HIGH): parking flattens the wave prefix (mv preserves basename only), so a
    # basename lookup can match wave-1/foo.log AND wave-2/foo.log — `head -1` would attribute the parked
    # pack to whichever the filesystem lists first, and could move the WRONG (still-unlanded) pack. If more
    # than one log matches the basename, attribution is ambiguous → SKIP (fail-closed), loudly.
    nlog="$(find "$LOG_DIR" -type f -name "${base}.log" 2>/dev/null | grep -c .)"
    if [ "${nlog:-0}" -gt 1 ]; then
      echo "  ⚠ parked pack $base: ${nlog} same-named runlogs across waves — cannot attribute a session; NOT reconciling (verify manually)"
      continue
    fi
    logf="$(find "$LOG_DIR" -type f -name "${base}.log" 2>/dev/null | head -1)"
    [ -n "$logf" ] || continue
    sid="$(grep -E '"type":[[:space:]]*"result"' "$logf" 2>/dev/null | tail -1 | jq -r '.session_id // empty' 2>/dev/null)"
    # a watchdog-killed log has no result event, but every task/system EVENT still carries the pinned sid.
    # AR-4: parse per JSONL line (structural field), never a raw cross-line substring grep — a tool-result
    # CONTENT string that merely quotes '"session_id": "<uuid>"' must not win.
    [ -n "$sid" ] || sid="$(jq -Rr 'fromjson? | .session_id // empty' "$logf" 2>/dev/null | grep -m1 -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')"
    [ -n "$sid" ] || continue
    pf="$REPO/.v/artifacts/commits-${sid}.txt"
    [ -s "$pf" ] || continue
    # AR-5 (defense-in-depth): the witness proves its listed commits are on main, not that the session has
    # no OTHER unmerged work. If any branch carrying this sid's short-8 still has commits ahead, don't call
    # the pack done.
    sid8="${sid%%-*}"
    openbr="$(git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | grep -E "(^|[-_/])${sid8}([-_/]|$)" | while IFS= read -r b; do
      [ "$(git -C "$REPO" rev-list --count "${main_branch}..${b}" 2>/dev/null || echo 1)" = 0 ] || { printf '%s' "$b"; break; }
    done)"
    if [ -n "$openbr" ]; then
      echo "  ⚠ parked pack $base: branch $openbr (same session) still has commits ahead of $main_branch — NOT reconciling"
      continue
    fi
    nsha=0; all=1
    while IFS= read -r sha; do
      sha="$(printf '%s' "$sha" | tr -dc '0-9a-f')"
      [ -n "$sha" ] || continue
      case "$sha" in ????????????????????????????????????????) : ;; *) all=0; break ;; esac
      git -C "$REPO" cat-file -e "${sha}^{commit}" 2>/dev/null || { all=0; break; }
      git -C "$REPO" merge-base --is-ancestor "$sha" "$main_branch" 2>/dev/null || { all=0; break; }
      nsha=$((nsha+1))
    done < "$pf"
    if [ "$all" = 1 ] && [ "$nsha" -gt 0 ]; then
      echo "  ⏭→✓ parked pack $base: its session's committed work ($nsha commit(s), witness commits-${sid}.txt) is fully on main — reconciling .needs-review/ → .done/"
      mv -f "$f" "$DONE_DIR/" 2>/dev/null || echo "  ⚠ parked pack $base is fully landed but could not be moved — reconcile manually: mv '$f' '$DONE_DIR/'"
    fi
  done
}

# ── F2 (2026-07-02): sweep branch refs left over from ANY prior merge, not just the one just drained ──
# WHY: a /v worktree branch (build/*, fix/*) can be fully merged into main yet survive as a dangling ref
# — its OWN cleanup (v-merge-back.sh's `git branch -d`) only runs on the SAME invocation that performed
# the merge; a branch merged by any other path (a manual merge, an earlier drain whose branch-delete step
# didn't apply, a worktree removed by other means) is never revisited (forensic 2026-07-01: an R3 leftover
# fix/<name>-<sid8> branch, 0 commits ahead of main, ancestor-of-main=YES — harmless but
# confusing debris that accumulates run over run).
# SAFETY (must hold on every call): scoped to the /v worktree naming convention (build/*, fix/*) only —
# never touches a user's own branches; skips main and the currently checked-out branch; skips any branch
# checked out in a worktree (never fights a live session); requires BOTH ancestor-of-main AND zero unique
# commits ahead before even attempting delete; uses `git branch -d` (never -D), which itself refuses a
# non-fast-forward branch — defense in depth, not the only guard.
gc_merged_branches(){ # $1 = repo root
  local repo="${1:-}" main_branch br ahead gc=0
  main_branch="$(_main_branch "${1:-.}")"
  [ -n "$repo" ] || return 0
  local live_branches; live_branches="$(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^branch refs\/heads\///p')"
  local cur_branch; cur_branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || true)"
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    case "$br" in build/*|fix/*) ;; *) continue ;; esac
    [ "$br" = "$main_branch" ] && continue
    [ -n "$cur_branch" ] && [ "$br" = "$cur_branch" ] && continue
    printf '%s\n' "$live_branches" | grep -qxF "$br" && continue   # checked out in a worktree — never touch a live session
    git -C "$repo" merge-base --is-ancestor "$br" "$main_branch" 2>/dev/null || continue   # not fully merged
    ahead="$(git -C "$repo" rev-list --count "$main_branch..$br" 2>/dev/null || echo 1)"
    [ "${ahead:-1}" = 0 ] || continue   # unique commits ahead of main — never touch
    if git -C "$repo" branch -d "$br" 2>/dev/null; then
      echo "  ✓ pruned fully-merged branch ref: $br"; gc=$((gc+1))
    fi
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
  [ "$gc" -gt 0 ] && echo "  branch GC: pruned $gc fully-merged /v worktree branch ref(s)."
  return 0
}

# ── P0-1 (2026-07-02 forensic): truthful per-branch drain verdict ─────────────────────────────
# WHY: the old end-of-run summary said "lands automatically once idle" for EVERY still-unmerged
# branch, and printed "✓ queue empty — nothing left to do" whenever the PACK-FILE queue was empty —
# even while gauntlet-passed commits sat stranded on branches the drain could NEVER land on its own
# (a permanent rc=2 short-SID loop, a mid-setup mis-skip). A real batch reported 100% success with
# ZERO commits actually landed on main. This maps each still-unmerged branch to its OWN verdict line
# from the drain's captured output (v-drain-deferred-merges.sh prints exactly one "✓ merged+cleaned:",
# "⏸ still deferred:", or "✗ merge-back rc=N for" line per branch it touched) instead of guessing.
_drain_verdict_for(){ # $1=drain_out  $2=branch -> merged | deferred | held | wgate | live | failed | unknown
  local out="$1" br="$2"
  # Fixed-string (-F) match on the FULL literal separator each drain line uses, not just the branch
  # name — a plain substring match on the branch alone would false-match a branch that is a PREFIX of
  # another (fix/foo vs fix/foo-bar); anchoring on the trailing "(sid="/"(main"/" (left" separator
  # closes that gap without needing to regex-escape an arbitrary branch name.
  printf '%s\n' "$out" | grep -qF "merged+cleaned: $br (sid=" && { echo merged; return; }
  printf '%s\n' "$out" | grep -qF "still deferred: $br (main" && { echo deferred; return; }
  # T-ACT/F5 (2026-07-01 forensic): the drain ALSO prints HOLD (verdict-gate), W-GATE-block, and
  # LIVE-skip lines — the old footer lumped all three into "session still live, or not yet drained —
  # re-run to retry", contradicting the drain's own HOLD printed 20 lines earlier in the same run.
  printf '%s\n' "$out" | grep -qF "HOLD $br — " && { echo held; return; }
  if printf '%s\n' "$out" | grep -F "for $br (left intact" | grep -qF 'W-GATE artifact block'; then echo wgate; return; fi
  printf '%s\n' "$out" | grep -qF "skip $br — owning session is ALIVE" && { echo live; return; }
  printf '%s\n' "$out" | grep -qF "for $br (left intact" && { echo failed; return; }
  echo unknown
}

reconcile_parked_readonly(){ # archive parked READ-ONLY verify packs whose verification demonstrably RAN
  # A read-only verify pack (/v-pre-flight, /v-verify-done — "Do NOT edit source") ships ZERO commits, so its
  # park can NEVER be an unlanded-CODE dependency for a later wave. Its deliverable is its findings REPORT,
  # which the fix wave consumes and the terminal 99-* verify re-gates. Yet the landing barrier counts ANY
  # parked pack as an unmet dependency (land_wave: needs>0 ⇒ block) — so a read-only verify wave that
  # legitimately FAILS / surfaces findings DEADLOCKS the very fix wave meant to address them (observed:
  # a w1-pre-flight FAIL + w1-review both parked, permanently blocking w2-hardening; --resume just
  # re-fails the pre-flight and re-parks). So: once a parked read-only pack's verification PROVABLY ran (a
  # durable PRE_FLIGHT_REPORT / VERIFY_DONE_REPORT / AGENT_REVIEW for ITS pinned sid exists on disk), archive
  # it to .done/ — verification-complete, findings captured — so it stops blocking. Pass vs FAIL is
  # irrelevant here: a verify pack's contract is to REPORT, and the batch's real GO/NO-GO is the terminal
  # 99-* verify. Opt out with V_PACK_READONLY_RECONCILE=0.
  [ "${V_PACK_READONLY_RECONCILE:-1}" = 1 ] || return 0
  local f base logf nlog sid rep _d _r _ahay
  find "$NEEDS_DIR" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | while IFS= read -r f; do
    base="$(basename "$f")"; base="${base%.txt}"; base="${base%.md}"
    # same fail-closed attribution guard as reconcile_parked_by_proof: an ambiguous basename across waves
    # must not archive the wrong pack.
    nlog="$(find "$LOG_DIR" -type f -name "${base}.log" 2>/dev/null | grep -c .)"
    [ "${nlog:-0}" -gt 1 ] && { echo "  ⚠ parked pack $base: ${nlog} same-named runlogs across waves — cannot attribute a session; NOT readonly-reconciling"; continue; }
    logf="$(find "$LOG_DIR" -type f -name "${base}.log" 2>/dev/null | head -1)"
    [ -n "$logf" ] || continue
    # sid: structural per-line parse (never a cross-line content substring) — mirrors by_proof (AR-4).
    sid="$(grep -E '"type":[[:space:]]*"result"' "$logf" 2>/dev/null | tail -1 | jq -r '.session_id // empty' 2>/dev/null)"
    [ -n "$sid" ] || sid="$(jq -Rr 'fromjson? | .session_id // empty' "$logf" 2>/dev/null | grep -m1 -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')"
    # READ-ONLY tag (the discriminator that keeps this OFF normal CODE packs): the runner's name-keyed sidecar
    # ($logf.readonly, written only when _pack_is_readonly matched), OR the session-side sid-keyed marker.
    # No tag ⇒ a normal code pack ⇒ leave it to by-sid/by-proof + the barrier (never archive code work here).
    if [ ! -f "${logf}.readonly" ]; then
      { [ -n "$sid" ] && [ -f "$REPO/.v/tmp/pack-readonly-${sid}.marker" ]; } || continue
    fi
    [ -n "$sid" ] || continue
    # PROOF the verification actually RAN this session: a durable report for THIS sid on disk (dual location —
    # .v/artifacts/ primary, repo root legacy fallback). No report ⇒ the read-only session stalled without
    # verifying (rate-limit / wedge) ⇒ leave it PARKED (fail-closed; never fake a completed verification).
    rep=""
    for _d in "$REPO/.v/artifacts" "$REPO"; do
      for _r in "PRE_FLIGHT_REPORT_${sid}.md" "VERIFY_DONE_REPORT_${sid}.md" "AGENT_REVIEW_${sid}.md"; do
        [ -f "$_d/$_r" ] && { rep="$_d/$_r"; break 2; }
      done
    done
    [ -n "$rep" ] || { echo "  ⏸ parked read-only pack $base (sid ${sid%%-*}): no durable verify report on disk — leaving PARKED (verification did not demonstrably complete)"; continue; }
    # ATTEST-MENTION-3 (CRITICAL, 2026-09-18 adversarial review): report EXISTENCE used to be the ONLY
    # test here ("Pass vs FAIL is irrelevant"), and this function never called verdict() or the attest
    # veto. So a session that legitimately dispatched a reviewer, got back GENUINE failing findings, and
    # then correctly REFUSED to print the completion tokens was swept .needs-review/ -> .done/ anyway —
    # a second, automatic, default-on door to the exact false-archive the veto exists to close, reached
    # with no adversarial phrasing at all. Proven by executing this function against a fixture of the real
    # incident's shape. The report's PASS/FAIL content is still deliberately not judged (that remains the
    # 99-* verify's job); what is now judged is whether the pack's own final message NAMES the completion
    # tokens while declining them. A read-only pack that never mentions them is unaffected.
    _ahay="$(grep -E '"type":[[:space:]]*"result"' "$logf" 2>/dev/null | tail -1 | jq -r '.result // ""' 2>/dev/null)"
    if _attest_mention_only "$_ahay" 'v-completion-selfcheck:[[:space:]]*pass' \
       || _attest_mention_only "$_ahay" 'gauntlet_attested'; then
      echo "  ⏸ parked read-only pack $base (sid ${sid%%-*}): its final message NAMES the completion tokens while declining them — leaving PARKED despite $(basename "$rep") on disk (attest-mention refusal)"
      continue
    fi
    echo "  ⏭→✓ parked read-only verify pack $base: verification ran (witness $(basename "$rep")) and ships no code — reconciling .needs-review/ → .done/ so it stops blocking the fix wave"
    mv -f "$f" "$DONE_DIR/" 2>/dev/null || echo "  ⚠ parked read-only pack $base could not be moved — reconcile manually: mv '$f' '$DONE_DIR/'"
  done
}

# ── W-LAND (2026-07-02): ONE landing pass — settle → drain → W-GATE re-drain → reconcile parked packs.
# Factored out of main()'s end-of-run block so the per-wave landing barrier (land_wave) and the final
# end-of-run sweep run IDENTICAL machinery — two hand-maintained copies of this sequence is exactly the
# contract-drift class that keeps recurring. Sets the caller-scoped _drain_out (ALL attempts, valid
# landing evidence for sid-reconcile) and _drain_last (LAST attempt only, for per-branch verdicts —
# AR-3). CONSUMES the settle window: HAD_TIMEOUT is reset on the way out so each timeout event buys
# exactly one settle, not one per every later landing pass.
_land_and_reconcile(){
  _drain_out=""; _drain_last=""; local _drain_out2=""
  if [ "${V_PACK_DRAIN:-1}" = 1 ] && [ -f "$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh" ]; then
    # T-ACT/F1b (2026-07-01 forensic, the photo-finish class): a watchdog-killed session's gate subagents
    # are DETACHED processes that survive the kill and keep flushing their reports for up to ~a minute
    # (observed: merge-back declared PRE_FLIGHT_REPORT missing at T+11s; the surviving pre-flight runner
    # wrote it at T+52s → a fully-gauntleted, QA-passed branch was reported NEEDS-MANUAL). If anything was
    # timeout-killed since the last landing, SETTLE before draining so those writers finish; and if the
    # drain still hits a W-GATE artifact block, re-drain ONCE more after a second settle. Idempotent +
    # guard-preserving: merge-back's own W-GATE/ownership/lock logic runs unchanged on every attempt — we
    # only retry, never bypass. V_PACK_SETTLE_SEC=0 disables both waits (tests).
    if [ "${HAD_TIMEOUT:-0}" = 1 ] && [ "${V_PACK_SETTLE_SEC:-90}" -gt 0 ] 2>/dev/null; then
      echo "── settling ${V_PACK_SETTLE_SEC:-90}s before the drain (timeout-killed sessions' gate subagents may still be flushing artifacts) ──"
      sleep "${V_PACK_SETTLE_SEC:-90}"
    fi
    echo "── landing stranded (ended) worktree fixes safely — v-drain-deferred-merges ──"
    _drain_out="$(bash "$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh" "$REPO" 2>&1)"
    printf '%s\n' "$_drain_out" | sed 's/^/  /'
    _drain_last="$_drain_out"
    if [ "${HAD_TIMEOUT:-0}" = 1 ] && printf '%s\n' "$_drain_out" | grep -qF 'W-GATE artifact block'; then
      [ "${V_PACK_SETTLE_SEC:-90}" -gt 0 ] 2>/dev/null && sleep "${V_PACK_SETTLE_SEC:-90}"
      echo "── re-draining once: a W-GATE artifact block after a timeout-kill is often a still-flushing report ──"
      _drain_out2="$(bash "$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh" "$REPO" 2>&1)"
      printf '%s\n' "$_drain_out2" | sed 's/^/  /'
      # AR-3 (adversarial review): the per-branch verdict must reflect the LAST attempt's terminal
      # state (attempt 2 can fail differently than attempt 1's W-GATE block) — combined output is kept
      # ONLY for the sid-reconcile, where lines from EITHER pass are valid landing evidence.
      _drain_last="$_drain_out2"
      _drain_out="$_drain_out
$_drain_out2"
    fi
    # F1: reconcile any pack still parked in .needs-review/ whose OWN pinned session-id matches a worktree
    # the drain above just landed — see reconcile_parked_by_sid's header comment for the full mapping proof.
    reconcile_parked_by_sid "$_drain_out"
  fi
  # F6: reconcile packs parked in EARLIER runs whose committed work is provably all on main (durable
  # commit-witness check — works even after the worktree/branch are gone). Opt out with V_PACK_RECONCILE_PROOF=0.
  [ "${V_PACK_RECONCILE_PROOF:-1}" = 1 ] && reconcile_parked_by_proof
  # F7 (2026-07-07): archive parked READ-ONLY verify packs whose verification demonstrably ran — they ship no
  # code and must not deadlock the fix wave behind the findings they exist to produce. See the function header.
  reconcile_parked_readonly
  HAD_TIMEOUT=0
  return 0
}

# ── W-LAND: worktree branches whose commits are NOT on main, each with the drain's OWN verdict for it. ──
# Shared by the wave landing barrier (gate input) and the end-of-run footer (report input) so the gate
# and the report can never disagree about what is stranded. Emits "verdict<TAB>branch<TAB>commits-ahead"
# per branch; skips the primary worktree's own branch (it IS the landing target, never stranded — R4).
# TAB is a safe separator BY GIT INVARIANT: refname rules reject every ASCII control char (git
# check-ref-format; verified: `git branch $'a\tb'` → rc 128), so no branch name can ever contain one.
# Quotes/$ ARE valid in refnames and pass through here untouched (printf '%s', no eval — U10 pins this).
_unlanded_branches(){
  local mainbr curbr br n
  mainbr="$(_main_branch "$REPO")"
  curbr="$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null)"
  git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^branch /{b=$2; sub(/^refs\/heads\//,"",b); print b}' | while IFS= read -r br; do
    [ -n "$br" ] || continue
    [ -n "$curbr" ] && [ "$br" = "$curbr" ] && continue
    n="$(git -C "$REPO" rev-list --count "${mainbr}..$br" 2>/dev/null || echo 0)"
    [ "${n:-0}" -gt 0 ] || continue
    printf '%s\t%s\t%s\n' "$(_drain_verdict_for "${_drain_last:-${_drain_out:-}}" "$br")" "$br" "$n"
  done
}
