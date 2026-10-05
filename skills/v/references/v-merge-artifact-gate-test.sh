#!/usr/bin/env bash
# v-merge-artifact-gate-test.sh — W-GATE artifact-presence merge precondition (forensic A-3
# 2026-06-04: a session merged to main with ZERO gate artifacts — no PRE_FLIGHT_REPORT, no
# AGENT_REVIEW, inline self-review only). Merge-back is the irreversible step, so it now
# refuses a code-bearing worktree whose SID has neither (PRE_FLIGHT + AGENT_REVIEW) nor a
# non-code bypass marker, with V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 as the logged escape hatch.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MB="$HERE/v-merge-back.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

# H4-6 fixture upgrade (2026-07-02): merge-back now runs Stop-grade validate_review_semantics on
# AGENT_REVIEW, so the old 2-line presence stub no longer represents a mergeable session. This
# helper emits the minimal SEMANTICALLY-VALID review (SID embedded, codex-ran provenance wording,
# hostile: no — these fixtures never touch hostile paths). The gate's PRESENCE cases still use
# deliberately-broken stubs where blocking is the expectation.
ar_valid(){  # $1=sid -> stdout
  printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: logic-reviewer (independent subprocess)\n- Codex adversarial reviewer: ran — 0 candidates (background agent)\n- Reviewer model: sonnet\n- Hostile adversarial focus: no\n- Dispatch mode: foreground\n- Review evidence: findings: 0\n- Remediation: 0 — no findings\n\n## Findings\n\nNo issues found.\n' "$1"
}


WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# Make sure an outer harness's skip doesn't leak in — this suite tests the gate itself.
unset V_MERGE_BACK_SKIP_ARTIFACT_GATE 2>/dev/null || true

# new_repo <name> <sid8> -> sets R (repo), WT (worktree), BR (branch)
new_repo() {
  R="$WORK/$1"; mkdir -p "$R"
  git -C "$R" init -q
  printf '.v/\n.worktrees/\n' > "$R/.gitignore"
  git -C "$R" add .gitignore
  git -C "$R" -c user.email=t@t -c user.name=t commit -q -m init
  BR="build/gate-$2"
  WT="$WORK/$1-wt"
  git -C "$R" worktree add -q -b "$BR" "$WT" >/dev/null 2>&1
  printf 'work\n' > "$WT/f.txt"
  git -C "$WT" add f.txt
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "feat: gate fixture"
}

SID="aa11bb22-0000-4000-8000-00000000a3a3"
S8="aa11bb22"

