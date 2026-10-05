#!/usr/bin/env bash
# session-start-marker.sh
# OBSERVABILITY HOOK — P2
# Event: SessionStart
# Version: 1.0.0  (W29 — telemetry foundation)
#
# Writes $V_TMP_DIR/session-start-${SID}.txt containing the session start
# timestamp (ISO 8601 UTC). The v-session-log skill reads this marker as the
# authoritative session start time for duration calculation.
#
# Production motivation (W28-followup deep analysis of 6 SESSION_LOGs):
#   - 4 of 6 sessions have `session.duration_seconds: null`
#   - All 6 have `session.start_time: null`
#   - v-session-log already supports the marker, but only v-bootstrap.sh
#     writes it — sessions that don't invoke /v (chat-only, /v-session-log
#     catch-up, ad-hoc work) never get the marker.
#
#   This hook closes the gap: EVERY session gets a marker, regardless of
#   whether /v was ever invoked.
#
# Idempotent + fail-open: any error path exits 0 silently.

set -euo pipefail

# Resolve hooks/lib path
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

# require-jq is for the OPTIONAL JSON input parsing; fail open if missing.
if [ -f "$HOOKS_LIB_DIR/require-jq.sh" ]; then
  source "$HOOKS_LIB_DIR/require-jq.sh"
  require_jq_or_skip
fi

# Source v-tmp-dir helper if available; otherwise compute repo-local path.
RESOLVE_VTMP=""
if [ -f "$HOOKS_LIB_DIR/v-tmp-dir.sh" ]; then
  source "$HOOKS_LIB_DIR/v-tmp-dir.sh"
  RESOLVE_VTMP="lib"
fi

# Read SessionStart hook input (Claude Code passes JSON on stdin).
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi

# Resolve session_id: hook input first, then env, then runtime file.
SID=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
fi
if [ -z "$SID" ] && [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  SID="$CLAUDE_SESSION_ID"
fi
if [ -z "$SID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ]; then
  SID=$(cat "$HOME/.claude/runtime/current-session-id" 2>/dev/null || true)
fi

# No SID? Can't write a marker. Fail open silently.
[ -z "$SID" ] && exit 0

# Defense-in-depth (W29 review fix): validate SID format strictly.
# An attacker who can write to ~/.claude/runtime/current-session-id could
# inject ../../../etc/passwd. Real Claude Code SIDs are UUID4 (lowercase hex
# with hyphens). Reject anything else and fail open.
if ! [[ "$SID" =~ ^[a-zA-Z0-9-]+$ ]]; then
  exit 0
fi

# Resolve V_TMP_DIR. Strategy:
#   1. Use $V_TMP_DIR if already exported.
#   2. Else use git rev-parse to find the repo root + append .v/tmp.
#   3. Else fail open silently (no V_TMP_DIR means we can't write to repo-local).
if [ -z "${V_TMP_DIR:-}" ]; then
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

  [ -z "$REPO_ROOT" ] && exit 0
  V_TMP_DIR="$REPO_ROOT/.v/tmp"
fi

mkdir -p "$V_TMP_DIR" 2>/dev/null || exit 0
[ -w "$V_TMP_DIR" ] || exit 0

START_MARKER="$V_TMP_DIR/session-start-${SID}.txt"

# Idempotent: if the marker already exists, do not overwrite (a marker from
# bootstrap or a prior SessionStart in the same logical session is preferred —
# Claude Code may fire SessionStart multiple times within a single conversation
# for resumed sessions).
if [ ! -f "$START_MARKER" ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$START_MARKER" 2>/dev/null || true
fi

# ── W-BASELINE-UNIVERSAL (2026-08-13) ────────────────────────────────────────
# Also record HEAD at session start. check-review-artifact.sh's CODE_CHANGED
# component #2 — whose own header says it "runs UNCONDITIONALLY" — compares this
# baseline against HEAD to catch code landed through the Bash tool, because
# track-session-writes.sh inspects Bash only for a v-dispatch-subagent marker and
# so never sees `git commit`/`git merge`. The W-LIGHT2-CHORE commit-tag escape
# reads the same file.
#
# Until now the ONLY writer was skills/v/references/v-bootstrap.sh, which runs
# inside /v (and, when /v is dispatched as a background agent, inside the SUBAGENT
# — never in the parent). Measured 2026-08-13: a session had many markers in
# .v/tmp and no head-baseline, so its pre-flight reported "Files in scope: 0"
# against a multi-file range and Bash-landed commits were invisible to the Stop
# gate. session-env-check.sh also writes it but was deliberately unregistered from
# SessionStart on 2026-05-16 during a session-freeze incident (see
# settings.json.bak-remove-session-env-check-*) — so it is NOT the place to fix this.
#
# Idempotent by design: v-bootstrap.sh writes only "if missing", so whichever fires
# first wins, and the EARLIEST baseline is the correct one. Fail-open like the
# marker above — a non-git dir (~/.claude has no repo) simply yields no SHA.
HEAD_BASELINE="$V_TMP_DIR/head-baseline-${SID}.txt"
if [ ! -f "$HEAD_BASELINE" ]; then
  _HEAD_SHA="$(git -C "$(dirname "$(dirname "$V_TMP_DIR")")" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$_HEAD_SHA" ]; then
    printf '%s\n' "$_HEAD_SHA" > "$HEAD_BASELINE" 2>/dev/null || true
  fi
fi

# ── REVIEW_DEBT surfacing (forensic 2026-07-04): a W59-F2 rearm escape used to leave
# NOTHING queued — the owed hostile re-review silently vanished. The Stop gate now writes durable
# REVIEW_DEBT_<sid>.md markers; surface them at every SessionStart so the next session (or the
# operator) sees the queue until it is worked off. additionalContext is advisory — never blocks.
_MR="$(cd "$V_TMP_DIR/../.." 2>/dev/null && pwd)"
if [ -n "$_MR" ] && [ -d "$_MR/.v/artifacts" ]; then
  _debts="$(find "$_MR/.v/artifacts" -maxdepth 1 -name 'REVIEW_DEBT_*.md' 2>/dev/null | head -10 || true)"
  if [ -n "$_debts" ]; then
    _n="$(printf '%s\n' "$_debts" | wc -l | tr -d ' ')"
    _list="$(printf '%s' "$_debts" | tr '\n' ' ' | sed 's/"/\\"/g')"
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"⚠️ REVIEW DEBT OUTSTANDING (%s marker(s)): hostile adversarial re-reviews are OWED for earlier sessions that completed while the codex CLI was unreachable. Files: %s. When codex is available, dispatch codex-adversarial-reviewer against each session diff, fix findings, then delete the marker."}}\n' \
      "$_n" "$_list" 2>/dev/null || true
  fi
fi

exit 0
