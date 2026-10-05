#!/usr/bin/env bash
# lib/constants.sh — Shared constants for Claude Code hooks.
#
# Source this file to avoid duplicating magic numbers and paths across hooks.
# All variables use readonly to prevent accidental reassignment.
#
# Usage:
#   source "${HOME}/.claude/hooks/lib/constants.sh"
#
# Note: CLAUDE_MAIN_BRANCH respects a pre-exported env override but must be
# set BEFORE sourcing this file. The readonly declaration locks the value at
# source time — runtime reassignment after sourcing is not supported.

# Guard against re-declaration errors when sourced multiple times.
if [ -n "${_CLAUDE_CONSTANTS_LOADED:-}" ]; then
  return 0
fi
readonly _CLAUDE_CONSTANTS_LOADED=1

# Session lock timeout — 4 hours (14400 seconds).
# A worktree lock younger than this is considered "active" and blocks removal.
# Consumers: session-env-check.sh, worktree-safety.sh, worktree-remove.sh
readonly CLAUDE_SESSION_TIMEOUT=14400

# Hook file locations.
# Consumers: session-env-check.sh
readonly CLAUDE_HOOKS_DIR="${HOME}/.claude/hooks"
readonly CLAUDE_HOOKS_LIB_DIR="${HOME}/.claude/hooks/lib"

# Attestation directory (used by Phase 3 trusted-runner attestation checks).
# Consumers: headless-detect.sh (currently uses /tmp; persistent dir for Phase 3)
readonly CLAUDE_ATTESTATION_DIR="${HOME}/.claude/attestations"

# Default main branch name — respects CLAUDE_MAIN_BRANCH env override.
# IMPORTANT: Set CLAUDE_MAIN_BRANCH in the environment BEFORE sourcing this
# file. The value is locked readonly at source time and cannot be changed after.
# Consumers: session-env-check.sh, check-session-branch.sh, enforce-branch-gate.sh,
#            check-review-artifact.sh, detect-branch-drift.sh, ai-test-antipattern-detector.sh,
#            session-context-loader.sh
readonly CLAUDE_MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"

# Export variables that child processes may need.
export CLAUDE_SESSION_TIMEOUT
export CLAUDE_HOOKS_DIR
export CLAUDE_HOOKS_LIB_DIR
export CLAUDE_ATTESTATION_DIR
export CLAUDE_MAIN_BRANCH
