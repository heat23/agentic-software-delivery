#!/usr/bin/env bash
# enforce-branch-gate.sh
# SAFETY HOOK — P0
# Event: PreToolUse/Bash
# Version: 1.0.0
# Purpose: BLOCK execution when the main working directory is on a non-main
#          branch (outside worktrees). This upgrades check-session-branch.sh
#          (advisory SessionStart warning) to a hard gate on the first Bash
#          command, preventing all downstream damage from wrong-base worktrees.
#
# Allows:
#   - Sessions inside linked worktrees (IS_WORKTREE=true)
#   - Sessions on build/* or fix/* branches (created by /v)
#   - CLAUDE_ALLOW_NON_MAIN=1 override
#   - Non-git directories (no repo detected)
#
# Blocks:
#   - Any Bash command when on wrong branch (first occurrence only — sets marker)
#
# One-shot per session+repo: marker is scoped to both session_id and repo
# fingerprint so one repo/session cannot suppress checks in another.

set -euo pipefail

# ── CLAUDE_ALLOW_NON_MAIN bypass ─────────────────────────────────────────────
if [[ "${CLAUDE_ALLOW_NON_MAIN:-0}" == "1" ]]; then
  exit 0
fi


# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
source "$HOOKS_LIB_DIR/v-tmp-dir.sh"
require_jq_or_deny

# Guard: git is required for branch detection
if ! command -v git >/dev/null 2>&1; then
  exit 0
fi

# Consume stdin (hook protocol)
INPUT=$(cat)

# Session-aware marker key
# W70: canonical SID resolver; preserve "unknown" sentinel semantics
source "$HOME/.claude/hooks/lib/resolve-sid.sh"
SESSION_ID=$(resolve_sid "$INPUT")
SESSION_ID="${SESSION_ID:-unknown}"
SESSION_KEY=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)
[[ -z "$SESSION_KEY" ]] && SESSION_KEY="unknown"

# ── Check git state ──────────────────────────────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
MARKER_DIR="$(v_tmp_marker_dir)"
if [[ -n "$REPO_ROOT" ]]; then
  REPO_SEED="repo:${REPO_ROOT}"
else
  INPUT_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
  REPO_SEED="nonrepo:${INPUT_CWD:-$PWD}"
fi
REPO_KEY=$(printf '%s' "$REPO_SEED" | cksum | awk '{print $1}')
MARKER_FILE="$MARKER_DIR/branch-gate-checked-${SESSION_KEY}-${REPO_KEY}"
if [[ -f "$MARKER_FILE" ]]; then
  exit 0
fi

if [[ -z "$REPO_ROOT" ]]; then
  # Not in a git repo — nothing to guard
  mkdir -p "$MARKER_DIR"
  touch "$MARKER_FILE"
  exit 0
fi

# Skip inside linked worktrees (git-common-dir differs from git-dir in linked worktrees)
GCD=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "")
GD=$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null || echo "")
if [[ -n "$GCD" && -n "$GD" && "$GCD" != "$GD" ]]; then
  mkdir -p "$MARKER_DIR"
  touch "$MARKER_FILE"
  exit 0
fi

CURRENT_BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
printf 'DEBUG %s: cwd=%s REPO_ROOT=%s CURRENT_BRANCH=%s SESSION_ID=%s MARKER_FILE=%s\n' "$(date +%s)" "$PWD" "$REPO_ROOT" "$CURRENT_BRANCH" "$SESSION_ID" "$MARKER_FILE" >> /tmp/branch-gate-debug.log 2>/dev/null || true

# Detached HEAD — block
if [[ -z "$CURRENT_BRANCH" ]]; then
  jq -n --arg reason "BLOCKED: Detached HEAD state detected. Run 'git checkout ${MAIN_BRANCH}' first. /v requires a branch to function correctly." \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

# On main — all good
if [[ "$CURRENT_BRANCH" == "$MAIN_BRANCH" ]]; then
  mkdir -p "$MARKER_DIR"
  touch "$MARKER_FILE"
  exit 0
fi

# Allow /v-created branches (build/* and fix/*)
if [[ "$CURRENT_BRANCH" == build/* ]] || [[ "$CURRENT_BRANCH" == fix/* ]]; then
  mkdir -p "$MARKER_DIR"
  touch "$MARKER_FILE"
  exit 0
fi

# ── BLOCK: wrong branch ─────────────────────────────────────────────────────
jq -n --arg reason "BLOCKED: Session is on branch '${CURRENT_BRANCH}', not '${MAIN_BRANCH}'. /v creates worktrees that branch off the current branch — starting on a feature branch means all worktrees branch from the wrong base. Run: git checkout ${MAIN_BRANCH}. Override: export CLAUDE_ALLOW_NON_MAIN=1" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'

exit 0
