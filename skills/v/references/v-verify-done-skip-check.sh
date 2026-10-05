#!/usr/bin/env bash
# v-verify-done-skip-check.sh — before a verify-done (re)dispatch, check whether
# session-owned state changed since the last green VERIFY_DONE_REPORT for this SID.
# If unchanged, skip the dispatch and reuse the prior result (Lever C — verify-done
# no-change reuse; the pre-flight equivalent is the W56-F1.6 no-diff markers / C6 skip-if-unchanged).
#
# Usage: bash v-verify-done-skip-check.sh [--record <report_path>]
#
# Without --record: outputs "SKIP:<report_path>" if nothing changed since the last
#   recorded green verify-done for THIS SID, else "RUN".
# With --record: stamps the current state signature next to a green verify-done report.
# Called by the orchestrator:
#   - After a PASS verify-done: `v-verify-done-skip-check.sh --record "$VD"`
#   - Before a verify-done re-dispatch (completion loop / QA-loop refresh):
#       `RESULT=$(v-verify-done-skip-check.sh); case "$RESULT" in SKIP:*) reuse;; *) dispatch;; esac`
#
# Unlike the pre-flight skip-check (HEAD-SHA only), verify-done reuse ALSO honours the
# working tree: an uncommitted source edit since the last green run forces RUN, because
# verify-done's convention checks read the working tree, not just committed state. The
# `.v/` orchestrator artifact dir is excluded from the working-tree signature (it is the
# skip-check's own scratch space, never source).
#
# Constraint (mirrors C6): do NOT add a hard idempotency block. A re-dispatch after the
# tree moved is INTENTIONAL. Skip ONLY when nothing changed since the last green run.
set -uo pipefail

SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
[ -n "$SESSION_ID" ] || { echo "RUN"; exit 0; }

PROJ="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# LEAK-GUARD (2026-08-03, class sweep): `git rev-parse --show-toplevel || pwd` falls through to bare
# `pwd` when there is no enclosing repo. ~/.claude has none by design, so running from a skill/hook
# SOURCE subdir made this resolve there and nest .v/ inside the source tree (stray files
# accumulated over weeks). The config dir ITSELF is a legitimate root (live .v/artifacts there), so snap only a
# STRICT DESCENDANT that is not itself a git work tree; real projects are never touched.
_lg_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "${PROJ:-}" ] && [ -n "$_lg_cfg" ] && [ "${PROJ}" != "$_lg_cfg" ]; then
  case "${PROJ}" in
    "$_lg_cfg"/*) git -C "${PROJ}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || PROJ="$_lg_cfg" ;;
  esac
fi

V_TMP="${V_TMP_DIR:-$PROJ/.v/tmp}"
SHA_FILE="$V_TMP/verify-done-sha-${SESSION_ID}.txt"

# Portable sha256 (macOS ships shasum, not always sha256sum).
_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

# Working-tree signature: hash of `git status --porcelain` with the orchestrator's own
# `.v/` scratch dir filtered out (so writing this very stamp does not flip the signature).
_worktree_sig() {
  git -C "$PROJ" status --porcelain 2>/dev/null \
    | cut -c4- \
    | grep -vE '^"?\.v(/|$)' \
    | LC_ALL=C sort \
    | _sha256 | awk '{print $1}'
}

# --record mode: stamp current HEAD SHA + working-tree signature after a green verify-done.
if [ "${1:-}" = "--record" ]; then
  shift
  REPORT="${1:-}"
  CURRENT_SHA=$(git -C "$PROJ" rev-parse HEAD 2>/dev/null || echo "")
  [ -z "$CURRENT_SHA" ] && exit 0
  mkdir -p "$V_TMP" 2>/dev/null || true
  {
    printf '%s\n' "$CURRENT_SHA"
    printf '%s\n' "${REPORT:-}"
    printf '%s\n' "$(_worktree_sig)"
  } > "$SHA_FILE"
  exit 0
fi

# Skip-check mode: RUN unless every reuse gate holds.
[ -f "$SHA_FILE" ] || { echo "RUN"; exit 0; }

RECORDED_SHA=$(sed -n '1p' "$SHA_FILE" 2>/dev/null | tr -d '[:space:]')
REPORT_PATH=$(sed -n '2p' "$SHA_FILE" 2>/dev/null | sed 's/[[:space:]]*$//')
RECORDED_SIG=$(sed -n '3p' "$SHA_FILE" 2>/dev/null | tr -d '[:space:]')
CURRENT_SHA=$(git -C "$PROJ" rev-parse HEAD 2>/dev/null || echo "")

# HEAD must be resolvable and unchanged.
{ [ -z "$RECORDED_SHA" ] || [ -z "$CURRENT_SHA" ]; } && { echo "RUN"; exit 0; }
[ "$RECORDED_SHA" = "$CURRENT_SHA" ] || { echo "RUN"; exit 0; }

# Working tree must be unchanged since the green run (uncommitted edits force RUN).
CURRENT_SIG=$(_worktree_sig)
[ "$RECORDED_SIG" = "$CURRENT_SIG" ] || { echo "RUN"; exit 0; }

# The recorded report must still exist (deleted → RUN).
[ -n "$REPORT_PATH" ] && [ -f "$REPORT_PATH" ] || { echo "RUN"; exit 0; }

# Confirm the report belongs to THIS session (no cross-session / foreign-SID reuse).
SID_SHORT="${SESSION_ID:0:8}"
case "$(basename "$REPORT_PATH")" in
  *"$SESSION_ID"*|*"$SID_SHORT"*) ;;
  *) echo "RUN"; exit 0 ;;
esac

echo "SKIP:$REPORT_PATH"
