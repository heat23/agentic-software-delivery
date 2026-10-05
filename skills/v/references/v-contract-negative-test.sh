#!/usr/bin/env bash
# v-contract-negative-test.sh — Per-field NEGATIVE fixture tests for every validate_* contract.
#
# WHY (audit 2026-06-18, survivors S-A..S-F):
# v-contract-audit-test.sh only tested VALID fixtures through the contract validators.
# A mutation that removes a single per-field check (e.g., the Overall Verdict check in
# validate_verify_done_w53_contract, or the Mode: check in validate_pre_flight_w53_contract)
# was INVISIBLE to the suite — the negative fixture path was never tested.
#
# This harness:
#  1. Sources validation.sh via ${V_VALIDATION_LIB:-...} so it HONORS the mutation-gate
#     injection vector (running this with V_VALIDATION_LIB=/path/to/mutant.sh proves
#     the mutant is caught — same injection contract as the e2e-lifecycle and parity harnesses).
#  2. Calls each validate_* with a CRAFTED per-field negative input.
#  3. Asserts the validator REJECTS it (non-zero + reason contains the field name).
#  4. Also calls each validator with the GOLDEN PATH input and asserts acceptance.
#
# Wired into mutation-gate.sh as guards S-A through S-F.
# Wired into the default vitest suite via v-contract-negative-harness.test.ts.
#
# Exit 0 iff all guards pass; exit 1 on any failure.
set -u
VALIDATION="${V_VALIDATION_LIB:-$HOME/.claude/hooks/lib/validation.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# Load validators
if [ ! -f "$VALIDATION" ]; then
  echo "FATAL: validation.sh not found at $VALIDATION" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$VALIDATION" 2>/dev/null

# Helper: call validator in a subshell; return 0 if rejects, 1 if accepts
# Usage: rejects <reason_keyword> <function_name> [args...]
# The harness runs the function, expects non-zero, and checks stderr contains keyword.
rejects() {
  local kw="$1" fn="$2"; shift 2
  local out rc
  out="$("$fn" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "$kw"; then
    return 0  # correctly rejected, stderr mentions the keyword
  fi
  return 1  # either accepted (rc=0) or rejected without mentioning the keyword
}

# Helper: call validator and expect acceptance (return 0)
accepts() {
  local fn="$1"; shift
  "$fn" "$@" >/dev/null 2>&1
}

# ── Padding: enough text to exceed the 100-byte minimum for valid artifacts ──
PAD=$(printf '%0200d' 0 | tr '0' 'x')

echo "== S-A: VALIDATION_MIN_SIZE floor — validate_artifact rejects 1-byte stub =="
# Negative: 1-byte stub (does not even reach the content-marker check)
printf 'x' > "$TMP/tiny.md"
rejects "small\|too small" validate_artifact "$TMP/tiny.md" "AGENT_REVIEW" \
  && ok "S-A negative: 1-byte stub rejected by validate_artifact (AGENT_REVIEW)" \
  || bad "S-A-neg AGENT_REVIEW" "validate_artifact accepted a 1-byte AGENT_REVIEW stub — VALIDATION_MIN_SIZE floor neutered or removed"

printf 'x' > "$TMP/tiny_pf.md"
rejects "small\|too small" validate_artifact "$TMP/tiny_pf.md" "PRE_FLIGHT_REPORT" \
  && ok "S-A negative: 1-byte stub rejected by validate_artifact (PRE_FLIGHT_REPORT)" \
  || bad "S-A-neg PRE_FLIGHT" "validate_artifact accepted a 1-byte PRE_FLIGHT stub"

printf 'x' > "$TMP/tiny_vd.md"
rejects "small\|too small" validate_artifact "$TMP/tiny_vd.md" "VERIFY_DONE_REPORT" \
  && ok "S-A negative: 1-byte stub rejected by validate_artifact (VERIFY_DONE_REPORT)" \
  || bad "S-A-neg VERIFY_DONE" "validate_artifact accepted a 1-byte VERIFY_DONE stub"

