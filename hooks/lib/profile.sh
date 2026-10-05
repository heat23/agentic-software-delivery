#!/usr/bin/env bash
# profile.sh — Opt-in hook profiling (W83-F3).
# Active ONLY when CLAUDE_HOOK_PROFILE=1. Otherwise both functions are
# fast no-ops (single env-var test, no I/O).
#
# Log format (one line per invocation):
#   ISO8601 | session_id | hook_name | tool_name | wall_ms
#
# Log file: ~/.claude/runtime/hook-profile-${session_id}.log
#
# Hygiene contract (PLAN-FINAL.md A6):
#   - NO set -e / -u / -o pipefail (caller's flags untouched)
#   - NO trap installation (callers may already have their own discipline)
#   - Only _PROFILE_* variables are touched in caller scope
#   - profile_done preserves caller's $? (always returns rc unchanged)
#   - profile_done is idempotent: subsequent calls in same invocation no-op
#
# Usage in a hook:
#   source "$HOOKS_LIB_DIR/profile.sh"
#   profile_start "my-hook"
#   ... hook body ...
#   profile_done
#   exit 0

# Guard against double-source (cheap function redefinition would otherwise
# clobber _PROFILE_DONE state mid-invocation).
if [ "${_PROFILE_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_PROFILE_LOADED=1

profile_start() {
  [ "${CLAUDE_HOOK_PROFILE:-}" = "1" ] || return 0
  _PROFILE_HOOK="${1:-unknown}"
  _PROFILE_DONE=0
  _PROFILE_T0=$(python3 -c 'import time; print(time.time_ns())' 2>/dev/null) || _PROFILE_T0=0
  return 0
}

profile_done() {
  local rc=$?
  [ "${CLAUDE_HOOK_PROFILE:-}" = "1" ] || return $rc
  [ "${_PROFILE_DONE:-0}" = "1" ] && return $rc
  [ -z "${_PROFILE_T0:-}" ] && return $rc
  [ "${_PROFILE_T0}" = "0" ] && return $rc
  _PROFILE_DONE=1

  local wall_ms
  wall_ms=$(python3 -c "import time; print((time.time_ns() - ${_PROFILE_T0}) // 1_000_000)" 2>/dev/null) || wall_ms=0

  local ts sid tool log runtime_dir
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts="unknown"
  sid="${CLAUDE_SESSION_ID:-unknown}"
  tool="${CLAUDE_HOOK_TOOL_NAME:-${TOOL_NAME:-unknown}}"

  runtime_dir="${HOME}/.claude/runtime"
  log="${runtime_dir}/hook-profile-${sid}.log"
  mkdir -p "$runtime_dir" 2>/dev/null
  printf '%s | %s | %s | %s | %d\n' "$ts" "$sid" "${_PROFILE_HOOK:-unknown}" "$tool" "$wall_ms" >> "$log" 2>/dev/null

  return $rc
}
