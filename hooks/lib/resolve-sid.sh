#!/usr/bin/env bash
# resolve-sid.sh — canonical CLAUDE_SESSION_ID resolution for hooks and bash callers.
# Version: 1.0.0  (W47-F1)
#
# WHY THIS EXISTS:
#   Claude Code does NOT propagate $CLAUDE_SESSION_ID into Bash tool subshells
#   from SessionStart hooks. The session-start-export-sid.sh and
#   refresh-session-id.sh hooks instead persist the SID to a runtime file
#   (~/.claude/runtime/current-session-id) on every Bash call. Bashes that
#   need the SID must read from THAT FILE if the env var is empty.
#
#   A production session (2026-05-04) tripped on this: the agent's
#   bash used `${CLAUDE_SESSION_ID:?missing}` directly and exited 127 with
#   "CLAUDE_SESSION_ID: missing", forcing the agent to re-run with manual
#   `export CLAUDE_SESSION_ID=...`.
#
# USAGE (in bash scripts):
#   source "$HOME/.claude/hooks/lib/resolve-sid.sh"
#   SID=$(resolve_sid)
#   [ -z "$SID" ] && { echo "ERROR: cannot resolve session id" >&2; exit 1; }
#
# USAGE (one-liner inline, when you can't source):
#   SID="${CLAUDE_SESSION_ID:-$(cat ~/.claude/runtime/current-session-id 2>/dev/null | tr -d '[:space:]')}"
#
# Resolution priority:
#   0. stdin JSON .session_id (hook payload — most authoritative when supplied)
#   1. $CLAUDE_SESSION_ID env (most authoritative when present)
#   1.5 $CLAUDE_CODE_SESSION_ID env (alias honored by v-gauntlet-attest.sh; kept in
#       sync so the Stop hook resolves the SAME SID the witness/marker use)
#   2. $SESSION_ID env (orchestrator-set for subagent dispatch)
#   3. ~/.claude/runtime/current-session-id file (kept fresh by refresh-session-id.sh)
#
# Returns the resolved SID on stdout (no trailing newline). Empty string if
# unresolvable. Caller decides whether empty is fatal — this lib never
# exits the calling shell; it's pure resolution logic.

resolve_sid() {
  local sid=""
  local stdin_json="${1:-}"  # W65-F1: optional JSON payload from hook stdin

  # Priority 0 (W65-F1): stdin JSON .session_id (most authoritative — what
  # Claude Code passes in the hook payload). Backward-compatible: zero-arg
  # callers skip this priority entirely.
  if [ -n "$stdin_json" ] && command -v jq >/dev/null 2>&1; then
    sid=$(printf '%s' "$stdin_json" | jq -r '.session_id // empty' 2>/dev/null || true)
    sid=$(printf '%s' "$sid" | tr -d '[:space:]')
    [ "$sid" = "null" ] && sid=""
  fi

  # Priority 1: CLAUDE_SESSION_ID env (when Claude Code propagates it)
  if [ -z "$sid" ] && [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    sid="$CLAUDE_SESSION_ID"
  fi

  # Priority 1.5 (2026-05-28 review fix, E2/SID-resolver unification): CLAUDE_CODE_SESSION_ID.
  # v-gauntlet-attest.sh honors this variable; without it here the Stop hook could
  # resolve a DIFFERENT SID than the witness/marker were filed under (false block).
  # Additive + safe: only consulted when the higher-priority sources are empty.
  if [ -z "$sid" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    sid="$CLAUDE_CODE_SESSION_ID"
  fi

  # INVARIANT (W-perf8, adversarial review): this ENFORCEMENT resolver intentionally has NO
  # artifact-presence "cross-fallback" (the kind v-completion-selfcheck.sh / v-gauntlet-attest.sh
  # carry to find the work-SID's artifacts). Adopting a SID *because it owns artifacts* at the gate
  # layer would let a session satisfy the witness gate using a SIBLING's witnessed SID — a
  # forge-a-pass hole. The Stop hook must resolve deterministically from identity (stdin/env), not
  # from "which SID has files on disk." v-contract-audit-test.sh Section I asserts this stays true.

  # Priority 2: SESSION_ID env (orchestrator-set for subagent dispatch)
  if [ -z "$sid" ] && [ -n "${SESSION_ID:-}" ]; then
    sid="$SESSION_ID"
  fi

  # Priority 3: runtime file (kept fresh by W22-2 + W39-A hooks)
  if [ -z "$sid" ]; then
    local runtime_file="$HOME/.claude/runtime/current-session-id"
    if [ -f "$runtime_file" ]; then
      sid=$(tr -d '[:space:]' < "$runtime_file" 2>/dev/null || true)
    fi
  fi

  # Validate UUID4 shape if non-empty. Reject obvious garbage (single chars,
  # paths, shell injections). Accept the zero-UUID sentinel as "uninitialised"
  # (return empty) — callers should treat it as missing.
  if [ -n "$sid" ]; then
    # M1 review-fix: case-insensitive — Claude Code currently emits lowercase
    # UUIDs but the spec allows uppercase; we accept either.
    if ! echo "$sid" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
      sid=""
    fi
    if [ "$sid" = "00000000-0000-0000-0000-000000000000" ]; then
      sid=""
    fi
  fi

  printf '%s' "$sid"
}

# resolve_sid_or_die: convenience for hooks that MUST have SID. Echoes a
# diagnostic and returns 1 if resolve_sid returns empty.
#
# H3 review-fix: when this lib is sourced, `exit 1` would terminate the
# CALLER's shell — violating the project's fail-open hooks convention.
# Use `return 1` so the caller can decide. Callers wanting hard-stop
# semantics use `$(resolve_sid_or_die) || exit 1` in a command substitution.
resolve_sid_or_die() {
  local sid; sid=$(resolve_sid)
  if [ -z "$sid" ]; then
    echo "ERROR: cannot resolve CLAUDE_SESSION_ID. Tried env vars and ~/.claude/runtime/current-session-id." >&2
    echo "REMEDIATION: ensure session-start-export-sid.sh and refresh-session-id.sh hooks are installed." >&2
    return 1
  fi
  printf '%s' "$sid"
}