# Positive: a minimal but valid artifact (>100 bytes, has Status: line)
printf 'Model: haiku\n## Test Results\nStatus: pass\n%s\n' "$PAD" > "$TMP/valid_min.md"
accepts validate_artifact "$TMP/valid_min.md" "AGENT_REVIEW" \
  && ok "S-A positive: >100-byte valid artifact accepted by validate_artifact" \
  || bad "S-A-pos" "validate_artifact rejected a valid artifact — over-strict regression"

echo
echo "== S-B: validate_verify_done_w53_contract — Overall Verdict check =="
# Negative: file without any Overall Verdict line (has Mode, Changed, Summary, but no verdict)
{
  printf 'Mode: full\nChanged: 3\n%s\n## Summary\nConvention checks pass.\n' "$PAD"
} > "$TMP/vd_nooverall.md"
rejects "Overall Verdict\|final.*line\|overall.*verdict" validate_verify_done_w53_contract "$TMP/vd_nooverall.md" \
  && ok "S-B negative: VERIFY_DONE without Overall Verdict line rejected" \
  || bad "S-B-neg" "validate_verify_done_w53_contract accepted a VERIFY_DONE missing Overall Verdict — check removed or bypassed"

# Negative: file where Overall Verdict is in the body but NOT the final line
{
  printf 'Mode: full\nChanged: 3\n## Summary\nConvention checks pass.\nOverall Verdict: PASS\n%s\n' "$PAD"
} > "$TMP/vd_verdictnotlast.md"
# This should FAIL because Overall Verdict must be the LAST non-blank line
rejects "final.*line\|Overall Verdict" validate_verify_done_w53_contract "$TMP/vd_verdictnotlast.md" \
  && ok "S-B negative: VERIFY_DONE with Overall Verdict not as final line rejected" \
  || bad "S-B-neg-pos" "validate_verify_done_w53_contract accepted Overall Verdict in middle of body"

# Positive: minimal valid VERIFY_DONE (Mode, Changed, ## Summary, Overall Verdict as last line)
{
  printf 'Mode: full\nChanged: 3\n## Summary\nConvention checks pass.\n%s\nOverall Verdict: PASS\n' "$PAD"
} > "$TMP/vd_ok.md"
accepts validate_verify_done_w53_contract "$TMP/vd_ok.md" \
  && ok "S-B positive: valid VERIFY_DONE accepted" \
  || bad "S-B-pos" "validate_verify_done_w53_contract rejected a valid VERIFY_DONE"

echo
echo "== S-C: validate_qa_report_structure — Model header check =="
# Negative: QA report without Model: header
{
  printf '## QA Acceptance\nverdict: pass\n%s\n' "$PAD"
} > "$TMP/qa_nomodel.md"
rejects "Model:\|model.*header\|missing.*model" validate_qa_report_structure "$TMP/qa_nomodel.md" \
  && ok "S-C negative: QA report without Model: header rejected" \
  || bad "S-C-neg" "validate_qa_report_structure accepted a QA report missing Model: header — check removed"

# Negative: Model: on line 6 (must be in first 5 lines)
{
  printf 'line1\nline2\nline3\nline4\nline5\nModel: sonnet\n## QA Acceptance\nverdict: pass\n%s\n' "$PAD"
} > "$TMP/qa_modellate.md"
rejects "Model:\|model.*header\|missing.*model" validate_qa_report_structure "$TMP/qa_modellate.md" \
  && ok "S-C negative: QA report with Model: on line 6 rejected" \
  || bad "S-C-neg-late" "validate_qa_report_structure accepted Model: on line 6 (must be in first 5)"

# Positive: valid QA report
{
  printf 'Model: sonnet\n## QA Acceptance\nverdict: pass\n%s\n' "$PAD"
} > "$TMP/qa_ok.md"
v=$(validate_qa_report_structure "$TMP/qa_ok.md" 2>/dev/null)
[ "$v" = "pass" ] \
  && ok "S-C positive: valid QA report accepted, verdict=pass" \
  || bad "S-C-pos" "validate_qa_report_structure rejected a valid QA report (verdict=$v)"

