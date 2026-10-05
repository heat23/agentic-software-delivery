#!/usr/bin/env bash
# block-vtmp-typo.sh
# WORKFLOW GUARD — P1
# Event: PreToolUse/Bash and PreToolUse/Write|Edit
# Version: 1.0.0
# Purpose: Prevent the orchestrator from writing to a hallucinated `.v-tmp/`
#          directory at the project root. The canonical scratch path is
#          `.v/tmp/` (hierarchical), but models conflate the lib filename
#          `v-tmp-dir.sh` and env var `$V_TMP_DIR` into a flat `.v-tmp/`
#          path and write files there instead. Block + redirect at the
#          tool-call boundary so the model retries with the right path.

set -euo pipefail

# W83-F3 opt-in profiling — no-op unless CLAUDE_HOOK_PROFILE=1
if [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh"
  profile_start "block-vtmp-typo"
fi



# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_deny

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

deny() {
  local reason="$1"
  jq -n --arg reason "$reason" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  profile_done
  exit 0
}

REASON='BLOCKED: writing to `.v-tmp/` is a known typo. The canonical scratch directory is `.v/tmp/` (note: hierarchical, NOT hyphenated). Rewrite the path: replace `.v-tmp/` with `.v/tmp/` and retry. The orchestrator scratch dir, gate logs, gate summary, and commit-msg templates all live under `.v/tmp/`. If you need the absolute path, use `$V_TMP_DIR` (set by Step 0 bootstrap) or `$(git rev-parse --show-toplevel)/.v/tmp/`.'

# Pattern matches `.v-tmp/` ONLY when used as a path (trailing slash
# required). This intentionally requires the slash so prose mentions of
# `.v-tmp` (e.g., in a commit message body talking about the rename) are
# not blocked.
PATTERN='(^|[[:space:]/=":'"'"'\$\(\)])\.v-tmp/'

# W-VTMP-READ (2026-08-09): for Bash, deny only when the path is in a WRITE position.
#
# This hook previously denied ANY Bash command whose text contained `.v-tmp/`. That is one layer
# off the property it exists to protect: the harm is CREATING files under the typo path, not
# naming it. Measured cost of the over-broad form during the 2026-08-09 forensic pass: it denied
# `ls -lt .v-tmp/`, and then denied an `echo` whose only sin was quoting the path inside a
# progress message — i.e. it made the directory both un-inspectable and un-discussable in a shell.
#
# It also never stopped the writes that actually happened. `~/.claude/.v-tmp/` exists with 50
# files (gate logs, gate-summary, pre-flight skeletons from a production session, newest 2026-08-04),
# because those were produced by scripts INSIDE a Bash call — the hook sees the outer command
# line, not paths a script constructs at runtime. A tree-wide search finds no live producer today
# (only prose references in v/SKILL.md and v-runtime-prereqs.md), so the guard's remaining live
# effect was friction against reads.
#
# FAILURE DIRECTION: an allowed command must contain no redirect, tee, or mutating verb whose
# operand region reaches the path. A read-only command cannot create a file there by any route
# this hook could have intercepted anyway. Write/Edit/MultiEdit below stay UNCONDITIONALLY denied
# — that branch targets a literal file_path and has no read/write ambiguity to resolve.
# Bite: hooks/block-vtmp-typo-read-test.sh.
WRITE_PATTERN='((>>?|\btee\b|\b(cp|mv|mkdir|touch|rm|rmdir|ln|dd|rsync|install|truncate|chmod|chown)\b|\bsed\b[^|;&]*-i)[^|;&]*\.v-tmp/)'

if [[ "$TOOL_NAME" == "Bash" ]] || [[ "$TOOL_NAME" == "mcp__workspace__bash" ]]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  if printf '%s\n' "$COMMAND" | grep -qE "$PATTERN"; then
    if printf '%s\n' "$COMMAND" | grep -qE "$WRITE_PATTERN"; then
      deny "$REASON"$'\n\nOffending command snippet:\n'"$(printf '%s\n' "$COMMAND" | grep -nE "$WRITE_PATTERN" | head -3)"
    fi
  fi
fi

if [[ "$TOOL_NAME" == "Write" ]] || [[ "$TOOL_NAME" == "Edit" ]] || [[ "$TOOL_NAME" == "MultiEdit" ]]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  if printf '%s\n' "$FILE_PATH" | grep -qE "$PATTERN"; then
    deny "$REASON"$'\n\nOffending file path: '"$FILE_PATH"
  fi
fi

profile_done
exit 0
