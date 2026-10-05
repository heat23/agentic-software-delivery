#!/usr/bin/env bash
# SessionStart hook: Validates environment requirements and injects worktree context.
# Checks: jq installed, hook scripts executable, hook versions match expectations.
# Also: detects parallel sessions, large uncommitted diffs, and advises on worktree isolation.
# Returns: additionalContext with active worktree info (if any) for Claude's context.
# Version: 2.0.0
#
# Exit 0 = success. JSON on stdout with additionalContext. Warnings on stderr.

set -euo pipefail

# P0 safety gate: stop session start if jq is missing.
# Without jq the entire hook safety layer silently fails open.

# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
source "$HOOKS_LIB_DIR/v-tmp-dir.sh"
require_jq_or_stop_session
source "$HOOKS_LIB_DIR/constants.sh"
# W77: canonical SID resolver (env + runtime-file fallback + stdin JSON)
source "$HOME/.claude/hooks/lib/resolve-sid.sh"

HOOKS_DIR="${HOME}/.claude/hooks"

# Critical hooks to verify exist and are executable.
# Version checking removed — was hardcoded and always stale, producing
# false-warning noise every session. Hook correctness is validated by
# the adversarial review process, not by version string matching.
CRITICAL_HOOKS="worktree-safety.sh
artifact-location-check.sh
worktree-lifecycle.sh
worktree-create.sh
worktree-remove.sh"

# Read stdin JSON (hook protocol provides session_id, cwd, etc.)
INPUT=$(cat)

warnings=()

# Check: git is required for worktree detection
if ! command -v git >/dev/null 2>&1; then
  warnings+=("git is not installed — worktree safety hooks cannot function")
fi

# Check: critical hook files exist and are executable
while IFS= read -r hook; do
  [ -z "$hook" ] && continue
  if [ ! -f "$HOOKS_DIR/$hook" ]; then
    warnings+=("Hook file missing: $HOOKS_DIR/$hook")
  elif [ ! -x "$HOOKS_DIR/$hook" ]; then
    warnings+=("Hook $hook not executable — run maintenance to restore +x")
  fi
done <<< "$CRITICAL_HOOKS"

