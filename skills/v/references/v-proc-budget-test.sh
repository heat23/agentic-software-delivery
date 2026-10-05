#!/usr/bin/env bash
# v-proc-budget-test.sh — unit tests for v-proc-budget.sh (the --processes resolver).
# Each case runs in a FRESH subshell so exported outputs never shadow the next input.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUDGET="$HERE/v-proc-budget.sh"
PASS=0; FAIL=0

# resolve <cores> <expected_sessions> <parallel_detected:true|false> [extra env assignments...]
# echoes "SCOPED FULL"
resolve() {
  local cores="$1" sessions="$2" par="$3"; shift 3
  env -i bash -c '
    export V_PROC_BUDGET_NO_AUTO=1
    export V_PEST_FORCE_CORES="'"$cores"'"
    [ -n "'"$sessions"'" ] && export V_EXPECTED_SESSIONS="'"$sessions"'"
    export PARALLEL_SESSIONS_DETECTED="'"$par"'"
    '"$*"'
    . "'"$BUDGET"'"
    vpb_resolve
    printf "%s %s\n" "$V_PEST_PROCESSES_SCOPED" "$V_PEST_PROCESSES_FULL"
  '
}

check() { # check <label> <got> <expected>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok  %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s — got [%s] want [%s]\n' "$1" "$2" "$3"; fi
}

echo "== v-proc-budget resolver =="

# Reference machine: 10 performance cores, expecting ~4 concurrent sessions.
check "10 cores / 4 sessions → scoped=2 full=6"  "$(resolve 10 4 false)"  "2 6"
# Fewer expected sessions → bigger scoped share, but clamped at 4.
check "10 cores / 2 sessions → scoped=4 full=6"  "$(resolve 10 2 false)"  "4 6"
check "10 cores / 1 session  → scoped=4 full=6"  "$(resolve 10 1 false)"  "4 6"
# Live contention drops the scoped notch (floor(10/4)=2 already at min → stays 2).
check "10c/4s + parallel-detected → scoped=2"    "$(resolve 10 4 true)"   "2 6"
# With 2 sessions scoped would be 4; parallel-detected drops it to 3.
check "10c/2s + parallel-detected → scoped=3"    "$(resolve 10 2 true)"   "3 6"

# Small machines: never exceed the core count.
check "4 cores / 4 sessions → scoped=2 full=2"   "$(resolve 4 4 false)"   "2 2"
check "2 cores / 4 sessions → scoped=2 full=2"   "$(resolve 2 4 false)"   "2 2"
check "1 core  / 4 sessions → scoped=1 full=1"   "$(resolve 1 4 false)"   "1 1"

# Big machine: full caps at 6, scoped caps at 4.
check "32 cores / 1 session → scoped=4 full=6"   "$(resolve 32 1 false)"  "4 6"
check "32 cores / 8 sessions → scoped=4 full=6"  "$(resolve 32 8 false)"  "4 6"

# Explicit overrides win.
check "override BOTH via V_PEST_PROCESSES=3"      "$(resolve 10 4 false 'export V_PEST_PROCESSES=3')"               "3 3"
check "override scoped only"                      "$(resolve 10 4 false 'export V_PEST_PROCESSES_SCOPED=1')"        "1 6"
check "override full only"                        "$(resolve 10 4 false 'export V_PEST_PROCESSES_FULL=10')"         "2 10"
check "per-budget override beats V_PEST_PROCESSES" "$(resolve 10 4 false 'export V_PEST_PROCESSES=3; export V_PEST_PROCESSES_FULL=8')" "3 8"

# Garbage inputs fall back sanely (non-numeric cores → 4; non-numeric sessions → 4).
check "garbage cores → default 4 → scoped=2 full=2" "$(resolve abc 4 false)" "2 2"
check "garbage sessions → default 4"                "$(resolve 10 xyz false)" "2 6"

# INVARIANT: scoped × expected-sessions must not exceed cores for the typical case
# (this is the whole point — no oversubscription). Spot-check the headline config.
read -r S F <<<"$(resolve 10 4 false)"
inv=$(( S * 4 ))
check "INVARIANT scoped(2)×4 sessions=8 ≤ 10 cores" "$([ "$inv" -le 10 ] && echo ok)" "ok"
check "INVARIANT full(6) ≤ 10 cores"                "$([ "$F" -le 10 ] && echo ok)"   "ok"

# Auto-resolve on source (no NO_AUTO) must export both vars on real hardware.
read -r AS AF <<<"$(env -i bash -c '. "'"$BUDGET"'"; printf "%s %s\n" "${V_PEST_PROCESSES_SCOPED:-MISSING}" "${V_PEST_PROCESSES_FULL:-MISSING}"')"
check "auto-resolve exports scoped (numeric)" "$(case "$AS" in (''|*[!0-9]*) echo no;; (*) echo yes;; esac)" "yes"
check "auto-resolve exports full (numeric)"   "$(case "$AF" in (''|*[!0-9]*) echo no;; (*) echo yes;; esac)" "yes"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
