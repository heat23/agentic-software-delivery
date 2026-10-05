#!/usr/bin/env bash
# v-bootstrap.sh — single-call orchestrator bootstrap (W14-3)
# Version: 2.0.0   ← W23 FND-19 follow-up: SID resolution via runtime file
#
# Combines into ONE bash invocation what Step 0/Step 2 previously did across
# 5-8 separate calls: SESSION_ID resolution, project root, session-start marker (into V_TMP_DIR),
# branch info, main-branch detection, dirty count, stack detection signals.
#
# v2 SID resolution: production logs (4 sessions, 2026-04-29) confirmed that
# `printf 'export CLAUDE_SESSION_ID=...'` from session-start-export-sid.sh v1
# is NOT sourced into the bash environment by Claude Code — stdout from a
# SessionStart hook becomes `additionalContext`, not env. So bootstrap saw
# empty SID every time. The v2 hook now persists the SID to a runtime file;
# this v2 bootstrap reads from that file as a fallback before declaring
# DETECTION_ERROR=session_id_unset_at_bootstrap.
#
# Output: key=value lines on stdout, all values printf-%q escaped (shell-safe).
# Parse via file (NEVER eval — values come from git/filesystem and could contain
# shell-interpretable characters in malicious repo paths):
#   bash references/v-bootstrap.sh > <V_TMP_DIR>/bootstrap-${CLAUDE_SESSION_ID:-$$}.env
#   while IFS='=' read -r key value; do printf '%s=%s\n' "$key" "$value"; done < "$V_TMP_DIR/bootstrap-${CLAUDE_SESSION_ID:-$$}.env"  # W18: repo-local .v/tmp
# DO NOT use `eval $(...)` — that's an RCE surface if PROJECT_ROOT or any value
# contains backticks, $(...), or other shell expansions.
#
# Exit code: always 0 (errors are reported as DETECTION_ERROR=<reason> lines).

set +e  # never abort the script — all detections are best-effort

# ---- Session ID ----
# W23 FND-19 follow-up: Claude Code's SessionStart hook stdout becomes
# additionalContext, NOT bash env. So `printf 'export CLAUDE_SESSION_ID=...'`
# from session-start-export-sid.sh v1 never reached us. As a fallback, read
# from the runtime file the v2 hook now writes on every SessionStart.
SESSION_ID="${CLAUDE_SESSION_ID:-}"
SID_SOURCE="env"

# W34 Layer 1: defensive mtime check on the runtime-file fallback.
#
# Production session (2026-05-02): bootstrap fell back to the runtime
# file because $CLAUDE_SESSION_ID was empty. The runtime file held a stale SID
# from a prior session, so all artifacts were filed under the wrong
# SID. The Stop hook then forced the orchestrator to fabricate replacement
# artifacts under the canonical SID — corrupting the audit trail.
#
# Defense: check the runtime file's mtime. If it's older than 2 hours, refuse
# to use it. The SessionStart hook (session-start-export-sid.sh) writes the
# fresh SID at every session start, so on a healthy session the file should
# be < 2 hours old (typically < 1 minute). Stale = SessionStart hook failed
# OR the user's session lifetime exceeded 2h with no resumes.
#
# We warn at 10 minutes and reject at 2 hours. Reject path emits a DETECTION
# _ERROR so /v fails loudly with a clear "restart Claude Code" remediation,
# rather than silently using the wrong SID.

_runtime_file="$HOME/.claude/runtime/current-session-id"
_runtime_age=""
if [ -f "$_runtime_file" ]; then
  _now=$(date +%s)
  _mtime=$(stat -c %Y "$_runtime_file" 2>/dev/null || stat -f %m "$_runtime_file" 2>/dev/null || echo 0)
  _runtime_age=$(( _now - _mtime ))
fi

if [ -z "$SESSION_ID" ] && [ -f "$_runtime_file" ]; then
  # Reject if older than 2 hours (7200 sec).
  if [ -n "$_runtime_age" ] && [ "$_runtime_age" -gt 7200 ]; then
    printf 'DETECTION_ERROR=%q\n' "stale_runtime_file_${_runtime_age}s"
    printf 'SESSION_ID=%q\n' ""
    printf 'SID_SOURCE=%q\n' "stale_runtime_file_rejected"
    printf 'REMEDIATION=%q\n' "Restart Claude Code session: SessionStart hook may have failed or runtime file is from a prior session. After restart, ~/.claude/runtime/current-session-id will be refreshed."
    exit 1
  fi
  CANDIDATE=$(tr -d '[:space:]' < "$_runtime_file" 2>/dev/null || true)
  # Only accept canonical UUID shape — reject empty file, stale garbage, or
  # accidental writes from other tooling. Length=36 with hyphens at 8/13/18/23.
  if echo "$CANDIDATE" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    SESSION_ID="$CANDIDATE"
    SID_SOURCE="runtime_file"
    # Warn (advisory only) if 10 min < age <= 2h.
    if [ -n "$_runtime_age" ] && [ "$_runtime_age" -gt 600 ]; then
      printf 'WARNING=%q\n' "runtime_file_${_runtime_age}s_old_proceeding_anyway"
    fi
  fi
