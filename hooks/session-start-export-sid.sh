#!/usr/bin/env bash
# session-start-export-sid.sh
# RUNTIME PREREQUISITE — installed for the W22-2 Prereq 1 (CLAUDE_SESSION_ID).
# Event: SessionStart
# Version: 2.0.0   ← W23 follow-up (FND-19): persist SID to file, not stdout
#
# Purpose: Make CLAUDE_SESSION_ID resolvable from inside any future Bash tool
#   invocation in this session. Claude Code's SessionStart hook contract treats
#   stdout as `additionalContext` text — it does NOT source the output into
#   subsequent bash environments. Each Bash tool call spawns a fresh shell with
#   no env carryover. The previous v1 hook printed `export CLAUDE_SESSION_ID=...`
#   on stdout and assumed it would be sourced; production logs (2026-04-29)
#   confirmed this never works — bootstrap saw empty SID every time.
#
# v2 fix: WRITE the resolved SID to ~/.claude/runtime/current-session-id (a file
#   that v-bootstrap.sh reads as a fallback source). The file is overwritten on
#   every SessionStart, so a stale value from a prior session is never used.
#
# Source priority for resolution:
#   1. SessionStart hook payload (.session_id from JSON input)   ← most reliable
#   2. Existing $CLAUDE_SESSION_ID env (if already set)
#   3. Most recent attestation file in ~/.claude/attestations/
#   4. Otherwise: write empty file + surface warning
#
# Why we don't read from ~/.claude/runtime/current-session-id ourselves: that
# would create a circular fallback if the file is stale. We always write fresh.

set -euo pipefail

# Read JSON input (Claude Code SessionStart hook spec)
INPUT=""
if [ -t 0 ]; then
  INPUT=""
else
  INPUT=$(cat)
fi

resolve_session_id() {
  local sid=""

  # Source 1: hook input (most reliable — Claude Code passes it explicitly)
  if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
    sid=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
    if [ -n "$sid" ]; then
      echo "$sid"
      return
    fi
  fi

  # Source 2: env (already set by parent process — Claude Code itself, perhaps)
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    echo "$CLAUDE_SESSION_ID"
    return
  fi

  # Source 3: most recent attestation file (last resort — could be stale)
  local attest_dir="${HOME}/.claude/attestations"
  if [ -d "$attest_dir" ]; then
    local recent
    recent=$(ls -t "$attest_dir"/*.json 2>/dev/null | head -1)
    if [ -n "$recent" ] && [ -f "$recent" ]; then
      sid=$(basename "$recent" .json 2>/dev/null || true)
      # Validate UUID-like shape
      if echo "$sid" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        echo "$sid"
        return
      fi
    fi
  fi

  # No source — empty output. Downstream bootstrap will surface DETECTION_ERROR.
  echo ""
}

SID=$(resolve_session_id)

# Persist the SID (or empty) to the runtime file. Always overwrite so prior
# sessions can't leak through. Atomic write: tmp+rename.
RUNTIME_DIR="${HOME}/.claude/runtime"
SID_FILE="${RUNTIME_DIR}/current-session-id"
mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
TMP_FILE="${SID_FILE}.tmp.$$"
printf '%s\n' "$SID" > "$TMP_FILE" 2>/dev/null && mv -f "$TMP_FILE" "$SID_FILE" 2>/dev/null || true

if [ -n "$SID" ]; then
  # Also emit JSON envelope so Claude Code surfaces resolution status as context.
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg sid "$SID" --arg file "$SID_FILE" '{
      "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "CLAUDE_SESSION_ID resolved to \($sid) and persisted to \($file) (W22-2 Prereq 1, v2)"
      }
    }'
  fi
else
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg file "$SID_FILE" '{
      "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "WARN: CLAUDE_SESSION_ID could not be resolved by session-start-export-sid.sh. Empty file written to \($file). /v bootstrap will surface DETECTION_ERROR=session_id_unset_at_bootstrap unless something else (e.g. parent env) provides it. See /v SKILL.md § Runtime Prerequisites Prereq 1."
      }
    }'
  fi
fi

exit 0
