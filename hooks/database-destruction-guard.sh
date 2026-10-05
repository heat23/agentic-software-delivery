#!/usr/bin/env bash
# database-destruction-guard.sh
# SAFETY HOOK — P0
# Event: PreToolUse/Bash
# Blocks: migrate:fresh, migrate:reset, db:wipe, eloquent:prune,
#          and raw destructive SQL (DELETE without WHERE, TRUNCATE, DROP DATABASE)
# Never blocks: migrate (normal), migrate:rollback (limited), seeds on local

set -euo pipefail

# W83-F3 opt-in profiling — no-op unless CLAUDE_HOOK_PROFILE=1
if [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh"
  profile_start "database-destruction-guard"
fi



# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e


# === TDD-Item-2: fail-closed on broken tools ===
# Verify intermediate tools work before relying on them for safety decisions.
# Without this, a poisoned PATH or broken utility could let a malicious
# payload pass silently (set +e above intentionally disables errexit for
# JSON-parsing tolerance, which would otherwise mask such failures).
_tdd_item2_security_self_test() {
  echo X | grep X >/dev/null 2>&1 || return 1
  return 0
}
if ! _tdd_item2_security_self_test; then
  printf '%s
' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (database-destruction-guard): a required tool (grep) failed its self-test. Cannot verify safety. Repair PATH and retry."}}'
  profile_done
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for database-destruction enforcement. Install jq and retry."}}'
  profile_done
  exit 0
fi


# Resolve hooks/lib path robustly (works under any $HOME).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_deny

HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
SEGMENT_LIB="$HOOKS_LIB_DIR/command-segments.sh"
if [[ -f "$SEGMENT_LIB" ]]; then
  source "$SEGMENT_LIB"
else
  split_shell_command_segments() {
    printf '%s\n' "$1"
  }
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  profile_done
  exit 0
fi

# Environment helper: returns 0 when the current env is non-local and should be blocked.
# Returns 1 when env cannot be determined or is local/testing (allowed).
should_block_non_local_env() {
  if [ ! -f .env ]; then
    return 1
  fi

  local app_env
  app_env=$(grep -E '^APP_ENV=' .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
  if [ -z "$app_env" ]; then
    return 1
  fi

  if [[ "$app_env" != "local" && "$app_env" != "testing" ]]; then
    printf '%s' "$app_env"
    return 0
  fi

  return 1
}

SEGMENT=""
while IFS= read -r SEGMENT; do
  [ -z "$SEGMENT" ] && continue

  # ── 1. UNCONDITIONAL blocks (always prohibited regardless of env) ───────────
  # migrate:fresh and migrate:reset ALWAYS require manual execution
  if printf '%s\n' "$SEGMENT" | grep -qE '\bartisan\b.*(migrate:(fresh|reset)|db:wipe)\b'; then
    OPERATION=$(printf '%s\n' "$SEGMENT" | grep -oE 'migrate:(fresh|reset)|db:wipe' | head -1)
    REASON=$(printf 'BLOCKED: artisan %s destroys ALL database data. This command is never executed autonomously. Run it manually in your terminal after confirming you are in the correct environment.' "$OPERATION")
    jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
    profile_done
    exit 0
  fi

  # ── 2. ENV-GATED blocks ─────────────────────────────────────────────────────
  if printf '%s\n' "$SEGMENT" | grep -qE '\bartisan\b.*migrate:rollback\b'; then
    APP_ENV=$(should_block_non_local_env || true)
    if [ -n "$APP_ENV" ]; then
      REASON=$(printf 'BLOCKED: migrate:rollback outside local environment (APP_ENV=%s). Migration rollbacks on non-local environments require manual execution to prevent data loss.' "${APP_ENV:-unknown}")
      jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
      profile_done
      exit 0
    fi
  fi

  # ── 3. Destructive SQL patterns ─────────────────────────────────────────────
  if printf '%s\n' "$SEGMENT" | grep -qiE '\bTRUNCATE\s+TABLE\b|\bDROP\s+TABLE\b|\bDROP\s+DATABASE\b|\bDROP\s+SCHEMA\b'; then
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Destructive SQL detected (TRUNCATE/DROP TABLE/DROP DATABASE). Use migrations for schema changes and soft deletes for data removal. Run this manually if intentional."}}'
    profile_done
    exit 0
  fi

  # DELETE FROM without WHERE (full table wipe). Match plain, quoted, and
  # schema-qualified identifiers such as users, `users`, "users", or public.users.
  if printf '%s\n' "$SEGMENT" | grep -qiE '\bDELETE\s+FROM\s+[`"]?[A-Za-z0-9_.-]+[`"]?' \
    && ! printf '%s\n' "$SEGMENT" | grep -qiE '\bDELETE\s+FROM\s+[`"]?[A-Za-z0-9_.-]+[`"]?.*\bWHERE\b'; then
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: DELETE FROM without WHERE clause detected — this would wipe an entire table. Add a WHERE clause or use soft deletes."}}'
    profile_done
    exit 0
  fi

  # eloquent:prune wipes records matching prunable models
  if printf '%s\n' "$SEGMENT" | grep -qE '\bartisan\b.*eloquent:prune\b'; then
    APP_ENV=$(should_block_non_local_env || true)
    if [ -n "$APP_ENV" ]; then
      REASON=$(printf 'BLOCKED: eloquent:prune outside local environment (APP_ENV=%s). Pruning deletes records permanently. Run manually after verifying scope.' "${APP_ENV:-unknown}")
      jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
      profile_done
      exit 0
    fi
  fi
done < <(split_shell_command_segments "$COMMAND")

profile_done
exit 0
