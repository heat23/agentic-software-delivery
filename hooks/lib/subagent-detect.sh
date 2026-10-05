#!/usr/bin/env bash
# subagent-detect.sh — Shared library for subagent context detection.
#
# Usage: source this file and call is_subagent "$INPUT" where $INPUT is the
# hook's stdin JSON. Returns 0 (true) if running inside a subagent, 1 (false)
# if in the parent session.
#
# WHY: Subagents (haiku pre-flight, verify-done, review agents) pay full hook
# overhead (~1s per tool call across 57 hooks). Most PostToolUse async hooks
# (linting, type checking, audit logging, scope detection) are redundant in
# subagents — the parent session's pre-flight and stop hooks validate everything.
# Skipping them in subagents reduces wall-clock time by 30-50%.

# Returns 0 if the hook is running inside a subagent context, 1 otherwise.
# Checks the JSON input for agent_type or agent_id fields.
is_subagent() {
  local input="$1"
  if ! command -v jq >/dev/null 2>&1; then
    return 1  # Can't detect — assume not subagent (conservative)
  fi
  local agent_type
  agent_type=$(echo "$input" | jq -r '.agent_type // empty' 2>/dev/null)
  if [ -n "$agent_type" ]; then
    return 0  # Is a subagent
  fi
  return 1  # Not a subagent
}
