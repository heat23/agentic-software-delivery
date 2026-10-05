#!/usr/bin/env bash
# stop-completion-check.sh
# SAFETY HOOK (sync) — P2
# Event: Stop
# Version: 1.0.0
# Purpose: Deterministic completion detection — replaces the haiku LLM Stop hook
#          (AVF-028). The LLM hook processed $ARGUMENTS (which contains untrusted
#          session content: repo files, commit messages, branch names) through an AI
#          model, creating a prompt injection vector. This script uses only regex
#          pattern matching and git state inspection — no LLM, no eval, no source
#          of untrusted content.
#
# Detects session completion via regex on last_assistant_message.
# When completion is detected and code changed, checks for required artifacts.
# Outputs advisory context only — does NOT block (check-review-artifact.sh blocks).
#
# Exit 0 = allow session to continue. JSON on stdout/stderr for additionalContext.

set -euo pipefail


# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
source "$HOOKS_LIB_DIR/v-tmp-dir.sh"
require_jq_or_skip

# Read stdin JSON — treated as DATA ONLY. Never eval'd or source'd.
INPUT=$(cat)

# Prevent Stop hook infinite loop
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi

# Only run inside git repositories
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

IMPLEMENTATION_ONLY_MODE="${CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY:-0}"

# ── Extract last assistant message ──────────────────────────────────────────
# Read as data only. Content is untrusted — only passed to grep regex, never
# evaluated or interpreted as code/instructions.
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")

# ── Completion detection (deterministic regex) ───────────────────────────────
# Pattern matches phrases that indicate a task is fully done.
# Anchored/bounded patterns prevent false positives on partial phrases like
# "I'm working on completing this" or "not yet complete".
#
# Tested non-matches (should NOT trigger):
#   "I'm working on completing this"    -- no word boundary on "complet" alone
#   "This is not yet done"              -- "done" preceded by "not yet"
#   "I will fix this soon"              -- "fix" alone, not "fixed"
#   "completing setup"                  -- "completing" without task context
#
# Tested matches (SHOULD trigger):
#   "Implementation is complete"        -- "complete" as standalone word
#   "All changes have been applied"     -- "all changes ... applied"
#   "The feature has been implemented"  -- "implemented"
#   "Done. The fix has been deployed"   -- "done" at start of sentence
COMPLETION_PATTERN='(^|[^a-z])(complete|completed|done|finished|implemented|resolved|fixed|accomplished|delivered|deployed|landed|wrapped|shipped|merged|finalized)([^a-z]|$)|all[[:space:]]+(tasks?|changes?|fixes?|updates?)[[:space:]]+(are[[:space:]]+|have[[:space:]]+been[[:space:]]+)?(complete|completed|done|applied|implemented|implemented|finished|resolved|fixed)'

COMPLETION_DETECTED=0
if echo "$LAST_MSG" | LC_ALL=C grep -qiE "$COMPLETION_PATTERN"; then
  COMPLETION_DETECTED=1
fi

# If no completion language detected, exit cleanly — nothing to check.
if [ "$COMPLETION_DETECTED" -eq 0 ]; then
  exit 0
fi

# ── Check for artifact validation library ────────────────────────────────────
# Source validation.sh if available (created by Phase 3 Prompt 01).
# If unavailable, perform inline artifact checks below.
VALIDATION_LIB="$HOOKS_LIB_DIR/validation.sh"
if [ -f "$VALIDATION_LIB" ]; then
  # shellcheck disable=SC1090
  source "$VALIDATION_LIB"
fi

# Load shared session-writes helpers (parallel-session safe attribution)
SESSION_WRITES_LIB="$HOOKS_LIB_DIR/session-writes.sh"
if [ -f "$SESSION_WRITES_LIB" ]; then
  # shellcheck disable=SC1090
  source "$SESSION_WRITES_LIB"
fi