echo
echo "== S-D: validate_impact_map_semantics — subsystems: check =="
# Negative: impact map without subsystems: anchor
{
  printf '## Impact\nreporting_metrics: no\ncache_invalidation: no\ndb_integrity: no\n%s\n' "$PAD"
} > "$TMP/impact_nosub.md"
rejects "subsystems\|subsystem" validate_impact_map_semantics "$TMP/impact_nosub.md" \
  && ok "S-D negative: IMPACT_MAP without subsystems: anchor rejected" \
  || bad "S-D-neg" "validate_impact_map_semantics accepted an IMPACT_MAP missing subsystems: — check removed"

# Negative: subsystems: present but missing required fields (db_integrity absent)
{
  printf 'subsystems:\n  reporting_metrics: { impacted: no }\n  cache_invalidation: { impacted: no }\n%s\n' "$PAD"
} > "$TMP/impact_nodb.md"
rejects "db_integrity\|incomplete" validate_impact_map_semantics "$TMP/impact_nodb.md" \
  && ok "S-D negative: IMPACT_MAP missing db_integrity rejected" \
  || bad "S-D-neg-fields" "validate_impact_map_semantics accepted IMPACT_MAP without db_integrity"

# Positive: valid IMPACT_MAP with all required fields
{
  printf 'subsystems:\n  reporting_metrics: { impacted: no }\n  cache_invalidation: { impacted: no }\n  db_integrity: { impacted: no }\n%s\n' "$PAD"
} > "$TMP/impact_ok.md"
accepts validate_impact_map_semantics "$TMP/impact_ok.md" \
  && ok "S-D positive: valid IMPACT_MAP accepted" \
  || bad "S-D-pos" "validate_impact_map_semantics rejected a valid IMPACT_MAP"

echo
echo "== S-E: validate_pre_flight_w53_contract — Mode: check =="
# Negative: PRE_FLIGHT without Mode: line
{
  printf '## Gates\n| PASS | Lint | 1s |\n%s\nOverall Status: PASS\n' "$PAD"
} > "$TMP/pf_nomode.md"
rejects "Mode:\|missing.*mode\|mode.*missing" validate_pre_flight_w53_contract "$TMP/pf_nomode.md" \
  && ok "S-E negative: PRE_FLIGHT without Mode: line rejected" \
  || bad "S-E-neg" "validate_pre_flight_w53_contract accepted a PRE_FLIGHT missing Mode: — check removed"

# Negative: PRE_FLIGHT without Overall Status: line
{
  printf 'Mode: full\n## Gates\n| PASS | Lint | 1s |\n%s\n' "$PAD"
} > "$TMP/pf_nostatus.md"
rejects "Overall Status\|final.*line\|status.*missing" validate_pre_flight_w53_contract "$TMP/pf_nostatus.md" \
  && ok "S-E negative: PRE_FLIGHT without Overall Status: line rejected" \
  || bad "S-E-neg-status" "validate_pre_flight_w53_contract accepted PRE_FLIGHT missing Overall Status:"

# Positive: valid PRE_FLIGHT
{
  printf 'Model: haiku\nMode: full\n## Gates\n| PASS | Lint | 1s |\n%s\nOverall Status: PASS\n' "$PAD"
} > "$TMP/pf_ok.md"
accepts validate_pre_flight_w53_contract "$TMP/pf_ok.md" \
  && ok "S-E positive: valid PRE_FLIGHT accepted" \
  || bad "S-E-pos" "validate_pre_flight_w53_contract rejected a valid PRE_FLIGHT"

echo
echo "== S-F: validate_review_semantics — Status: blocked rejected =="
# Negative: AGENT_REVIEW with Status: blocked (must be rejected)
cat > "$TMP/review_blocked.md" << 'REVIEW_EOF'
Model: haiku

