#!/usr/bin/env bash
# v-run-gates-phpstan-test.sh — regression harness for the PHPStan gate (W-PHPSTAN1, forensic
# 2026-07-14).
#
# WHY: the gate did not exist. v-pre-flight-runner.md's Contract table listed "PHPStan" among the gate
# commands the runner owns, and a project's CLAUDE.md pre-flight checklist includes
# `vendor/bin/phpstan analyse --memory-limit=1G` — but v-run-gates.sh never ran it and emitted no
# PHPSTAN_RC. One session shipped a "full" PASS with PHP static analysis silently uncovered, and
# the PRE_FLIGHT_REPORT had no row in which a reader could even notice the gap.
#
# Pins: (1) the gate runs in Phase 1, (2) its RC blocks ALL_PASS, (3) RC + duration reach the durable
# gate-summary, (4) a row is emitted even when SKIP (an absent row is how the gap hid), (5) it SKIPs
# cleanly on non-PHP projects rather than failing them.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/v-run-gates.sh"
[ -f "$SCRIPT" ] || { echo "NO v-run-gates.sh missing"; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }

bash -n "$SCRIPT" 2>/dev/null && ok "v-run-gates.sh parses" || no "v-run-gates.sh syntax error"

# 1. Gate is wired into Phase 1 (before the Phase 1 wait barrier).
_l_phase1=$(grep -nE '^# ── 4\. Phase 1:' "$SCRIPT" | head -1 | cut -d: -f1)
_l_stan=$(grep -n '^PHPSTAN_PID=""' "$SCRIPT" | head -1 | cut -d: -f1)
_l_wait=$(grep -n '^# 4d. Wait for Phase 1' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$_l_phase1" ] && [ -n "$_l_stan" ] && [ -n "$_l_wait" ] \
   && [ "$_l_stan" -gt "$_l_phase1" ] && [ "$_l_stan" -lt "$_l_wait" ]; then
  ok "PHPStan launches inside Phase 1 (parallel with TSC), before the wait barrier"
else
  no "PHPStan not wired into Phase 1" "phase1=$_l_phase1 stan=$_l_stan wait=$_l_wait"
fi

# 2. Its RC is awaited (otherwise PHPSTAN_RC stays "SKIP" and the gate is decorative).
grep -q 'wait "$PHPSTAN_PID"; PHPSTAN_RC=$?' "$SCRIPT" \
  && ok "PHPSTAN_RC captured from the background job" \
  || no "PHPSTAN_RC never awaited — gate would always report SKIP"

# 3. BLOCKING: PHPSTAN_RC must be in the ALL_PASS loop. This is the one that matters — a reported-but-
#    non-blocking gate is worse than none (it looks covered).
_allpass_line=$(grep -n 'for _rc in "$TSC_RC"' "$SCRIPT" | head -1 | cut -d: -f2-)
case "$_allpass_line" in
  *'$PHPSTAN_RC'*) ok "PHPSTAN_RC is in the ALL_PASS blocking set" ;;
  *) no "PHPSTAN_RC absent from ALL_PASS — a PHPStan failure would still report a clean PASS" "$_allpass_line" ;;
esac

# 4. Durable machine record: the Stop hook and the orchestrator read gate-summary, not prose.
grep -q 'echo "PHPSTAN_RC=${PHPSTAN_RC}"' "$SCRIPT" \
  && ok "PHPSTAN_RC emitted to gate-summary" \
  || no "PHPSTAN_RC missing from gate-summary (orchestrator cannot transcribe it)"
grep -q 'echo "PHPSTAN_DURATION_SEC=${PHPSTAN_DURATION_SEC}"' "$SCRIPT" \
  && ok "PHPSTAN_DURATION_SEC emitted to gate-summary" \
  || no "PHPSTAN_DURATION_SEC missing from gate-summary"

# 5. Report row is emitted unconditionally (SKIP must be legible, not absent).
grep -q '_row "$PHPSTAN_RC" "Static analysis (PHPStan)"' "$SCRIPT" \
  && ok "PHPStan row emitted to the report skeleton (SKIP stays visible)" \
  || no "no PHPStan row in the report skeleton — a skipped gate would be invisible again"

# 6. The emitted row must satisfy the Stop hook's gate-table regex (status in the FIRST cell).
#    check-review-artifact.sh counts: ^\s*\|\s*(PASS|FAIL|SKIP|...)\s*\|.*(tests?|build|lint|typecheck|typescript|security)
#    "Static analysis (PHPStan)" matches NONE of those keywords — so this row is intentionally NOT
#    counted by that regex. Pin the fact so nobody "fixes" the row name and silently changes the count.
_row_rendered='| SKIP | Static analysis (PHPStan) | 0s |'
if printf '%s\n' "$_row_rendered" | grep -qiE '^[[:space:]]*\|[[:space:]]*(PASS|FAIL|SKIP)[[:space:]]*\|.*(tests?|build|lint|typecheck|typescript|security)'; then
  no "PHPStan row now matches the hook's gate-count regex — row count semantics changed unexpectedly"
else
  ok "PHPStan row is status-first and does not perturb the hook's gate-count regex"
fi

# 7. Non-PHP projects: detection requires BOTH a phpstan binary and a config, else SKIP (never FAIL).
_detect=$(sed -n '/^_PHPSTAN_BIN=""/,/^fi$/p' "$SCRIPT")
printf '%s\n' "$_detect" | grep -q 'phpstan.neon' \
  && ok "detection requires a phpstan config (neon/neon.dist)" \
  || no "detection does not check for a phpstan config"
printf '%s\n' "$_detect" | grep -q 'PHPStan skipped' \
  && ok "absent phpstan → SKIP with an explicit log line (non-PHP projects unaffected)" \
  || no "no explicit SKIP path for projects without phpstan"

# 8. SKIP must be an accepted (non-blocking) ALL_PASS value, or PHP-less projects would always fail.
grep -q '0|SKIP|PASS_WITH_PRE_EXISTING|not_run|ADVISORY' "$SCRIPT" \
  && ok "SKIP is an accepted ALL_PASS value (PHP-less projects still pass)" \
  || no "SKIP not accepted by ALL_PASS — would break non-PHP projects"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
