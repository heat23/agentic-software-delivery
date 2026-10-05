#!/usr/bin/env bash
# v-hostile-required.sh — single-sourced HOSTILE_REVIEW_REQUIRED predicate (H4-5,
# PLAN_2026-07-02_orchestrator-hardening-4).
#
# WHY: a production-session forensic — the orchestrator (SKILL.md Step 3.4), the Stop hook
# (check-review-artifact.sh -> hooks/lib/validation.sh), and the session-log gather
# (v-gather-session-data.sh) each hand-rolled their OWN copy of the "does this diff touch a
# hostile (auth/billing/data-mutation) path" regex. The three lists had DRIFTED (gather's
# HOSTILE_PATTERN was missing csrf-token/encryption/storage that validation.sh's
# HOSTILE_REVIEW_PATH_PATTERN carries, and never stripped pure UI-asset extensions the way
# review_requires_hostile_focus_from_paths does) — the orchestrator computed hostile=no while the
# Stop hook computed yes on the SAME diff, causing a post-merge scramble (work landed before the
# hostile review the Stop hook actually required existed) and validator-gaming remediation.
#
# FIX: hooks/lib/validation.sh's HOSTILE_REVIEW_PATH_PATTERN / review_requires_hostile_focus_from_paths
# is the canonical implementation (it is the one actually ENFORCED at the Stop/commit gates — the
# highest-stakes consumer) and now the ONLY place the regex + UI-asset-exclusion logic lives. This
# script is a thin CLI wrapper any other consumer (orchestrator prose, resolve_review_model's model
# tiering, the session-log gather) calls INSTEAD of hand-rolling their own copy.
#
# Usage:
#   v-hostile-required.sh --sid SID [--tmp-dir V_TMP_DIR] [--worktree-root DIR]
#   v-hostile-required.sh --base SHA [--worktree-root DIR]
#   v-hostile-required.sh --paths-file FILE
#   (echo "$PATHS" | v-hostile-required.sh --stdin)
#
# Path-source priority (first that yields any input wins — mirrors the union of what the three
# prior hand-rolled consumers each did):
#   1. --paths-file FILE       — caller already computed the changed-path list (one path per line)
#   2. --stdin                 — same, piped
#   3. --sid SID               — session-writes log (V_TMP_DIR, then worktree .v/tmp, then the
#                                 durable git-common-dir fallback path track-session-writes.sh uses)
#   4. --base SHA (+ --worktree-root) — git diff --name-only SHA..HEAD in that worktree (or cwd)
#
# Output (stdout):
#   HOSTILE_REQUIRED=0|1
#   === HOSTILE_PATHS ===
#   <one matching path per line, or the literal NONE>
#   === END_HOSTILE_PATHS ===
#
# Exit: 0 always (informational; caller branches on the printed value, not the exit code) — a
# missing validation.sh degrades to HOSTILE_REQUIRED=1 (fail toward the SAFER/stricter path, never
# silently fail open on a hostile diff).
set -u

SID=""
TMP_DIR=""
WORKTREE_ROOT=""
BASE_SHA=""
PATHS_FILE=""
USE_STDIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --sid) SID="${2:-}"; shift 2 ;;
    --tmp-dir) TMP_DIR="${2:-}"; shift 2 ;;
    --worktree-root) WORKTREE_ROOT="${2:-}"; shift 2 ;;
    --base) BASE_SHA="${2:-}"; shift 2 ;;
    --paths-file) PATHS_FILE="${2:-}"; shift 2 ;;
    --stdin) USE_STDIN=1; shift 1 ;;
    *) shift 1 ;;
  esac
done

_CDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
_LIB="$_CDIR/hooks/lib/validation.sh"

PATHS=""
if [ -n "$PATHS_FILE" ] && [ -f "$PATHS_FILE" ]; then
  PATHS=$(cat "$PATHS_FILE" 2>/dev/null)
elif [ "$USE_STDIN" -eq 1 ]; then
  PATHS=$(cat 2>/dev/null)
elif [ -n "$SID" ]; then
  _root="${WORKTREE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  _writes_log=""
  for _cand in \
    "${TMP_DIR:-}/session-writes-${SID}.txt" \
    "$_root/.v/tmp/session-writes-${SID}.txt"; do
    [ -n "$_cand" ] && [ -s "$_cand" ] && { _writes_log="$_cand"; break; }
  done
  if [ -z "$_writes_log" ]; then
    _gc_dir="$(git -C "$_root" rev-parse --git-common-dir 2>/dev/null || true)"
    case "$_gc_dir" in /*) : ;; *) [ -n "$_gc_dir" ] && _gc_dir="$_root/$_gc_dir" ;; esac
    if [ -n "$_gc_dir" ] && [ -f "${_gc_dir}/claude-session-writes-${SID}.txt" ]; then
      _writes_log="${_gc_dir}/claude-session-writes-${SID}.txt"
    fi
  fi
  if [ -n "$_writes_log" ]; then
    PATHS=$(grep -v '^\[subagent-dispatch\]$' "$_writes_log" 2>/dev/null)
  else
    PATHS=$(git -C "$_root" diff --name-only HEAD 2>/dev/null)
  fi
elif [ -n "$BASE_SHA" ]; then
  _root="${WORKTREE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  PATHS=$(git -C "$_root" diff --name-only "${BASE_SHA}..HEAD" 2>/dev/null)
fi

HOSTILE_REQUIRED=0
HOSTILE_PATHS_OUT=""

if [ -f "$_LIB" ]; then
  # shellcheck source=/dev/null
  source "$_LIB" 2>/dev/null
fi

if [ -n "$PATHS" ]; then
  if type review_requires_hostile_focus_from_paths >/dev/null 2>&1; then
    if review_requires_hostile_focus_from_paths "$PATHS"; then
      HOSTILE_REQUIRED=1
      # Recompute the matching subset for display (the function only returns a boolean) — same
      # UI-asset exclusion + pattern the function itself used, so the printed paths are exactly
      # what tripped it.
      _code_paths=$(printf '%s\n' "$PATHS" | grep -ivE '\.(css|scss|sass|less|html?|png|jpe?g|gif|svg|webp|ico|bmp|tiff|md|markdown|txt|rst)$' 2>/dev/null || true)
      HOSTILE_PATHS_OUT=$(printf '%s\n' "$_code_paths" | grep -iE "${HOSTILE_REVIEW_PATH_PATTERN:-}" 2>/dev/null | sort -u)
    fi
  else
    # DEGRADED: validation.sh unreachable — fail toward the STRICTER outcome (hostile review
    # required) rather than silently skipping it. This should never happen in a healthy install;
    # if it does, the caller sees HOSTILE_REQUIRED=1 and a note, not a silent 0.
    HOSTILE_REQUIRED=1
    HOSTILE_PATHS_OUT="DEGRADED: $_LIB unreachable — defaulting to hostile-required=1 (fail-strict)"
  fi
fi

echo "HOSTILE_REQUIRED=${HOSTILE_REQUIRED}"
# Marker-block form (matches the existing GATHER_HOSTILE_PATHS convention in
# v-gather-session-data.sh) so a multi-line path list survives intact — a caller doing
# `grep '^HOSTILE_REQUIRED='` never needs this block; a caller wanting the paths reads between
# the markers instead of assuming they fit on one `KEY=value` line.
echo "=== HOSTILE_PATHS ==="
if [ -n "$HOSTILE_PATHS_OUT" ]; then
  printf '%s\n' "$HOSTILE_PATHS_OUT"
else
  echo "NONE"
fi
echo "=== END_HOSTILE_PATHS ==="
exit 0