## Agent Review — 11111111-2222-3333-4444-555555555555

- Status: blocked
- Agents dispatched: codex-adversarial-reviewer
- Codex adversarial reviewer: ran — 0 candidates
- Hostile adversarial focus: no
- Dispatch mode: foreground
- Review evidence: codex_candidates: 0 — No issues found
- Remediation: none required

## Findings

No issues found
REVIEW_EOF
rejects "blocked\|non-completed\|unexpected.*status" validate_review_semantics "$TMP/review_blocked.md" 0 \
  && ok "S-F negative: AGENT_REVIEW with Status: blocked rejected" \
  || bad "S-F-neg" "validate_review_semantics accepted Status: blocked — should reject non-completed status"

# Negative: AGENT_REVIEW with Status: failed
cat > "$TMP/review_failed.md" << 'REVIEW_EOF2'
Model: haiku

## Agent Review — 11111111-2222-3333-4444-555555555555

- Status: failed
- Agents dispatched: codex-adversarial-reviewer
- Codex adversarial reviewer: ran — 0 candidates
- Hostile adversarial focus: no
- Dispatch mode: foreground
- Review evidence: codex_candidates: 0 — No issues found
- Remediation: none required

## Findings

No issues found
REVIEW_EOF2
rejects "failed\|non-completed\|unexpected.*status" validate_review_semantics "$TMP/review_failed.md" 0 \
  && ok "S-F negative: AGENT_REVIEW with Status: failed rejected" \
  || bad "S-F-neg-failed" "validate_review_semantics accepted Status: failed — should reject"

# Positive: valid AGENT_REVIEW
cat > "$TMP/review_ok.md" << 'REVIEW_EOF3'
Model: haiku

## Agent Review — 11111111-2222-3333-4444-555555555555

- Status: completed
- Agents dispatched: codex-adversarial-reviewer
- Codex adversarial reviewer: ran — 0 candidates, 0 accepted
- Hostile adversarial focus: no
- Dispatch mode: foreground
- Review evidence: codex_candidates: 0 — No issues found
- Remediation: none required

## Findings

No issues found
REVIEW_EOF3
accepts validate_review_semantics "$TMP/review_ok.md" 0 \
  && ok "S-F positive: valid AGENT_REVIEW accepted" \
  || bad "S-F-pos" "validate_review_semantics rejected a valid AGENT_REVIEW (require_executed=0)"

echo
echo "== S-G: validate_workflow_verification_structure — '## Workflow Verification' heading + status: line =="
# S-G neg1: WORKFLOW_VERIFICATION missing the required '## Workflow Verification' heading is rejected.
printf 'Model: claude-sonnet-4-6\nstatus: pass\n## Results\n%s\n' "$PAD" > "$TMP/wf_noheading.md"
rejects "Workflow Verification\|heading" validate_workflow_verification_structure "$TMP/wf_noheading.md" \
  && ok "S-G negative: WORKFLOW_VERIFICATION without '## Workflow Verification' heading rejected" \
  || bad "S-G-neg-heading" "validate_workflow_verification_structure accepted a WF missing the '## Workflow Verification' heading — check removed/bypassed"
# S-G neg2: WORKFLOW_VERIFICATION with heading but no 'status:' line is rejected.
printf 'Model: claude-sonnet-4-6\n## Workflow Verification\nAll flows exercised.\n%s\n' "$PAD" > "$TMP/wf_nostatus.md"
rejects "status" validate_workflow_verification_structure "$TMP/wf_nostatus.md" \
  && ok "S-G negative: WORKFLOW_VERIFICATION without 'status:' line rejected" \
  || bad "S-G-neg-status" "validate_workflow_verification_structure accepted a WF missing the 'status:' line — check removed/bypassed"
