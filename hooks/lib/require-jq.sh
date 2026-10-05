#!/usr/bin/env bash
# lib/require-jq.sh — Shared jq dependency guard for Claude Code hooks.
#
# Hooks fall into two priority classes:
#
#   P0/P1 (safety-critical) — MUST have jq to function. A missing jq silently
#     disables the entire safety layer. These hooks should call require_jq_or_deny()
#     for blocking-capable events or require_jq_or_stop_session() for SessionStart.
#
#   P2+ (advisory/informational) — Can degrade gracefully when jq is absent.
#     These hooks call require_jq_or_skip() to preserve the existing fail-open
#     behaviour, but now intentionally and explicitly.
#     Example: lint-on-edit.sh, debug-statement-detector.sh
#
# Usage (source this file then call the guard at the top of your hook):
#
#   source "${HOME}/.claude/hooks/lib/require-jq.sh"
#   require_jq_or_deny    # P0/P1 hooks on blocking-capable events
#   require_jq_or_stop_session  # SessionStart hooks that must halt the session
#   require_jq_or_skip    # P2+ hooks

# require_jq_or_deny — P0/P1 safety-critical hooks on events where exit 2 blocks.
# Emits stderr only; Claude Code ignores stdout JSON on non-zero exits.
require_jq_or_deny() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "BLOCKED: jq is required for this safety hook. Install jq and retry." >&2
    exit 2
  fi
  return 0
}

# require_jq_or_stop_session — hard stop for SessionStart hooks.
# SessionStart cannot block via exit 2, so use universal continue:false JSON.
require_jq_or_stop_session() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"continue":false,"stopReason":"jq is required for Claude safety hooks. Install jq and restart Claude Code."}\n'
    exit 0
  fi
  return 0
}

# require_jq_or_skip — P2+ advisory hooks.
# If jq is absent, exits 0 silently. This is the same fail-open behaviour that
# existed before, but now explicitly declared rather than accidentally implicit.
require_jq_or_skip() {
  if ! command -v jq >/dev/null 2>&1; then
    exit 0
  fi
  return 0
}
