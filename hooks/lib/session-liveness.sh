#!/usr/bin/env bash
# session-liveness.sh — shared transcript-liveness primitive.
# Introduced by the concurrency-isolation start-claim work (HANDOFF 2026-06-28); designed to ALSO
# back FND-3's transcript-liveness in v-active-siblings.sh so BOTH consumers share ONE definition
# (the handoff's "factor it into a tiny shared helper" directive — avoids two near-identical liveness
# checks drifting apart).
#
# WHY A TRANSCRIPT IS THE LIVENESS SIGNAL:
# A Claude session appends to its transcript (${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/<sid>.jsonl)
# on every turn, so the transcript's mtime is a robust "is this session still alive?" gauge that does
# NOT depend on any /v-specific lock or marker. That matters because the OLD sibling detector keyed on
# a worktree LOCK (.worktrees/*/.claude-session-lock), which only exists AFTER a session has created its
# worktree — so a simultaneously-launched fleet saw every sibling as "solo" before anyone had locked, and
# the inline-eligible paths all proceeded on shared main → contamination. A claim + transcript
# liveness is visible the instant a session starts, INLINE sessions included.
#
# CONTRACT: this file is SOURCED (it defines functions + one default var); it has no effect when run
# directly. Safe under `set -u` and `set +e`.
#
# Portable mtime (codex CDX-005, same as hooks/lib/validation.sh `_v_mtime_epoch`): GNU stat reads
# `-f` as a *filesystem* stat and prints a filesystem summary, so a BSD-first `-f || -c` chain returns
# garbage on Linux. Try the GNU form first: BSD stat rejects `-c` without printing anything. This also
# holds on macOS with GNU coreutils ahead of /usr/bin on PATH, where branching on `uname` picked the BSD
# form for a GNU stat. Guarded by scripts/portability-test.sh.

# Liveness window (seconds): a session whose transcript has not been touched within this window is
# treated as no-longer-live. 45 min is deliberately generous so a long in-flight agent dispatch / build
# that appends nothing to the parent transcript for several minutes is NOT mistaken for dead — the safe
# direction is to keep treating a sibling as live (→ force isolation), since under-isolation contaminates
# main while over-isolation only costs a cheap worktree. Override with V_SESSION_LIVENESS_WINDOW_SEC.
#
# COMPANION KNOB (documented here so this lib surfaces the mechanism's full tunability, FP-LOW4): the
# DELETION of a dead claim file is governed separately by V_SESSION_CLAIM_GC_SEC (default 28800s / 8h),
# read by v-bootstrap.sh — NOT by this window. The two are intentionally decoupled: liveness (this
# window) decides "is the sibling working right now"; GC (the 8h threshold) decides "is this claim
# ancient enough to delete." Keep V_SESSION_CLAIM_GC_SEC >= V_SESSION_LIVENESS_WINDOW_SEC, else a
# merely-idle live session's claim could be deleted and the session would go undetected on resume.
: "${V_SESSION_LIVENESS_WINDOW_SEC:=2700}"

# _slv_mtime_epoch <file> -> prints epoch mtime; non-zero rc (no output) if absent/unreadable.
_slv_mtime_epoch() {
  [ -f "$1" ] || return 1
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# _slv_transcript_for <sid> -> prints the path of the NEWEST transcript for <sid> ("" if none).
# Globs every project dir: a sid is globally unique, but a resumed session can have transcripts under
# more than one project dir, so the newest mtime reflects the most recent activity.
# H4-2 (PLAN_2026-07-02_orchestrator-hardening-4): ALSO globs the SID's subagents/ tree
# ($_cfg/projects/*/<sid>/subagents/*.jsonl). A session that is mid-dispatch (waiting on a
# background Agent-tool reviewer/runner) appends nothing to its OWN transcript for the dispatch's
# whole duration, but the DISPATCHED subagent's transcript is actively growing — missing it made a
# genuinely-live, actively-writing session look stale by this check alone.
_slv_transcript_for() {
  local _sid="${1:-}" _cfg _best="" _best_mt=0 _f _mt
  [ -n "$_sid" ] || return 0
  _cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  for _f in "$_cfg"/projects/*/"$_sid".jsonl "$_cfg"/projects/*/"$_sid"/subagents/*.jsonl; do
    [ -f "$_f" ] || continue              # no-match → literal glob pattern → skipped here
    _mt=$(_slv_mtime_epoch "$_f") || continue
    [ -n "$_mt" ] || continue
    if [ "$_mt" -gt "$_best_mt" ] 2>/dev/null; then _best_mt="$_mt"; _best="$_f"; fi
  done
  printf '%s' "$_best"
}

# is_session_live <sid> [window_sec] -> TRI-STATE via exit code (caller decides the fail-safe direction
# for the indeterminate case):
#   0 = transcript found AND modified within the window   (LIVE)
#   1 = transcript found BUT older than the window        (DEAD / stale)
#   2 = no transcript found for this sid                  (INDETERMINATE)
is_session_live() {
  local _sid="${1:-}" _win="${2:-$V_SESSION_LIVENESS_WINDOW_SEC}" _t _mt _now _age
  [ -n "$_sid" ] || return 2
  _t=$(_slv_transcript_for "$_sid")
  [ -n "$_t" ] || return 2
  _mt=$(_slv_mtime_epoch "$_t") || return 2
  [ -n "$_mt" ] || return 2
  _now=$(date +%s 2>/dev/null || echo 0)
  _age=$(( _now - _mt ))
  [ "$_age" -lt 0 ] && _age=0            # clock skew / date failure → treat as fresh (safe direction)
  [ "$_age" -le "$_win" ] && return 0
  return 1
}
