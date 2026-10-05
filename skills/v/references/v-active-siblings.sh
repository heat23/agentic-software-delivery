#!/usr/bin/env bash
# v-active-siblings.sh <repo_root> <self_sid> [worktree_age_min]
#
# Prints one line ("<sid> <lockfile>") per OTHER active /v WORKTREE session in this repo
# (.worktrees/*/.claude-session-lock). Excludes the caller's own SID and locks older than
# worktree_age_min (default 240). EMPTY output = caller has no active sibling.
#
# Optimistic universal-worktree model (2026-05-25): every /v request runs in its own
# worktree, so "active sibling" == an active worktree session lock. This helper is the
# sibling signal for:
#   - the Maintenance-inline guard (SKILL.md Step 2a): if any worktree sibling is active,
#     an otherwise-eligible Maintenance fast-path MUST create a worktree instead of working
#     inline on main;
#   - dependency detect-and-recover (v-dependency-recover.sh): the poll loop waits until
#     this prints empty (all in-flight siblings merged/cleared) before rebasing + retrying.
#
# NOTE: the inline-on-main-lock scan was REMOVED with the staged-multi-wave exception —
# /v no longer works inline on main for feature/bug waves, so nothing writes
# .v/tmp/inline-main-lock-* anymore. v-merge-back.sh keeps its OWN age-bounded defensive
# find for inline-main-lock (so a maintenance-inline editor or a manual lock can't be
# tangled over); that detection no longer lives here.
set -u
REPO="${1:?usage: v-active-siblings.sh <repo_root> <self_sid> [worktree_age_min]}"
SELF="${2:-}"
# Worktree locks legitimately persist for long-running features → 240min window.
WT_AGE="${3:-240}"

# Shared lock-format parser (2026-07-02 fix): a lock may be positional 3-field "SID PID EPOCH",
# positional 2-field "SID EPOCH" (no pid), or key=value "sid=... pid=... started=...". Both this
# script and v-drain-deferred-merges.sh source the SAME parser so a format fix lands once, not twice
# (previously each had its own positional-only parser; the key=value shape silently degraded BOTH to
# the mtime fallback instead of the authoritative kill -0 check — HIGH-3, forensic 2026-07-02).
_LOCK_LIB="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-lock-parse.sh"
# shellcheck disable=SC1090
[ -f "$_LOCK_LIB" ] && . "$_LOCK_LIB" || true

_emit_if_other() {
  local f="$1" sid
  [ -f "$f" ] || return 0
  if command -v _lock_sid >/dev/null 2>&1; then
    sid=$(_lock_sid "$f" 2>/dev/null)
  else
    sid=$(sed -n '1p' "$f" 2>/dev/null | awk '{print $1}')
  fi
  [ -n "$sid" ] && [ "$sid" != "$SELF" ] || return 0
  # Liveness (2026-07-01 lesson: a 240-min mtime window is UNSAFE — it reads an 11h-LIVE session's lock as
  # dead → MISSES a live sibling → merge clobbers it; and reads a just-crashed session's fresh lock as
  # alive → false-defers). lock_alive() decides by the OWNING PID via kill -0 when a pid is resolvable in
  # ANY of the 3 known formats — the same authoritative check v-drain-deferred-merges.sh uses. Only a
  # lock with no trustworthy PID falls back to the mtime/epoch window. PID reuse only OVER-reports a
  # sibling ⇒ fail-safe (defer).
  if command -v lock_alive >/dev/null 2>&1; then
    lock_alive "$f" "$WT_AGE" && printf '%s %s\n' "$sid" "$f"
    return 0
  fi
  # Lib unavailable — fail-safe: treat as alive (old behavior's safe direction).
  printf '%s %s\n' "$sid" "$f"
}

# Worktree session locks (long window).
#
# A-4 hardening (forensic Wave-H 2026-06-04): the original scan covered ONLY
# $REPO/.worktrees/** — but worktrees are routinely created EXTERNALLY (the Wave-H sessions
# all lived under ~/.claude/worktrees/<repo>/build/...), so H-7 asked for siblings,
# got an empty answer while SIX sibling sessions were live, and fell back to editing main
# directly. Scan BOTH: the legacy $REPO/.worktrees tree AND every worktree git itself
# registers (authoritative, location-independent). Dedupe by lock path.
{
  find "$REPO/.worktrees" -name '.claude-session-lock' 2>/dev/null
  git -C "$REPO" worktree list --porcelain 2>/dev/null \
    | sed -n 's/^worktree //p' | tail -n +2 \
    | while IFS= read -r _wt; do
        [ -n "$_wt" ] && [ -d "$_wt" ] || continue
        find "$_wt" -maxdepth 1 -name '.claude-session-lock' 2>/dev/null
      done
} | while IFS= read -r _f; do
      # Normalize to the PHYSICAL path before dedupe — the legacy find and git's registry can
      # name the same lock through different symlink forms (macOS /var vs /private/var).
      [ -f "$_f" ] || continue
      _d=$(cd "$(dirname "$_f")" 2>/dev/null && pwd -P) || continue
      [ -n "$_d" ] && printf '%s/%s\n' "$_d" "$(basename "$_f")"
    done | sort -u | while IFS= read -r f; do _emit_if_other "$f"; done
exit 0
