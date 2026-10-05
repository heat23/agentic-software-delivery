#!/usr/bin/env bash
# PreCompact hook: Preserves worktree state before context compaction.
# When a long session compacts, Claude loses track of active worktrees.
# This hook injects a summary of active worktrees into the compacted context.
# Version: 1.3.2
#
# Exit 0 = success. Plain text on stdout — NOT the hookSpecificOutput JSON envelope.
#
# VERIFIED against the Claude Code 2.1.228 binary (2026-08-11), not inferred:
#   * The hookSpecificOutput discriminated union has 20 hookEventName cases and
#     "PreCompact" is NOT one of them (PreToolUse/PostToolUse/SessionStart/Setup/… are).
#     PreCompact IS a valid hook *event*, but that is a different list — conflating the
#     event registry with the output-schema union is the trap here.
#   * The PreCompact handler collects each succeeded hook's trimmed STDOUT and returns it as
#     `newCustomInstructions`, which is fed to the compactor. So plain stdout is the ONLY
#     mechanism that works for this event; a JSON envelope would be passed through verbatim
#     as instruction text rather than parsed.
#
# jq is deliberately NOT required. This hook emits plain text and parses no JSON, so the
# `require_jq_or_skip` guard it carried through 1.3.1 was a vestigial dependency: on a
# machine without jq it exited 0 early and silently dropped worktree state from every
# compaction, for no reason. Guarding on a proxy the decision no longer depends on.

set -euo pipefail

# Guard: git is required for branch/worktree detection
if ! command -v git >/dev/null 2>&1; then
  exit 0
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0  # Not inside a git repo
fi

wt_count=$(git worktree list 2>/dev/null | wc -l | tr -d ' ' || echo "0")

if [ "$wt_count" -le 1 ]; then
  exit 0  # No active worktrees — nothing to preserve
fi

# Build a detailed summary of all worktrees and their lock status
wt_summary=""
while IFS= read -r line; do
  wt_path=$(echo "$line" | awk '{print $1}')
  wt_branch=$(echo "$line" | grep -oE '\[.*\]' || echo "[detached]")

  lock_info="no lock"
  if [ -f "$wt_path/.claude-session-lock" ]; then
    lock_content=$(cat "$wt_path/.claude-session-lock" 2>/dev/null || echo "")
    lock_info="locked: $lock_content"
  fi

  wt_summary="$wt_summary
  - $wt_path $wt_branch ($lock_info)"
done < <(git worktree list 2>/dev/null)

context="CONTEXT PRESERVED BY PreCompact HOOK: $wt_count active worktrees. Worktree safety rules are enforced by hooks in ~/.claude/hooks/. Rules: (1) No git stash (2) No branch switching on main (3) No git gc/prune/repack (4) Artifacts go in original dir, not worktrees. Worktree details:$wt_summary"

printf '%s\n' "$context"

exit 0