# SessionStart must stay interactive-fast. Expensive cleanup, repo-wide dirty
# scans, ~/.claude/projects scans, worktree walks, and mass chmod repair are
# intentionally disabled on the default path. Run maintenance-cleanup.sh
# manually, or set CLAUDE_SESSION_ENV_FULL=1 for a one-off diagnostic start.
if [ "${CLAUDE_SESSION_ENV_FULL:-0}" != "1" ]; then
  if [ ${#warnings[@]} -gt 0 ]; then
    {
      echo "=== Worktree Hook Environment Check (fast mode) ==="
      for w in "${warnings[@]}"; do
        echo "  WARNING: $w"
      done
      echo "==============================================="
    } >&2
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg ctx "SessionStart environment check ran in fast mode. Expensive cleanup and repository scans are disabled by default for interactive responsiveness." '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$ctx}}'
  fi
  exit 0
fi

# ── Detect potentially stale core.worktree git config (advisory only) ───────
# SessionStart MUST NOT mutate repo config. If a stale core.worktree entry is
# detected, emit a warning and require explicit user-approved maintenance.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  _wt_count=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')
  if [ "${_wt_count:-0}" -gt 1 ]; then
    _core_wt=$(git config --local core.worktree 2>/dev/null || true)
    if [ -n "$_core_wt" ]; then
      warnings+=("MAINTENANCE REQUIRED: Detected local core.worktree='$_core_wt' with ${_wt_count} active worktrees. No automatic change was made. With explicit approval, run: git config --local --unset core.worktree")
    fi
  fi
fi

# Build additionalContext: inject active worktree info into Claude's context
context=""
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  wt_count=$(git worktree list 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  if [ "$wt_count" -gt 1 ]; then
    wt_list=$(git worktree list 2>/dev/null)
    # Check if THIS session owns a worktree (lock file contains our session ID)
    my_worktree=""
    # W77: canonical SID resolver — adds Priority 3 runtime-file fallback
    SESSION_ID=$(resolve_sid "$INPUT")
    if [ -n "$SESSION_ID" ]; then
      repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
      for lock in "$repo_root"/.worktrees/*/.claude-session-lock; do
        [ -f "$lock" ] || continue
        lock_sid=$(awk '{print $1}' "$lock" 2>/dev/null || echo "")
        if [ "$lock_sid" = "$SESSION_ID" ]; then
          my_worktree=$(dirname "$lock")
          break
        fi
      done
    fi

    worktree_path_msg=""
    if [ -n "$my_worktree" ]; then
      abs_wt=$(cd "$my_worktree" 2>/dev/null && pwd || echo "$my_worktree")
      worktree_path_msg=" THIS SESSION'S WORKTREE: $abs_wt — ALL file reads, edits, and Bash commands MUST use absolute paths within this directory. Do NOT read or edit files in the main working directory. The only exception is session artifacts (*_*.md) which go in the repo root."
    fi

    context="WORKTREE SAFETY ACTIVE: $wt_count worktrees detected.${worktree_path_msg} Rules enforced by hooks: (1) Never git stash — repo-wide LIFO stack corrupts across worktrees. (2) Never switch branches on the main working directory. (3) Never run git gc/prune/repack. (4) Write all session artifacts to the repo root, not worktrees. (5) Check .claude-session-lock before removing worktrees. (6) Never use 'git checkout --theirs' or '--ours' on multiple files — resolve each conflict individually. Active worktrees: $wt_list"
  fi
fi

# ── Dirty-tree baseline capture ────────────────────────────────────────────────
# Snapshot the current dirty files at session start so the Stop hook
# (uncommitted-changes-gate.sh) can distinguish pre-existing dirt from
# session-introduced changes. Only block on NEW dirty files at exit.
#
# CRITICAL: SESSION_ID is only parsed inside the worktree block above (wt_count > 1).
# We must parse it unconditionally here for non-worktree sessions too.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  # W77: canonical SID resolver — adds Priority 3 runtime-file fallback
  _baseline_sid=$(resolve_sid "$INPUT")
  if [ -n "$_baseline_sid" ]; then
    _baseline_file="$(v_tmp_dir)/dirty-baseline-${_baseline_sid}.txt"
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
    (cd "$_repo_root" && LC_ALL=C git status --porcelain 2>/dev/null | LC_ALL=C sort) > "$_baseline_file" 2>/dev/null || true

    # Capture session-start HEAD so Stop hooks can detect committed changes
    # even when git diff is clean at session end.
    _head_baseline_file="$(v_tmp_dir)/head-baseline-${_baseline_sid}.txt"
    (cd "$_repo_root" && git rev-parse HEAD 2>/dev/null) > "$_head_baseline_file" 2>/dev/null || true
  fi
fi

# ── Stale Claude /tmp file cleanup ────────────────────────────────────────────
# Remove Claude-owned temp files older than 24h. These accumulate across sessions
# (baseline files, HEAD baseline markers, headless-mode markers, cache dirs).
# Best-effort: errors are suppressed so session startup is never blocked.
# -maxdepth 1 ensures we only touch the /tmp root, never recurse into subdirs.
# -mtime +1 means strictly older than 24h — current/recent session files are safe.
_CLAUDE_TMPDIR="${TMPDIR:-/tmp}"
if [ -d "$_CLAUDE_TMPDIR" ] && [ "$_CLAUDE_TMPDIR" != "/" ]; then
find "$_CLAUDE_TMPDIR" -maxdepth 1 -name "claude-*" -mtime +1 -delete 2>/dev/null || true
find "$_CLAUDE_TMPDIR" -maxdepth 1 -name ".claude-*" -mtime +1 -delete 2>/dev/null || true
# Clean stale dirty-baseline and head-baseline marker files (written by this hook)
find "$_CLAUDE_TMPDIR" -maxdepth 1 -name "dirty-baseline-*" -mtime +1 -delete 2>/dev/null || true
find "$_CLAUDE_TMPDIR" -maxdepth 1 -name "head-baseline-*" -mtime +1 -delete 2>/dev/null || true
# Clean stale claude-headless-* markers (old /tmp location before Phase 3 migration)
find "$_CLAUDE_TMPDIR" -maxdepth 1 -name "claude-headless-*" -mtime +1 -delete 2>/dev/null || true
# Clean stale claude-git-cache directories (directory, not file — use -type d)
find "$_CLAUDE_TMPDIR" -maxdepth 1 -name "claude-git-cache" -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true
fi  # end TMPDIR safety check

# ── W25-D: Repo-local .v/tmp cleanup (24h staleness window) ───────────────────
# Production audit (W25, .v/tmp inventory): 154 leftover files including 74
# orphaned dispatch-* artifacts, 13 bootstrap-* files (mostly PID-named from
# pre-W23 sessions when SID resolution failed), 18 v-emit-*.tmp scratch files
# from killed/crashed helper invocations, and 9 session-start-*.txt markers
# never reaped. None of these files are useful past the session that wrote
# them; -mtime +1 is a safe window since no /v session runs >24h.
#
# This hook fires at SessionStart, so we're cleaning AT THE START of the
# new session — guaranteed not to remove this session's own files.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  _v_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  _v_tmp_target="$_v_repo_root/.v/tmp"
  if [ -n "$_v_repo_root" ] && [ -d "$_v_tmp_target" ] && [ ! -L "$_v_repo_root/.v" ]; then
    # Each pattern is per-session; -mtime +1 means "last modified more than 24h ago".
    # The leading 2>/dev/null on each line suppresses errors from nonexistent
    # patterns (a fresh .v/tmp will have nothing matching).
    find "$_v_tmp_target" -maxdepth 1 -name "dispatch-*"      -mtime +1 -delete 2>/dev/null || true
    find "$_v_tmp_target" -maxdepth 1 -name "v-emit-*.tmp"    -mtime +1 -delete 2>/dev/null || true
    find "$_v_tmp_target" -maxdepth 1 -name "bootstrap-*.env" -mtime +1 -delete 2>/dev/null || true
    find "$_v_tmp_target" -maxdepth 1 -name "session-start-*.txt" -mtime +1 -delete 2>/dev/null || true
    find "$_v_tmp_target" -maxdepth 1 -name "session-writes-*.txt" -mtime +1 -delete 2>/dev/null || true
    find "$_v_tmp_target" -maxdepth 1 -name "gate-*.log"      -mtime +1 -delete 2>/dev/null || true
    # W26-followup-2: session-log pending files are kept 7 days (not 1) so an
    # operator inspecting a validator failure has time to retrieve the artifact.
    find "$_v_tmp_target" -maxdepth 1 -name "session-log-*-pending*.yaml" -mtime +7 -delete 2>/dev/null || true
    find "$_v_tmp_target" -maxdepth 1 -name "gate-summary-*.txt" -mtime +1 -delete 2>/dev/null || true
    find "$_v_tmp_target" -maxdepth 1 -name "main-head-at-start-*" -mtime +1 -delete 2>/dev/null || true
    # W40 review-fix: clean up commit-msg-* files written by /v's
    # commit-message file-first pattern (SKILL.md "Commit Message Authoring").
    find "$_v_tmp_target" -maxdepth 1 -name "commit-msg-*"   -mtime +1 -delete 2>/dev/null || true
  fi
fi

# ── Stale per-session writes-log cleanup (in-repo, anchored to .git) ──────────
# track-session-writes.sh stores per-session writes logs at
# ${git_common_dir}/claude-session-writes-${SESSION_ID}.txt. These are anchored
# to .git so they survive cwd changes and /tmp races, but they still need
# periodic pruning. Best-effort, never blocks session startup.
#
# Two-tier cleanup:
#   1. Delete logs whose owning session is no longer present in
#      ~/.claude/projects/*/*.jsonl (authoritative session list).
#   2. Delete logs older than 6 hours as a fallback (handles logs whose
#      session directory was pruned or whose mtime never advanced).
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  _git_common=$(git rev-parse --git-common-dir 2>/dev/null || git rev-parse --git-dir 2>/dev/null || true)
  if [ -n "$_git_common" ] && [ -d "$_git_common" ]; then
    # Tier 1: active session list — any session that still has a jsonl file
    # under ~/.claude/projects/ is potentially active, so keep its log.
    # NOTE: The active session list is written to a temp file rather than a
    # bash variable because:
    #   (a) it can be very large (>4000 entries on active machines), and
    #   (b) pipelines with `grep -q` under `set -o pipefail` can SIGPIPE
    #       the upstream `printf` when grep exits early on a match — causing
    #       the entire pipeline to return non-zero and falsely report "not
    #       found" for sessions that ARE in the list.
    _active_sessions_file=$(mktemp "$(v_tmp_dir)/claude-active-sessions.XXXXXX")
    find "${HOME}/.claude/projects" -maxdepth 2 -name '*.jsonl' -type f 2>/dev/null \
      | sed -e 's|.*/||' -e 's|\.jsonl$||' | LC_ALL=C sort -u > "$_active_sessions_file" 2>/dev/null || true
    if [ -s "$_active_sessions_file" ]; then
      for _log in "$_git_common"/claude-session-writes-*.txt; do
        [ -f "$_log" ] || continue
        _lsid=$(basename "$_log" | sed -e 's|^claude-session-writes-||' -e 's|\.txt$||')
        [ -n "$_lsid" ] || continue
        # Use -Fx (fixed-string, whole-line) and capture output instead of
        # -q to avoid the pipefail/SIGPIPE interaction.
        if ! LC_ALL=C grep -Fx -- "$_lsid" "$_active_sessions_file" >/dev/null 2>&1; then
          # Session is gone from the project history — safe to delete its log.
          rm -f "$_log" 2>/dev/null || true
        fi
      done
    fi
    rm -f "$_active_sessions_file" 2>/dev/null || true
    # Tier 2: time-based fallback (6h) for anything Tier 1 missed.
    # -mmin is used instead of -mtime for finer resolution (6h = 360min).
    find "$_git_common" -maxdepth 1 -name "claude-session-writes-*.txt" -mmin +360 -delete 2>/dev/null || true

    # Ensure THIS session has an empty writes log so downstream Stop hooks
    # can distinguish "tracking enabled, nothing written yet" (empty log) from
    # "tracking not enabled, fall back to legacy git state" (no log at all).
    # Without this sentinel, a read-only session on a pre-populated repo would
    # take the legacy path and block on pre-existing dirty files.
    # W77: canonical SID resolver — adds Priority 3 runtime-file fallback
    _session_id_for_sentinel=$(resolve_sid "$INPUT")
    if [ -n "$_session_id_for_sentinel" ]; then
      _sentinel_log="${_git_common}/claude-session-writes-${_session_id_for_sentinel}.txt"
      : >> "$_sentinel_log" 2>/dev/null || true
    fi
  fi
fi

# ── Parallel session / dirty tree detection ───────────────────────────────────
# Warn when the working tree has a large uncommitted diff (likely from prior
# parallel sessions) or when other active session locks exist.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

  # Count uncommitted changes (staged + unstaged + untracked code files)
  dirty_count=$(cd "$repo_root" && {
    git diff --name-only HEAD 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -c . 2>/dev/null || echo "0")

  # Count active session locks from other sessions
  other_locks=0
  for lock in "$repo_root"/.worktrees/*/.claude-session-lock; do
    [ -f "$lock" ] || continue
    lock_sid=$(awk '{print $1}' "$lock" 2>/dev/null || echo "")
    sid="${SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
    if [ -n "$sid" ] && [ "$lock_sid" != "$sid" ]; then
      # Check if lock is recent (< 4 hours)
      lock_mtime=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo "0")
      now=$(date +%s)
      age=$(( now - lock_mtime ))
      if [ "$age" -lt $CLAUDE_SESSION_TIMEOUT ]; then
        other_locks=$((other_locks + 1))
      fi
    fi
  done

  parallel_warning=""
  if [ "$other_locks" -gt 0 ]; then
    parallel_warning="PARALLEL SESSION WARNING: $other_locks other active session(s) detected via lock files. You MUST use worktree isolation — invoke /v to auto-create a worktree, or manually create one. Working directly on main risks silent overwrites of other sessions' changes."
  elif [ "$dirty_count" -gt 20 ]; then
    parallel_warning="DIRTY TREE WARNING: $dirty_count uncommitted file changes detected on main. This may indicate prior parallel sessions. Use /v to scope and isolate your work, and run /v-pre-flight before completing. Quality gates (pre-flight, agent review) are mandatory even when implementing pre-built plans."
  fi

  if [ -n "$parallel_warning" ]; then
    if [ -n "$context" ]; then
      context="$context $parallel_warning"
    else
      context="$parallel_warning"
    fi
  fi
fi

# ── Stale worktree detection (advisory only; no auto-cleanup) ────────────────
# SessionStart MUST NOT remove worktrees or branches automatically.
# Detect candidates and provide explicit, manual maintenance guidance.
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  cleanup_candidates=""
  active_lock_candidates=""
  cleanup_count=0
  active_lock_count=0
  now=$(date +%s)
  while IFS= read -r wt_line; do
    [ -z "$wt_line" ] && continue
    wt_path=$(echo "$wt_line" | awk '{print $1}')
    wt_branch=$(echo "$wt_line" | sed 's/.*\[//' | sed 's/\].*//')
    # Skip the main worktree
    [ "$wt_path" = "$repo_root" ] && continue
    # Check if branch is fully merged to main (is-ancestor = all commits in branch are in main)
    if git merge-base --is-ancestor "$wt_branch" "$MAIN_BRANCH" 2>/dev/null; then
      # Check for uncommitted changes in the worktree
      wt_dirty=$(git -C "$wt_path" diff --name-only HEAD 2>/dev/null | head -1 || true)
      if [ -z "$wt_dirty" ]; then
        # Check lock age — auto-remove if lock is expired (>4h) or missing
        lock_file="$wt_path/.claude-session-lock"
        lock_expired=false
        if [ ! -f "$lock_file" ]; then
          lock_expired=true
        else
          lock_mtime=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null || echo "0")
          lock_age=$(( now - lock_mtime ))
          if [ "$lock_age" -gt $CLAUDE_SESSION_TIMEOUT ]; then
            lock_expired=true
          fi
        fi

        if $lock_expired; then
          cleanup_candidates="$cleanup_candidates  - $wt_path ($wt_branch) — merged, lock expired/missing"$'\n'
          cleanup_count=$((cleanup_count + 1))
        else
          active_lock_candidates="$active_lock_candidates  - $wt_path ($wt_branch) — merged, lock still active"$'\n'
          active_lock_count=$((active_lock_count + 1))
        fi
      fi
    fi
  done < <(git worktree list 2>/dev/null)

  maintenance_msg=""
  if [ "$cleanup_count" -gt 0 ]; then
    maintenance_msg="MAINTENANCE REQUIRED: $cleanup_count merged worktree(s) are cleanup candidates. No automatic removal was performed. With explicit user approval, remove manually (git worktree remove + git branch -d):"$'\n'"$cleanup_candidates"
  fi
  if [ "$active_lock_count" -gt 0 ]; then
    lock_msg="STALE WORKTREES (LOCKED): $active_lock_count merged worktree(s) still have active locks:"$'\n'"$active_lock_candidates""Do not remove until the owning session approves cleanup."
    if [ -n "$maintenance_msg" ]; then
      maintenance_msg="$maintenance_msg"$'\n\n'"$lock_msg"
    else
      maintenance_msg="$lock_msg"
    fi
  fi

  if [ -n "$maintenance_msg" ]; then
    if [ -n "$context" ]; then
      context="$context $maintenance_msg"
    else
      context="$maintenance_msg"
    fi
  fi
fi

# ── Dirty tree quality gate reminder ─────────────────────────────────────────
if [ -n "${parallel_warning:-}" ] || [ "${dirty_count:-0}" -gt 20 ]; then
  gate_reminder="QUALITY GATE REMINDER: Pre-flight (/v-pre-flight), agent review, and verify-done (/v-verify-done) are MANDATORY even when implementing pre-built plans. Do not skip these gates."
  if [ -n "$context" ]; then
    context="$context $gate_reminder"
  else
    context="$gate_reminder"
  fi
fi

# Report all warnings on stderr after all checks have populated the warning list.
if [ ${#warnings[@]} -gt 0 ]; then
  echo "=== Worktree Hook Environment Check ===" >&2
  for w in "${warnings[@]}"; do
    echo "  WARNING: $w" >&2
  done
  echo "========================================" >&2
fi

# Output JSON with additionalContext (only if we have context to inject)
if [ -n "$context" ] && command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$context" '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$ctx}}' || {
    echo "ERROR: Failed to generate additionalContext JSON" >&2
  }
fi

exit 0
