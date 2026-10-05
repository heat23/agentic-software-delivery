#!/usr/bin/env bash
# v-pest-extraction-e1-test.sh — E1 (forensic 2026-06-15): when pest RC!=0 but the failing
# FILE paths can't be extracted (Pest FAIL lines carry the test CLASS, not a path), v-run-gates.sh used
# to emit a bare "EXTRACTION INCONCLUSIVE — manual review required" row, and the orchestrator
# re-dispatched the WHOLE pre-flight blind (one session double-ran pre-flight). E1 enriches that row with
# the Pest summary failed-count + failing class names so it can be adjudicated from the existing log —
# WITHOUT changing any verdict toward pass (a fatal in changed code must still stay INCONCLUSIVE).
#
# Two checks: (1) CONTRACT — the enrichment logic is present in v-run-gates.sh (drift guard);
# (2) FUNCTIONAL — the count/name extraction the script uses produces the right values on synthetic
# pest logs (rc!=0 + failed=0 → non-test-failure row; rc!=0 + failed=N + FAIL class lines → names).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GATES="$HERE/v-run-gates.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

echo "== E1 pest extraction-inconclusive enrichment =="
[ -f "$GATES" ] || { echo "  NO  v-run-gates.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

# ── (1) CONTRACT: the enrichment exists in the script (catches drift / accidental revert) ──
grep -qF 'PEST_FAILED_COUNT=$(printf' "$GATES" && ok "contract: PEST_FAILED_COUNT summary parse present" || no "PEST_FAILED_COUNT parse missing"
grep -qF 'PEST_FAIL_NAMES=$(printf' "$GATES" && ok "contract: PEST_FAIL_NAMES class-name parse present" || no "PEST_FAIL_NAMES parse missing"
grep -q 'summary shows 0 FAILED tests' "$GATES" && ok "contract: failed=0 non-test-failure report row present" || no "failed=0 report row missing"
grep -q 'Target these directly' "$GATES" && ok "contract: failed>0 named-class report row present" || no "failed>0 report row missing"
# Safety: the enrichment must NOT auto-pass — no reclassification of EXTRACTION_FAILED_PEST to PASS.
grep -q 'EXTRACTION_FAILED_PEST=1' "$GATES" && ok "safety: extraction-failed still flagged INCONCLUSIVE (no auto-pass)" || no "EXTRACTION_FAILED_PEST flag removed (unsafe)"

# ── (2) FUNCTIONAL: the exact extraction the script runs, on synthetic Pest logs ──
# Mirrors v-run-gates.sh: failed-count from the `Tests:` summary, class names from FAIL lines.
extract_count(){ printf '%s\n' "$1" | grep -oE 'Tests:[^\n]*' | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+' | sort -rn | head -1; }
extract_names(){ printf '%s\n' "$1" | grep -oE '^[[:space:]]*(FAIL|FAILED|⨯)[[:space:]]+[A-Za-z0-9_\\]+' 2>/dev/null | sed -E 's/^[[:space:]]*(FAIL|FAILED|⨯)[[:space:]]+//' | sort -u | paste -sd',' -; }
extract_paths(){ printf '%s\n' "$1" | grep -oE '(tests|app|src|database|config|routes|bootstrap)/[^[:space:]]+\.php' | grep -vE '(^|/)(vendor|node_modules|Illuminate|Symfony)/' | sort -u; }

# Case A: real failures, class names only (no file path in output) — the observed shape.
LOG_A='   FAIL  Tests\Feature\ReportControllerTest
  ⨯ it surfaces the effective sort default
   FAIL  Tests\Unit\Services\MetricsServiceTest

  Tests:    2 failed, 53 passed (238 assertions)'
[ "$(extract_count "$LOG_A")" = "2" ] && ok "A: failed-count parsed = 2" || no "A: failed-count wrong ('$(extract_count "$LOG_A")')"
[ -z "$(extract_paths "$LOG_A")" ] && ok "A: 0 file paths (the trigger condition)" || no "A: unexpectedly found paths"
echo "$(extract_names "$LOG_A")" | grep -q 'ReportControllerTest' && ok "A: failing class names extracted" || no "A: class names not extracted"

# Case B: non-test-failure RC (deprecation/risky) — summary shows 0 failed.
LOG_B='  Tests:    0 failed, 41 passed, 3 risky (120 assertions)
  WARN  3 tests are risky'
[ "$(extract_count "$LOG_B")" = "0" ] && ok "B: failed-count = 0 (non-test-failure → don't blind re-dispatch)" || no "B: failed-count wrong ('$(extract_count "$LOG_B")')"

# Case C: a fatal in a changed file DOES yield a path (must NOT be the count==0 non-test path).
LOG_C='PHP Fatal error: Uncaught TypeError in app/Services/ScoreCalculator.php on line 127
  Tests:    1 failed, 37 passed'
[ "$(extract_count "$LOG_C")" = "1" ] && ok "C: fatal-with-path still counts as 1 failed (stays INCONCLUSIVE, not non-test)" || no "C: failed-count wrong ('$(extract_count "$LOG_C")')"
echo "$(extract_paths "$LOG_C")" | grep -q 'ScoreCalculator.php' && ok "C: fatal file path extracted (whole-log fallback catches it)" || no "C: fatal path missed"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
