#!/usr/bin/env bash
# block-pr-creation.sh
# WORKFLOW GUARD — P1
# Event: PreToolUse/Bash and PreToolUse/mcp__codex_apps__github_create_pull_request
# Version: 2.0.0
# Purpose: Prevent autonomous PR creation in a solo workflow that prefers direct
#          local merge + push over GitHub pull requests.
#
# v2.0.0 (2026-08-21, operator instruction): the deny is no longer unconditional.
# A runnable prompt pack MAY opt its own session in. Default is still DENY — the
# solo-workflow default is unchanged for every ordinary session.
#
# OPT-IN CONTRACT (both conditions required — deliberately two independent signals):
#   1. $V_PACK_ALLOW_PR is non-empty in THIS HOOK'S environment. The hook is a
#      subprocess of the Claude Code CLI, so it inherits the CLI's env, which the
#      model cannot mutate mid-session. An inline `V_PACK_ALLOW_PR=1 gh ...` prefix
#      in the tool command does NOT reach here — that is the point.
#   2. $V_PACK_FILE names a readable file that itself carries an explicit
#      declaration line: `Allow-PR:` / `PR-Mode:` / `PR-Target:` with a value.
#      This is the "explicitly asked in the prompt pack itself" requirement — the
#      authority is the pack on disk, not an env var alone.
#
# Both must come from the launching process (run-v-packs exporting them for a pack
# whose body declares PR mode). A session that satisfies only one is denied.

set -euo pipefail

# W83-F3 opt-in profiling — no-op unless CLAUDE_HOOK_PROFILE=1
if [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh"
  profile_start "block-pr-creation"
fi

# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
set +e

# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
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

allow_note() {
  # Permit by staying silent (no decision object) — other PreToolUse hooks still run.
  profile_done
  exit 0
}

# --- Opt-in evaluation (fails closed on every unexpected condition) ---
pack_opt_in() {
  [ -n "${V_PACK_ALLOW_PR:-}" ] || return 1
  [ -n "${V_PACK_FILE:-}" ]     || return 1
  [ -f "${V_PACK_FILE}" ]       || return 1
  [ -r "${V_PACK_FILE}" ]       || return 1
  grep -qE '^[[:space:]]*(Allow-PR|PR-Mode|PR-Target)[[:space:]]*:[[:space:]]*[^[:space:]]' \
    "${V_PACK_FILE}" 2>/dev/null || return 1
  return 0
}

REASON="BLOCKED: Autonomous pull-request creation is disabled in this workflow. Preferred alternative: merge locally back into main and push main directly when allowed. If remote branch protection requires a PR, stop and report that constraint instead of opening one automatically. OPT-IN: a runnable prompt pack may enable PR creation for its OWN session by declaring an 'Allow-PR:' / 'PR-Mode:' / 'PR-Target:' line in the pack body AND being dispatched with V_PACK_ALLOW_PR + V_PACK_FILE exported by the runner. Setting the env var inline in this command does not count and will not reach the hook."

is_pr_attempt=0
# Any MCP pull-request-creation tool (codex apps, the GitHub MCP server, ...), not one exact name.
if [[ "$TOOL_NAME" == mcp__*create_pull_request* ]]; then
  is_pr_attempt=1
fi

if [[ "$TOOL_NAME" == "Bash" ]]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  if printf '%s\n' "$COMMAND" | grep -qE '(^|[[:space:]])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
    is_pr_attempt=1
  fi
fi

if [ "$is_pr_attempt" -eq 1 ]; then
  if pack_opt_in; then
    # Audit trail: a permitted PR creation is rare and worth recording.
    _log_dir="${V_TMP_DIR:-${TMPDIR:-/tmp}}"
    printf '%s pack-opt-in PR permitted pack=%s base=%s tool=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${V_PACK_FILE}" "${V_PACK_ALLOW_PR}" "${TOOL_NAME}" \
      >> "${_log_dir%/}/pr-creation-optin.log" 2>/dev/null || true
    allow_note
  fi
  deny "$REASON"
fi

profile_done
exit 0
