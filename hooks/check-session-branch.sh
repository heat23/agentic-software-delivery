#!/usr/bin/env bash
# check-session-branch.sh
# Event: SessionStart
# SessionStart hook: Warns when a session starts on a non-main branch.
# Version: 1.0.0
#
# WHY: Worktree-based skills (/v, /impl, /qa) create git worktrees that inherit
# the current branch as their base. Starting on a feature branch means all
# worktrees branch off from there instead of main — landing work in the wrong place.
#
# BEHAVIOUR:
#   - Fires exactly once per session (SessionStart fires once at session open).
#   - Non-blocking (exit 0) — injects warning into Claude's context via additionalContext.
#   - Skips automatically when running inside a linked worktree (.git is a file, not a dir).
#   - Respects CLAUDE_ALLOW_NON_MAIN=1 to suppress entirely.
#   - Respects CLAUDE_MAIN_BRANCH=<name> if the default branch is renamed.
#
# Exit 0 = always (advisory only). JSON on stdout with additionalContext if warning applies.

set -euo pipefail

if [[ "${CLAUDE_ALLOW_NON_MAIN:-0}" == "1" ]]; then
  exit 0
fi

# Require jq and git — fail open if missing

# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip

# Guard: git is required for branch/worktree detection
if ! command -v git >/dev/null 2>&1; then
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
  exit 0
fi

# Skip inside linked worktrees (git-common-dir differs from git-dir in linked worktrees)
GCD=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "")
GD=$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null || echo "")
if [[ -n "$GCD" && -n "$GD" && "$GCD" != "$GD" ]]; then
  exit 0
fi

CURRENT_BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
if [[ -z "$CURRENT_BRANCH" ]]; then
  exit 0  # Detached HEAD — skip
fi

MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
if [[ "$CURRENT_BRANCH" == "$MAIN_BRANCH" ]]; then
  exit 0
fi

# Inject warning into Claude's session context
WARNING="SESSION BRANCH WARNING: Session started on branch '$CURRENT_BRANCH', not '$MAIN_BRANCH'. Worktree-based skills (/v, /v-build, /impl, /qa) will create branches off '$CURRENT_BRANCH' — NOT '$MAIN_BRANCH'. This is almost certainly wrong. Fix before running any worktree skill: git checkout $MAIN_BRANCH. To suppress: export CLAUDE_ALLOW_NON_MAIN=1"

jq -n --arg ctx "$WARNING" '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$ctx}}'

exit 0
