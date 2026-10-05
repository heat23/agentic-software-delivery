#!/usr/bin/env bash
# harness-sweep-skip: production hook (not a test harness); matches *test*.sh glob but exits 0 vacuously
# parallel-test-throttle.sh
# RESOURCE MANAGEMENT HOOK — P0
# Event: PreToolUse/Bash
# Version: 2.1.0   ← W27-F8: tightened command-boundary regex (see fix below)
#
# Enforces conservative worker/thread execution for common test commands and
# injects a configurable Node.js heap ceiling for node-based commands.

set -euo pipefail


# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_deny

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$COMMAND" ] && exit 0

NEW_COMMAND="$COMMAND"
REASONS=()

coerce_positive_int() {
  local value="$1"
  local fallback="$2"
  if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

coerce_nonnegative_int() {
  local value="$1"
  local fallback="$2"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

PHP_TEST_PROCESSES=$(coerce_positive_int "${CLAUDE_PHP_TEST_PROCESSES:-1}" 1)
VITEST_THREADS=$(coerce_positive_int "${CLAUDE_VITEST_THREADS:-1}" 1)
JEST_MAX_WORKERS=$(coerce_positive_int "${CLAUDE_JEST_MAX_WORKERS:-1}" 1)
PYTEST_WORKERS=$(coerce_positive_int "${CLAUDE_PYTEST_WORKERS:-1}" 1)
PLAYWRIGHT_WORKERS=$(coerce_positive_int "${CLAUDE_PLAYWRIGHT_WORKERS:-1}" 1)
CARGO_TEST_THREADS=$(coerce_positive_int "${CLAUDE_CARGO_TEST_THREADS:-1}" 1)
GO_TEST_P=$(coerce_positive_int "${CLAUDE_GO_TEST_P:-1}" 1)
NODE_HEAP_MB=$(coerce_nonnegative_int "${CLAUDE_NODE_HEAP_MB:-1536}" 1536)

add_reason() {
  REASONS+=("$1")
}

# W27-F8 fix: require a TRUE command boundary, not "any whitespace". The prior
# regex `(^|[[:space:]])` matched "vitest" inside quoted strings such as
#   git commit -m "improve vitest config"
# causing the hook to inject NODE_OPTIONS / --maxWorkers into git commits and
# break heredoc commits (cost: ~1000 tokens per session, observed in a
# production session).
#
# A command boundary is: start-of-string, or after a shell statement separator
# (`;`, `&&`, `||`, `|`, `&`, `(`), with optional whitespace. Any other space
# is part of arguments (potentially inside quotes) and must not trigger.
contains_node_runtime_command() {
  local cmd="$1"
  echo "$cmd" | grep -qE '(^|[;&|()]+[[:space:]]*)(env[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*((npx|npm|pnpm|pnpx|yarn|bun|node|tsx|ts-node|tsc)([[:space:]]|$)|([^[:space:]]*/)?(vitest|vite|vite-node|jest|playwright|eslint|next|nuxt|astro)([[:space:]]|$))'
}

command_has_explicit_node_heap_cap() {
  local cmd="$1"
  echo "$cmd" | grep -qE '(^|[[:space:]])(export[[:space:]]+)?NODE_OPTIONS=.*max-old-space-size|--max-old-space-size(=|[[:space:]]+)[0-9]+'
}

# Clamp PHP parallel runners to one process.
if echo "$NEW_COMMAND" | grep -qE '\-\-parallel'; then
  TMP="$NEW_COMMAND"
  if echo "$TMP" | grep -qE '\-\-processes(=|[[:space:]]+)[^[:space:]]+'; then
    TMP=$(echo "$TMP" | sed -E "s/--processes=[^[:space:]]+/--processes=${PHP_TEST_PROCESSES}/g")
    TMP=$(echo "$TMP" | sed -E "s/--processes[[:space:]]+[^[:space:]]+/--processes ${PHP_TEST_PROCESSES}/g")
  else
    TMP=$(echo "$TMP" | sed "s/--parallel/--parallel --processes=${PHP_TEST_PROCESSES}/")
  fi
  if [[ "$TMP" != "$NEW_COMMAND" ]]; then
    NEW_COMMAND="$TMP"
    add_reason "forced PHP parallel workers to ${PHP_TEST_PROCESSES}"
  fi
fi

# Force Vitest to limited workers.
# Vitest 4.x removed --pool-options.threads.*; use --maxWorkers instead.
# W27-F8: require true command boundary (^|;&|()) instead of any whitespace
if echo "$NEW_COMMAND" | grep -qE '(^|[;&|()]+[[:space:]]*)(npx[[:space:]]+)?([^[:space:]]*/)?vitest([[:space:]]|$)'; then
  TMP="$NEW_COMMAND"
  if echo "$TMP" | grep -q -- '--maxWorkers'; then
    TMP=$(echo "$TMP" | sed -E "s/--maxWorkers(=|[[:space:]]+)[^[:space:]]+/--maxWorkers=${VITEST_THREADS}/g")
  elif ! echo "$TMP" | grep -qE '\|'; then
    TMP="$TMP --maxWorkers=${VITEST_THREADS}"
  fi
  if [[ "$TMP" != "$NEW_COMMAND" ]]; then
    NEW_COMMAND="$TMP"
    add_reason "forced Vitest workers to ${VITEST_THREADS}"
  fi
fi

# Force Jest to one worker.
# W27-F8: require true command boundary
if echo "$NEW_COMMAND" | grep -qE '(^|[;&|()]+[[:space:]]*)(npx[[:space:]]+)?([^[:space:]]*/)?jest([[:space:]]|$)'; then
  TMP="$NEW_COMMAND"
  TMP=$(echo "$TMP" | sed -E "s/--maxWorkers=[^[:space:]]+/--maxWorkers=${JEST_MAX_WORKERS}/g")
  TMP=$(echo "$TMP" | sed -E "s/--maxWorkers[[:space:]]+[^[:space:]]+/--maxWorkers ${JEST_MAX_WORKERS}/g")
  if ! echo "$TMP" | grep -q -- '--runInBand' && ! echo "$TMP" | grep -qE '\|'; then
    TMP="$TMP --runInBand"
  fi
  if [[ "$TMP" != "$NEW_COMMAND" ]]; then
    NEW_COMMAND="$TMP"
    add_reason "forced Jest workers to ${JEST_MAX_WORKERS} and enabled runInBand"
  fi
fi

# Clamp pytest-xdist to one worker when present.
# W27-F8: require true command boundary
if echo "$NEW_COMMAND" | grep -qE '(^|[;&|()]+[[:space:]]*)([^[:space:]]*/)?pytest([[:space:]]|$)'; then
  TMP="$NEW_COMMAND"
  TMP=$(echo "$TMP" | sed -E "s/(^|[[:space:]])-n[[:space:]]+[^[:space:]]+/\\1-n ${PYTEST_WORKERS}/g")
  TMP=$(echo "$TMP" | sed -E "s/--numprocesses(=|[[:space:]]+)[^[:space:]]+/--numprocesses=${PYTEST_WORKERS}/g")
  if [[ "$TMP" != "$NEW_COMMAND" ]]; then
    NEW_COMMAND="$TMP"
    add_reason "forced pytest-xdist workers to ${PYTEST_WORKERS}"
  fi
fi

# Force Playwright to one worker.
# W27-F8: require true command boundary
if echo "$NEW_COMMAND" | grep -qE '(^|[;&|()]+[[:space:]]*)(npx[[:space:]]+)?([^[:space:]]*/)?playwright[[:space:]]+test([[:space:]]|$)'; then
  TMP="$NEW_COMMAND"
  TMP=$(echo "$TMP" | sed -E "s/--workers=[^[:space:]]+/--workers=${PLAYWRIGHT_WORKERS}/g")
  TMP=$(echo "$TMP" | sed -E "s/--workers[[:space:]]+[^[:space:]]+/--workers ${PLAYWRIGHT_WORKERS}/g")
  if ! echo "$TMP" | grep -q -- '--workers' && ! echo "$TMP" | grep -qE '\|'; then
    TMP="$TMP --workers=${PLAYWRIGHT_WORKERS}"
  fi
  if [[ "$TMP" != "$NEW_COMMAND" ]]; then
    NEW_COMMAND="$TMP"
    add_reason "forced Playwright workers to ${PLAYWRIGHT_WORKERS}"
  fi
fi

# Force cargo test to one thread.
# W27-F8: require true command boundary
if echo "$NEW_COMMAND" | grep -qE '(^|[;&|()]+[[:space:]]*)cargo[[:space:]]+test([[:space:]]|$)'; then
  TMP="$NEW_COMMAND"
  TMP=$(echo "$TMP" | sed -E "s/--test-threads(=|[[:space:]]+)[^[:space:]]+/--test-threads=${CARGO_TEST_THREADS}/g")
  if ! echo "$TMP" | grep -q -- '--test-threads' && ! echo "$TMP" | grep -qE '\|'; then
    if echo "$TMP" | grep -qE '[[:space:]]--[[:space:]]'; then
      TMP="$TMP --test-threads=${CARGO_TEST_THREADS}"
    else
      TMP="$TMP -- --test-threads=${CARGO_TEST_THREADS}"
    fi
  fi
  if [[ "$TMP" != "$NEW_COMMAND" ]]; then
    NEW_COMMAND="$TMP"
    add_reason "forced cargo test threads to ${CARGO_TEST_THREADS}"
  fi
fi

# Force go test package parallelism to one.
# W27-F8: require true command boundary
if echo "$NEW_COMMAND" | grep -qE '(^|[;&|()]+[[:space:]]*)go[[:space:]]+test([[:space:]]|$)'; then
  TMP="$NEW_COMMAND"
  TMP=$(echo "$TMP" | sed -E "s/-p=[^[:space:]]+/-p=${GO_TEST_P}/g")
  TMP=$(echo "$TMP" | sed -E "s/(^|[[:space:]])-p[[:space:]]+[^[:space:]]+/\\1-p ${GO_TEST_P}/g")
  if ! echo "$TMP" | grep -qE "(^|[[:space:]])-p(=|[[:space:]]+)${GO_TEST_P}([[:space:]]|$)"; then
    TMP=$(echo "$TMP" | sed -E "s/go[[:space:]]+test/go test -p ${GO_TEST_P}/")
  fi
  if [[ "$TMP" != "$NEW_COMMAND" ]]; then
    NEW_COMMAND="$TMP"
    add_reason "forced go test package parallelism to ${GO_TEST_P}"
  fi
fi

# Bound Node.js heap usage for package-manager and node-based commands.
if [ "$NODE_HEAP_MB" -gt 0 ] && contains_node_runtime_command "$NEW_COMMAND" && ! command_has_explicit_node_heap_cap "$NEW_COMMAND"; then
  TMP="export NODE_OPTIONS=\"\${NODE_OPTIONS:+\$NODE_OPTIONS }--max-old-space-size=${NODE_HEAP_MB}\"; $NEW_COMMAND"
  if [[ "$TMP" != "$NEW_COMMAND" ]]; then
    NEW_COMMAND="$TMP"
    add_reason "capped Node heap to ${NODE_HEAP_MB} MiB"
  fi
fi

if [[ "$NEW_COMMAND" = "$COMMAND" ]]; then
  exit 0
fi

REASON=$(printf '%s; ' "${REASONS[@]}")
REASON=${REASON%; }

UPDATED_INPUT=$(echo "$INPUT" | jq --arg cmd "$NEW_COMMAND" '.tool_input.command = $cmd')
jq -n --argjson updated "$(echo "$UPDATED_INPUT" | jq '.tool_input')" \
  --arg reason "Auto-throttled worker usage and Node heap size: ${REASON}" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":$updated,"additionalContext":$reason}}'
