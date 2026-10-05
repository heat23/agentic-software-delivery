#!/usr/bin/env bash
set -e
trap 'exit 0' ERR  # fail-open: this best-effort capture hook must never block prompt submission
# capture-user-prompt.sh — UserPromptSubmit hook (W59-F4 — closes the 4(a) abandonment pattern).
#
# Writes /v-prefixed user prompts atomically to:
#   ~/.claude/runtime/last-user-prompt-<sid>.txt
#
# so that /v Step-3 Channel 4 (UserPromptSubmit fallback) ALWAYS has the
# prompt available — regardless of:
#   - whether Claude Code's history.jsonl write has completed
#   - whether capture-skill-args.sh fired (it may miss when /v is typed in
#     chat rather than dispatched via Task/Skill tool)
#   - any other async write race
#
# Idempotent (atomic mv from tempfile). Advisory (always exit 0).
# Never blocks the user's prompt from being processed downstream.

# Tolerate malformed JSON and any subprocess failure — defensive pattern (R3).
set +e
set -u

{
  INPUT=$(cat)
  SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

  # Only capture when SID is non-empty AND prompt looks like a /v invocation.
  # Pattern matches: /v, /v <task>, /v-tdd, /v-build, /v-pre-flight, etc.
  if [ -n "$SID" ] && [ -n "$PROMPT" ]; then
    # W71-F5 (forensic 2026-07-02): also record paste-led submissions. When the user
    # pastes a multi-line /v command, the submitted prompt is the PLACEHOLDER
    # "[Pasted text #N +M lines]" — it does not start with /v, so all four fleet
    # sessions on 2026-07-02 got NO Channel-4 capture at all. W71-review M1: paste-led
    # prompts go to a SEPARATE file — a mid-session paste ("[Pasted text #3] why does
    # this happen?") must never clobber a good /v capture in the Channel-4 file, which
    # was previously /v-pure by construction. The paste-led record is a SID-scoped
    # forensic breadcrumb of WHICH paste ref this session submitted.
    RUNTIME_DIR="$HOME/.claude/runtime"
    TARGET=""
    case "$PROMPT" in
      "/v"|"/v "*|"/v-"*)      TARGET="$RUNTIME_DIR/last-user-prompt-${SID}.txt" ;;
      "[Pasted text #"*)       TARGET="$RUNTIME_DIR/last-paste-prompt-${SID}.txt" ;;
    esac
    if [ -n "$TARGET" ]; then
      mkdir -p "$RUNTIME_DIR" 2>/dev/null
      TMPFILE=$(mktemp "$RUNTIME_DIR/.lup-${SID}.tmp.XXXXXX" 2>/dev/null)
      if [ -n "$TMPFILE" ]; then
        printf '%s' "$PROMPT" > "$TMPFILE" 2>/dev/null
        mv -f "$TMPFILE" "$TARGET" 2>/dev/null || rm -f "$TMPFILE" 2>/dev/null
      fi
    fi
  fi
} 2>/dev/null

exit 0
