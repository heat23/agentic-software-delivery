#!/usr/bin/env bash
# capture-skill-args.sh
# Event: PreToolUse (matcher: Skill|Agent)
# Purpose: Capture the args/prompt of Skill and Agent tool invocations to a
# known location so skills can recover the user's input when the Skill tool's
# own tool_input arrives empty.
#
# Background (corrected 2026-05-10 W25-F8): The original comment here claimed
# "UserPromptSubmit hooks don't fire" on Claude Code v2.1.138. On-disk evidence
# disproves that — UserPromptSubmit DOES fire on slash-command Skill invocations
# (last-user-prompt-${SID}.txt is being written reliably, including for /v).
# The actual regression is narrower: when a slash-command Skill is invoked with
# an image attachment, BOTH `tool_input.args` and `tool_input.prompt` arrive
# empty in the PreToolUse payload. This hook still fires; it just receives
# empty values to capture.
#
# Confirmed on Claude Code v2.1.128. Treat as "v2.1.x regression, image+slash-
# command Skill invocations only" until Anthropic fixes upstream.
#
# Recovery path: /v Step -3 reads this capture FIRST, then falls back to
# ~/.claude/runtime/last-user-prompt[-${SID}].txt written by the
# UserPromptSubmit hook (prompt-task-classifier.sh). The UserPromptSubmit
# channel is the actual lifeline when the PreToolUse capture is empty.
#
# Non-blocking: exit 0 silently on any failure. Never disrupts tool dispatch.
# Idempotent: each invocation overwrites the capture file for its session.

set -euo pipefail

if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip

INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")

# Only capture Skill and Agent invocations
case "$TOOL_NAME" in
  Skill|Agent) ;;
  *) exit 0 ;;
esac

# Resolve SID — JSON .session_id, env, then runtime-file fallback
SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
SID="${SID:-${CLAUDE_SESSION_ID:-}}"
if [ -z "$SID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ]; then
  _c=$(tr -d '[:space:]' < "$HOME/.claude/runtime/current-session-id" 2>/dev/null)
  if echo "$_c" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
     && [ "$_c" != "00000000-0000-0000-0000-000000000000" ]; then
    SID="$_c"
  fi
fi
[ -z "$SID" ] && SID="unknown"

# Extract args (Skill) and prompt (Agent). For Skill the user input is in
# tool_input.args; for Agent it's in tool_input.prompt. Both fields may exist.
ARGS=$(echo "$INPUT" | jq -r '.tool_input.args // empty' 2>/dev/null || echo "")
PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null || echo "")
SKILL_NAME=$(echo "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null || echo "")
DESCRIPTION=$(echo "$INPUT" | jq -r '.tool_input.description // empty' 2>/dev/null || echo "")

# Write capture file. Format: key=value lines, then a delimited body containing
# whichever of args/prompt was non-empty (preferring args for Skill, prompt for Agent).
CAPTURE_DIR="${HOME}/.claude/runtime"
mkdir -p "$CAPTURE_DIR" 2>/dev/null || exit 0

# W71-F5 (forensic 2026-07-02): Agent captures get their OWN file. Previously both
# tools shared last-skill-args-<SID>.txt, so the first mid-session Agent dispatch
# (e.g. a review subagent) CLOBBERED the /v task capture — observed in a
# production session: the file held "TOOL_NAME=Agent ... Adversarial logic review" instead of
# the user's task, poisoning both /v Step -3 re-runs (Channel 1/2) and the Stop
# hook's abandon-enrich task quote (check-review-artifact.sh reads it FIRST).
if [ "$TOOL_NAME" = "Agent" ]; then
  CAPTURE_FILE="$CAPTURE_DIR/last-agent-args-${SID}.txt"
else
  CAPTURE_FILE="$CAPTURE_DIR/last-skill-args-${SID}.txt"
fi
TMPFILE="${CAPTURE_FILE}.tmp.$$"

{
  echo "CAPTURED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "TOOL_NAME=$TOOL_NAME"
  echo "SKILL_NAME=$SKILL_NAME"
  echo "DESCRIPTION=$DESCRIPTION"
  echo "ARGS_LENGTH=${#ARGS}"
  echo "PROMPT_LENGTH=${#PROMPT}"
  echo "---ARGS-BEGIN---"
  printf '%s' "$ARGS"
  echo
  echo "---ARGS-END---"
  echo "---PROMPT-BEGIN---"
  printf '%s' "$PROMPT"
  echo
  echo "---PROMPT-END---"
} > "$TMPFILE" 2>/dev/null && mv "$TMPFILE" "$CAPTURE_FILE" 2>/dev/null || true

# W25-F9: REMOVED unscoped "latest" copy. Previously this hook also wrote
# $CAPTURE_DIR/last-skill-args.txt as a fallback for skills that don't know
# their SID. That file became a cross-session contamination vector when
# multiple Claude Code sessions ran in parallel — Session A overwrote it,
# then Session B's /v Step -3 read Session A's args. SID-scoped capture
# (last-skill-args-${SID}.txt above) is the only file written. Skills that
# need recovery without knowing their SID should resolve SID first via
# $CLAUDE_SESSION_ID or ~/.claude/runtime/current-session-id.
#
# Self-healing: if a stale unscoped file exists from a previous installation,
# delete it on the first PreToolUse fire. Prevents new-debugging confusion and
# prevents any forgotten consumer from reading cross-session-leaked content.
[ -f "$CAPTURE_DIR/last-skill-args.txt" ] && rm -f "$CAPTURE_DIR/last-skill-args.txt" 2>/dev/null || true

# Diagnostic marker so we can confirm the hook fired (parallel to the
# review-reminded-* marker pattern from enforce-agent-review.sh).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# LEAK-GUARD (2026-08-03, class sweep): `git rev-parse --show-toplevel || pwd` falls through to bare
# `pwd` when there is no enclosing repo. ~/.claude has none by design, so running from a skill/hook
# SOURCE subdir made this resolve there and nest .v/ inside the source tree (stray files accumulated
# over weeks). The config dir ITSELF is a legitimate root (live .v/artifacts there), so snap only a
# STRICT DESCENDANT that is not itself a git work tree; real projects are never touched.
_lg_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "${REPO_ROOT:-}" ] && [ -n "$_lg_cfg" ] && [ "${REPO_ROOT}" != "$_lg_cfg" ]; then
  case "${REPO_ROOT}" in
    "$_lg_cfg"/*) git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || REPO_ROOT="$_lg_cfg" ;;
  esac
fi

if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/.v/tmp" ]; then
  MARKER_DIR="$REPO_ROOT/.v/tmp/hook-markers"
  mkdir -p "$MARKER_DIR" 2>/dev/null || true
  touch "$MARKER_DIR/skill-args-captured-${SID}-$(date +%s)" 2>/dev/null || true
fi

exit 0