fi

case "$SESSION_ID" in
  ""|"not-set")
    # Don't silently synthesize — downstream Stop hook validates against $CLAUDE_SESSION_ID
    # and will reject artifacts named with a fallback ID. Emit a structured error so the
    # orchestrator can decide whether to abort or proceed with a known-broken session.
    printf 'DETECTION_ERROR=%q\n' "session_id_unset_at_bootstrap"
    printf 'SESSION_ID=%q\n' ""
    printf 'SID_SOURCE=%q\n' "none"
    ;;
  *)
    printf 'SESSION_ID=%q\n' "$SESSION_ID"
    printf 'SID_SOURCE=%q\n' "$SID_SOURCE"
    # Also export into our own env so anything we shell out to within this
    # script inherits it. (Does NOT carry over to subsequent Bash tool calls;
    # the orchestrator must re-resolve the SID per-invocation via the same
    # runtime-file fallback. Step 0 documents this in /v SKILL.md.)
    export CLAUDE_SESSION_ID="$SESSION_ID"
    ;;
esac

# ---- Concurrency start-claim (HANDOFF 2026-06-28) — race-free parallel-session detection ----
# Drop a claim marker the MOMENT the SID is known — BEFORE the parallel scan below and BEFORE any
# scope classification — so a simultaneously-launched fleet has every session's claim on disk before
# anyone decides "solo." This is the fix for the startup race in worktree-lock-only sibling detection:
# a worktree lock only appears AFTER a session has created its worktree, so at simultaneous launch each
# session saw no sibling and the inline-eligible paths (Maintenance <=3 files / read-only / worktree-
# setup-failure fallback) all proceeded inline on shared main -> contamination. A claim is
# detectable immediately, INLINE sessions included. Writing it here (earliest safe point after SID
# resolution, ~70 lines ahead of the scan) maximizes the window in which a sibling's later scan will
# see it. FAIL-SAFE: a claim-write failure must NEVER break bootstrap (mkdir/write are `|| true`) — and
# if it fails, _CLAIM_WRITTEN stays 0 so the scan below force-isolates us (SREV-001): a session whose
# own claim is missing cannot be seen by siblings, so it must take a worktree rather than risk main.
_CLAIM_WRITTEN=0
if [ -n "$SESSION_ID" ]; then
  _CLAIM_DIR="$HOME/.claude/runtime"
  mkdir -p "$_CLAIM_DIR" 2>/dev/null || true
  if : > "$_CLAIM_DIR/v-session-claim-${SESSION_ID}" 2>/dev/null; then _CLAIM_WRITTEN=1; fi
fi

# Session-start marker is written below, after V_TMP_DIR is available (W18+W19 FND-1).

# ---- Project root ----
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
printf 'PROJECT_ROOT=%q\n' "$PROJECT_ROOT"

# W43-N2: refuse to bootstrap outside a git repo OR at $HOME. A production
# session was launched from $HOME directly, bootstrap silently
# resolved PROJECT_ROOT=$HOME with CURRENT_BRANCH=unknown, END_SHA=unknown.
# Subsequent /v steps pretended to work but the agent had to manually `cd`
# into the actual project to do anything. Better to fail loud at Step 0.
if ! git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'DETECTION_ERROR=%q\n' "not_inside_git_repo"
  printf 'REMEDIATION=%q\n' "cd into a git repository before invoking /v. Bootstrap resolved PROJECT_ROOT=$PROJECT_ROOT, but no git repository was found there. /v requires a repo to scope changes, run gates, and write artifacts."
  echo "BOOTSTRAP_DONE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit 1
fi
# Refuse if PROJECT_ROOT is the user's HOME (extremely common confusion when
# /v is invoked from a fresh terminal). Allow override via V_ALLOW_HOME_REPO=1
# for the rare case the user genuinely wants to operate on a repo at $HOME.
if [ "$PROJECT_ROOT" = "$HOME" ] && [ "${V_ALLOW_HOME_REPO:-0}" != "1" ]; then
  printf 'DETECTION_ERROR=%q\n' "project_root_equals_home"
  printf 'REMEDIATION=%q\n' "PROJECT_ROOT==\$HOME ($HOME). This is almost always a mistake — /v was probably invoked from the wrong directory. cd into the actual project repo and retry. To override (operating on a repo that genuinely lives at \$HOME), set V_ALLOW_HOME_REPO=1."
  echo "BOOTSTRAP_DONE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit 1
fi

# ---- W18: V_TMP_DIR — repo-local transient directory (no /tmp pollution) ----
# All /v transient files go here: dispatch prompts, gate logs, session-writes log,
# merge-resolve log, bootstrap output, commit messages, etc.
# A self-ignoring .gitignore keeps the contents out of git while preserving the
# directory itself for parallel sessions and tooling.
V_TMP_DIR="$PROJECT_ROOT/.v/tmp"
# Sec-FND-5: refuse to use .v/ if it's a symlink (could redirect writes outside repo).
if [ -L "$PROJECT_ROOT/.v" ]; then
  printf 'DETECTION_ERROR=%q\n' "v_directory_is_symlink_at_$PROJECT_ROOT/.v"
  printf 'V_TMP_DIR=%q\n' ""
  echo "BOOTSTRAP_DONE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit 0
