#!/usr/bin/env bash
# v-lint-advisory-test.sh — α (2026-06-16): lint is ADVISORY (non-blocking) in pre-flight.
# Two layers: (1) CONTRACT — the ADVISORY wiring is present in all consumers of v-run-gates.sh
# (drift guard: if someone removes a branch, this fails loudly); (2) BEHAVIORAL — the ALL_PASS
# + fail-fast decision logic (mirrored from the source, kept honest by the contract grep) treats
# ADVISORY as non-blocking while a REAL gate failure still fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATES="$HERE/v-run-gates.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

[ -f "$GATES" ] || { echo "TOTAL: 0 passed, 1 failed (v-run-gates.sh missing)"; exit 1; }

# ── (1) CONTRACT: ADVISORY wired into every consumer ──────────────────────────
grep -qE 'LINT_RC="ADVISORY"' "$GATES" && ok "normalize: failing lint → ADVISORY" || no "normalize branch missing"
grep -qE 'V_LINT_BLOCKING' "$GATES" && ok "opt-out: V_LINT_BLOCKING restores blocking" || no "V_LINT_BLOCKING opt-out missing"
grep -qE '\[ "\$LINT_RC" = "ADVISORY" \]' "$GATES" && ok "build-gate accepts ADVISORY" || no "build-gate missing ADVISORY"
grep -qE 'case "\$_rc" in 0\|SKIP\|""\|INCONCLUSIVE\|ADVISORY\)' "$GATES" && ok "fail-fast accepts ADVISORY" || no "fail-fast missing ADVISORY"
grep -qE '0\|SKIP\|PASS_WITH_PRE_EXISTING\|not_run\|ADVISORY\)' "$GATES" && ok "ALL_PASS accepts ADVISORY" || no "ALL_PASS missing ADVISORY"
grep -qE '^\s*ADVISORY\) echo "\| ADVISORY \|' "$GATES" && ok "skeleton renders ADVISORY row" || no "skeleton ADVISORY row missing"

# ── (2) BEHAVIORAL: mirror the ALL_PASS loop + fail-fast (kept in sync by contract above) ──
all_pass(){  # args: list of RCs
  local ALL_PASS=1 _rc
  for _rc in "$@"; do
    case "$_rc" in 0|SKIP|PASS_WITH_PRE_EXISTING|not_run|ADVISORY) ;; *) ALL_PASS=0; break ;; esac
  done
  echo "$ALL_PASS"
}
failfast(){  # args: TSC LINT BUILD ; echoes 1 if a prior phase failed
  local _rc
  for _rc in "$@"; do
    _rc=$(printf '%s' "$_rc" | tr -d '[:space:]')
    case "$_rc" in 0|SKIP|""|INCONCLUSIVE|ADVISORY) : ;; *) echo 1; return ;; esac
  done
  echo 0
}

[ "$(all_pass 0 ADVISORY 0 0 0 SKIP SKIP)" = "1" ] && ok "lint ADVISORY → Overall Status PASS" || no "ADVISORY wrongly failed ALL_PASS"
[ "$(all_pass 0 ADVISORY 0 1 0 SKIP SKIP)" = "0" ] && ok "real PEST fail still → FAIL (ADVISORY doesn't mask)" || no "real failure not caught"
[ "$(all_pass 1 ADVISORY 0 0 0 SKIP SKIP)" = "0" ] && ok "real TSC fail still → FAIL" || no "TSC failure not caught"
[ "$(failfast 0 ADVISORY 0)" = "0" ] && ok "lint ADVISORY → no fail-fast (tests still run)" || no "ADVISORY wrongly triggered fail-fast"
[ "$(failfast 0 ADVISORY 1)" = "1" ] && ok "BUILD fail → fail-fast (still works)" || no "build fail-fast broken"
[ "$(failfast 1 ADVISORY 0)" = "1" ] && ok "TSC fail → fail-fast (still works)" || no "tsc fail-fast broken"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
