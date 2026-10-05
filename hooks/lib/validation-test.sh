#!/usr/bin/env bash
# validation-test.sh — E1 (efficiency, 2026-07-05) regression: validators must emit a COMPLETE
# manifest of every unmet requirement on rejection, not just the FIRST one found. Before this fix,
# validate_verify_done_w53_contract / validate_pre_flight_w53_contract / validate_qa_report_structure /
# validate_ux_critique_structure / validate_success_criteria_structure /
# validate_workflow_verification_structure / validate_impact_map_semantics each `return 1` on the
# first missing field, forcing the caller to fix-and-retry once per requirement (each retry burns a
# full dispatch round-trip). This pins: (a) a file missing N independent fields reports all N in one
# rejection message, (b) the accept/reject DECISION is unchanged (still 0 on a complete artifact,
# still 1 on an incomplete one) — batching must never change the verdict, only the message.
set -u
LIB="${V_VALIDATION_LIB:-$HOME/.claude/hooks/lib/validation.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$LIB" ] || { echo "NO validation.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
# shellcheck source=validation.sh
source "$LIB"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

echo "== validation.sh :: complete unmet-requirement manifests (E1) =="

# ── validate_verify_done_w53_contract: missing BOTH Mode: and Changed: must name BOTH in one msg ──
f="$WORK/verify_done_bad.md"
cat > "$f" <<'EOF'
Some report with neither Mode nor Changed lines.

## Summary
did some things

Overall Verdict: PASS
EOF
out="$(validate_verify_done_w53_contract "$f" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "verify-done: rejects artifact missing Mode:+Changed:" || no "verify-done: should have rejected" "rc=$rc"
echo "$out" | grep -qi "Mode:" && ok "verify-done manifest names missing Mode:" || no "verify-done manifest missing 'Mode:' mention" "$out"
echo "$out" | grep -qi "Changed:" && ok "verify-done manifest ALSO names missing Changed: (not just first miss)" || no "verify-done manifest missing 'Changed:' mention (still first-miss-only?)" "$out"

# ── validate_verify_done_w53_contract: a fully valid artifact still passes (0) ──
f="$WORK/verify_done_good.md"
cat > "$f" <<'EOF'
Mode: full
Changed: 3

## Summary
did some things

Overall Verdict: PASS
EOF
validate_verify_done_w53_contract "$f" >/dev/null 2>&1
[ $? -eq 0 ] && ok "verify-done: valid artifact still accepted (0)" || no "verify-done: valid artifact wrongly rejected"

# ── validate_pre_flight_w53_contract: missing BOTH Mode: and Overall Status: ──
f="$WORK/pre_flight_bad.md"
cat > "$f" <<'EOF'
Neither Mode nor a valid final status line here.
EOF
out="$(validate_pre_flight_w53_contract "$f" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "pre-flight: rejects artifact missing both fields" || no "pre-flight: should have rejected" "rc=$rc"
echo "$out" | grep -qi "Mode:" && ok "pre-flight manifest names missing Mode:" || no "pre-flight manifest missing 'Mode:' mention" "$out"
echo "$out" | grep -qi "Overall Status" && ok "pre-flight manifest ALSO names missing Overall Status:" || no "pre-flight manifest missing 'Overall Status' mention" "$out"

f="$WORK/pre_flight_good.md"
cat > "$f" <<'EOF'
Mode: full

Overall Status: PASS
EOF
validate_pre_flight_w53_contract "$f" >/dev/null 2>&1
[ $? -eq 0 ] && ok "pre-flight: valid artifact still accepted (0)" || no "pre-flight: valid artifact wrongly rejected"

# ── validate_qa_report_structure: missing BOTH Model: and heading ──
f="$WORK/qa_bad.md"
{ printf 'no model header, no qa heading, but padded to clear the size floor.\n'
  for i in $(seq 1 10); do printf 'padding line %s to clear the 100 byte floor.\n' "$i"; done; } > "$f"
out="$(validate_qa_report_structure "$f" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "qa-report: rejects artifact missing both fields" || no "qa-report: should have rejected" "rc=$rc"
echo "$out" | grep -qi "Model:" && ok "qa-report manifest names missing Model:" || no "qa-report manifest missing 'Model:' mention" "$out"
echo "$out" | grep -qi "QA Acceptance" && ok "qa-report manifest ALSO names missing '## QA Acceptance'" || no "qa-report manifest missing heading mention" "$out"

f="$WORK/qa_good.md"
{ printf 'Model: sonnet\n\n## QA Acceptance\n\nverdict: pass\n'
  for i in $(seq 1 10); do printf 'padding line %s.\n' "$i"; done; } > "$f"
out="$(validate_qa_report_structure "$f" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "qa-report: valid artifact still accepted (0)" || no "qa-report: valid artifact wrongly rejected" "rc=$rc out=$out"

# ── validate_ux_critique_structure: missing BOTH Model: and heading ──
f="$WORK/ux_bad.md"
{ printf 'no model, no ux heading here, just prose padded out.\n'
  for i in $(seq 1 10); do printf 'padding line %s.\n' "$i"; done; } > "$f"
out="$(validate_ux_critique_structure "$f" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "ux-critique: rejects artifact missing both fields" || no "ux-critique: should have rejected" "rc=$rc"
echo "$out" | grep -qi "Model:" && ok "ux-critique manifest names missing Model:" || no "ux-critique manifest missing 'Model:' mention" "$out"
echo "$out" | grep -qi "UX Critique" && ok "ux-critique manifest ALSO names missing heading" || no "ux-critique manifest missing heading mention" "$out"

# ── validate_success_criteria_structure: missing BOTH criteria and workflow_states ──
f="$WORK/sc_bad.md"
{ printf 'neither block present, just padded prose text here.\n'
  for i in $(seq 1 10); do printf 'padding line %s.\n' "$i"; done; } > "$f"
out="$(validate_success_criteria_structure "$f" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "success-criteria: rejects artifact missing both blocks" || no "success-criteria: should have rejected" "rc=$rc"
echo "$out" | grep -qi "criteria" && ok "success-criteria manifest names missing 'criteria'" || no "success-criteria manifest missing 'criteria' mention" "$out"
echo "$out" | grep -qi "workflow_states" && ok "success-criteria manifest ALSO names missing 'workflow_states'" || no "success-criteria manifest missing 'workflow_states' mention" "$out"

# ── validate_workflow_verification_structure: missing Model:, heading, AND status ──
f="$WORK/wf_bad.md"
{ printf 'no model, no heading, no status line, just padded prose.\n'
  for i in $(seq 1 10); do printf 'padding line %s.\n' "$i"; done; } > "$f"
out="$(validate_workflow_verification_structure "$f" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "workflow-verification: rejects artifact missing all three fields" || no "workflow-verification: should have rejected" "rc=$rc"
echo "$out" | grep -qi "Model:" && ok "workflow-verification manifest names missing Model:" || no "workflow-verification manifest missing 'Model:' mention" "$out"
echo "$out" | grep -qi "Workflow Verification" && ok "workflow-verification manifest ALSO names missing heading" || no "workflow-verification manifest missing heading mention" "$out"
echo "$out" | grep -qi "status:" && ok "workflow-verification manifest ALSO names missing status line" || no "workflow-verification manifest missing status mention" "$out"

# ── validate_impact_map_semantics: missing subsystems + 2 of 3 checklist keys named individually ──
f="$WORK/im_bad.md"
{ printf 'reporting_metrics: no\nsome other prose padded out to clear the 200 byte floor for this check.\n'
  for i in $(seq 1 10); do printf 'padding line %s to make this file long enough.\n' "$i"; done; } > "$f"
out="$(validate_impact_map_semantics "$f" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "impact-map: rejects artifact missing subsystems/cache_invalidation/db_integrity" || no "impact-map: should have rejected" "rc=$rc"
echo "$out" | grep -qi "subsystems" && ok "impact-map manifest names missing 'subsystems'" || no "impact-map manifest missing 'subsystems' mention" "$out"
echo "$out" | grep -qi "cache_invalidation" && ok "impact-map manifest ALSO names missing 'cache_invalidation'" || no "impact-map manifest missing 'cache_invalidation' mention" "$out"
echo "$out" | grep -qi "db_integrity" && ok "impact-map manifest ALSO names missing 'db_integrity'" || no "impact-map manifest missing 'db_integrity' mention" "$out"
# reporting_metrics WAS present — must NOT be listed as missing (no false positive in the manifest).
echo "$out" | grep -qi "reporting_metrics" && no "impact-map manifest falsely lists PRESENT 'reporting_metrics' as missing" "$out" || ok "impact-map manifest correctly omits the present 'reporting_metrics' key"

echo
echo "TOTAL: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