fi
mkdir -p "$V_TMP_DIR" 2>/dev/null
# UX-FND-2: ensure .worktrees/ is also gitignored. Self-ignore pattern same as .v/.
if [ ! -f "$PROJECT_ROOT/.worktrees/.gitignore" ] && { mkdir -p "$PROJECT_ROOT/.worktrees" 2>/dev/null; }; then
  cat > "$PROJECT_ROOT/.worktrees/.gitignore" 2>/dev/null <<'WT_GITIGNORE_EOF' || true
# /v worktree directory — each subdirectory is either a git worktree or a compatibility
# symlink → ~/.claude/worktrees/<repo-slug>/<name>/ (C4: external canonical path, fixes
# Pest P\worktrees\fix\... namespace collision). Nothing here is committed.
*
!.gitignore
WT_GITIGNORE_EOF
fi

# C4: external worktrees base — canonical path is outside the repo to eliminate the
# Pest namespace collision (P\worktrees\fix\...) and cross-session sibling visibility.
# The symlink at $PROJECT_ROOT/.worktrees/<name> → external path keeps all existing
# hooks (which glob $REPO_ROOT/.worktrees/*/.*) working without modification.
# <repo-slug> derived from the directory name so cross-project isolation is automatic.
_WT_SLUG=$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
WORKTREES_EXTERNAL_BASE="$HOME/.claude/worktrees/${_WT_SLUG}"
mkdir -p "$WORKTREES_EXTERNAL_BASE" 2>/dev/null || true
printf 'WORKTREES_EXTERNAL_BASE=%q\n' "$WORKTREES_EXTERNAL_BASE"
printf 'WORKTREES_REPO_SLUG=%q\n' "$_WT_SLUG"

# C5: scan for concurrently-active worktree sessions at bootstrap time.
# Other sessions write ~/.claude/runtime/active-worktree-<SID> when they create a
# worktree; scanning for non-self markers detects parallel sessions (C1: commit
# attribution is then scoped to the worktree branch, not live HEAD).
PARALLEL_SESSIONS_DETECTED=0
PARALLEL_SESSION_SIDS=""
# Fail-safe (SREV-001): if we have a SID but could NOT write our own start-claim (full disk / perms),
# siblings cannot see us — so isolate OURSELVES (force a worktree) rather than risk running inline on a
# main another session may also be editing. Over-isolation is cheap; contamination is not.
if [ -n "$SESSION_ID" ] && [ "${_CLAIM_WRITTEN:-0}" != "1" ]; then
  PARALLEL_SESSIONS_DETECTED=1
