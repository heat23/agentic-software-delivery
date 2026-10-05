#!/usr/bin/env bash
# v-dispatch-lock-test.sh — W-DISPATCHLOCK: one live dispatch per artifact (2026-08-04).
#
# THE BUG, OBSERVED LIVE. A production session had TWO independent dispatch
# chains running simultaneously, both writing the same QA_REPORT_<sid>.md.
# Both were QA iteration 3/3 for the same pack. `v-dispatch-subagent.sh` had no flock/lockfile/
# mkdir guard of any kind, so the two raced on the artifact: double spend, and whichever finished
# LAST overwrote the other's verdict — including the case where the loser was the better result.
#
# DESIGN CONSTRAINTS discovered while writing this (each one would have broken the helper):
#   1. FAIL OPEN. The lock may only ever PREVENT a duplicate; it must never block a legitimate
#      dispatch. Any failure of the lock mechanism itself ⇒ proceed unlocked. Worst case is
#      today's behaviour, never worse.
#   2. Refuse ONLY on a PROVEN live holder (`kill -0`). A stale directory left by a killed
#      dispatch must be taken over, not treated as a conflict — otherwise one SIGKILL wedges
#      that artifact forever.
#   3. Do NOT install a second EXIT trap. The helper already sets one at line ~598; a trap added
#      earlier is silently CLOBBERED by it, which would leak the lock dir on every single run.
#      Release must be folded into the existing trap.
#   4. Skip when `_V_DISPATCH_LOCK_HELD` is already set — the helper forks a watchdog subshell
#      (line ~648) that shows the same argv in `ps`, and `--detach` re-execs itself; neither may
#      deadlock against the outer acquisition.
#
# RED ORACLE: V_DSA=<pre-W-DISPATCHLOCK bak> has no lock block.
set -u
DSA="${V_DSA:-$HOME/.claude/skills/v/references/v-dispatch-subagent.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
[ -f "$DSA" ] || { echo "  NO  helper not found"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

BLK="$(awk '/=== W-DISPATCHLOCK/,/=== end W-DISPATCHLOCK/' "$DSA")"
echo "== W-DISPATCHLOCK :: one live dispatch per artifact =="
if [ -z "$BLK" ]; then
  no "W-DISPATCHLOCK block present" "awk range empty (pre-fix = RED)"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "W-DISPATCHLOCK block present"

run(){ # $1=artifact $2=preset _V_DISPATCH_LOCK_HELD -> "rc|locked"
  # The block `exit`s on refusal, which kills the subshell BEFORE any printf inside it — so the
  # exit status must be read from the subshell itself, not printed from within. Reading it any
  # other way yields an empty rc and the refusal assertion degrades to "non-zero", which would
  # still pass if the block crashed for an unrelated reason.
  local rc
  ( set +eu
    ARTIFACT="$1"; _V_DISPATCH_LOCK_HELD="$2"
    eval "$BLK" >/dev/null 2>&1 ) ; rc=$?
  printf '%s|%s' "$rc" "$([ -d "$1.dispatch-lock" ] && echo yes || echo no)"
}

A="$WORK/QA_REPORT_x.md"; : > "$A"

# (1) first acquisition succeeds and creates the lock
r=$(run "$A" "")
case "$r" in 0\|yes) ok "first dispatch acquires the lock" ;; *) no "first acquisition failed" "$r" ;; esac
rm -rf "$A.dispatch-lock"

# (2) a LIVE holder ⇒ refuse (this is the observed double-dispatch case)
mkdir -p "$A.dispatch-lock"; echo $$ > "$A.dispatch-lock/pid"   # $$ is alive by definition
r=$(run "$A" "")
rc="${r%%|*}"
[ "$rc" = "10" ] \
  && ok "LIVE holder → refused with the dedicated rc=10 (duplicate prevented)" \
  || no "expected refusal rc=10, got '$rc' (non-zero alone would also match a crash)" "$r"
rm -rf "$A.dispatch-lock"

# (3) a STALE holder (dead pid) ⇒ take over, never wedge
mkdir -p "$A.dispatch-lock"; echo 999999 > "$A.dispatch-lock/pid"   # not a live pid
r=$(run "$A" "")
case "$r" in 0\|yes) ok "STALE holder → taken over (a killed dispatch cannot wedge the artifact)" ;;
             *) no "stale lock was not reclaimed" "$r" ;; esac
rm -rf "$A.dispatch-lock"

# (4) nested subshell / detach re-exec must pass straight through
r=$(run "$A" "$A")
case "$r" in 0\|no) ok "already-held env guard → pass-through, no re-acquire (no self-deadlock)" ;;
             *) no "nested invocation tried to re-acquire" "$r" ;; esac

# (5) FAIL OPEN: an unwritable parent must not block the dispatch
UNW="$WORK/nodir/QA.md"
r=$(run "$UNW" "")
[ "${r%%|*}" = "0" ] \
  && ok "lock mechanism failure → FAIL OPEN (proceeds unlocked, never blocks a real dispatch)" \
  || no "a lock-mechanism failure blocked a legitimate dispatch" "$r"

# (6) release must be folded into the EXISTING exit trap, not a second one
_traps=$(grep -cE "^\s*trap .*EXIT" "$DSA")
[ "${_traps:-0}" -eq 1 ] \
  && ok "exactly ONE EXIT trap (release folded in; a 2nd would be clobbered and leak the lock)" \
  || no "more than one EXIT trap — the earlier one is silently clobbered" "count=$_traps"
grep -qE 'trap .*_DL_DIR.*EXIT|_DL_DIR.*rm -rf' "$DSA" \
  && ok "the existing EXIT trap releases the lock dir" \
  || no "lock dir is never released by the exit trap" ""

# (7) the refusal code must not collide with codes the helper already returns
used=$(grep -oE '^\s*exit [0-9]+' "$DSA" | grep -oE '[0-9]+' | sort -un | tr '\n' ' ')
rc_lock=$(printf '%s' "$BLK" | grep -oE 'exit [0-9]+' | grep -oE '[0-9]+' | head -1)
n=$(grep -oE '^\s*exit [0-9]+' "$DSA" | grep -oE '[0-9]+' | grep -c "^${rc_lock}$")
[ "${n:-0}" -eq 1 ] \
  && ok "refusal code ${rc_lock} is unique (others in use: ${used})" \
  || no "refusal code ${rc_lock} collides with an existing exit code" "used=${used}"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
