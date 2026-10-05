#!/usr/bin/env bash
# detect-readonly-intent.sh — UserPromptSubmit hook (W57-F4)
# Event: UserPromptSubmit
# Purpose: when the user's prompt carries an explicit read-only directive (the
#   /v review/verify/audit pattern, or a hard "do not edit source"), write a
#   per-session marker so readonly-edit-guard.sh can block edits to TRACKED
#   source for the rest of this prompt. Re-evaluated every prompt: a follow-up
#   prompt WITHOUT the directive clears the marker (so "now fix it" re-enables
#   editing).
#
# Motivation (2026-05-26): a /v session whose prompt said "READ-ONLY ... do NOT
# edit source" instrumented an application service file with debug
# probes (then reverted) in the SHARED main tree while two sibling sessions ran
# against it — a concurrency hazard. The user OWNS the read-only contract; this
# makes it enforceable instead of advisory.
#
# Advisory hook: always exits 0, never blocks prompt submission.

set -e
trap 'exit 0' ERR  # fail-open: advisory marker hook must never block prompt submission
set +e
set -u

{
  INPUT=$(cat)
  SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

  if [ -n "$SID" ]; then
    RUNTIME_DIR="$HOME/.claude/runtime"
    mkdir -p "$RUNTIME_DIR" 2>/dev/null
    MARKER="$RUNTIME_DIR/readonly-session-${SID}"

    _readonly=0
    # (a) hard directive anywhere: "do not edit/modify/touch [the] source/code/tree"
    if printf '%s' "$PROMPT" | grep -qiE 'do[[:space:]]*n[o'"'"']?t[[:space:]]+(edit|modify|touch|change)[[:space:]]+(the[[:space:]]+)?(source|code|tree)'; then
      _readonly=1
    fi
    # (b) explicit "no/zero source edits"
    if printf '%s' "$PROMPT" | grep -qiE '(no|zero)[[:space:]]+source[[:space:]]+edits'; then
      _readonly=1
    fi
    # (c) a /v invocation that declares itself READ-ONLY (the dominant pattern)
    case "$PROMPT" in
      "/v"|"/v "*|"/v-"*)
        if printf '%s' "$PROMPT" | grep -qiE 'read[-_ ]?only'; then
          _readonly=1
        fi
        ;;
    esac

    if [ "$_readonly" -eq 1 ]; then
      TMP=$(mktemp "$RUNTIME_DIR/.ro-${SID}.XXXXXX" 2>/dev/null)
      if [ -n "$TMP" ]; then
        printf 'readonly-intent set %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP" 2>/dev/null
        mv -f "$TMP" "$MARKER" 2>/dev/null || rm -f "$TMP" 2>/dev/null
      fi
    else
      # Not a read-only prompt → clear any stale marker for this session.
      rm -f "$MARKER" 2>/dev/null
    fi
  fi
} 2>/dev/null

exit 0
