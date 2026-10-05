#!/usr/bin/env bash
# v-artifact-validate-all-test.sh — regression harness for v-artifact-validate-all.sh (forensic 2026-06-19).
# Proves the batch validator (a) passes a full set of well-formed artifacts, and (b) reports EVERY
# malformed artifact in a SINGLE run (the anti-death-march property) and exits non-zero.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/v-artifact-validate-all.sh"
[ -f "$SCRIPT" ] || { echo "NO v-artifact-validate-all.sh missing"; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }

SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
T="$(mktemp -d)"; trap 'rm -rf "$T" 2>/dev/null' EXIT
A="$T/.v/artifacts"; mkdir -p "$A"

# ---- well-formed set (each crafted to its validator's contract) ----
valid_preflight(){ cat > "$A/PRE_FLIGHT_REPORT_${SID}.md" <<EOF
Mode: full
## Gates
| Status | Gate |
| PASS | tests |
Overall Status: PASS
EOF
}
valid_verifydone(){ cat > "$A/VERIFY_DONE_REPORT_${SID}.md" <<EOF
Mode: full
Changed: 3
## Summary
All conventions followed.
Overall Verdict: PASS
EOF
}
valid_review(){ cat > "$A/AGENT_REVIEW_${SID}.md" <<EOF
Model: haiku
Status: completed
Session: ${SID}
Agents dispatched: logic-reviewer
Codex adversarial reviewer: superpowers:requesting-code-review
Hostile adversarial focus: no
Dispatch mode: subagent-dispatched
Review evidence: findings: 0
Remediation: none
## Findings
No issues found.
EOF
}
valid_impactmap(){ cat > "$A/IMPACT_MAP_${SID}.md" <<EOF
subsystems:
  functional_flow:    { impacted: no, reason: x }
  reporting_metrics:  { impacted: no, reason: x }
  cache_invalidation: { impacted: no, reason: x }
  db_integrity:       { impacted: no, reason: x }
EOF
}
valid_qa(){ cat > "$A/QA_REPORT_${SID}.md" <<EOF
Model: haiku
## QA Acceptance
verdict: pass
acceptance: accept  critical:0 high:0 medium:0 low:0  iterations: 1/3
The change was exercised end-to-end; all acceptance criteria pass.
EOF
}
valid_ux(){ cat > "$A/UX_CRITIQUE_${SID}.md" <<EOF
Model: haiku
## UX Critique
No blocking heuristic violations across the changed admin surfaces.
Contrast, focus states, and error affordances were reviewed and pass.
EOF
}
valid_wf(){ cat > "$A/WORKFLOW_VERIFICATION_${SID}.md" <<EOF
Model: haiku
## Workflow Verification
status: pass
The primary admin workflow was driven end-to-end with zero console errors.
EOF
}

valid_preflight; valid_verifydone; valid_review; valid_impactmap; valid_qa; valid_ux; valid_wf