# S-G neg3 (SREV-002): Model: past the NR<=5 window (line 6) is rejected — pins the awk boundary.
printf 'l1\nl2\nl3\nl4\nl5\nModel: claude-sonnet-4-6\n## Workflow Verification\nstatus: pass\n%s\n' "$PAD" > "$TMP/wf_modellate.md"
rejects "Model" validate_workflow_verification_structure "$TMP/wf_modellate.md" \
  && ok "S-G negative: WORKFLOW_VERIFICATION with 'Model:' on line 6 (past NR<=5) rejected" \
  || bad "S-G-neg-modellate" "validate_workflow_verification_structure accepted 'Model:' on line 6 — NR<=5 boundary widened"
# S-G positive (SREV-001): a valid WF is accepted AND echoes status=pass (the value the gate consumes).
printf 'Model: claude-sonnet-4-6\n## Workflow Verification\nstatus: pass\n%s\n' "$PAD" > "$TMP/wf_ok.md"
_wf_v=$(validate_workflow_verification_structure "$TMP/wf_ok.md" 2>/dev/null)
[ "$_wf_v" = "pass" ] \
  && ok "S-G positive: valid WORKFLOW_VERIFICATION accepted, echoed status=pass" \
  || bad "S-G-pos" "validate_workflow_verification_structure returned wrong status [$_wf_v] for a valid fixture (expected 'pass')"

echo
echo "== S-H: validate_ux_critique_structure — 'Model:' header + anti-masquerade '## UX Critique' heading =="
# S-H neg1: UX_CRITIQUE missing the 'Model:' header (first 5 lines) is rejected.
printf '## UX Critique\nContrast and focus states reviewed.\n%s\n' "$PAD" > "$TMP/ux_nomodel.md"
rejects "Model" validate_ux_critique_structure "$TMP/ux_nomodel.md" \
  && ok "S-H negative: UX_CRITIQUE without 'Model:' header rejected" \
  || bad "S-H-neg-model" "validate_ux_critique_structure accepted a UX_CRITIQUE missing the 'Model:' header — check removed/bypassed"
# S-H neg2: bare '## Findings' (an AGENT_REVIEW masquerading as a UX critique) is rejected.
printf 'Model: claude-sonnet-4-6\n## Findings\nSome issues.\n%s\n' "$PAD" > "$TMP/ux_masquerade.md"
rejects "UX Critique\|masquerad" validate_ux_critique_structure "$TMP/ux_masquerade.md" \
  && ok "S-H negative: UX_CRITIQUE with bare '## Findings' (masquerade) rejected" \
  || bad "S-H-neg-masquerade" "validate_ux_critique_structure accepted a bare '## Findings' UX masquerade — anti-masquerade heading check removed"
# S-H neg3 (SREV-002): Model: past the NR<=5 window (line 6) is rejected — pins the awk boundary.
printf 'l1\nl2\nl3\nl4\nl5\nModel: claude-sonnet-4-6\n## UX Critique\nReviewed.\n%s\n' "$PAD" > "$TMP/ux_modellate.md"
rejects "Model" validate_ux_critique_structure "$TMP/ux_modellate.md" \
  && ok "S-H negative: UX_CRITIQUE with 'Model:' on line 6 (past NR<=5) rejected" \
  || bad "S-H-neg-modellate" "validate_ux_critique_structure accepted 'Model:' on line 6 — NR<=5 boundary widened"
# S-H positive: a valid UX_CRITIQUE is accepted.
printf 'Model: claude-sonnet-4-6\n## UX Critique\nContrast, focus, hierarchy reviewed.\n%s\n' "$PAD" > "$TMP/ux_ok.md"
accepts validate_ux_critique_structure "$TMP/ux_ok.md" \
  && ok "S-H positive: valid UX_CRITIQUE accepted" \
  || bad "S-H-pos" "validate_ux_critique_structure rejected a valid UX_CRITIQUE — over-strict regression"

echo "== S-I: validate_success_criteria_structure — size + 'criteria'/'workflow_states' field-key (:|) anchors + heading-masquerade =="
cat > "$TMP/sc_ok.md" <<'SC_OK'
Model: opus

## Success Criteria

