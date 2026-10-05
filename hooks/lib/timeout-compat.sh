#!/usr/bin/env bash
# timeout-compat.sh — shared timeout compatibility for macOS/Linux
# Source this in any hook that needs timeout:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/timeout-compat.sh"
#
# Sets TIMEOUT_CMD to "timeout" (Linux), "gtimeout" (macOS via Homebrew coreutils),
# or "" (neither available — caller must handle gracefully).
#
# Usage after sourcing:
#   if [[ -n "$TIMEOUT_CMD" ]]; then
#     $TIMEOUT_CMD 5 some-command
#   else
#     some-command  # run without timeout
#   fi
#
# Or use:
#   run_with_timeout 5 some-command
# which automatically falls back to direct execution when timeout isn't available.

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
fi

run_with_timeout() {
  local seconds="$1"
  shift
  if [[ -n "${TIMEOUT_CMD:-}" ]]; then
    "$TIMEOUT_CMD" "$seconds" "$@"
  else
    local timeout_flag
    timeout_flag="$(command -p mktemp 2>/dev/null || echo "/tmp/timeout-compat-${$}-$(printf '%s' "${RANDOM:-0}").flag")"
    "$@" &
    local cmd_pid=$!
    (
      command -p sleep "$seconds"
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      echo timeout > "$timeout_flag"
      kill -TERM "$cmd_pid" 2>/dev/null || exit 0
      command -p sleep 2
      kill -KILL "$cmd_pid" 2>/dev/null || true
    ) &
    local watchdog_pid=$!
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    if [[ -s "$timeout_flag" ]]; then
      rm -f "$timeout_flag"
      return 124
    fi
    rm -f "$timeout_flag"
    return "$exit_code"
  fi
}
