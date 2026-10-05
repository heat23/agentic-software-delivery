#!/usr/bin/env bash
# v-preflight-mark.sh — write the W56-F1.6 no-diff markers (HEAD + session-writes hash) that
# Step 6.1 reads to short-circuit a redundant pre-flight re-dispatch.
#
# THE FIX (2026-06-16): previously these markers were written ONLY at Step 4. After a Step 6.1
# re-validate or a QA-loop (E) pre-flight re-run, they went stale → the NEXT no-diff check saw a
# moved HEAD and re-dispatched pre-flight even though nothing had changed since the last run.
# Call this helper after EVERY pre-flight dispatch (Step 4, Step 6.1 re-run, QA-loop E) so the
# short-circuit baseline always reflects the LAST run. (Marker filenames keep the historical
# `step4-` prefix so the Step 6.1 reader needs no change — they now mean "last pre-flight".)
#
# Usage: bash v-preflight-mark.sh           # uses CLAUDE_SESSION_ID / V_TMP_DIR / PROJECT_ROOT
# Always exits 0 (a marker-write failure must never break the gate; a missing marker just makes
# Step 6.1 re-dispatch defensively, which is the safe direction).
set -uo pipefail

SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -z "$SID" ]; then
  # CDX-1 (codex 2026-07-01): --check must honor the word-on-stdout contract even with no SID —
  # print the safe verdict (re-dispatch) rather than empty stdout.
  [ "${1:-}" = "--check" ] && echo "PREFLIGHT_REUSE=0"
  echo "v-preflight-mark: no SID — skipped (Step 6.1 will re-dispatch defensively)" >&2
  exit 0
fi

PROJ="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# LEAK-GUARD (2026-08-03, class sweep): `git rev-parse --show-toplevel || pwd` falls through to bare
# `pwd` when there is no enclosing repo. ~/.claude has none by design, so running from a skill/hook
# SOURCE subdir made this resolve there and nest .v/ inside the source tree (stray files accumulated over
# weeks). The config dir ITSELF is a legitimate root (live .v/artifacts there), so snap only a
# STRICT DESCENDANT that is not itself a git work tree; real projects are never touched.
_lg_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "${PROJ:-}" ] && [ -n "$_lg_cfg" ] && [ "${PROJ}" != "$_lg_cfg" ]; then
  case "${PROJ}" in
    "$_lg_cfg"/*) git -C "${PROJ}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || PROJ="$_lg_cfg" ;;
  esac
fi

V_TMP="${V_TMP_DIR:-$PROJ/.v/tmp}"
mkdir -p "$V_TMP" 2>/dev/null || true

HEAD_FILE="$V_TMP/step4-head-${SID}.txt"
WRITES_HASH_FILE="$V_TMP/step4-writes-hash-${SID}.txt"
WRITES_LOG="$V_TMP/session-writes-${SID}.txt"

# --check (2026-07-01, folded from SKILL.md Step 6.1): compare live HEAD + session-writes hash
# against the last-pre-flight markers AND require the report itself on disk. Prints
# PREFLIGHT_REUSE=1 (nothing changed since the last pre-flight — reuse its report) or
# PREFLIGHT_REUSE=0 (re-dispatch pre-flight, then call this helper in write mode to refresh).
# Always exits 0 — the WORD on stdout is the contract, never the exit code (exit codes get
# eaten by `|| true` batching; same lesson as the cosmetic classifier).
if [ "${1:-}" = "--check" ]; then
  _REPORT="$PROJ/PRE_FLIGHT_REPORT_${SID}.md"
  _CUR_HEAD=$(git -C "$PROJ" rev-parse HEAD 2>/dev/null || echo "")
  _CUR_HASH=$(sha256sum "$WRITES_LOG" 2>/dev/null | awk '{print $1}' || echo "")
  _M_HEAD=$(cat "$HEAD_FILE" 2>/dev/null || echo "")
  _M_HASH=$(cat "$WRITES_HASH_FILE" 2>/dev/null || echo "")
  if [ -f "$_REPORT" ] && [ -n "$_M_HEAD" ] && [ "$_CUR_HEAD" = "$_M_HEAD" ] && [ "$_CUR_HASH" = "$_M_HASH" ]; then
    echo "PREFLIGHT_REUSE=1"
  else
    echo "PREFLIGHT_REUSE=0"
  fi
  exit 0
fi

git -C "$PROJ" rev-parse HEAD 2>/dev/null > "$HEAD_FILE" || : > "$HEAD_FILE"
sha256sum "$WRITES_LOG" 2>/dev/null | awk '{print $1}' > "$WRITES_HASH_FILE" || : > "$WRITES_HASH_FILE"

echo "v-preflight-mark: refreshed no-diff markers for ${SID:0:8} (HEAD=$(cat "$HEAD_FILE" 2>/dev/null | cut -c1-8))" >&2
exit 0
