#!/usr/bin/env bash
# refresh-session-id.sh
# OBSERVABILITY/CORRECTNESS HOOK
# Event: PreToolUse / Bash (runs FIRST in the chain)
# Version: 1.0.0  (W39-A — SID always-fresh)
#
# Production motivation: every /v session showed
#   WARNING=runtime_file_NNNNs_old_proceeding_anyway (10-25 min stale)
# meaning v-bootstrap.sh read a stale SID from the runtime file. The file
# is normally written by session-start-export-sid.sh at SessionStart, but
# Claude Code's compaction triggers a NEW session_id WITHOUT firing
# SessionStart — leaving the runtime file stuck on the pre-compaction SID.
# Stop hooks (which use the fresh JSON input session_id) then complain
# about missing artifacts under the canonical SID.
#
# Fix: this PreToolUse hook fires on EVERY Bash call. It reads .session_id
# from the JSON input and writes it to ~/.claude/runtime/current-session-id
# IF different. Result: the runtime file is always fresh, regardless of
# compaction or other Claude Code session-id changes.
#
# Idempotent + fail-open: any error path exits 0 silently. No JSON output
# (PreToolUse Bash hook output schema doesn't have a way to non-blockingly
# pass info through — and we don't need it).

set -euo pipefail

# W83-F3 opt-in profiling — no-op unless CLAUDE_HOOK_PROFILE=1
if [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh"
  profile_start "refresh-session-id"
fi


if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
if [ -f "$HOOKS_LIB_DIR/require-jq.sh" ]; then
  source "$HOOKS_LIB_DIR/require-jq.sh"
  require_jq_or_skip
fi

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

# Extract session_id from JSON input (Claude Code passes this on every hook call)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

# Validate as UUID4 shape — reject garbage
if ! echo "$SID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  profile_done
  exit 0
fi
# W39 review F2: reject the zero-UUID sentinel — structurally valid but
# semantically meaningless; signals a nullified/uninitialized SID.
if [ "$SID" = "00000000-0000-0000-0000-000000000000" ]; then
  profile_done
  exit 0
fi

# Write to runtime file ONLY if different from current contents.
# Avoids spurious mtime updates that would mask other issues.
RUNTIME_DIR="$HOME/.claude/runtime"
RUNTIME_FILE="$RUNTIME_DIR/current-session-id"
mkdir -p "$RUNTIME_DIR" 2>/dev/null || exit 0

CURRENT=""
[ -f "$RUNTIME_FILE" ] && CURRENT=$(tr -d '[:space:]' < "$RUNTIME_FILE" 2>/dev/null || true)

if [ "$CURRENT" != "$SID" ]; then
  # W39 review F1: atomic write via temp + mv to avoid torn writes under
  # concurrent invocations. mv on POSIX is atomic for files in the same
  # filesystem.
  _tmp_file="${RUNTIME_FILE}.$$.tmp"
  echo "$SID" > "$_tmp_file" 2>/dev/null && mv -f "$_tmp_file" "$RUNTIME_FILE" 2>/dev/null || rm -f "$_tmp_file" 2>/dev/null
  # Optional debug: log to stderr (visible in transcripts but not advisory)
  if [ "${V_REFRESH_SID_DEBUG:-0}" = "1" ]; then
    echo "[refresh-session-id] updated $RUNTIME_FILE: $CURRENT -> $SID" >&2
  fi
fi

profile_done
exit 0
