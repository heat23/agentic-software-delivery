#!/usr/bin/env bash
# worktree-remove.sh
# Event: WorktreeRemove
# WorktreeRemove hook: Advisory cleanup for native worktree removal.
# This event cannot block removal, so it logs lock conflicts and rescues artifacts
# back to the main repo root when possible.
# Version: 2.0.0
#
# Input JSON includes: session_id, worktree_path (absolute path to worktree being removed)
# Exit 0 = best-effort cleanup only. Claude Code ignores blocking semantics here.

set -euo pipefail



# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

# Resolve hooks/lib path robustly (works under any $HOME).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip
source "$HOOKS_LIB_DIR/constants.sh"

HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
WORKTREE_LIB="$HOOKS_LIB_DIR/worktree-command.sh"
if [[ -f "$WORKTREE_LIB" ]]; then
  source "$WORKTREE_LIB"
fi

INPUT=$(cat)
# W70: canonical SID resolver (env + runtime-file fallback + stdin JSON)
source "$HOME/.claude/hooks/lib/resolve-sid.sh"
SESSION_ID=$(resolve_sid "$INPUT")
WT_PATH=$(echo "$INPUT" | jq -r '.worktree_path // empty')

warn() {
  echo "WORKTREE_REMOVE_HOOK: $1" >&2
}

rescue_artifacts() {
  local repo_root=""
  local rescue_dir=""
  local artifact=""
  local rescued_any=0
  local artifact_base=""
  local target=""
  local worktree_name=""

  if declare -F worktree_common_repo_root >/dev/null 2>&1; then
    repo_root=$(worktree_common_repo_root "$WT_PATH" 2>/dev/null || echo "")
  fi
  if [ -z "$repo_root" ] || [ ! -d "$repo_root" ]; then
    warn "Unable to derive repo root for '$WT_PATH'; artifacts cannot be rescued automatically."
    return 1
  fi

  worktree_name=$(basename "$WT_PATH")
  rescue_dir="$repo_root/.claude-rescued-worktree-artifacts/$worktree_name"
  mkdir -p "$rescue_dir"

  while IFS= read -r artifact; do
    [ -f "$artifact" ] || continue
    artifact_base=$(basename "$artifact")
    target="$rescue_dir/$artifact_base"
    if [ -e "$target" ]; then
      target="$rescue_dir/$(date +%s)-$artifact_base"
    fi
    if cp "$artifact" "$target" 2>/dev/null; then
      rescued_any=1
    fi
  done <<< "$ARTIFACTS"

  if [ "$rescued_any" -eq 1 ]; then
    warn "Rescued worktree artifacts from '$WT_PATH' to '$rescue_dir' before removal."
  else
    warn "Attempted artifact rescue from '$WT_PATH', but no files could be copied."
    return 1
  fi
}

if [ -z "$WT_PATH" ] || [ ! -d "$WT_PATH" ]; then
  exit 0
fi

# ── Lock ownership check FIRST (higher priority than artifact check) ───────────
# Surface fresh ownership conflicts before artifact rescue so the debug log keeps
# the original safety signal even though WorktreeRemove cannot block cleanup.
if [ -f "$WT_PATH/.claude-session-lock" ]; then
  LOCK_CONTENT=$(cat "$WT_PATH/.claude-session-lock" 2>/dev/null || echo "")
  LOCK_SESSION_ID=$(echo "$LOCK_CONTENT" | awk '{print $1}')

  # Guard: corrupted or empty lock file — warn when a session_id is available.
  if [ -z "$LOCK_SESSION_ID" ]; then
    if [ -n "$SESSION_ID" ]; then
      warn "Fresh remove for '$WT_PATH' saw a corrupted or empty lock file. Ownership could not be verified."
    fi
    exit 0
  fi

  # Allow: this session owns the lock
  if [ -n "$SESSION_ID" ] && [ "$LOCK_SESSION_ID" = "$SESSION_ID" ]; then
    exit 0
  fi

  if [ -n "$SESSION_ID" ] && [ "$LOCK_SESSION_ID" != "$SESSION_ID" ]; then
    LOCK_AGE_SECONDS=0
    LOCK_MTIME=$(stat -c %Y "$WT_PATH/.claude-session-lock" 2>/dev/null || stat -f %m "$WT_PATH/.claude-session-lock" 2>/dev/null || echo "0")
    NOW=$(date +%s)
    LOCK_AGE_SECONDS=$((NOW - LOCK_MTIME))

    if [ "$LOCK_AGE_SECONDS" -lt $CLAUDE_SESSION_TIMEOUT ]; then
      warn "Removing '$WT_PATH' even though it appears owned by session '$LOCK_SESSION_ID' (lock age ${LOCK_AGE_SECONDS}s). WorktreeRemove cannot block cleanup."
    fi
  fi
fi

# ── Artifact check SECOND (only reached if lock check passed) ─────────────────
# Phase-2 relocation (2026-07-06): scan BOTH the worktree root (legacy) and its .v/artifacts.
ARTIFACTS=$(find "$WT_PATH" "$WT_PATH/.v/artifacts" -maxdepth 1 -name '*.md' -type f 2>/dev/null | grep -E '(PLAN|AUDIT_REPORT|REFACTOR_PLAN|IMPLEMENTATION_REPORT|PRE_FLIGHT_REPORT|VERIFY_DONE_REPORT|AGENT_REVIEW|HANDOFF|BUILD_BLOCKER|PROGRESS_NOTE|TRAFFIC_PLAN|DOCS_AUDIT|LAUNCH_PLAN|LAUNCH_CHECKLIST|PRELAUNCH_READINESS_REPORT|ADMIN_AUDIT_REPORT|POLISH_PLAN|CONSOLIDATED_AUDIT_REPORT|DIFFERENTIATION_BRIEF|SKILL_REVIEW_REPORT|GAUNTLET_REPORT|LEGAL_AUDIT|PROD_TRIAGE|V_NEXT_REPORT|FEATURE_ROADMAP)_' || echo "")
if [ -n "$ARTIFACTS" ]; then
  if [ -f "$WT_PATH/.artifacts-rescued" ]; then
    rm -f "$WT_PATH/.artifacts-rescued"
  else
    rescue_artifacts || warn "Artifacts remained in '$WT_PATH' during removal and automatic rescue was incomplete."
  fi
fi

# ── Per-session writes log cleanup ────────────────────────────────────────────
# track-session-writes.sh stores writes logs in ${git_common_dir}/claude-session-writes-*.txt.
# When this worktree's owning session is being torn down, clean up its log.
# Safe to run here: we already early-exited if THIS session owns the lock, so
# reaching this point means the lock owner is gone or a different session is
# removing the worktree.
if [ -n "${LOCK_SESSION_ID:-}" ] && [ -d "$WT_PATH" ]; then
  _git_common=$(git -C "$WT_PATH" rev-parse --git-common-dir 2>/dev/null || true)
  if [ -n "$_git_common" ] && [ -d "$_git_common" ]; then
    rm -f "${_git_common}/claude-session-writes-${LOCK_SESSION_ID}.txt" 2>/dev/null || true
  fi
fi

exit 0
