#!/usr/bin/env bash
# session-lock-parse.sh — shared .claude-session-lock format parser.
#
# WHY (forensic 2026-07-02, run-v-packs landing-layer audit): THREE lock formats have been observed
# in the wild:
#   1. positional 3-field  "SID PID EPOCH"          (documented canonical — v-build-workflows.md's
#      inline /v worktree-creation template writes this)
#   2. positional 2-field  "SID EPOCH"               (hooks/worktree-create.sh + worktree-lifecycle.sh
#      wrote this historically — NO pid recorded)
#   3. key=value            "sid=... pid=... started=..." (an ad-hoc format a session improvised when
#      it created a worktree lock inline without going through the hook)
#
# v-drain-deferred-merges.sh's `_session_alive` and v-active-siblings.sh's `_emit_if_other` used to
# each implement their OWN positional-only parser, so a fix to one (the 2026-07-01 PID-liveness
# hardening) did not propagate to the other, and NEITHER correctly parsed the key=value format — it
# fell through to the "field 2" slot, read the literal string "pid=NNNNN" as a fake token, and silently
# degraded to the mtime fallback (the exact HIGH-3 defect: a dead session's lock read as "ALIVE" for up
# to the full mtime window because kill -0 was never attempted on the real pid). This file is the ONE
# parser both readers now source, so a future format fix only has to land once.
#
# CONTRACT: sourced, not executed. Safe under `set -u`/`set +e`/`set -o pipefail`. Every function is
# read-only (no writes) and never fails the caller's script (best-effort parsing; empty output on any
# ambiguity, never a hard error).

# _lock_kv_field <line> <name> -> prints the value of a key=value field ("" if absent). Tolerates any
# field order / extra whitespace. Anchors on a field boundary (start-of-line or preceding whitespace)
# so it can't match a substring inside a DIFFERENT field's value (e.g. "started=" containing "id=").
_lock_kv_field() {
  local line="$1" name="$2"
  printf '%s\n' "$line" | grep -oE "(^|[[:space:]])${name}=[^[:space:]]+" 2>/dev/null | sed -E "s/^[[:space:]]*${name}=//" | tail -1
}

# _lock_sid <lockfile> -> prints the SID regardless of format.
_lock_sid() {
  local f="$1" line
  [ -f "$f" ] || return 0
  line=$(sed -n '1p' "$f" 2>/dev/null)
  case "$line" in
    *sid=*) _lock_kv_field "$line" sid ;;
    *) printf '%s' "$line" | awk '{print $1}' ;;
  esac
}

# _lock_pid <lockfile> -> prints the resolvable numeric PID on stdout, or nothing if the lock carries
# none. A 2-field "SID EPOCH" lock legitimately has NO pid — field 2 there IS the epoch, so the caller
# MUST fall back to _lock_epoch/mtime rather than guessing a positional field is a pid. A pid is only
# inferred positionally when BOTH field 2 AND field 3 are present and numeric (the 3-field shape).
_lock_pid() {
  local f="$1" line pid f2 f3
  [ -f "$f" ] || return 0
  line=$(sed -n '1p' "$f" 2>/dev/null)
  case "$line" in
    *pid=*)
      pid=$(_lock_kv_field "$line" pid)
      case "$pid" in ''|*[!0-9]*) : ;; *) printf '%s\n' "$pid" ;; esac
      return 0
      ;;
  esac
  f2=$(printf '%s' "$line" | awk '{print $2}')
  f3=$(printf '%s' "$line" | awk '{print $3}')
  if [ -n "$f2" ] && [ -n "$f3" ] && [ -z "${f2//[0-9]/}" ] && [ -z "${f3//[0-9]/}" ]; then
    printf '%s\n' "$f2"
  fi
  return 0
}

# _lock_epoch <lockfile> -> prints the best-effort epoch timestamp recorded IN the lock content (used
# as the mtime-fallback clock for a lock with no resolvable pid). Prints nothing if unresolvable —
# caller falls back to `stat` mtime on the file itself.
_lock_epoch() {
  local f="$1" line iso f2 f3
  [ -f "$f" ] || return 0
  line=$(sed -n '1p' "$f" 2>/dev/null)
  case "$line" in
    *started=*)
      iso=$(_lock_kv_field "$line" started)
      [ -n "$iso" ] || return 0
      date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
      date -d "$iso" +%s 2>/dev/null && return 0
      return 0
      ;;
  esac
  f2=$(printf '%s' "$line" | awk '{print $2}')
  f3=$(printf '%s' "$line" | awk '{print $3}')
  if [ -n "$f3" ] && [ -z "${f3//[0-9]/}" ]; then
    printf '%s\n' "$f3"          # 3-field: field 3 is the epoch
  elif [ -n "$f2" ] && [ -z "${f2//[0-9]/}" ]; then
    printf '%s\n' "$f2"          # 2-field: field 2 IS the epoch (no pid recorded)
  fi
  return 0
}

# _lock_is_uuid <sid> -> 0 if sid looks like a real session UUID (8-4-4-4-12 hex). Guards the
# sid-keyed liveness fallbacks below from over-matching on a short/synthetic placeholder (a bare
# "x" would make `pgrep -f -- x` match nearly every process on the box).
_lock_is_uuid() {
  case "${1:-}" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) return 0 ;;
    *) return 1 ;;
  esac
}