# ── Determine if code changed this session ───────────────────────────────────
# W70: canonical SID resolver (env + runtime-file fallback + stdin JSON)
source "$HOME/.claude/hooks/lib/resolve-sid.sh"
SESSION_ID=$(resolve_sid "$INPUT")

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
MAIN_ROOT=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
MAIN_ROOT="${MAIN_ROOT:-$REPO_ROOT}"

# ND-0716: source the SHARED pattern lib (ORCHFIX-C class — this file carried the THIRD stale
# private copy: no .sh/.sql/.yml/.json, no Dockerfile/workflows, so its advisory "code not
# changed" signal lied on config/schema-only diffs). Inline fallback = same values as the lib.
_CEP_LIB="$HOME/.claude/hooks/lib/code-ext-pattern.sh"
if [ -f "$_CEP_LIB" ]; then
  # shellcheck source=lib/code-ext-pattern.sh
  source "$_CEP_LIB"
else
  CODE_EXT_PATTERN='\.(php|ts|tsx|js|jsx|mjs|cjs|vue|svelte|py|rb|go|rs|java|kt|kts|swift|c|cc|cpp|cxx|h|hh|hpp|cs|scala|ex|exs|sh|bash|zsh|sql|m|mm|dart|lua|pl|pm|r|clj|cljs|erl|hs|yml|yaml|json|neon|toml|lock)$|(^|/)Dockerfile[^/]*$|(^|/)Makefile$|(^|/)\.husky/[^/.]+$|(^|/)\.github/workflows/[^/]+$'
  CODE_EXT_EXEMPT='(^|/)(SESSION_LOG_[^/]*\.ya?ml(\.invalid)?|OP_TELEMETRY_[^/]*\.json|[A-Z][A-Z0-9_]*_(AUDIT|REPORT)_[^/]*\.json)$|(^|/)\.v/|(^|/)\.v-prompt-packs/|(^|/)\.audit[0-9]*/'
fi
CODE_CHANGED=0
WRITES_LOG_AVAILABLE=0

