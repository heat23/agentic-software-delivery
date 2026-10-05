#!/usr/bin/env bash
# v-proc-budget-pd1-test.sh — QA-F4 bite: the live-contention budget-shrink must fire on the NUMERIC
# PARALLEL_SESSIONS_DETECTED=1 that v-bootstrap.sh actually emits (not only the "true" the gather/docs
# use). RED on v-proc-budget.sh.pre-pd1-bak (the "true"-only check ignores "1" -> the throttle never
# fires under a parallel fleet). Re-run: bash <thisfile>
set -uo pipefail
PB="${V_PB_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-proc-budget.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$PB" ] || { echo "SKIP: v-proc-budget.sh missing"; exit 0; }

# scoped = clamp(cores/conc, 2..4); a live-contention signal drops it one notch (floor 2). Force cores=8,
# conc=2 -> scoped=4; with the parallel signal -> 3.
_scoped(){  # $1 = value for PARALLEL_SESSIONS_DETECTED ("" = leave unset)
  ( export V_PEST_FORCE_CORES=8 V_EXPECTED_SESSIONS=2
    [ -n "${1:-}" ] && export PARALLEL_SESSIONS_DETECTED="$1"
    source "$PB" >/dev/null 2>&1
    printf '%s' "${V_PEST_PROCESSES_SCOPED:-?}" )
}
S_NONE=$(_scoped "")
S_PAR=$(_scoped 1)
[ "$S_NONE" = "4" ] \
  && ok "baseline scoped budget = 4 (cores 8 / conc 2, clamped 2..4)" \
  || no "baseline scoped wrong (test setup)" "got $S_NONE"
[ "$S_PAR" = "3" ] \
  && ok "PARALLEL_SESSIONS_DETECTED=1 shrinks the scoped budget 4->3 (the burn-reducing throttle now fires on bootstrap's numeric flag)" \
  || no "numeric '1' did NOT trigger the live-contention shrink" "got $S_PAR (pre-fix ignores '1' -> stays 4)"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