echo "== W-GATE :: blocks without artifacts =="
new_repo r1 "$S8"
OUT=$(bash "$MB" "$SID" "$WT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "no artifacts → merge BLOCKED (exit 1)" || no "expected exit 1, got $RC"
echo "$OUT" | grep -q "W-GATE artifact-presence merge precondition FAILED" && ok "gate error message present" || no "gate message missing: $(echo "$OUT" | head -3)"
echo "$OUT" | grep -q "DO NOT FALL BACK TO A MANUAL" && ok "never-manual banner printed on gate failure" || no "banner missing"
[ -d "$WT" ] && ok "worktree intact after block (retry-safe)" || no "worktree was removed despite block"
grep -q 'work' "$R/f.txt" 2>/dev/null && no "branch content reached main despite block" || ok "branch content NOT merged"

echo "== W-GATE :: PRE_FLIGHT alone is not enough =="
mkdir -p "$WT/.v/artifacts"
printf 'Model: haiku\nOverall Status: PASS\n' > "$WT/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
OUT=$(bash "$MB" "$SID" "$WT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "PRE_FLIGHT only → still blocked" || no "expected exit 1, got $RC"

echo "== W-GATE :: PRE_FLIGHT + AGENT_REVIEW WITHOUT verify-done is still blocked (P0-1) =="
ar_valid "${SID}" > "$WT/.v/artifacts/AGENT_REVIEW_${SID}.md"
OUT=$(bash "$MB" "$SID" "$WT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "PRE_FLIGHT + AGENT_REVIEW only → still BLOCKED (verify-done mandatory, P0-1)" || no "expected exit 1 (no verify-done), got $RC — $OUT"
grep -q 'work' "$R/f.txt" 2>/dev/null && no "content reached main without verify-done" || ok "branch content NOT merged without verify-done"

echo "== W-GATE :: retry after adding VERIFY_DONE (PASS) + IMPACT_MAP + QA succeeds (worktree-local artifacts count) =="
printf 'Model: haiku\nMode: scoped(writes-log)\nChanged: 1\nOverall Verdict: PASS\n' > "$WT/.v/artifacts/VERIFY_DONE_REPORT_${SID}.md"
# F3 (forensic 2026-06-04): a code-gauntlet session must also carry IMPACT_MAP + QA at merge (Stop-hook parity).
printf 'Model: haiku\nsubsystems:\n- functional_flow\n' > "$WT/.v/artifacts/IMPACT_MAP_${SID}.md"
printf 'Model: haiku\n## QA Acceptance\nverdict: pass\n' > "$WT/.v/artifacts/QA_REPORT_${SID}.md"
OUT=$(bash "$MB" "$SID" "$WT" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "PRE_FLIGHT + AGENT_REVIEW + VERIFY_DONE(PASS) + IMPACT_MAP + QA → merge succeeds (exit 0)" || no "expected exit 0, got $RC — $OUT"
grep -q 'work' "$R/f.txt" 2>/dev/null && ok "branch content merged after gate satisfied" || no "content missing post-merge"
[ -f "$R/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md" ] && ok "artifacts consolidated to main during gated merge" || no "artifacts not consolidated"

echo "== W-GATE :: VERIFY_DONE with FAIL verdict BLOCKS merge (P0-1: FAIL-verdict class) =="
SIDF="bb22cc33-0000-4000-8000-00000000a3a3"
new_repo rF "bb22cc33"
mkdir -p "$WT/.v/artifacts"
printf 'Model: haiku\nOverall Status: PASS\n' > "$WT/.v/artifacts/PRE_FLIGHT_REPORT_${SIDF}.md"
ar_valid "${SIDF}" > "$WT/.v/artifacts/AGENT_REVIEW_${SIDF}.md"
printf 'Model: haiku\nMode: scoped(fallback-git-state)\nChanged: 29\nOverall Verdict: FAIL\n' > "$WT/.v/artifacts/VERIFY_DONE_REPORT_${SIDF}.md"
OUT=$(bash "$MB" "$SIDF" "$WT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "verify-done FAIL verdict → merge BLOCKED (exit 1)" || no "expected exit 1 (FAIL blocks), got $RC — $OUT"
echo "$OUT" | grep -qi "verify-done not mergeable" && ok "FAIL-verdict block message present" || no "FAIL message missing"
grep -q 'work' "$R/f.txt" 2>/dev/null && no "FAIL-verdict branch content reached main" || ok "FAIL-verdict branch NOT merged"

echo "== W-GATE :: past-tense FAILED verdict also BLOCKS (review FND-001 regex hardening) =="
SIDX="dd44ee55-0000-4000-8000-00000000a3a3"
new_repo rX "dd44ee55"
mkdir -p "$WT/.v/artifacts"
printf 'Model: haiku\nOverall Status: PASS\n' > "$WT/.v/artifacts/PRE_FLIGHT_REPORT_${SIDX}.md"
ar_valid "${SIDX}" > "$WT/.v/artifacts/AGENT_REVIEW_${SIDX}.md"
printf 'Model: haiku\nMode: scoped(writes-log)\nChanged: 2\n**Overall Verdict: FAILED**\n' > "$WT/.v/artifacts/VERIFY_DONE_REPORT_${SIDX}.md"
OUT=$(bash "$MB" "$SIDX" "$WT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "past-tense **FAILED** verdict → merge BLOCKED" || no "expected exit 1 (FAILED blocks), got $RC — $OUT"

echo "== W-GATE :: no-isolation PASS does NOT gate the merge (HIGH-3 + review #4) =="
SIDN="ff5500aa-0000-4000-8000-00000000a3a3"
new_repo rN "ff5500aa"
mkdir -p "$WT/.v/artifacts"
printf 'Model: haiku\nOverall Status: PASS\n' > "$WT/.v/artifacts/PRE_FLIGHT_REPORT_${SIDN}.md"
ar_valid "${SIDN}" > "$WT/.v/artifacts/AGENT_REVIEW_${SIDN}.md"
printf 'Model: haiku\nMode: scoped(fallback-git-state:no-isolation)\nChanged: 0\nOverall Verdict: PASS\n' > "$WT/.v/artifacts/VERIFY_DONE_REPORT_${SIDN}.md"
OUT=$(bash "$MB" "$SIDN" "$WT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "no-isolation PASS → merge BLOCKED (untrusted scope, not a valid gate)" || no "expected exit 1 (no-isolation blocks), got $RC — $OUT"
echo "$OUT" | grep -qi "no-isolation scope" && ok "no-isolation block message present" || no "no-isolation message missing"

echo "== W-GATE :: artifacts at MAIN root (legacy location) satisfy the gate =="
SID2="cc33dd44-0000-4000-8000-00000000a3a3"
new_repo r2 "cc33dd44"
printf 'Model: haiku\nOverall Status: PASS\n' > "$R/PRE_FLIGHT_REPORT_${SID2}.md"
ar_valid "${SID2}" > "$R/AGENT_REVIEW_${SID2}.md"
printf 'Model: haiku\nMode: scoped(writes-log)\nChanged: 1\nOverall Verdict: PASS\n' > "$R/VERIFY_DONE_REPORT_${SID2}.md"
printf 'Model: haiku\nsubsystems:\n- functional_flow\n' > "$R/IMPACT_MAP_${SID2}.md"
printf 'Model: haiku\n## QA Acceptance\nverdict: pass\n' > "$R/QA_REPORT_${SID2}.md"
OUT=$(bash "$MB" "$SID2" "$WT" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "legacy-root artifacts satisfy the gate" || no "legacy-root artifacts rejected (rc=$RC) — $OUT"

echo "== F3 :: code-gauntlet session MISSING IMPACT_MAP or QA is BLOCKED (forensic 2026-06-04) =="
SIDG="abab0099-0000-4000-8000-00000000a3a3"
new_repo rG "abab0099"
mkdir -p "$WT/.v/artifacts"
printf 'Model: haiku\nOverall Status: PASS\n' > "$WT/.v/artifacts/PRE_FLIGHT_REPORT_${SIDG}.md"
ar_valid "${SIDG}" > "$WT/.v/artifacts/AGENT_REVIEW_${SIDG}.md"
printf 'Model: haiku\nMode: scoped(writes-log)\nChanged: 1\nOverall Verdict: PASS\n' > "$WT/.v/artifacts/VERIFY_DONE_REPORT_${SIDG}.md"
# full basic gauntlet but NO IMPACT_MAP / QA — the exact forensic state
OUT=$(bash "$MB" "$SIDG" "$WT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "F3: gauntlet present but IMPACT_MAP missing → merge BLOCKED" || no "F3: expected exit 1 (IMPACT_MAP missing), got $RC — $OUT"
echo "$OUT" | grep -qi "IMPACT_MAP.*missing" && ok "F3: block names the missing IMPACT_MAP" || no "F3: IMPACT_MAP message missing"
# add IMPACT_MAP but still no QA → still BLOCKED (on QA)
printf 'Model: haiku\nsubsystems:\n- functional_flow\n' > "$WT/.v/artifacts/IMPACT_MAP_${SIDG}.md"
OUT=$(bash "$MB" "$SIDG" "$WT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && echo "$OUT" | grep -qi "QA_REPORT.*missing" && ok "F3: IMPACT_MAP present but QA missing → still BLOCKED on QA" || no "F3: expected QA-missing block, got $RC — $OUT"
# add QA → now merges
printf 'Model: haiku\n## QA Acceptance\nverdict: pass\n' > "$WT/.v/artifacts/QA_REPORT_${SIDG}.md"
OUT=$(bash "$MB" "$SIDG" "$WT" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "F3: complete gauntlet (incl IMPACT_MAP + QA) → merge succeeds" || no "F3: expected exit 0 with full gauntlet, got $RC — $OUT"

echo "== F3/R10 :: QA_REPORT with an explicit top verdict:fail BLOCKS merge (do not ship QA-rejected work) =="
SIDQF="fa110099-0000-4000-8000-00000000a3a3"
new_repo rQF "fa110099"; mkdir -p "$WT/.v/artifacts"
printf 'Model: haiku\nOverall Status: PASS\n'                                > "$WT/.v/artifacts/PRE_FLIGHT_REPORT_${SIDQF}.md"
ar_valid "${SIDQF}" > "$WT/.v/artifacts/AGENT_REVIEW_${SIDQF}.md"
printf 'Model: haiku\nMode: scoped(writes-log)\nChanged: 1\nOverall Verdict: PASS\n' > "$WT/.v/artifacts/VERIFY_DONE_REPORT_${SIDQF}.md"
printf 'Model: haiku\nsubsystems:\n- functional_flow\n'                      > "$WT/.v/artifacts/IMPACT_MAP_${SIDQF}.md"
printf 'Model: haiku\n## QA Acceptance\nverdict: fail  acceptance: partial  critical:1\n' > "$WT/.v/artifacts/QA_REPORT_${SIDQF}.md"
OUT=$(bash "$MB" "$SIDQF" "$WT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "QA verdict:fail → merge BLOCKED (exit 1)" || no "expected exit 1 (QA fail blocks), got $RC — $OUT"
echo "$OUT" | grep -qi "QA_REPORT verdict is FAIL" && ok "block message names the QA FAIL verdict" || no "QA-FAIL block message missing — $OUT"
grep -q 'work' "$R/f.txt" 2>/dev/null && no "QA-fail branch content reached main" || ok "QA-fail branch NOT merged (left for remediation)"

echo "== F3/R10 :: col-0 anchoring — a PASS verdict whose prose mentions a prior 'verdict: fail' still MERGES =="
SIDQP="fb110099-0000-4000-8000-00000000a3a3"
new_repo rQP "fb110099"; mkdir -p "$WT/.v/artifacts"
printf 'Model: haiku\nOverall Status: PASS\n'                                > "$WT/.v/artifacts/PRE_FLIGHT_REPORT_${SIDQP}.md"
ar_valid "${SIDQP}" > "$WT/.v/artifacts/AGENT_REVIEW_${SIDQP}.md"
printf 'Model: haiku\nMode: scoped(writes-log)\nChanged: 1\nOverall Verdict: PASS\n' > "$WT/.v/artifacts/VERIFY_DONE_REPORT_${SIDQP}.md"
printf 'Model: haiku\nsubsystems:\n- functional_flow\n'                      > "$WT/.v/artifacts/IMPACT_MAP_${SIDQP}.md"
printf 'Model: haiku\n## QA Acceptance\nverdict: pass  acceptance: full\niteration note: a prior verdict: fail was resolved in cycle 2\n' > "$WT/.v/artifacts/QA_REPORT_${SIDQP}.md"
OUT=$(bash "$MB" "$SIDQP" "$WT" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "QA top verdict:pass merges despite prose 'verdict: fail' (col-0 anchoring, no false-block)" || no "col-0 anchoring failed — prose false-blocked a PASS (rc=$RC) — $OUT"

echo "== F3 :: a BYPASS-marker (HANDOFF) session is EXEMPT from IMPACT_MAP/QA (non-code/deferred) =="
SIDH="cdcd0099-0000-4000-8000-00000000a3a3"
new_repo rH "cdcd0099"
mkdir -p "$WT/.v/artifacts"
printf '# Handoff\nDeferred — out of scope; will resume. Changed app/Foo.php.\n' > "$WT/.v/artifacts/HANDOFF_${SIDH}.md"
OUT=$(bash "$MB" "$SIDH" "$WT" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "F3: HANDOFF bypass merges without IMPACT_MAP/QA (exempt — _gate_via_gauntlet=0)" || no "F3: HANDOFF wrongly blocked on IMPACT_MAP/QA, got $RC — $OUT"

echo "== W-GATE :: non-code bypass marker (HANDOFF) satisfies the gate =="
SID3="ee55ff66-0000-4000-8000-00000000a3a3"
new_repo r3 "ee55ff66"
mkdir -p "$R/.v/artifacts"
printf '# Handoff\n\nlong enough body for structural checks elsewhere\n' > "$R/.v/artifacts/HANDOFF_${SID3}.md"
OUT=$(bash "$MB" "$SID3" "$WT" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "HANDOFF bypass marker admits merge" || no "bypass marker rejected (rc=$RC) — $OUT"

echo "== W-GATE :: env escape hatch =="
SID4="0077aa88-0000-4000-8000-00000000a3a3"
new_repo r4 "0077aa88"
OUT=$(V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 bash "$MB" "$SID4" "$WT" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 skips the gate" || no "escape hatch broken (rc=$RC)"
echo "$OUT" | grep -q "artifact-presence merge precondition SKIPPED" && ok "skip is LOGGED (not silent)" || no "skip not logged"

echo "== W-GATE :: sibling SID's artifacts do NOT satisfy this SID's gate =="
SID5="99aabb00-0000-4000-8000-00000000a3a3"
new_repo r5 "99aabb00"
mkdir -p "$R/.v/artifacts"
printf 'x\n' > "$R/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"   # a DIFFERENT session's artifacts
printf 'x\n' > "$R/.v/artifacts/AGENT_REVIEW_${SID}.md"
OUT=$(bash "$MB" "$SID5" "$WT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "sibling-SID artifacts rejected (SID-scoped globs)" || no "sibling artifacts accepted (rc=$RC)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "RESULT: PASS"