fi
if [ -n "$SESSION_ID" ]; then
  _RUNTIME_DIR="$HOME/.claude/runtime"
  _now_wt=$(date +%s 2>/dev/null || echo 0)
  for _marker in "$_RUNTIME_DIR"/active-worktree-*; do
    [ -f "$_marker" ] || continue
    _marker_sid=$(basename "$_marker" | sed 's/^active-worktree-//')
    [ "$_marker_sid" = "$SESSION_ID" ] && continue  # skip self
    # TTL: discard markers older than 8 hours (stale crashed sessions)
    _mt=$(stat -c %Y "$_marker" 2>/dev/null || stat -f %m "$_marker" 2>/dev/null || echo 0)
    if [ "$(( _now_wt - _mt ))" -lt 28800 ]; then
      PARALLEL_SESSIONS_DETECTED=1
      PARALLEL_SESSION_SIDS="${PARALLEL_SESSION_SIDS} ${_marker_sid}"
    fi
  done

  # ---- Claim-based detection (HANDOFF 2026-06-28) ----
  # The active-worktree markers above only appear AFTER a sibling has created its worktree, so a
  # simultaneously-launched fleet is invisible to them at decision time. The start-claim each session
  # drops at bootstrap (above, ~70 lines earlier) IS visible immediately. Source the shared
  # transcript-liveness primitive to tell a still-running sibling from a crashed one — works for INLINE
  # siblings too (no worktree lock needed). Resolve the lib relative to THIS script first (so a test
  # driving the real bootstrap under an overridden $HOME still loads the real lib), then the canonical
  # install path. Sourcing failure must NOT break bootstrap (fail-safe).
  _BOOT_SRC="${BASH_SOURCE[0]:-$0}"
  _BOOT_DIR=$(cd "$(dirname "$_BOOT_SRC")" 2>/dev/null && pwd)
  for _cand in "$_BOOT_DIR/../../../hooks/lib/session-liveness.sh" \
               "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/session-liveness.sh" \
               "$HOME/.claude/hooks/lib/session-liveness.sh"; do
    if [ -n "$_cand" ] && [ -f "$_cand" ]; then . "$_cand" 2>/dev/null || true; break; fi
  done

  for _claim in "$_RUNTIME_DIR"/v-session-claim-*; do
    [ -f "$_claim" ] || continue
    _claim_sid=$(basename "$_claim" | sed 's/^v-session-claim-//')
    [ "$_claim_sid" = "$SESSION_ID" ] && continue   # skip self
    # Reject non-UUID claim names (manual artifacts / test debris) — without this guard a stray file
    # like `v-session-claim-test-c4-sid` would force PARALLEL detection for every session until it aged
    # out (SREV-004). Case-INSENSITIVE (`-i`, pass-2 SREV-001): the env-var SID path is NOT lowercased,
    # so an (unusual) upper-case-hex SID's claim must still match here — else it would be invisible to
    # siblings and that session could run inline despite live siblings. Same UUID shape as L77.
    echo "$_claim_sid" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || continue
    # Already counted via an active-worktree marker above? skip (dedupe).
    case " $PARALLEL_SESSION_SIDS " in *" $_claim_sid "*) continue ;; esac
    # Claim file's own age (fallback liveness when no transcript is resolvable). Do NOT coerce a stat
    # failure to epoch 0 (SREV-002 / logic-MED): a ~1.7e9 bogus age would BOTH miss a live sibling in
    # the rc=2 path AND trip the GC and delete a valid claim. Leave _claim_age EMPTY on failure and fail
    # SAFE below (unknown age -> live, never GC). Clamp a clock-skew negative to 0.
    _cmt=$(stat -c %Y "$_claim" 2>/dev/null || stat -f %m "$_claim" 2>/dev/null)
    if [ -n "$_cmt" ]; then _claim_age=$(( _now_wt - _cmt )); [ "$_claim_age" -lt 0 ] && _claim_age=0; else _claim_age=""; fi
    # Tri-state liveness: prefer transcript (works for inline siblings). rc=2 (no transcript) falls back
    # to the claim-file mtime TTL — inclusive `-le`, matching is_session_live's boundary. Fail-safe: ANY
    # ambiguity (no transcript with unknown claim age, or helper unavailable) resolves toward LIVE.
    _live=0; _rc=2
    if command -v is_session_live >/dev/null 2>&1; then
      is_session_live "$_claim_sid"; _rc=$?
    fi
    case "$_rc" in
      0) _live=1 ;;                                                              # transcript fresh -> live
      1) _live=0 ;;                                                              # transcript stale -> dead
      *) if [ -z "$_claim_age" ] || [ "$_claim_age" -le "${V_SESSION_LIVENESS_WINDOW_SEC:-2700}" ]; then _live=1; else _live=0; fi ;;  # no transcript -> claim TTL (unknown age -> live)
    esac
    if [ "$_live" = "1" ]; then
      PARALLEL_SESSIONS_DETECTED=1
      PARALLEL_SESSION_SIDS="${PARALLEL_SESSION_SIDS} ${_claim_sid}"
    elif [ -n "$_claim_age" ] && [ "$_claim_age" -ge "${V_SESSION_CLAIM_GC_SEC:-28800}" ]; then
      # Self-healing GC of an ANCIENT (>=8h) dead claim. Threshold DECOUPLED from the 45-min liveness
      # window (8h matches the active-worktree TTL above): a session can go quiet longer than the window
      # mid-run (a multi-minute dispatch appends nothing to the parent transcript) and then resume, so
      # GC'ing at the window would delete a merely-idle LIVE session's claim -> under-isolation. Never GC
      # when the age is unknown (stat failed -> empty). Re-verify NOT-live IMMEDIATELY before unlinking to
      # shrink the TOCTOU window where the owner resumes between the first liveness read and the rm
      # (SREV-002). At >=8h, BOTH rc 1 (stale transcript) AND rc 2 (no transcript at all) mean abandoned,
      # so delete on any rc != 0; only a resumed session reading rc 0 (fresh transcript) is kept. Best-effort.
      if command -v is_session_live >/dev/null 2>&1; then
        is_session_live "$_claim_sid"; _gc_rc=$?
        [ "$_gc_rc" -ne 0 ] && rm -f "$_claim" 2>/dev/null || true
      fi
    fi
  done
fi
printf 'PARALLEL_SESSIONS_DETECTED=%q\n' "$PARALLEL_SESSIONS_DETECTED"
if [ "$PARALLEL_SESSIONS_DETECTED" = "1" ]; then
  printf 'PARALLEL_SESSION_SIDS=%q\n' "${PARALLEL_SESSION_SIDS# }"
fi
# Write self-ignoring .gitignore on first use (idempotent — only writes if absent)
if [ ! -f "$PROJECT_ROOT/.v/.gitignore" ]; then
  cat > "$PROJECT_ROOT/.v/.gitignore" 2>/dev/null <<'GITIGNORE_EOF' || true
