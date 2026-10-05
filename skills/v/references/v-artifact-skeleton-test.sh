#!/usr/bin/env bash
# v-artifact-skeleton-test.sh — B: deterministic IMPACT_MAP/QA skeletons round-trip through the
# REAL validators (hooks/lib/validation.sh). Proves the helper's output is accepted by the exact
# functions the Stop hook + v-completion-selfcheck.sh call, and that the structural anchors the
# helper emits are load-bearing (corrupting them makes the validator reject).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/v-artifact-skeleton.sh"
VALIDATION="$(cd "$HERE/../../.." && pwd)/hooks/lib/validation.sh"
[ -f "$VALIDATION" ] || VALIDATION="$HOME/.claude/hooks/lib/validation.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

# shellcheck source=/dev/null
if ! source "$VALIDATION" 2>/dev/null; then echo "FATAL: cannot source $VALIDATION" >&2; exit 1; fi
type validate_impact_map_semantics >/dev/null 2>&1 || { echo "FATAL: validate_impact_map_semantics undefined" >&2; exit 1; }
type validate_qa_report_structure  >/dev/null 2>&1 || { echo "FATAL: validate_qa_report_structure undefined" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SID="deadbeef-0000-4000-8000-000000000000"

echo "== v-artifact-skeleton :: round-trip through real validators =="

# --- IMPACT_MAP ---
bash "$HELPER" --type impact_map --sid "$SID" > "$WORK/im.md" 2>/dev/null
if validate_impact_map_semantics "$WORK/im.md" >/dev/null 2>&1; then
  ok "IMPACT_MAP skeleton passes validate_impact_map_semantics"
else
  no "IMPACT_MAP skeleton REJECTED: $(validate_impact_map_semantics "$WORK/im.md" 2>&1)"
fi
# load-bearing: drop a mandatory subsystem key -> must reject
grep -v 'reporting_metrics' "$WORK/im.md" > "$WORK/im_broken.md"
validate_impact_map_semantics "$WORK/im_broken.md" >/dev/null 2>&1 \
  && no "validator accepted IMPACT_MAP missing reporting_metrics (anchor not load-bearing)" \
  || ok "dropping reporting_metrics is rejected (anchor load-bearing)"

# --- QA_REPORT ---
bash "$HELPER" --type qa_report --sid "$SID" > "$WORK/qa.md" 2>/dev/null
v=$(validate_qa_report_structure "$WORK/qa.md" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "QA_REPORT skeleton passes validate_qa_report_structure" \
               || no "QA_REPORT skeleton REJECTED: $(validate_qa_report_structure "$WORK/qa.md" 2>&1)"
[ "$v" = "fail" ] && ok "QA verdict anchor present + fail-closed default ('$v')" \
                  || no "QA verdict extracted as '$v' (expected fail-closed 'fail')"
# load-bearing: corrupt the '## QA Acceptance' heading -> must reject
sed 's/## QA Acceptance/## QA Notes/' "$WORK/qa.md" > "$WORK/qa_broken.md"
validate_qa_report_structure "$WORK/qa_broken.md" >/dev/null 2>&1 \
  && no "validator accepted QA_REPORT without '## QA Acceptance' (anchor not load-bearing)" \
  || ok "corrupting '## QA Acceptance' heading is rejected (anchor load-bearing)"
# load-bearing: bold the verdict (the classic '**verdict: pass**' bounce) -> verdict no longer col-0
bash "$HELPER" --type qa_report --sid "$SID" | sed 's/^verdict: fail/**verdict: fail**/' > "$WORK/qa_bold.md"
vb=$(validate_qa_report_structure "$WORK/qa_bold.md" 2>/dev/null)
[ -z "$vb" ] && ok "bolded '**verdict:**' yields empty verdict (helper's col-0 anchor is what matters)" \
             || no "bolded verdict still parsed as '$vb' (unexpected)"

# --- UX_CRITIQUE (forensic 2026-06-19: '## UX Findings' case trap death-march) ---
type validate_ux_critique_structure >/dev/null 2>&1 || { echo "FATAL: validate_ux_critique_structure undefined" >&2; exit 1; }
bash "$HELPER" --type ux_critique --sid "$SID" > "$WORK/ux.md" 2>/dev/null
validate_ux_critique_structure "$WORK/ux.md" >/dev/null 2>&1 \
  && ok "UX_CRITIQUE skeleton passes validate_ux_critique_structure" \
  || no "UX_CRITIQUE skeleton REJECTED: $(validate_ux_critique_structure "$WORK/ux.md" 2>&1)"
# strip BOTH accepted headings (the skeleton emits '## UX Critique' AND '## Heuristic coverage')
sed -e 's/## UX Critique/## Notes/' -e 's/## Heuristic coverage/## Coverage/' "$WORK/ux.md" > "$WORK/ux_broken.md"
validate_ux_critique_structure "$WORK/ux_broken.md" >/dev/null 2>&1 \
  && no "validator accepted UX_CRITIQUE with no valid H2 (anchor not load-bearing)" \
  || ok "corrupting BOTH accepted UX headings is rejected (anchor load-bearing)"

# --- WORKFLOW_VERIFICATION ---
type validate_workflow_verification_structure >/dev/null 2>&1 || { echo "FATAL: validate_workflow_verification_structure undefined" >&2; exit 1; }
bash "$HELPER" --type workflow_verification --sid "$SID" > "$WORK/wf.md" 2>/dev/null
validate_workflow_verification_structure "$WORK/wf.md" >/dev/null 2>&1 \
  && ok "WORKFLOW_VERIFICATION skeleton passes its validator" \
  || no "WORKFLOW_VERIFICATION skeleton REJECTED: $(validate_workflow_verification_structure "$WORK/wf.md" 2>&1)"
wfs=$(validate_workflow_verification_structure "$WORK/wf.md" 2>/dev/null)
[ "$wfs" = "degraded" ] && ok "WF status anchor present + safe 'degraded' default ('$wfs')" \
                        || no "WF status extracted as '$wfs' (expected non-blocking 'degraded')"

# --- VERIFY_DONE_REPORT ---
type validate_verify_done_w53_contract >/dev/null 2>&1 || { echo "FATAL: validate_verify_done_w53_contract undefined" >&2; exit 1; }
bash "$HELPER" --type verify_done_report --sid "$SID" > "$WORK/vd.md" 2>/dev/null
validate_verify_done_w53_contract "$WORK/vd.md" >/dev/null 2>&1 \
  && ok "VERIFY_DONE_REPORT skeleton passes validate_verify_done_w53_contract" \
  || no "VERIFY_DONE_REPORT skeleton REJECTED: $(validate_verify_done_w53_contract "$WORK/vd.md" 2>&1)"
# load-bearing: the final-line 'Overall Verdict:' anchor
grep -v '^Overall Verdict:' "$WORK/vd.md" > "$WORK/vd_broken.md"
validate_verify_done_w53_contract "$WORK/vd_broken.md" >/dev/null 2>&1 \
  && no "validator accepted VERIFY_DONE without 'Overall Verdict:' final line (anchor not load-bearing)" \
  || ok "dropping the 'Overall Verdict:' final line is rejected (anchor load-bearing)"

# NOTE (W-PFSKEL investigation, 2026-08-03 — deliberately NO pre_flight_report type here).
# A pre_flight_report seed was prototyped for this helper and REVERTED: v-run-gates.sh already
# emits `$V_TMP_DIR/pre-flight-skeleton-<sid>.md` with the canonical Gates table and the final
# `Overall Status: PASS|FAIL` line (v-run-gates.sh:1477-1568), and dispatch-v-pre-flight.md:181
# declares THAT file "IS the report body". A second producer of the same artifact shape is the
# producer-drift failure class this ecosystem keeps re-learning ("test producer→detector→tag").
# The observed format bounce was NOT a missing-seed bug: the parent hand-wrote PRE_FLIGHT_REPORT
# with the Write tool (the string `pre-flight-skeleton` appears exactly ONCE in that whole
# transcript) and then hand-edited it twice — which dispatch-v-pre-flight.md:375 already forbids
# as provenance-sha-bound. Root cause = skeleton BYPASS, not skeleton ABSENCE. If you are here to
# "add a pre-flight skeleton", read v-run-gates.sh:1477 first.

# --- helper hygiene ---
bash "$HELPER" --type bogus --sid "$SID" >/dev/null 2>&1 && no "bad --type should exit non-zero" || ok "bad --type rejected"
bash "$HELPER" --type impact_map >/dev/null 2>&1 && no "missing --sid should exit non-zero" || ok "missing --sid rejected"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "RESULT: PASS"
