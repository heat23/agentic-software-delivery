#!/usr/bin/env bash
# worktree-write-boundary.sh
# Event: PreToolUse (Edit|Write|MultiEdit|NotebookEdit)
#
# W25-F25 write boundary (forensic 2026-07-03): a /v session that OWNS a
# worktree wrote its entire implementation to the SHARED MAIN checkout instead — which
# (a) bypassed the merge-back gate (inline-on-main work never passes review-completeness checks),
# (b) contaminated every sibling's git status/diff on main, and (c) sat one `git reset` from
# permanent loss after its PID died. The dup-guard can't catch this (it's not a duplicate) and
# FND-2/FND-3 only witness it at someone ELSE's merge time.
#
# RULE: if THIS session provably owns a live worktree in the target file's repo (its
# .claude-session-lock names our SID), then SOURCE writes at that repo's MAIN root are blocked —
# the session's work belongs in its worktree. Everything else is allowed:
#   - sessions with no worktree (inline/maintenance sessions) — not our case, fail-open
#   - writes inside any worktree (that's the point)
#   - non-source paths at main root (reports, artifacts, docs at root)
#   - ~/.claude itself (orchestrator home is never "product main")
#   - any resolution failure — ALWAYS fail-open; this guard must never break normal editing.
set -uo pipefail

if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh" 2>/dev/null || exit 0
require_jq_or_skip

INPUT=$(cat)
TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
[ -n "$TARGET" ] || exit 0

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
case "$TARGET" in "$CFG"/*|"$HOME/.claude"/*) exit 0 ;; esac

# Cheap pre-filter before any git call: only source-shaped paths can ever be denied.
case "$TARGET" in
  */app/*|*/src/*|*/resources/*|*/routes/*|*/database/*|*/tests/*|*/config/*|*/lib/*|*/plugin/*) : ;;
  *) exit 0 ;;
esac

# macOS /private symlink normalizer (same class as worktree-safety.sh _mv_norm): git returns the
# physical /private/var/... path while tool inputs may carry the /var/... symlinked form — the
# prefix-strip below needs both in the same form or REL never goes repo-relative (live-fired).
_wb_norm(){ case "$1" in /private/var/*|/private/tmp/*) printf '%s' "${1#/private}" ;; *) printf '%s' "$1" ;; esac; }
TARGET_N=$(_wb_norm "$TARGET")

_dir=$(dirname "$TARGET")
[ -d "$_dir" ] || _dir=$(dirname "$_dir")
[ -d "$_dir" ] || exit 0
ROOT=$(git -C "$_dir" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || exit 0
# main checkout has a .git DIRECTORY; a worktree has a .git file → writes inside worktrees are fine
[ -d "$ROOT/.git" ] || exit 0
ROOT_N=$(_wb_norm "$ROOT")

# Source-shape check against the repo-relative path (the pre-filter above may have matched a
# same-named dir outside the repo root).
REL="${TARGET_N#"$ROOT_N"/}"
case "$REL" in
  app/*|src/*|resources/*|routes/*|database/*|tests/*|config/*|lib/*|plugin/*) : ;;
  *) exit 0 ;;
esac

# Does THIS session own a live worktree of THIS repo? (lock line 1, field 1 = SID)
source "$HOOKS_LIB_DIR/resolve-sid.sh" 2>/dev/null || exit 0
SID=$(resolve_sid "$INPUT" 2>/dev/null || true)
[ -n "$SID" ] && [ "$SID" != "unknown" ] || exit 0

# P3-17 (plan item 17, inline-on-main guard): the HARD block below requires THIS session's own
# active-worktree marker — it says nothing about a session that has NO worktree of its own
# (never entered one, or a Maintenance-tier fast-path) writing SOURCE straight to the shared main
# checkout WHILE OTHER sessions' worktrees are live. That shape is not a violation of THIS
# session's own boundary, but it is exactly the "no exceptions" parallel-safety hole plan item 17
# targets: a worktree-less session editing app/* on main while siblings are mid-flight risks the
# same sibling-clobber / dirty-main contamination the hard block exists to prevent, just from the
# other direction. WARN (advisory, non-blocking — never deny a worktree-less session outright;
# that would be a NEW hard requirement to always use a worktree, which is Step 2's job, not this
# hook's) whenever a FRESH (<240min, same convention as check-review-artifact.sh's sibling-lock
# staleness window) sibling worktree lock exists for a DIFFERENT SID.
if [ ! -f "${CFG}/runtime/active-worktree-${SID}" ]; then
  _p317_now=$(date +%s 2>/dev/null || echo 0)
  _p317_sib=""
  while IFS= read -r _wt; do
    [ -n "$_wt" ] && [ "$_wt" != "$ROOT" ] && [ -f "$_wt/.claude-session-lock" ] || continue
    _lsid=$(awk 'NR==1{print $1}' "$_wt/.claude-session-lock" 2>/dev/null || true)
    case "$_lsid" in sid=*) _lsid="${_lsid#sid=}" ;; esac
    [ -n "$_lsid" ] && [ "$_lsid" != "$SID" ] || continue
    _lm=$(stat -c %Y "$_wt/.claude-session-lock" 2>/dev/null || stat -f %m "$_wt/.claude-session-lock" 2>/dev/null || echo 0)
    if [ "$_p317_now" -gt 0 ] && [ "${_lm:-0}" -gt 0 ] && [ $(( (_p317_now - _lm) / 60 )) -lt 240 ]; then
      _p317_sib="$_wt"
      break
    fi
  done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  if [ -n "$_p317_sib" ]; then
    echo "⚠️ P3-17 inline-on-main advisory: writing SOURCE ($REL) directly to the shared main checkout at $ROOT while a parallel session's worktree ($_p317_sib) is live (lock <240min old). This session has no worktree of its own — consider isolating in one (git worktree add) to avoid contaminating siblings' view of main / racing their merge-back. Not blocked (advisory only)." >&2
  fi
  exit 0
fi

OWN_WT=""
while IFS= read -r _wt; do
  [ -n "$_wt" ] && [ "$_wt" != "$ROOT" ] && [ -f "$_wt/.claude-session-lock" ] || continue
  _lsid=$(awk 'NR==1{print $1}' "$_wt/.claude-session-lock" 2>/dev/null || true)
  case "$_lsid" in sid=*) _lsid="${_lsid#sid=}" ;; esac
  [ "$_lsid" = "$SID" ] && { OWN_WT="$_wt"; break; }
done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
[ -n "$OWN_WT" ] || exit 0

jq -n --arg reason "BLOCKED (W25-F25 write boundary): this session owns worktree $OWN_WT but is writing SOURCE ($REL) to the SHARED MAIN checkout at $ROOT. Inline-on-main work bypasses the merge-back gate, contaminates every sibling's view of main, and is one 'git reset' from permanent loss. Write the file inside your worktree instead: $OWN_WT/$REL — merge-back will land it on main through the gates." \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
exit 0