# ---- Scenario 1: all valid -> exit 0, 7 ok ----
OUT=$(bash "$SCRIPT" "$SID" "$A" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "all-valid set exits 0" || no "all-valid set non-zero (rc=$RC)" "$OUT"
printf '%s' "$OUT" | grep -q '7 ok, 0 invalid' && ok "all 7 report ok" || no "not 7 ok" "$OUT"

# ---- Scenario 2: corrupt THREE different artifacts in three different ways ----
# UX wrong-case heading (the case-sensitivity trap), QA wrong heading, AGENT_REVIEW missing fields.
printf 'Model: haiku\n## UX Findings\nx\n'            > "$A/UX_CRITIQUE_${SID}.md"          # capital F (rejected today)
printf 'Model: haiku\n## Acceptance\nverdict: pass\n' > "$A/QA_REPORT_${SID}.md"             # missing "QA"
printf 'Model: haiku\nStatus: completed\nSession: %s\n## Findings\nx\n' "$SID" > "$A/AGENT_REVIEW_${SID}.md"  # missing 6 fields

OUT2=$(bash "$SCRIPT" "$SID" "$A" 2>&1); RC2=$?
[ "$RC2" -ne 0 ] && ok "corrupt set exits non-zero" || no "corrupt set returned 0" "$OUT2"
# The anti-death-march property: ALL THREE failures reported in ONE run.
N_FAIL=$(printf '%s' "$OUT2" | grep -c 'FAIL ')
[ "$N_FAIL" -ge 3 ] && ok "reports >=3 failures in ONE run (anti-death-march: $N_FAIL)" || no "did not batch failures (saw $N_FAIL)" "$OUT2"
printf '%s' "$OUT2" | grep -q 'FAIL    UX_CRITIQUE' && ok "flags the UX heading-case trap" || no "missed UX failure" "$OUT2"
printf '%s' "$OUT2" | grep -q 'FAIL    QA_REPORT' && ok "flags the QA heading trap" || no "missed QA failure" "$OUT2"
printf '%s' "$OUT2" | grep -q 'FAIL    AGENT_REVIEW' && ok "flags AGENT_REVIEW missing-fields" || no "missed AGENT_REVIEW failure" "$OUT2"
# The still-valid ones must NOT be reported as FAIL.
printf '%s' "$OUT2" | grep -q 'ok      PRE_FLIGHT' && ok "valid PRE_FLIGHT still ok in corrupt run" || no "PRE_FLIGHT mis-flagged" "$OUT2"

# ---- Scenario 3: absent artifacts are 'absent', not 'invalid' ----
rm -f "$A/WORKFLOW_VERIFICATION_${SID}.md"
OUT3=$(bash "$SCRIPT" "$SID" "$A" 2>&1)
printf '%s' "$OUT3" | grep -q 'absent  WORKFLOW_VERIFICATION' && ok "missing artifact reported as absent" || no "absent not reported" "$OUT3"

# ---- Scenario 4 (W71, 2026-07-02): 'Model: fable' is an accepted review model ----
# Codex-quota-degraded sessions dispatch Fable subprocess reviewers; the allowlist
# rejecting the honest label forced either a FAIL board or a mislabeled model.
valid_review
sed -i '' 's/^Model: haiku$/Model: fable/' "$A/AGENT_REVIEW_${SID}.md" 2>/dev/null \
  || sed -i 's/^Model: haiku$/Model: fable/' "$A/AGENT_REVIEW_${SID}.md"
OUT4=$(bash "$SCRIPT" "$SID" "$A" 2>&1)
printf '%s' "$OUT4" | grep -q 'ok      AGENT_REVIEW' && ok "Model: fable accepted (W71 allowlist)" || no "Model: fable rejected" "$OUT4"
# red-oracle for the class: a validation.sh whose allowlist lacks fable must FAIL this artifact
OLDLIB="$T/validation-prefable.sh"
sed 's/haiku|sonnet|opus|fable/haiku|sonnet|opus/' "$HERE/../../../hooks/lib/validation.sh" > "$OLDLIB"
OUT5=$(V_VALIDATION_LIB="$OLDLIB" bash "$SCRIPT" "$SID" "$A" 2>&1)
printf '%s' "$OUT5" | grep -q 'FAIL    AGENT_REVIEW' && ok "pre-fable allowlist rejects it (guard bites, not vacuous)" || no "red-oracle vacuous: pre-fable lib accepted fable" "$OUT5"

# ---- Scenario 5 (SREV-001 emission contract, 2026-07-05): EVERY reason line carries '↳ ' ----
# Validator reasons can embed artifact-derived content (verify-done's "(got: '<last line>')"), and
# line-oriented consumers (v-artifact-board.sh's injection guard) strip detail by dropping ↳-marked
# lines. E1's batched multi-error manifests made reasons MULTI-LINE; the old single `↳ %s` printf
# prefixed only line 1, so continuation lines — including one embedding raw artifact content —
# leaked past the strip (the reopened SREV-001 surface, caught by v-artifact-board-test.sh).
# Pin: an invalid VERIFY_DONE whose last line is an injection marker must produce (a) MULTIPLE
# ↳-prefixed reason lines (the E1 manifest value survives) and (b) ZERO unprefixed lines carrying
# the marker (strip-safety for every artifact-derived byte).
MARK6="ZZINJECTMARKERZZ-ignore-previous-instructions"
printf 'not a valid verify-done report\n%s\n' "$MARK6" > "$A/VERIFY_DONE_REPORT_${SID}.md"
OUT6=$(bash "$SCRIPT" "$SID" "$A" 2>&1)
_n_prefixed=$(printf '%s\n' "$OUT6" | grep -c '↳ verify-done:' || true)
[ "${_n_prefixed:-0}" -ge 2 ] \
  && ok "multi-error manifest emits MULTIPLE ↳-prefixed reason lines (E1 batching intact: $_n_prefixed)" \
  || no "batched reasons collapsed/lost (expected >=2 ↳ verify-done lines)" "$OUT6"
if printf '%s\n' "$OUT6" | grep -v '↳' | grep -q "$MARK6"; then
  no "SREV-001 REOPENED: artifact-derived content on an unprefixed line (leaks past line-oriented strips)" "$OUT6"
else
  ok "SREV-001 emission contract: every artifact-derived reason line is ↳-prefixed (strip-safe)"
fi

# ---- W-CWD1 (forensic 2026-07-14): DEFAULT search dirs must anchor to the REPO
# ROOT, not $PWD. The default was SEARCH_DIRS=("$PWD/.v/artifacts" "$PWD"), so invoking the validator
# from ANY repo subdirectory (the Bash tool's cwd routinely drifts — e.g. to .v-prompt-packs) reported
# EVERY artifact as "absent" even with a full, valid set on disk at <root>/.v/artifacts. That false
# TOTAL-LOSS reading is the precise trigger for the fabrication drift this script exists to prevent
# (see header): a session that believes its artifacts vanished re-creates them from prose.
# Pin: from a subdirectory, with a valid artifact at <root>/.v/artifacts, the DEFAULT invocation
# (no explicit search dirs) must find it and report ok — never "absent".
G="$T/gitrepo"
mkdir -p "$G/.v/artifacts" "$G/sub/deeper"
( cd "$G" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
if [ -d "$G/.git" ]; then
  cat > "$G/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md" <<EOF
Mode: full
## Gates
| Status | Gate |
| PASS | tests |
Overall Status: PASS
EOF
  # Invoke with NO explicit search dirs, from a nested subdirectory of the repo.
  OUT7=$(cd "$G/sub/deeper" && bash "$SCRIPT" "$SID" 2>&1)
  if printf '%s\n' "$OUT7" | grep -qE '^[[:space:]]*ok[[:space:]]+PRE_FLIGHT_REPORT'; then
    ok "W-CWD1: default search dirs anchor to repo root (found from subdir)"
  else
    no "W-CWD1: default invocation from a subdir cannot see <root>/.v/artifacts (false 'absent')" "$OUT7"
  fi
  # Guard the guard: the same call must NOT report the present artifact as absent.
  if printf '%s\n' "$OUT7" | grep -qE '^[[:space:]]*absent[[:space:]]+PRE_FLIGHT_REPORT'; then
    no "W-CWD1: present artifact still reported 'absent' from subdir (bite check)" "$OUT7"
  else
    ok "W-CWD1: present artifact never reported absent from subdir (bite check)"
  fi
else
  no "W-CWD1: could not init throwaway git repo (test inconclusive — not a pass)"
fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