# /v orchestrator transient directory — all contents are session-scoped temp files.
# This file itself is the only tracked content; everything else is ignored.
*
!.gitignore
GITIGNORE_EOF
fi
# Verify writability — write a probe file to detect read-only filesystems
if [ ! -d "$V_TMP_DIR" ] || ! touch "$V_TMP_DIR/.write-probe" 2>/dev/null; then
  printf 'DETECTION_ERROR=%q\n' "v_tmp_dir_unwritable_at_$V_TMP_DIR"
  printf 'V_TMP_DIR=%q\n' ""
else
  rm -f "$V_TMP_DIR/.write-probe"
  printf 'V_TMP_DIR=%q\n' "$V_TMP_DIR"
fi

# ---- W18+W19 FND-1: session-start marker, written into V_TMP_DIR (NOT /tmp) ----
# Skipping when SID is empty avoids creating session-start-.txt orphans.
if [ -n "$SESSION_ID" ] && [ -n "$V_TMP_DIR" ] && [ -d "$V_TMP_DIR" ]; then
  START_MARKER="$V_TMP_DIR/session-start-${SESSION_ID}.txt"
  if [ ! -f "$START_MARKER" ]; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "$START_MARKER" 2>/dev/null
    echo "SESSION_START_MARKER_WRITTEN=true"
  else
    echo "SESSION_START_MARKER_WRITTEN=false"
  fi
  printf 'SESSION_START_ISO=%q\n' "$(cat "$START_MARKER" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

  # N4 (2026-06-01): write head-baseline-<SID>.txt with the current HEAD SHA so the session-log
  # generator can ground project.base_sha against session-start HEAD rather than log-time
  # merge-base (which drifts after merge-back). Written once (idempotent: only if missing).
  # DISPATCH_PROMPT.md C1 reads this file; without the write it always falls back to merge_base.
  _HB_FILE="$V_TMP_DIR/head-baseline-${SESSION_ID}.txt"
  if [ ! -f "$_HB_FILE" ]; then
    _HEAD_AT_START="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$_HEAD_AT_START" ]; then
      printf '%s\n' "$_HEAD_AT_START" > "$_HB_FILE" 2>/dev/null
    fi
  fi
  # CANARY-A-rest (DUC-002, forensic 2026-06-22): the .v/tmp copies above are swept by a concurrent sibling's
  # worktree teardown / git clean before /v-session-log runs -> base_sha=null + sibling-contaminated commit
  # attribution. Mirror head-baseline + session-start into the DURABLE .v/artifacts on the MAIN root (resolved
  # explicitly — from a worktree CWD, PROJECT_ROOT may be the worktree, which is torn down). The session-log
  # gather's head-baseline/commit-witness resolution now searches .v/artifacts.
  _BS_MAIN=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)
  _BS_ART="${_BS_MAIN:-$PROJECT_ROOT}/.v/artifacts"
  if mkdir -p "$_BS_ART" 2>/dev/null; then
    [ -f "$_HB_FILE" ] && cp -p "$_HB_FILE" "$_BS_ART/head-baseline-${SESSION_ID}.txt" 2>/dev/null || true
    [ -f "$START_MARKER" ] && cp -p "$START_MARKER" "$_BS_ART/session-start-${SESSION_ID}.txt" 2>/dev/null || true
  fi

  # Bug 6 (2026-07-01, folded from SKILL.md Step 0): per-INVOCATION start marker — UNCONDITIONAL
  # overwrite every bootstrap run (session-start above is write-once; a same-SID second /v invocation
  # must not inherit the first invocation's freshness baseline). v-gauntlet-attest.sh and
  # check-review-artifact.sh compare every gauntlet artifact + completion marker against THIS file.
  # Filename SID is LOWERCASED to mirror the readers' SESSION_ID_LC resolution; a non-UUID SID skips
  # the write (readers only look for UUID-named files) and reports degraded so the orchestrator sees it.
  _SID_LC=$(printf '%s' "$SESSION_ID" | tr '[:upper:]' '[:lower:]')
  # === P2-SID-COLLISION (2026-07-03, forensic N5) ===
  # One interactive terminal ran TWO unrelated /v tasks under one SID:
  # every per-SID artifact became a 2-task HYBRID (files_changed mixing both diffs), validate-log
  # true-blocked, and a false-green log claimed a sibling task done. Detect the reuse HERE, at the
  # second invocation's bootstrap: a prior invocation marker + a COMPLETION artifact for this SID
  # (VERIFY_DONE / QA / TRIVIAL_PASS — proof task #1 finished its lifecycle) means this is a NEW
  # task under a used-up SID. REFUSE loudly (namespace-minting would require every per-SID consumer
  # to learn the new name — refusal is the safe, tractable arm the synthesis allows). Durable
  # SID_COLLISION_<sid>.md marker survives even if the orchestrator ignores stdout.
  # Dial: V_SID_COLLISION_GUARD=0 disables. Bite: p2-sid-collision-test.sh.
  if [ "${V_SID_COLLISION_GUARD:-1}" = "1" ] \
     && [ -f "$V_TMP_DIR/v-invocation-start-${_SID_LC}.txt" ]; then
    _P2_PRIOR_DONE=""
    # Review L#8: search the MAIN root's artifact surface too, not just $PWD — a bootstrap running
    # from a worktree (or vice versa) would otherwise under-detect the very reuse it exists to catch.
    _P2_MAIN_ROOT="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)"
    for _p2d in "$PWD" "$PWD/.v/artifacts" ${_P2_MAIN_ROOT:+"$_P2_MAIN_ROOT" "$_P2_MAIN_ROOT/.v/artifacts"}; do
      for _p2p in VERIFY_DONE_REPORT QA_REPORT TRIVIAL_PASS; do
        [ -f "${_p2d}/${_p2p}_${SESSION_ID}.md" ] && { _P2_PRIOR_DONE="${_p2d}/${_p2p}_${SESSION_ID}.md"; break 2; }
      done
    done
    if [ -n "$_P2_PRIOR_DONE" ]; then
      echo "SID_COLLISION=detected"
      echo "SID_COLLISION_EVIDENCE=$_P2_PRIOR_DONE"
      { echo "# SID collision — ${SESSION_ID}"
        echo ""
        echo "A /v invocation started under a SID whose previous task already completed (evidence: ${_P2_PRIOR_DONE}). If the new work is an UNRELATED task, proceeding makes every per-SID artifact a two-task hybrid (an observed false-PASS). Directive given: refuse unrelated tasks; same-task follow-up remediation may proceed (its regenerated artifacts supersede the completed set for the same scope)."
      } > "$PWD/SID_COLLISION_${SESSION_ID}.md" 2>/dev/null || true
      # Review L#7/CDX-4: an unconditional STOP false-refused the ROUTINE case — "QA found a bug,
      # fix it" in the same terminal. The directive now discriminates: same-task follow-up
      # remediation proceeds (its re-run gauntlet REGENERATES the per-SID artifacts for the same
      # scope — no hybrid); an UNRELATED new task must refuse. The durable marker + the session-log
      # validator (which true-blocked the observed hybrid) remain the mechanical backstop.
      echo "SID_COLLISION_DIRECTIVE=CHECK BEFORE PROCEEDING. A previous /v task already COMPLETED under this session id. If the current request is a FOLLOW-UP to that same task (remediation, review findings, 'fix what you just shipped'), PROCEED — your fresh gauntlet run regenerates the per-SID artifacts for the same scope. If it is a NEW, UNRELATED task: STOP and tell the operator to run it in a NEW terminal session (fresh SID) or via run-v-packs — per-SID artifacts would become a two-task hybrid and produce a false-PASS (observed in a prior session). State which case applies in your first response sentence."
    fi
  fi
  # === end P2-SID-COLLISION ===
  if printf '%s' "$_SID_LC" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    if date -u +%s > "$V_TMP_DIR/v-invocation-start-${_SID_LC}.txt" 2>/dev/null; then
      echo "INVOCATION_MARKER_WRITTEN=true"
    else
      echo "INVOCATION_MARKER_WRITTEN=degraded_write_failed"
    fi
  else
    echo "INVOCATION_MARKER_WRITTEN=degraded_invalid_sid"
  fi
