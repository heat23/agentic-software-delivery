#!/usr/bin/env bash
# enforce-agent-review.sh
# Event: UserPromptSubmit
# UserPromptSubmit hook: injects a one-shot reminder when /v or /v-build is invoked
# that adversarial review is mandatory and the Superpower Review fallback applies
# when codex CLI is unavailable.
#
# WHY: The most common failure mode is Claude silently skipping the review because
# the codex binary isn't installed and treating "graceful degradation" as "skip".
# This reminder fires once at the start of a /v session so Claude sees the rule
# before it reaches the review step.
#
# BEHAVIOUR:
#   - Fires only when the user prompt starts with /v or /v-build (or contains it
#     after whitespace, to catch "run /v fix the bug" patterns).
#   - One-shot per session+prompt-prefix (marker file prevents repeat noise).
#   - Non-blocking (exit 0) — injects advisory context via hookSpecificOutput JSON on stdout.

set -euo pipefail


# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
source "$HOOKS_LIB_DIR/v-tmp-dir.sh"
require_jq_or_skip

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "")

if [[ -z "$PROMPT" ]]; then
  exit 0
fi

# Detect /v or /v-build invocation patterns.
# FB-29 (forensic 2026-07-03): match ONLY a prompt that STARTS with the slash command. The old
# anywhere-in-prompt match fired on prompts that merely MENTION "/v" — pasted forensic reports,
# discussion of the orchestrator, read-only analysis sessions — stamping the mandatory-review
# contract (and arming the Stop-gate expectation) on sessions that ship no code. An invocation
# is a slash command at prompt start; mid-text "/v" is quotation. The Stop hook (keyed on actual
# code writes) remains the real gate for sessions that implement without ever typing /v.
if ! echo "$PROMPT" | grep -qE '^[[:space:]]*/v(-build)?([[:space:]]|$)'; then
  exit 0
fi

# Determine which skill is being invoked for the marker key
if echo "$PROMPT" | grep -qE '(^|[[:space:]])/v-build([[:space:]]|$)'; then
  SKILL="v-build"
else
  SKILL="v"
fi

# One-shot marker: key on skill + session_id (no date coupling)
# W70: canonical SID resolver; preserve "unknown" sentinel semantics
source "$HOME/.claude/hooks/lib/resolve-sid.sh"
SESSION_ID=$(resolve_sid "$INPUT")
SESSION_ID="${SESSION_ID:-unknown}"
SESSION_KEY=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)
[[ -z "$SESSION_KEY" ]] && SESSION_KEY="unknown"

MARKER_DIR="$(v_tmp_marker_dir)"
MARKER_FILE="$MARKER_DIR/review-reminded-${SKILL}-${SESSION_KEY}"

if [[ -f "$MARKER_FILE" ]]; then
  exit 0
fi

touch "$MARKER_FILE"

CTX="/${SKILL} SESSION — ADVERSARIAL REVIEW RULES"$'\n\n'"The adversarial review is MANDATORY for this session."$'\n\n'"Review path (in order of preference):"$'\n'"  1. Dispatch codex-adversarial-reviewer from ~/.claude/agents/ (uses codex CLI if available)"$'\n'"  2. If codex CLI unavailable -> Superpower Review (Claude performs the review natively — same format, same adjudication, same artifact. NOT an empty skip.)"$'\n\n'"Output rules:"$'\n'"  - Report ALL severity levels: critical, high, medium, low"$'\n'"  - Adjudicate every finding: ACCEPT -> fix now, MODIFY -> fix with adjustments, REJECT -> document reason. No DEFER."$'\n'"  - Write AGENT_REVIEW_\${CLAUDE_SESSION_ID}.md before session end (Stop hook will block if this artifact is missing)"$'\n'"  - Degraded self-review text does NOT satisfy the artifact gate; prove codex-adversarial-reviewer or superpowers:requesting-code-review actually ran"
jq -n --arg ctx "$CTX" '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":$ctx}}'

exit 0