# _lock_process_alive <sid> -> 0 if a live process whose command line names this SID exists
# (e.g. `claude -p --session-id <sid>` or a resumed `claude --resume <sid>`). Best-effort — a
# missing pgrep degrades silently to "not found" (caller has other fallbacks); never hard-errors.
_lock_process_alive() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 1
  command -v pgrep >/dev/null 2>&1 || return 1
  pgrep -f -- "$sid" >/dev/null 2>&1
}

# lock_alive <lockfile> [dead_age_min] -> 0 = ALIVE (do not touch), 1 = DEAD/expired/absent.
#
# H4-2 (PLAN_2026-07-02_orchestrator-hardening-4): the OLD predicate returned DEAD the instant
# kill -0 failed on the lock's recorded pid, with no fallback. That pid can be STALE relative to a
# genuinely live session — a re-exec, a forked child, or a runner that rewrote the lock race-late
# (forensic 2026-07-02: all 6 fleet locks' recorded PIDs failed kill -0 while >=4 sessions
# were actively writing; one session's real PID != its lock's recorded PID). A drain/GC
# gating on kill -0 alone would clobber live work. ALIVE is now the union of THREE signals, any one
# sufficient: (1) kill -0 succeeds on the recorded pid, (2) the session's transcript (main OR
# subagents/*, shared via session-liveness.sh) was touched within the liveness window, (3) a live
# process whose args name this SID exists. Only when ALL three miss does this fall back to the
# lock's own age against dead_age_min (default 360 = 6h, deliberately generous — every ambiguous
# case fails toward "still alive").
lock_alive() {
  local f="$1" dead_age_min="${2:-360}" pid ep now mt age sid
  [ -f "$f" ] || return 1
  pid=$(_lock_pid "$f")
  if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null && return 0
    # kill -0 failed on a RESOLVABLE pid: could be a genuinely dead session (GC target), or a
    # session whose lock carries a STALE pid while the session itself is still live elsewhere
    # (observed). The sid-keyed transcript/process checks are the ONLY tiebreaker here — if
    # neither confirms liveness, this pid's evidence stands: DEAD (never fall through to the
    # generous age-based check, which would just re-declare ALIVE off a fresh-looking lock mtime
    # and defeat the whole point of a provably-dead-pid GC target).
    sid=$(_lock_sid "$f")
    if [ -n "$sid" ] && _lock_is_uuid "$sid" && _lock_sid_alive "$sid"; then
      return 0
    fi
    return 1
  fi
  # No resolvable pid at all (legacy 2-field "SID EPOCH" lock, or an unparseable line) — sid-keyed
  # liveness is still a stronger signal than raw age when available, then fall back to age.
  sid=$(_lock_sid "$f")
  if [ -n "$sid" ] && _lock_is_uuid "$sid" && _lock_sid_alive "$sid"; then
    return 0
  fi
  now=$(date +%s 2>/dev/null || echo 0)
  ep=$(_lock_epoch "$f")
  if [ -n "$ep" ]; then mt="$ep"; else mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now"); fi
  age=$(( (now - ${mt:-$now}) / 60 ))
  [ "$age" -lt "$dead_age_min" ] && return 0 || return 1
}

# owning_claude_pid [start_pid] -> prints the PID of the nearest ancestor whose executable is the
# `claude` CLI itself; falls back to the start pid (default $$) when no such ancestor exists.
#
# WRONG-PID-LOCK class (forensic 2026-07-04, Jul-4 fleet): lock minting stamped `$$` — the
# EPHEMERAL Bash-tool subshell that dies the moment the tool call returns — so kill -0 on every
# fleet lock was permanently false while all 7 sessions sat alive in idle terminal tabs. Every
# PID-based liveness guard (lock_alive, drain skip, GC) silently degraded to the transcript-mtime
# tiebreaker, which idle-open tabs refresh forever → the drain was starved all day and nothing
# landed. The OWNING process is the long-lived `claude` ancestor: stamp THAT.
# Matches on `ps -o comm=` (bare executable name) — never the full command line, which would
# false-match any script path under ~/.claude/ (observed: "bash $HOME/.claude/skills/…").
# Bite: session-lock-owning-pid-test.sh (red vs .pre-ownpid0704-bak lock mint).
owning_claude_pid() {
  local pid="${1:-$$}" comm depth=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$depth" -lt 20 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | awk '{print $1}')
    case "${comm##*/}" in
      claude) printf '%s\n' "$pid"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    depth=$((depth+1))
  done
  printf '%s\n' "${1:-$$}"
  return 1
}

# _lock_sid_alive <sid> -> 0 if session-liveness.sh's is_session_live confirms LIVE, or a live
# process names this sid. Sourced lazily (once per shell) to keep lock_alive dependency-light for
# callers that never hit this path (the common resolvable-and-alive pid case never reaches here).
_lock_sid_alive() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 1
  if [ -z "${_SLP_LIVENESS_SOURCED:-}" ]; then
    local _slp_dir
    _slp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    # shellcheck source=/dev/null
    [ -n "$_slp_dir" ] && [ -f "$_slp_dir/session-liveness.sh" ] && source "$_slp_dir/session-liveness.sh" 2>/dev/null
    _SLP_LIVENESS_SOURCED=1
  fi
  if type is_session_live >/dev/null 2>&1 && is_session_live "$sid"; then
    return 0
  fi
  _lock_process_alive "$sid"
}