# Primary attribution: per-session writes log (parallel-session safe).
# See check-review-artifact.sh for the rationale — git working tree is shared
# across parallel Claude sessions and cannot be used for session attribution.
if type get_session_writes >/dev/null 2>&1; then
  _writes=$(get_session_writes "$SESSION_ID" 2>/dev/null || true)
  if [ -n "$_writes" ] || [ -f "$(session_writes_log_path "$SESSION_ID" 2>/dev/null || true)" ]; then
    WRITES_LOG_AVAILABLE=1
    # See check-review-artifact.sh for why we avoid `grep -q` on pipes here.
    if [ -n "$_writes" ]; then
      _match=$(printf '%s\n' "$_writes" | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
      [ -n "$_match" ] && CODE_CHANGED=1
    fi
  fi
fi

# Legacy fallback: session predates the track-session-writes.sh hook.
if [ "$WRITES_LOG_AVAILABLE" -eq 0 ]; then
  # Unstaged + staged + untracked
  CHANGED_CODE=$(git diff --name-only HEAD 2>/dev/null | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
  STAGED_CODE=$(git diff --cached --name-only 2>/dev/null | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
  UNTRACKED_CODE=$(git ls-files --others --exclude-standard 2>/dev/null | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
  if [ -n "${CHANGED_CODE}${STAGED_CODE}${UNTRACKED_CODE}" ]; then
    CODE_CHANGED=1
  fi

  # Committed changes since session start (baseline from session-env-check.sh)
  if [ "$CODE_CHANGED" -eq 0 ] && [ -n "$SESSION_ID" ]; then
    HEAD_BASELINE="$(v_tmp_find "head-baseline-${SESSION_ID}.txt")"
    if [ -f "$HEAD_BASELINE" ]; then
      START_HEAD=$(head -1 "$HEAD_BASELINE" 2>/dev/null || true)
      CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || true)
      if [ -n "$START_HEAD" ] && [ "$START_HEAD" != "$CURRENT_HEAD" ]; then
        COMMITTED_CODE=$(git diff --name-only "${START_HEAD}..${CURRENT_HEAD}" 2>/dev/null | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
        [ -n "$COMMITTED_CODE" ] && CODE_CHANGED=1
      fi
    fi
  fi
fi

# ── Artifact presence check ───────────────────────────────────────────────────
# Advisory only — check-review-artifact.sh is the authoritative blocker.
# This hook emits a friendly reminder if artifacts are missing at completion time.
# ITEM 27b (forensics remediation 2026-07-03, R4 M-1 / R2 MEDIUM-2 split-brain): this search set
# used to be root-only — a verify-done pass reported an AGENT_REVIEW artifact "missing" while it
# had sat in .v/artifacts/ for hours (artifacts are consolidated there, not left at repo root — see
# W-perf6/W-perf8). Same lookup-fix family as the already-landed archive-sweep in
# skills/v-session-log/references/v-session-log-integrity.sh (search BOTH root and .v/artifacts, plus
# .v/archive/<sid> for a since-archived canonical). Additive: still advisory, never blocks.
ARTIFACT_SEARCH_DIRS=("$REPO_ROOT" "$REPO_ROOT/.v/artifacts")
[ -n "$SESSION_ID" ] && ARTIFACT_SEARCH_DIRS+=("$REPO_ROOT/.v/archive/${SESSION_ID}")
if [ "$MAIN_ROOT" != "$REPO_ROOT" ]; then
  ARTIFACT_SEARCH_DIRS+=("$MAIN_ROOT" "$MAIN_ROOT/.v/artifacts")
  [ -n "$SESSION_ID" ] && ARTIFACT_SEARCH_DIRS+=("$MAIN_ROOT/.v/archive/${SESSION_ID}")
fi

PREFLIGHT_FOUND=0
REVIEW_FOUND=0
IMPLEMENTATION_FOUND=0

if [ -n "$SESSION_ID" ]; then
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    if [ "$IMPLEMENTATION_ONLY_MODE" = "1" ]; then
      if ls "${_dir}/IMPLEMENTATION_REPORT_"*"${SESSION_ID}"*.md 2>/dev/null | head -1 | grep -q .; then
        IMPLEMENTATION_FOUND=1
      fi
    else
      if ls "${_dir}/PRE_FLIGHT_REPORT_"*"${SESSION_ID}"*.md 2>/dev/null | head -1 | grep -q .; then
        PREFLIGHT_FOUND=1
      fi
      if ls "${_dir}/AGENT_REVIEW_"*"${SESSION_ID}"*.md 2>/dev/null | head -1 | grep -q .; then
        REVIEW_FOUND=1
      fi
    fi
  done
fi

# ── Emit advisory context ─────────────────────────────────────────────────────
if [ "$CODE_CHANGED" -eq 1 ]; then
  if [ "$IMPLEMENTATION_ONLY_MODE" = "1" ]; then
    if [ "$IMPLEMENTATION_FOUND" -eq 0 ]; then
      # W38-A: Stop hook schema does NOT support hookSpecificOutput.additionalContext.
      # Same bug as W36-A (completion-summary.sh) — use systemMessage at top level.
      CTX="COMPLETION DETECTED — missing session artifact: IMPLEMENTATION_REPORT. Runner-managed implementation-only sessions should write IMPLEMENTATION_REPORT_<session>.md and let the external runner own pre-flight, review, and verify-done."
      jq -n --arg msg "$CTX" '{"systemMessage":$msg}'
    fi
  else
    MISSING=""
    [ "$PREFLIGHT_FOUND" -eq 0 ] && MISSING="${MISSING} PRE_FLIGHT_REPORT"
    [ "$REVIEW_FOUND" -eq 0 ] && MISSING="${MISSING} AGENT_REVIEW"

    if [ -n "$MISSING" ]; then
      CTX="COMPLETION DETECTED — missing session artifacts:${MISSING}. Run /v-pre-flight and dispatch agent review before the session ends. check-review-artifact.sh will block if these remain absent."
      # W38-A: Stop hook schema fix.
      jq -n --arg msg "$CTX" '{"systemMessage":$msg}'
    fi
  fi
fi

exit 0
