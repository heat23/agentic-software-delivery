#!/usr/bin/env bash
# session-lock-liveness-stale-pid-test.sh — H4-2 (PLAN_2026-07-02_orchestrator-hardening-4)
#
# lock_alive()'s OLD predicate declared a lock DEAD the instant kill -0 failed on its recorded pid,
# with no fallback. Ground truth (forensic 2026-07-02): all 6 fleet locks' recorded PIDs failed
# kill -0 while >=4 sessions were actively writing — one session's real PID did not
# match its lock's recorded PID. A drain/GC gating on kill -0 alone would clobber live work.
#
# Fix: ALIVE is the union of (1) kill -0 on the recorded pid, (2) the session's transcript (main OR
# subagents/*) touched within the liveness window (shared session-liveness.sh), (3) a live process
# naming the sid. Only when a pid IS resolvable and ALL of these miss is the lock DEAD (no
# generous age-fallback in that case — a resolvable-and-dead pid is authoritative once the sid
# checks also miss). When NO pid is resolvable at all, sid-liveness then age is still the fallback
# chain (unchanged legacy behavior for 2-field locks).
#
# RED on the pre-edit backup (declares DEAD purely from kill -0 failure, ignoring the live
# transcript). GREEN on the fix.
set -uo pipefail
LOCKLIB="${V_LOCKLIB_OVERRIDE:-$HOME/.claude/hooks/lib/session-lock-parse.sh}"
LOCKLIB_BAK="$HOME/.claude/hooks/lib/session-lock-parse.sh.pre-h4-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }

echo "== H4-2 :: lock_alive() stale-pid-but-live-transcript =="

bash -n "$LOCKLIB" && ok "session-lock-parse.sh parses (bash -n)" || no "syntax error"

TH=$(mktemp -d); trap 'rm -rf "$TH"' EXIT
mkdir -p "$TH/.claude/projects/p"
REAL_SID="5e55a000-1111-4222-8333-444455556666"
# A pid guaranteed dead: fork+reap immediately (matches the existing landing-layer test technique).
( exit 0 ) & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null || true

_run() {  # $1=lockdir(lib override target) -> prints results for both scenarios
  ( CLAUDE_CONFIG_DIR="$TH/.claude"
    . "$1"
    LF="$TH/lock-stale-pid"
    printf '%s %s %s\n' "$REAL_SID" "$DEAD_PID" "$(date +%s)" > "$LF"
    # Scenario A: stale pid + a FRESH transcript for the real sid -> must be ALIVE (5e55a000 shape)
    : > "$TH/.claude/projects/p/${REAL_SID}.jsonl"
    lock_alive "$LF" 360 && echo "A=ALIVE" || echo "A=DEAD"
    # Scenario B: stale pid + NO transcript at all for this sid -> must be DEAD (real GC target)
    rm -f "$TH/.claude/projects/p/${REAL_SID}.jsonl"
    lock_alive "$LF" 360 && echo "B=ALIVE" || echo "B=DEAD"
  )
}

echo "-- GREEN: fixed lib --"
OUT=$(_run "$LOCKLIB")
printf '%s\n' "$OUT" | grep -q '^A=ALIVE$' \
  && ok "fixed: stale-pid + live transcript for the real sid -> ALIVE (5e55a000 fix)" \
  || no "fixed: stale-pid + live transcript should be ALIVE" "$OUT"
printf '%s\n' "$OUT" | grep -q '^B=DEAD$' \
  && ok "fixed: stale-pid + no transcript at all -> DEAD (still a valid GC target)" \
  || no "fixed: stale-pid + no transcript should stay DEAD" "$OUT"

echo "-- RED: pre-edit backup (kill -0 failure alone = DEAD, ignores the live transcript) --"
if [ -f "$LOCKLIB_BAK" ]; then
  OUT2=$(_run "$LOCKLIB_BAK")
  printf '%s\n' "$OUT2" | grep -q '^A=DEAD$' \
    && ok "backup: stale-pid + live transcript incorrectly read DEAD (confirms the bug pre-fix)" \
    || no "backup: expected the pre-fix bug (DEAD) but got something else" "$OUT2"
else
  echo "  SKIP: no backup at $LOCKLIB_BAK"
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
