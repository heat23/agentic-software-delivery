#!/usr/bin/env bash
# v-suite-lock-dead-holder-test.sh — cycle-2 F5 follow-up (2026-07-04) regression: a SIGKILLed
# lock holder skips its EXIT-trap release and leaks the suite lock; waiters used to burn the full
# wait-timeout fail-open (live incident: killed sweep leaked .suite-lock.d, next sweep waited 900s).
# The fix is OPT-IN dead-holder reclaim: acquire records `holder-live` + a caller-guaranteed PID
# ONLY when V_SUITE_LOCK_HOLDER_PID is passed; waiters steal only such locks when that PID is dead.
# A naive always-on PID steal was tried first and BROKE the session-owned design (v-perf3: acquire
# runs in throwaway $(...) subshells whose PID is dead while the session still holds the lock).
# Pins:
#   T1   holder-live marker + dead PID -> instant steal + acquire (no timeout burn)
#   T1b  UNMARKED owner line + dead PID (the legacy/subshell shape) -> NOT stolen (v-perf3 pin)
#   T2   holder-live marker + LIVE PID -> NOT stolen (no over-steal)
#   T3   EMPTY owner file (mid-acquire TOCTOU) -> NOT dead-stolen (mtime backstop only)
#   T4   V_SUITE_LOCK_HOLDER_PID recorded with holder-live; default write stays 3-field unmarked
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCKER="$HERE/v-suite-lock.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }
[ -f "$LOCKER" ] || { echo "SKIP: v-suite-lock.sh missing"; exit 0; }

BASE=$(mktemp -d); trap 'rm -rf "$BASE" 2>/dev/null; [ -n "${_live_pid:-}" ] && kill "$_live_pid" 2>/dev/null' EXIT
REPO="$BASE/repo"; mkdir -p "$REPO"   # non-git dir: _shared_root falls back to the dir itself
LOCK_DIR="$REPO/.worktrees/.suite-lock.d"

plant_lock(){ # $1=owner-line (empty string = empty owner file)
  mkdir -p "$LOCK_DIR"
  if [ -n "$1" ]; then printf '%s\n' "$1" > "$LOCK_DIR/owner"; else : > "$LOCK_DIR/owner"; fi
}

echo "== T1: holder-live marker + dead PID -> instant steal =="
plant_lock "aaaa1111-2222-3333-4444-555566667777 999999 1700000000 holder-live"
_t0=$(date +%s)
OUT=$(bash "$LOCKER" acquire "$REPO" "bbbb0000-0000-0000-0000-000000000000" 30 3600 2>&1)
_dt=$(( $(date +%s) - _t0 ))
{ printf '%s' "$OUT" | grep -q 'stealing-dead-holder' && printf '%s' "$OUT" | grep -q 'SUITE_LOCK=acquired' && [ "$_dt" -lt 10 ]; } \
  && ok "marked dead holder stolen instantly (${_dt}s, no timeout burn)" \
  || no "T1 dead-holder steal failed (dt=${_dt}s out=[$OUT])"
bash "$LOCKER" release "$REPO" "bbbb0000-0000-0000-0000-000000000000" >/dev/null 2>&1

echo "== T1b: UNMARKED owner line + dead PID -> NOT stolen (session-owned; v-perf3 pin) =="
plant_lock "aaaa1111-2222-3333-4444-555566667777 999999 1700000000"
OUT=$(bash "$LOCKER" acquire "$REPO" "bbbb0000-0000-0000-0000-000000000000" 3 3600 2>&1)
{ printf '%s' "$OUT" | grep -q 'timeout-proceeding' && ! printf '%s' "$OUT" | grep -q 'stealing-dead-holder' && [ -d "$LOCK_DIR" ]; } \
  && ok "unmarked (legacy/subshell) lock NOT stolen despite dead recorded PID" \
  || no "T1b regression: unmarked lock stolen or wrong path (out=[$OUT])"
rm -rf "$LOCK_DIR"

echo "== T2: holder-live marker + LIVE PID -> not stolen (fail-open timeout) =="
sleep 60 & _live_pid=$!
plant_lock "cccc1111-2222-3333-4444-555566667777 $_live_pid 1700000000 holder-live"
OUT=$(bash "$LOCKER" acquire "$REPO" "bbbb0000-0000-0000-0000-000000000000" 3 3600 2>&1)
{ printf '%s' "$OUT" | grep -q 'timeout-proceeding' && ! printf '%s' "$OUT" | grep -q 'stealing-dead-holder' && [ -d "$LOCK_DIR" ]; } \
  && ok "live marked holder's lock NOT stolen (fail-open after 3s, lock intact)" \
  || no "T2 over-steal or wrong path on live holder (out=[$OUT])"
kill "$_live_pid" 2>/dev/null; _live_pid=""
rm -rf "$LOCK_DIR"

echo "== T3: empty owner file (mid-acquire TOCTOU) -> not dead-stolen =="
plant_lock ""
OUT=$(bash "$LOCKER" acquire "$REPO" "bbbb0000-0000-0000-0000-000000000000" 3 3600 2>&1)
{ printf '%s' "$OUT" | grep -q 'timeout-proceeding' && ! printf '%s' "$OUT" | grep -q 'stealing-dead-holder' && [ -d "$LOCK_DIR" ]; } \
  && ok "empty owner file not treated as dead holder (mtime backstop owns that case)" \
  || no "T3 empty-owner lock wrongly stolen (out=[$OUT])"
rm -rf "$LOCK_DIR"

echo "== T4: owner-line format — override marked, default unmarked =="
bash_out="$BASE/t4.out"
V_SUITE_LOCK_HOLDER_PID=$$ bash "$LOCKER" acquire "$REPO" "dddd0000-0000-0000-0000-000000000000" 5 3600 > "$bash_out" 2>&1
_oline=$(awk 'NR==1{print}' "$LOCK_DIR/owner" 2>/dev/null)
{ [ "$(printf '%s' "$_oline" | awk '{print $2}')" = "$$" ] && [ "$(printf '%s' "$_oline" | awk '{print $4}')" = "holder-live" ]; } \
  && ok "override recorded with holder-live marker ($$)" \
  || no "T4 override line wrong: [$_oline]"
bash "$LOCKER" release "$REPO" "dddd0000-0000-0000-0000-000000000000" >/dev/null 2>&1
bash "$LOCKER" acquire "$REPO" "eeee0000-0000-0000-0000-000000000000" 5 3600 > "$bash_out" 2>&1
_oline=$(awk 'NR==1{print}' "$LOCK_DIR/owner" 2>/dev/null)
{ [ "$(printf '%s' "$_oline" | awk '{print NF}')" = "3" ]; } \
  && ok "default write stays 3-field unmarked (liveness never inferred from it)" \
  || no "T4 default line wrong: [$_oline]"
bash "$LOCKER" release "$REPO" "eeee0000-0000-0000-0000-000000000000" >/dev/null 2>&1

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
