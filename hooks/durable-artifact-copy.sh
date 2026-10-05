#!/usr/bin/env bash
# durable-artifact-copy.sh — C-2 (handoff-3, 2026-07-02): write-time durable copy of verdict-bearing
# /v artifacts.
#
# WHY: the only durable copy previously happened at merge/finalize (v-artifact-consolidate.sh, called
# from v-merge-back.sh) — a session that aborts, crashes, hits a QA-fail, or is stranded before
# merge-back NEVER reaches that step, so exactly the evidence that matters most (the FAIL verdict, the
# BLOCKED reason) is lost to worktree teardown / sibling `git clean`. Verified real losses in production sessions:
# a QA_REPORT (sha256 recorded in provenance, file itself gone) and another session's
# PRE_FLIGHT_REPORT/AGENT_REVIEW/BLOCKED (worktree-only, protected only by chance via the merge-back
# M2 dirty-guard). This is the abort-path instance of the documented durability-under-concurrency class
# — the prior fix covered finalize only.
#
# MECHANISM: fires on every Write of a verdict-bearing artifact filename and copies it byte-identical to
# <main-checkout-root>/.v/artifacts/<basename> immediately. Main-root resolution uses the SHARED helper
# hooks/lib/git-main-root.sh (Trap 3, handoff-3): env-clean, canonicalized git-common-dir identity —
# NEVER a repo-root path-prefix guess. C-3 (hooks/track-session-writes.sh) already proved a path-prefix
# test is blind to the external-worktree convention (~/.claude/worktrees/<repo>/<slug>); C-2 must use the
# identical identity test or risk recreating the same worktree-blindness class.
#
# REGISTER (PostToolUse, matcher "Write" — DUAL registration required in BOTH settings.json AND
# settings.headless.json; a single-context registration is the exact "dead-in-one-context trap" this
# plan calls out):
#   { "matcher": "Write", "hooks": [ { "type": "command", "command": "~/.claude/hooks/durable-artifact-copy.sh" } ] }
#
# Fail-open: PostToolUse must NEVER block or error. Idempotent: re-writing the same artifact (a
# pre-flight retry) overwrites the durable copy with the latest content — write-time semantics, not an
# append/history log (v-artifact-consolidate.sh already owns any longer-term archival policy).
#
# Bite: hooks/durable-artifact-copy-test.sh.
set -uo pipefail
trap 'exit 0' EXIT

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null || true)"
[ -n "$INPUT" ] || exit 0

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
# ORCHFIX-A2 (forensics 2026-07-02, mirror-desync): cover Edit/MultiEdit too. Write-only
# coverage meant every EDIT to a root artifact left the .v/artifacts durable copy STALE — and the
# validators/attest resolve that copy, so sessions hit repeated false Stop-blocks on content they
# had already fixed, then learned to hand-sync.
# The registration matcher must be "Write|Edit|MultiEdit" in BOTH settings files (dual-registration
# test updated in lockstep).
case "$TOOL" in Write|Edit|MultiEdit) ;; *) exit 0 ;; esac

# Anti-forgery / correctness: only copy a write that actually succeeded.
IS_ERR="$(printf '%s' "$INPUT" | jq -r '.tool_response.is_error // .is_error // false' 2>/dev/null || true)"
[ "$IS_ERR" != "true" ] || exit 0

FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[ -n "$FILE_PATH" ] || exit 0
BASENAME="$(basename "$FILE_PATH")"

# Scope: verdict-bearing artifacts only (mirrors the Stop hook's gauntlet-artifact vocabulary).
case "$BASENAME" in
  QA_REPORT_*|AGENT_REVIEW_*|PRE_FLIGHT_REPORT_*|VERIFY_DONE_REPORT_*|BLOCKED_*|IMPACT_MAP_*) ;;
  *) exit 0 ;;
esac

[ -f "$FILE_PATH" ] || exit 0   # nothing landed on disk to copy (shouldn't happen post-Write, defensive)

HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/git-main-root.sh
source "$HOOKS_LIB_DIR/git-main-root.sh" 2>/dev/null || exit 0

FILE_DIR="$(dirname "$FILE_PATH")"
MAIN_ROOT="$(resolve_main_root "$FILE_DIR" 2>/dev/null || true)"
[ -n "$MAIN_ROOT" ] && [ -d "$MAIN_ROOT" ] || exit 0   # not inside any git repo — fail-open no-op

DEST_DIR="$MAIN_ROOT/.v/artifacts"
mkdir -p "$DEST_DIR" 2>/dev/null || exit 0
DEST="$DEST_DIR/$BASENAME"

# Idempotent byte-identical copy; skip the write entirely if content is already identical (avoids
# needless mtime churn on repeated no-op fires).
if [ -f "$DEST" ] && cmp -s "$FILE_PATH" "$DEST" 2>/dev/null; then
  exit 0
fi
cp -f "$FILE_PATH" "$DEST" 2>/dev/null || true

exit 0