else
  echo "SESSION_START_MARKER_WRITTEN=skipped_no_v_tmp_dir_or_empty_sid"
  printf 'SESSION_START_ISO=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

# ---- Branch info ----
CURRENT_BRANCH="$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo unknown)"
printf 'CURRENT_BRANCH=%q\n' "$CURRENT_BRANCH"

END_SHA="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
printf 'END_SHA=%q\n' "$END_SHA"

# ---- Main branch (env override → origin/HEAD → main → master → develop) ----
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-}"
if [ -z "$MAIN_BRANCH" ]; then
  MAIN_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
fi
[ -z "$MAIN_BRANCH" ] && MAIN_BRANCH="main"
if ! git -C "$PROJECT_ROOT" rev-parse --verify "$MAIN_BRANCH" >/dev/null 2>&1; then
  for cand in main master develop; do
    if git -C "$PROJECT_ROOT" rev-parse --verify "$cand" >/dev/null 2>&1; then
      MAIN_BRANCH="$cand"
      break
    fi
  done
fi
printf 'MAIN_BRANCH=%q\n' "$MAIN_BRANCH"

BASE_SHA="$(git -C "$PROJECT_ROOT" merge-base "$MAIN_BRANCH" HEAD 2>/dev/null || echo "")"
printf 'BASE_SHA=%q\n' "$BASE_SHA"

# W22-3 / FND-4 (2026-07-01, folded from SKILL.md Step 0): capture main HEAD at session start so
# Step 6.-1 can detect mid-session main advancement. Refresh when the capture is missing, the
# session-start marker is missing (cannot prove freshness — original SHOULD_CAPTURE=true default),
# or the capture predates this session's start marker (stale prior-session file). A same-session
# re-invocation keeps the first capture (file newer than session start).
if [ -n "$SESSION_ID" ] && [ -n "$V_TMP_DIR" ] && [ -d "$V_TMP_DIR" ]; then
  _MH_FILE="$V_TMP_DIR/main-head-at-start-${SESSION_ID}.txt"
  _SS_MARKER="$V_TMP_DIR/session-start-${SESSION_ID}.txt"
  if [ ! -f "$_MH_FILE" ] || [ ! -f "$_SS_MARKER" ] || [ "$_MH_FILE" -ot "$_SS_MARKER" ]; then
    git -C "$PROJECT_ROOT" rev-parse "refs/heads/$MAIN_BRANCH" > "$_MH_FILE" 2>/dev/null || true
  fi
  printf 'MAIN_HEAD_AT_START=%q\n' "$(cat "$_MH_FILE" 2>/dev/null || echo "")"
