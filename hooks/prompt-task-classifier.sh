#!/usr/bin/env bash
# prompt-task-classifier.sh
# WORKFLOW HOOK — P2
# Event: UserPromptSubmit
# Purpose: Classify the incoming task and inject appropriate workflow context.
#          - Detects code-change requests and reminds about /v-first rule
#          - Detects Large-scope signals and reminds about worktree requirement
#          - Detects billing/auth keywords and injects elevated review reminder
#          - Detects security-sensitive keywords and adds security context
# NOTE: async=true — advisory context only, does not block.

set -euo pipefail



# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)

# W25-F6: Persist the user's literal prompt to a known location so /v can fall back to
# reading it when the Skill tool's args field arrives empty (Claude Code drops args for
# slash-command-invoked skills with `context: fork` and image attachments — confirmed
# 2026-05-10 across multiple production sessions). The skill's Step -3 reads this file
# as a fallback when its own args is empty/whitespace-only.
#
# Capture even an empty prompt so the skill can distinguish "user actually typed nothing"
# from "args propagation dropped the user's text on the way to the fork." Write to a
# stable path (no SID required at hook fire time) — newest-mtime wins for the consumer.
W25_F6_CAPTURE_DIR="${HOME}/.claude/runtime"
if mkdir -p "$W25_F6_CAPTURE_DIR" 2>/dev/null; then
  # W25-F9: Resolve SID from input (UserPromptSubmit JSON has .session_id) and
  # write ONLY the SID-scoped capture. The unscoped last-user-prompt.txt write
  # was REMOVED because it caused cross-session contamination when multiple
  # Claude Code sessions ran in parallel — Session A overwrote it, then
  # Session B's /v read Session A's prompt as if it were B's task.
  #
  # Self-healing: delete any stale unscoped file from a previous installation
  # on every fire. Cheap (one stat + one unlink), prevents lingering
  # cross-session leakage if any forgotten consumer still reads the unscoped
  # path.
  [ -f "$W25_F6_CAPTURE_DIR/last-user-prompt.txt" ] && rm -f "$W25_F6_CAPTURE_DIR/last-user-prompt.txt" 2>/dev/null || true
  # Write atomically — .tmp then mv so readers never see a half-write.
  W25_F6_SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  if [ -n "$W25_F6_SID" ]; then
    W25_F6_SID_FILE="${W25_F6_CAPTURE_DIR}/last-user-prompt-${W25_F6_SID}.txt"
    printf '%s' "$PROMPT" > "${W25_F6_SID_FILE}.tmp" 2>/dev/null && \
      mv "${W25_F6_SID_FILE}.tmp" "$W25_F6_SID_FILE" 2>/dev/null || true
  fi
fi

[ -z "$PROMPT" ] && exit 0

LOWER_PROMPT=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')
CONTEXT=""

# ── Detect code-change intent ─────────────────────────────────────────────────
CODE_CHANGE_WORDS="implement|add|create|build|write|fix|refactor|update|modify|change|delete|remove|rename|move|extract|replace|integrate"
if echo "$LOWER_PROMPT" | grep -qE "\b($CODE_CHANGE_WORDS)\b"; then
  # Only inject if /v is not already mentioned in the prompt
  if ! echo "$LOWER_PROMPT" | grep -qE '\bv(-|\s)?(build|plan|pre.?flight|check|polish|verify|new.?feature|setup|ship|docs|refactor)\b|^/v\b'; then
    CONTEXT="$CONTEXT
📋 WORKFLOW REMINDER: For code changes, invoke /v first to ensure proper quality gates, scope classification, and agent review. /v routes this through pre-flight, adversarial review, and completion verification."
  fi
fi

# ── Detect Large-scope signals ────────────────────────────────────────────────
LARGE_SCOPE_WORDS="new feature|new page|new module|new service|new api|full|complete|entire|whole|all.*routes|all.*components|redesign|refactor.*entire|migrate.*all"
if echo "$LOWER_PROMPT" | grep -qE "$LARGE_SCOPE_WORDS"; then
  CONTEXT="$CONTEXT
🔧 SCOPE REMINDER: This appears to be a Large-scope task (10+ files). /v will automatically create a git worktree for isolation. Do not skip worktree creation for Large tasks."
fi

# ── Detect billing/auth sensitive context ────────────────────────────────────
BILLING_WORDS="billing|subscription|stripe|payment|checkout|invoice|charge|webhook|cashier|plan|upgrade|downgrade|cancel"
AUTH_WORDS="auth|authentication|login|register|password|token|session|oauth|sanctum|permission|role|middleware"
if echo "$LOWER_PROMPT" | grep -qE "\b($BILLING_WORDS)\b"; then
  CONTEXT="$CONTEXT
💳 BILLING CONTEXT: This task involves billing/payment code. ELEVATED review required:
  - Test coverage must be 100% for changed billing paths
  - Verify eager-loading before billing API calls
  - Run adversarial review with billing-specific threat model
  - Create BILLING_REVIEWED_<session-id>.md marker before committing"
fi

if echo "$LOWER_PROMPT" | grep -qE "\b($AUTH_WORDS)\b" && ! echo "$LOWER_PROMPT" | grep -qE "\b($BILLING_WORDS)\b"; then
  CONTEXT="$CONTEXT
🔐 AUTH CONTEXT: This task involves authentication/authorization. Ensure:
  - All new routes have auth middleware
  - Queries are tenant/user-scoped (no unscoped model access)
  - No mass-assignment vulnerabilities in fillable arrays"
fi

# ── Detect database schema changes ───────────────────────────────────────────
SCHEMA_WORDS="migration|migrate|schema|column|table|index|foreign key|add field|rename.*column|drop.*column"
if echo "$LOWER_PROMPT" | grep -qE "\b($SCHEMA_WORDS)\b"; then
  CONTEXT="$CONTEXT
🗄  DATABASE CONTEXT: This task may involve schema changes. Remember:
  - New migrations need a down() rollback method
  - NOT NULL columns on existing tables need ->default() or ->nullable()
  - Applied migrations cannot be edited — create a new migration instead
  - Two-phase deploys for breaking schema changes (add nullable first, populate, then add NOT NULL)"
fi

if [ -n "$CONTEXT" ]; then
  # Output as additionalContext using jq for proper JSON escaping (handles pipes, quotes, etc.)
  # jq is guaranteed available — line 15 already uses it to parse input (fails gracefully if missing)
  jq -n --arg ctx "$CONTEXT" '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":$ctx}}'
fi

exit 0
