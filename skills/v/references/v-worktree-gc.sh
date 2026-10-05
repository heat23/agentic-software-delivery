#!/usr/bin/env bash
# v-worktree-gc.sh <repo_root> [--apply] — prune LEAKED worktrees whose work is SAFELY merged.
#
# Forensic 2026-06-19: a parallel wave left several worktrees leaked (`git worktree list` after the wave). This
# GC reclaims them — but CONSERVATIVELY, because pruning an UNMERGED worktree is itself the data-loss
# class we are fighting (most of those carried stranded, unmerged fixes). Rules:
#   - Remove a worktree ONLY when its branch is an ANCESTOR of <main> (0 commits ahead = fully merged)
#     AND its session is done (no fresh .claude-session-lock within V_WT_GC_LOCK_AGE_MIN, default 240).
#   - NEVER remove an AHEAD-of-main worktree — its commits are recovered by the FND-3 stranded-deferral
#     gate (check-review-artifact.sh) + a re-run merge-back. Report it loudly instead.
#   - NEVER remove a worktree with a fresh lock (an active session).
#
# Dry-run by DEFAULT (lists actions, removes nothing). Pass --apply to actually `git worktree remove`.
# Exit: 0 always (advisory tool). Prints a summary: pruned / kept-unmerged / kept-active.
set -u
REPO="${1:?usage: v-worktree-gc.sh <repo_root> [--apply]}"
APPLY=0; [ "${2:-}" = "--apply" ] && APPLY=1
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
AGE_MIN="${V_WT_GC_LOCK_AGE_MIN:-240}"
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo: $REPO"; exit 0; }
NOW=$(date +%s 2>/dev/null || echo 0)
MAIN_ROOT=$(git -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')

# F3-item4 (2026-07-05): shared lock-format/liveness parser — same "_LOCK_LIB + best-effort
# source" convention as v-drain-deferred-merges.sh / v-active-siblings.sh. Wiring lock_alive()
# here (instead of the old mtime-only freshness check) closes a real false-prune hole: a long
# multi-hour session that had not rewritten its own lock within AGE_MIN (default 240min) used to
# read as "session done" by file age ALONE, even when its owning PID (kill -0) was still alive —
# this GC would then remove its merged-but-still-in-progress worktree out from under it.
# lock_alive() gates on the recorded PID (kill -0) + transcript liveness first, falling back to
# age only when neither signal is available (grace period + liveness check, never either alone —
# see hooks/lib/session-lock-parse.sh header for the full contract).
_LOCK_LIB="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-lock-parse.sh"
# shellcheck disable=SC1090
[ -f "$_LOCK_LIB" ] && . "$_LOCK_LIB" 2>/dev/null || true

_PRUNED=0; _KEPT_UNMERGED=0; _KEPT_ACTIVE=0; _KEPT_OTHER=0

_lock_is_fresh() {  # <worktree_dir> -> 0 if the owning session reads ALIVE (PID/liveness-gated).
  local _lk="$1/.claude-session-lock" _m
  [ -f "$_lk" ] || return 1
  if command -v lock_alive >/dev/null 2>&1; then
    lock_alive "$_lk" "$AGE_MIN"
    return $?
  fi
  # Lib unavailable — fall back to the original mtime-only heuristic (never worse than before).
  _m=$(stat -c %Y "$_lk" 2>/dev/null || stat -f %m "$_lk" 2>/dev/null || echo 0)
  [ "$NOW" -gt 0 ] && [ "${_m:-0}" -gt 0 ] && [ $(( (NOW - _m) / 60 )) -lt "$AGE_MIN" ]
}

_gc_one() {  # <worktree_path> <branch>
  local _wt="$1" _br="$2" _ahead
  # Belt-and-suspenders (codex HIGH): NEVER GC a worktree on the main branch — that is the main
  # checkout (git main..main == 0 would otherwise classify it "merged" and prune the repo root if the
  # MAIN_ROOT path extraction ever failed). The MAIN_ROOT != check upstream already excludes it; this
  # guards the path-extraction-failure case independently.
  if [ "$_br" = "$MAIN_BRANCH" ]; then
    echo "KEEP (main-branch checkout): $_wt"; _KEPT_OTHER=$((_KEPT_OTHER+1)); return
  fi
  if [ -z "$_br" ]; then
    echo "KEEP (detached, no branch to verify merged): $_wt"; _KEPT_OTHER=$((_KEPT_OTHER+1)); return
  fi
  _ahead=$(git -C "$REPO" rev-list --count "${MAIN_BRANCH}..${_br}" 2>/dev/null || echo unknown)
  if [ "$_ahead" = unknown ]; then
    echo "KEEP (cannot compare ${_br} to ${MAIN_BRANCH}): $_wt"; _KEPT_OTHER=$((_KEPT_OTHER+1)); return
  fi
  if [ "$_ahead" -gt 0 ]; then
    echo "KEEP — UNMERGED (${_br} is ${_ahead} commit(s) ahead of ${MAIN_BRANCH}): $_wt  ⟶ recover via: bash ~/.claude/skills/v/references/v-merge-back.sh <sid> '$_wt'  (NEVER pruned by GC — that would strand the work)"
    _KEPT_UNMERGED=$((_KEPT_UNMERGED+1)); return
  fi
  # ahead == 0 -> fully merged into main, safe to reclaim IF the session is done.
  if _lock_is_fresh "$_wt"; then
    echo "KEEP (merged but session still ACTIVE, fresh lock): $_wt"; _KEPT_ACTIVE=$((_KEPT_ACTIVE+1)); return
  fi
  # CRITICAL (audit GC-DIRTY-WORKTREE 2026-06-21; widened to DRY-RUN 2026-07-04): ahead==0 proves only
  # that COMMITTED ancestry is merged — the WORKING TREE may still hold uncommitted edits / untracked
  # files that `--force` destroys IRREVERSIBLY. Forensic 2026-07-04 (false-landed-by-reset): several
  # features existed ONLY as staged bytes in ahead=0 worktrees; the old dry-run printed "WOULD PRUNE"
  # for them — an explicit invitation for a human to run the destructive removal. The dirty check now
  # gates BOTH modes so the report itself never mislabels staged-only work as prunable.
  _dirty="$(git -C "$_wt" status --porcelain 2>/dev/null | grep -vE '(^|[ /])\.claude-session-lock$' || true)"
  if [ -n "$_dirty" ]; then
    # F3-item3 backstop (2026-07-05): "commit-or-preserve" for STAGED-but-uncommitted work in a
    # merged + dead-session worktree — the exact false-landed-by-reset precursor (a
    # 2026-07-04 fleet-strand recovery had to hand-recover worktrees this way; no automatic
    # backstop existed). Never let staged bytes just sit here forever with no durable record:
    # checkpoint-commit them when this session's OWN gates already proved the work reviewed, else
    # leave a discoverable marker. Never prune in either branch (unchanged from the KEEP above) —
    # only fires under --apply (dry-run only ever REPORTS, mirroring the PRUNE/WOULD-PRUNE split).
    _staged="$(git -C "$_wt" diff --cached --name-only 2>/dev/null || true)"
    if [ -n "$_staged" ]; then
      _lk="$_wt/.claude-session-lock"
      _sid=""
      command -v _lock_sid >/dev/null 2>&1 && _sid=$(_lock_sid "$_lk" 2>/dev/null)
      # HIGH-fix (adversarial review 2026-07-05): COMMIT IS THE PRIVILEGE, PRESERVE IS THE DEFAULT.
      # The original check authorized the auto-commit by filename-glob EXISTENCE alone — never the
      # verdict, never freshness — and when the lock SID was unparseable it fell back to matching
      # ANY report in the dir, so a stale/foreign session's reports could authorize committing a
      # brand-new unreviewed diff. _gates_ok=1 now requires ALL of:
      #   (1) a parseable lock SID (no SID -> NEVER commit; degrade to the preserve path below),
      #   (2) SID-bound artifacts (PRE_FLIGHT_REPORT_*<sid>*.md + AGENT_REVIEW_*<sid>*.md — never
      #       an unbound glob),
      #   (3) verdict PARSED, not globbed: PRE_FLIGHT must carry 'Overall Status: PASS',
      #   (4) substance floor: both artifacts >=200B (the F4.2 strong-artifact/placeholder bar),
      #   (5) freshness: both artifact mtimes >= the newest staged file's mtime (they graded THIS
      #       diff, not an earlier one — the gauntlet-attest newest-write-vs-artifact convention).
      _gates_ok=0
      if [ -n "$_sid" ]; then
        _pf=""; _ar=""
        for _f in "$_wt"/PRE_FLIGHT_REPORT_*"${_sid}"*.md; do [ -f "$_f" ] && _pf="$_f"; done
        for _f in "$_wt"/AGENT_REVIEW_*"${_sid}"*.md;      do [ -f "$_f" ] && _ar="$_f"; done
        if [ -n "$_pf" ] && [ -n "$_ar" ] \
           && [ "$(wc -c < "$_pf" 2>/dev/null | tr -d ' ')" -ge 200 ] \
           && [ "$(wc -c < "$_ar" 2>/dev/null | tr -d ' ')" -ge 200 ] \
           && grep -qiE '^[[:space:]]*Overall Status:[[:space:]]*PASS' "$_pf" 2>/dev/null; then
          _newest_staged=0
          while IFS= read -r _sf; do
            [ -n "$_sf" ] && [ -f "$_wt/$_sf" ] || continue
            _m=$(stat -c %Y "$_wt/$_sf" 2>/dev/null || stat -f %m "$_wt/$_sf" 2>/dev/null || echo 0)
            [ "${_m:-0}" -gt "$_newest_staged" ] && _newest_staged="$_m"
          done <<< "$_staged"
          _pf_m=$(stat -c %Y "$_pf" 2>/dev/null || stat -f %m "$_pf" 2>/dev/null || echo 0)
          _ar_m=$(stat -c %Y "$_ar" 2>/dev/null || stat -f %m "$_ar" 2>/dev/null || echo 0)
          if [ "${_pf_m:-0}" -ge "$_newest_staged" ] && [ "${_ar_m:-0}" -ge "$_newest_staged" ]; then
            _gates_ok=1
          fi
        fi
      fi
      if [ "$_gates_ok" -eq 1 ]; then
        if [ "$APPLY" -eq 1 ]; then
          if git -C "$_wt" commit -q -m "checkpoint(${_br}): preserve staged-only session work found stranded in dead worktree (v-worktree-gc backstop)" >/dev/null 2>&1; then
            echo "COMMITTED — staged work checkpointed (dead session, gates already passed): $_wt [${_br}]"
          else
            echo "KEEP — DIRTY (checkpoint-commit attempt failed; inspect manually): $_wt  ⟶ inspect: git -C '$_wt' status"
          fi
        else
          echo "WOULD COMMIT — staged work + gates present (dead session; re-run with --apply to checkpoint): $_wt [${_br}]"
        fi
        _KEPT_OTHER=$((_KEPT_OTHER+1)); return
      fi
      # No QUALIFYING gate evidence for this SID (absent, FAIL/unparsed verdict, below the 200B
      # substance floor, staler than the staged writes, or the lock SID itself was unparseable) —
      # do NOT silently clear/lose it, and NEVER commit on ambiguity. Write a durable, discoverable
      # marker (idempotent — skip if one already exists) rather than leaving the debt invisible.
      if [ "$APPLY" -eq 1 ] && ! ls "$_wt"/STAGED_WORK_PRESERVED_*.md >/dev/null 2>&1; then
        _marker="$_wt/STAGED_WORK_PRESERVED_$(date +%s 2>/dev/null || echo 0).md"
        {
          printf '# Staged work preserved by v-worktree-gc backstop\n\n'
          printf 'Worktree: %s\nBranch: %s\nDetected: %s\nOwning session (from lock): %s\n\n' \
            "$_wt" "$_br" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "${_sid:-unknown}"
          printf 'This worktree'"'"'s branch is fully merged into %s, its owning session appears to\n' "$MAIN_BRANCH"
          printf 'have ended, and the working tree still holds STAGED-but-uncommitted changes. No\n'
          printf 'QUALIFYING PRE_FLIGHT_REPORT/AGENT_REVIEW gate evidence exists for this session\n'
          printf '(SID-bound + Overall Status: PASS + >=200B + newer than the staged writes), so this\n'
          printf 'backstop did NOT auto-commit — inspect and land manually:\n\nStaged files:\n'
          printf '%s\n' "$_staged" | sed 's/^/  - /'
          printf '\ngit -C '"'"'%s'"'"' status\ngit -C '"'"'%s'"'"' diff --cached\n' "$_wt" "$_wt"
        } > "$_marker" 2>/dev/null || true
        echo "PRESERVED — staged work marker written (dead session, no gate evidence): $_wt [${_br}] ⟶ $_marker"
      else
        echo "KEEP — DIRTY (staged, dead session, no gate evidence$([ "$APPLY" -eq 1 ] && echo ' — marker already present' || echo ' — marker would be written on --apply')): $_wt  ⟶ inspect: git -C '$_wt' status"
      fi
      _KEPT_OTHER=$((_KEPT_OTHER+1)); return
    fi
    echo "KEEP — DIRTY (branch reads merged but the tree holds uncommitted/untracked content; removal would DESTROY it — false-landed-by-reset shape): $_wt  ⟶ inspect: git -C '$_wt' status"
    _KEPT_OTHER=$((_KEPT_OTHER+1)); return
  fi
  if [ "$APPLY" -eq 1 ]; then
    # Clean tree confirmed: try the non-force remove first (it is the safe path); fall back to --force only
    # for git's non-dirtiness refusals (e.g. a stray gitdir lock) now that we KNOW the tree carries no work.
    if git -C "$REPO" worktree remove "$_wt" 2>/dev/null || git -C "$REPO" worktree remove --force "$_wt" 2>/dev/null; then
      echo "PRUNED (merged + done + clean): $_wt [${_br}]"; _PRUNED=$((_PRUNED+1))
    else
      echo "KEEP (merged + done + clean, but 'git worktree remove' failed): $_wt"; _KEPT_OTHER=$((_KEPT_OTHER+1))
    fi
  else
    echo "WOULD PRUNE (merged + done; re-run with --apply): $_wt [${_br}]"; _PRUNED=$((_PRUNED+1))
  fi
}

_wt=""; _br=""
while IFS= read -r _line; do
  case "$_line" in
    worktree\ *) _wt="${_line#worktree }"; _br="" ;;
    branch\ *)   _br="${_line#branch refs/heads/}" ;;
    "")          [ -n "$_wt" ] && [ "$_wt" != "$MAIN_ROOT" ] && _gc_one "$_wt" "$_br"; _wt=""; _br="" ;;
  esac
done < <(printf '%s\n\n' "$(git -C "$REPO" worktree list --porcelain 2>/dev/null)")

echo "── v-worktree-gc: $([ "$APPLY" -eq 1 ] && echo PRUNED || echo would-prune)=$_PRUNED  kept-unmerged=$_KEPT_UNMERGED  kept-active=$_KEPT_ACTIVE  kept-other=$_KEPT_OTHER"
exit 0