criteria:
  - SC-1: subscribe succeeds; verify_by: both; done_when: subscriptions row + UI shows active
  - SC-2: duplicate submit is idempotent; verify_by: test; done_when: no second charge

workflow_states:
  empty: n/a (plans always exist)
  loading: spinner shown
  error: inline message, no crash
  permission_denied: 403 page
  concurrent: last-write-wins
  double_submit: idempotent

human_success_check: a real user feels the subscription completed end-to-end.
SC_OK
cat > "$TMP/sc_small.md" <<'SC_SMALL'
Model: opus
SUCCESS_CRITERIA
SC_SMALL
cat > "$TMP/sc_nocriteria.md" <<'SC_NOCRIT'
Model: opus

## Success Criteria

workflow_states:
  empty: n/a
  loading: spinner
  error: handled inline
  permission_denied: 403
  concurrent: last-write-wins
  double_submit: idempotent

human_success_check: the workflow feels complete to a real user end to end.
SC_NOCRIT
cat > "$TMP/sc_nostates.md" <<'SC_NOSTATE'
Model: opus

## Success Criteria

criteria:
  - SC-1: it works; verify_by: test; done_when: green
  - SC-2: and again; verify_by: both; done_when: subscriptions row exists

human_success_check: a real user feels this worked from start to finish here.
SC_NOSTATE
# Masquerade: a bare '## Criteria' HEADING (the anchor word, but no `criteria:` field) + prose mention,
# with a real workflow_states: block so the rejection isolates the missing criteria FIELD. Pre-SREV-006
# (substring anchor) this was wrongly ACCEPTED; the `[:|]` delimiter now requires the field-key form.
cat > "$TMP/sc_masquerade.md" <<'SC_MASQ'
Model: opus

## Success Criteria

## Criteria

We discuss the criteria narratively in this section but never declare the field itself.

workflow_states:
  empty: n/a
  loading: spinner
  error: handled inline
  permission_denied: 403
  concurrent: last-write-wins
  double_submit: idempotent

human_success_check: the user feels this completed end to end across the whole flow.
SC_MASQ
rejects "small" validate_success_criteria_structure "$TMP/sc_small.md" \
  && ok "S-I negative: blank SUCCESS_CRITERIA stub rejected (size floor)" \
  || bad "S-I-neg-size" "validate_success_criteria_structure accepted a blank stub — size floor removed/bypassed"
rejects "criteria" validate_success_criteria_structure "$TMP/sc_nocriteria.md" \
  && ok "S-I negative: SUCCESS_CRITERIA without 'criteria' block rejected" \
  || bad "S-I-neg-criteria" "validate_success_criteria_structure accepted a SUCCESS_CRITERIA missing the 'criteria' block — check removed/bypassed"
rejects "criteria" validate_success_criteria_structure "$TMP/sc_masquerade.md" \
  && ok "S-I negative: SUCCESS_CRITERIA with bare '## Criteria' heading (masquerade, no field) rejected" \
  || bad "S-I-neg-masquerade" "validate_success_criteria_structure accepted a bare '## Criteria' heading masquerade — delimiter anchor [:|] loosened (codex SREV-006)"
rejects "workflow_states" validate_success_criteria_structure "$TMP/sc_nostates.md" \
  && ok "S-I negative: SUCCESS_CRITERIA without 'workflow_states' block rejected" \
  || bad "S-I-neg-states" "validate_success_criteria_structure accepted a SUCCESS_CRITERIA missing the 'workflow_states' block — check removed/bypassed"
accepts validate_success_criteria_structure "$TMP/sc_ok.md" \
  && ok "S-I positive: valid SUCCESS_CRITERIA accepted" \
  || bad "S-I-pos" "validate_success_criteria_structure rejected a valid SUCCESS_CRITERIA — over-strict regression"

echo "== S-J: validate_blast_radius_structure — size + 'states_to_verify' field-key (:|) anchor + heading-masquerade =="
cat > "$TMP/br_ok.md" <<'BR_OK'
Model: opus