fi

# ---- Dirty count (untracked + modified + staged) ----
# W40-A: was `grep -c . ... || echo "0"`. When the input had zero lines,
# grep -c emitted "0" THEN exited 1, triggering the `|| echo "0"` which
# appended a SECOND "0" — producing DIRTY_COUNT=$'0\n0' (two-line string,
# not an integer). wc -l always exits 0 and always emits a single integer;
# tr -d ' ' strips macOS BSD `wc`'s leading whitespace. No fallback needed.
# W45-A: dual-source cross-check. Production observed DIRTY_COUNT=0 when
# the tree had 30+ dirty files — the diff/ls-files pipeline can return
# empty when git is locked, when cwd races against PROJECT_ROOT resolution,
# or when an internal git error swallows output. Compute the count two
# different ways and emit a warning if they disagree, so the orchestrator
# never silently trusts a false-zero.
#
# Source 1: union of diff/staged/untracked file lists (what we had before).
DIRTY_COUNT_DIFF=$( {
  git -C "$PROJECT_ROOT" diff --name-only HEAD 2>/dev/null
  git -C "$PROJECT_ROOT" diff --cached --name-only 2>/dev/null
  git -C "$PROJECT_ROOT" ls-files --others --exclude-standard 2>/dev/null
} | sort -u | wc -l | tr -d ' ')
DIRTY_COUNT_DIFF=${DIRTY_COUNT_DIFF:-0}

# Source 2: git status --porcelain, completely independent code path.
DIRTY_COUNT_PORCELAIN=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
DIRTY_COUNT_PORCELAIN=${DIRTY_COUNT_PORCELAIN:-0}

# Use the higher of the two as the canonical value (more conservative —
# never under-report). Emit DIRTY_COUNT_DISAGREEMENT when they differ
# materially so the orchestrator knows the count may be unreliable.
if [ "$DIRTY_COUNT_DIFF" -ge "$DIRTY_COUNT_PORCELAIN" ] 2>/dev/null; then
  DIRTY_COUNT="$DIRTY_COUNT_DIFF"
else
  DIRTY_COUNT="$DIRTY_COUNT_PORCELAIN"
fi
printf 'DIRTY_COUNT=%q\n' "$DIRTY_COUNT"

# Surface disagreement so the orchestrator can spot a flaky git probe.
if [ "$DIRTY_COUNT_DIFF" != "$DIRTY_COUNT_PORCELAIN" ]; then
  printf 'DIRTY_COUNT_DISAGREEMENT=%q\n' "diff_source=${DIRTY_COUNT_DIFF},porcelain_source=${DIRTY_COUNT_PORCELAIN}"
  printf 'WARNING=%q\n' "DIRTY_COUNT sources disagree (diff=${DIRTY_COUNT_DIFF}, porcelain=${DIRTY_COUNT_PORCELAIN}); using higher value. Possible: git lock, permission issue, race with another git process."
fi

# ---- Worktree detection ----
ACTIVE_WORKTREES=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')
[ -z "$ACTIVE_WORKTREES" ] && ACTIVE_WORKTREES="unknown"
printf 'ACTIVE_WORKTREES=%q\n' "$ACTIVE_WORKTREES"

# ---- Sibling SCOPE visibility (W-conc-scope): file-set, not just count ----
# The bare ACTIVE_WORKTREES count tells the orchestrator that OTHER sessions exist,
# but not WHAT they're touching — so two sessions can edit the same files and only
# discover it at merge time (the duplicate-work collision observed 2026-05-26, where
# two sessions independently fixed the same file). We emit each non-self sibling
# worktree's changed-file set (committed diff vs merge-base ∪ working-tree status)
# so the orchestrator can compare against its OWN planned files at Step 2a and warn
# the operator BEFORE editing. Read-only + advisory: best-effort, capped, never blocks.
_SIB_N=0
_PR_REAL=$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P || echo "$PROJECT_ROOT")
while IFS= read -r _wt; do
  [ -n "$_wt" ] || continue
  # Skip the main checkout. Compare realpaths (pwd -P) so a symlinked PROJECT_ROOT
  # still excludes it — otherwise main's own diff could be advertised as a sibling.
  [ "$(cd "$_wt" 2>/dev/null && pwd -P || echo "$_wt")" = "$_PR_REAL" ] && continue
  git -C "$_wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  _wb=$(git -C "$_wt" branch --show-current 2>/dev/null || echo "")
  [ -n "$SESSION_ID" ] && case "$_wb" in *"$SESSION_ID"*) continue ;; esac   # our own worktree
  _mb=$(git -C "$_wt" merge-base "$MAIN_BRANCH" HEAD 2>/dev/null || echo "")
  _sf=$( {
    [ -n "$_mb" ] && git -C "$_wt" diff --name-only "${_mb}..HEAD" 2>/dev/null
    git -C "$_wt" status --porcelain 2>/dev/null | sed -e 's/^...//' -e 's/^"//' -e 's/"$//' -e 's/.* -> //'
  } | sort -u | grep -v '^[[:space:]]*$' | grep -v '\.claude-session-lock$' | head -50 | tr '\n' ',' )
  [ -n "$_sf" ] || continue
  _SIB_N=$((_SIB_N + 1))
  printf 'SIBLING_SCOPE_%s=%q\n' "$_SIB_N" "branch=${_wb:-?} files=${_sf%,}"