## Workflow Blast Radius

flow: Controller@store -> Service::charge -> Webhook@handle
shared_deps: Service::charge is also called by Admin RefundController

states_to_verify:
  - state: empty; scenario: no line items; test_layer: feature; arrange: cart empty; act: submit; assert: 422
  - state: error; scenario: gateway 500; test_layer: feature; arrange: stub 500; act: submit; assert: inline error, no charge

browser_only_states:
  - slow_network
BR_OK
cat > "$TMP/br_small.md" <<'BR_SMALL'
Model: opus
WORKFLOW_BLAST_RADIUS
BR_SMALL
cat > "$TMP/br_nostates.md" <<'BR_NOSTATE'
Model: opus

## Workflow Blast Radius

flow: Controller@store -> Service::charge
shared_deps: also called by Admin RefundController and the nightly reconcile job

browser_only_states:
  - slow_network
  - concurrent edits across two open tabs
BR_NOSTATE
# Masquerade: a bare '## states_to_verify' HEADING (anchor word, but no `states_to_verify:` list field)
# + prose. Pre-SREV-006 (substring anchor) this was wrongly ACCEPTED; the `[:|]` delimiter now requires
# the field-key form so a decorative heading with no per-state list behind it is rejected.
cat > "$TMP/br_masquerade.md" <<'BR_MASQ'
Model: opus

## Workflow Blast Radius

## states_to_verify

We narrate the states to verify in prose here, but never list them as the field.

flow: Controller@store -> Service::charge
shared_deps: also called by Admin RefundController and the nightly reconcile job
BR_MASQ
rejects "small" validate_blast_radius_structure "$TMP/br_small.md" \
  && ok "S-J negative: blank WORKFLOW_BLAST_RADIUS stub rejected (size floor)" \
  || bad "S-J-neg-size" "validate_blast_radius_structure accepted a blank stub — size floor removed/bypassed"
rejects "states_to_verify" validate_blast_radius_structure "$TMP/br_nostates.md" \
  && ok "S-J negative: WORKFLOW_BLAST_RADIUS without 'states_to_verify' list rejected" \
  || bad "S-J-neg-states" "validate_blast_radius_structure accepted a WORKFLOW_BLAST_RADIUS missing 'states_to_verify' — check removed/bypassed"
rejects "states_to_verify" validate_blast_radius_structure "$TMP/br_masquerade.md" \
  && ok "S-J negative: WORKFLOW_BLAST_RADIUS with bare '## states_to_verify' heading (masquerade, no list) rejected" \
  || bad "S-J-neg-masquerade" "validate_blast_radius_structure accepted a bare '## states_to_verify' heading masquerade — delimiter anchor [:|] loosened (codex SREV-006)"
accepts validate_blast_radius_structure "$TMP/br_ok.md" \
  && ok "S-J positive: valid WORKFLOW_BLAST_RADIUS accepted" \
  || bad "S-J-pos" "validate_blast_radius_structure rejected a valid WORKFLOW_BLAST_RADIUS — over-strict regression"

echo
echo "== HOOKS_LIB_DIR injection vector — V_VALIDATION_LIB is the canonical source =="
# This section verifies that the harness ITSELF honors V_VALIDATION_LIB
# (the override-blind audit note: the harness must use the injected lib, not a hardcoded path)
# Meta-test: if V_VALIDATION_LIB is set, VALIDATION should equal it
if [ -n "${V_VALIDATION_LIB:-}" ]; then
  [ "$VALIDATION" = "$V_VALIDATION_LIB" ] \
    && ok "injection-vector: harness used V_VALIDATION_LIB injection (override NOT blind)" \
    || bad "injection-vector" "VALIDATION ($VALIDATION) != V_VALIDATION_LIB ($V_VALIDATION_LIB) — override-blind bug re-introduced"
else
  ok "injection-vector: V_VALIDATION_LIB not set — harness used live lib (expected in normal run)"
fi

echo
printf 'TOTAL: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