done < <(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
if [ "$_SIB_N" -gt 0 ]; then
  printf 'SIBLING_SCOPE_COUNT=%q\n' "$_SIB_N"
  printf 'SIBLING_SCOPE_NOTE=%q\n' "Compare these file sets against your planned changes (Step 2a). Overlap ⇒ another session is editing the same files; warn the operator and consider /v-merge-all or deferring rather than duplicating work."
fi

# ---- Stack detection signals ----
STACK_SIGNALS=""
[ -f "$PROJECT_ROOT/composer.json" ] && STACK_SIGNALS="${STACK_SIGNALS}php,"
[ -f "$PROJECT_ROOT/package.json" ]  && STACK_SIGNALS="${STACK_SIGNALS}js,"
[ -f "$PROJECT_ROOT/pyproject.toml" ] && STACK_SIGNALS="${STACK_SIGNALS}python,"
[ -f "$PROJECT_ROOT/Cargo.toml" ]    && STACK_SIGNALS="${STACK_SIGNALS}rust,"
[ -f "$PROJECT_ROOT/go.mod" ]        && STACK_SIGNALS="${STACK_SIGNALS}go,"
[ -f "$PROJECT_ROOT/Gemfile" ]       && STACK_SIGNALS="${STACK_SIGNALS}ruby,"
echo "STACK_SIGNALS=${STACK_SIGNALS%,}"

# Framework hints (cheap grep, no jq)
[ -f "$PROJECT_ROOT/composer.json" ] && grep -q '"laravel/framework"' "$PROJECT_ROOT/composer.json" 2>/dev/null && echo "PHP_FRAMEWORK=laravel"
[ -f "$PROJECT_ROOT/package.json" ] && {
  if grep -q '"next"' "$PROJECT_ROOT/package.json"; then echo "JS_FRAMEWORK=nextjs"
  elif grep -q '@sveltejs/kit' "$PROJECT_ROOT/package.json"; then echo "JS_FRAMEWORK=sveltekit"
  elif grep -q '"nuxt"' "$PROJECT_ROOT/package.json"; then echo "JS_FRAMEWORK=nuxt"
  elif grep -q '"@inertiajs/' "$PROJECT_ROOT/package.json"; then echo "JS_FRAMEWORK=inertia"
  elif grep -q '"react"' "$PROJECT_ROOT/package.json"; then echo "JS_FRAMEWORK=react"
  elif grep -q '"vue"' "$PROJECT_ROOT/package.json"; then echo "JS_FRAMEWORK=vue"
  fi
}

# ---- CLAUDE.md presence (orchestrator decides whether to read it) ----
[ -f "$PROJECT_ROOT/CLAUDE.md" ] && echo "CLAUDE_MD_PRESENT=true" || echo "CLAUDE_MD_PRESENT=false"

# ---- W22 FND-7: validation.sh prereq check ----
# /v Step 0 documents that validation.sh must accept Model: (haiku|sonnet|opus). If the
# user's local validator still has the strict `Model: haiku` literal check, sonnet/opus
# reviews (W13 tiering) will hit opaque hook-block errors. Detect and emit a soft warning.
VALIDATION_SH="$HOME/.claude/hooks/lib/validation.sh"
if [ -f "$VALIDATION_SH" ]; then
  if grep -qE "Model: \(haiku\|sonnet\|opus\)" "$VALIDATION_SH" 2>/dev/null; then
    echo "VALIDATION_SH_PREREQ=ok"
  else
    # Stale validator detected — emit warning, not DETECTION_ERROR (sessions
    # using haiku-only review still work; only hostile/billing reviews break).
    echo "VALIDATION_SH_PREREQ=stale_haiku_only"
    echo "WARN: $VALIDATION_SH appears to enforce 'Model: haiku' literal" >&2
    echo "WARN: hostile/billing sessions (W13 sonnet/opus tiering) may hit stop-hook blocks" >&2
    echo "WARN: see /v SKILL.md § Runtime Prerequisites — Prereq 2 for the regex update" >&2
  fi
else
  # No validator found — warn but don't block.
  echo "VALIDATION_SH_PREREQ=not_found"
fi

# ---- Done ----
echo "BOOTSTRAP_DONE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit 0
