#!/usr/bin/env bash
# mutation-gate.sh — prove the regression harnesses actually DETECT the bugs they guard.
#
# For each registered guard: the harness MUST pass on live code (control) and MUST fail on the
# mutant (proving the guard is alive, not vacuous). Two mutant-injection modes:
#
#   gate        — FROZEN-FIXTURE mutant: a pre-fix copy under skills/__tests__/fixtures/pre-fix,
#                 injected via the harness's hermetic override env var. Good for small files.
#   gate_patch  — PATCH mutant (audit 2026-06-17): apply a small, reviewable revert to a TEMP COPY
#                 of the live file at gate-time, then inject that. Avoids freezing huge files (e.g.
#                 validate-log.py is 5k lines / 276K — a frozen copy would drift heavily). Patch
#                 mutants fail CLOSED on drift: if the revert expression no longer matches the live
#                 code, the temp copy == live, the harness PASSES, and the gate reports the guard as
#                 unverifiable (the `cmp` check below) — prompting a fix instead of silent rot.
#
# NO live file is ever swapped (lesson learned: a live-swap helper once corrupted the base). The
# gate runs the mutant by pointing the harness at the fixture/temp via its override var.
#
# OVERRIDE-INTEGRITY (audit 2026-06-17): before trusting any result, the gate asserts the harness
# actually REFERENCES its override var. A harness that ignores the override silently runs against the
# REAL tree, so the injected mutant is invisible — exactly the blindness that made backtest bug #7
# (v-contract-audit-test.sh ignoring its VL override) look "not caught." Without this check that
# manifests as an ambiguous "guard DEAD"; with it the gate names the real cause.
#
# Run:  bash scripts/mutation-gate.sh   (scripts/run-tests.sh also runs it, last)
# Exit: 0 iff every guard is proven alive.
set -u
CDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
REFS="$CDIR/skills/v/references"
REFS_SL="$CDIR/skills/v-session-log/references"
FIX="$CDIR/skills/__tests__/fixtures/pre-fix"
ENVU=(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SESSION_ID)
PASS=0; FAIL=0

# Control-result cache (audit 2026-06-19): _control runs the harness on LIVE code, which is IDENTICAL
# for every guard sharing that harness (7 guards share check-review-artifact.sh, 6 share
# v-contract-negative-test.sh, 5 share p2-bite-gate-behavioral-test.sh, ...). Running each unique
# harness's control ONCE instead of once-per-guard removes redundant heavy runs from the
# gate so it stays inside its time budget under load (mutants still run per-guard; only the
# identical live-control is deduped). Portable (no bash-4 assoc array): one marker file per harness.
_CTRL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mgctrl.XXXXXX")"
trap 'rm -rf "$_CTRL_DIR" 2>/dev/null' EXIT

# _check_override_integrity <name> <harness> <var> -> 0 if the harness honors the override var.
_check_override_integrity() {
  local name="$1" harness="$2" var="$3"
  if ! grep -q "$var" "$harness"; then
    echo "FAIL $name: harness does NOT reference \$$var — the mutant would be invisible and the"
    echo "     harness would run against the REAL tree (backtest-#7 blindness class). Make the"
    echo "     harness honor \${$var:-<live path>}."
    return 1
  fi
  return 0
}

# _judge <name> <rc> <out> — record alive (rc!=0 AND positive failure evidence) vs dead.
# Failure evidence = a literal 'FAIL'/'NO ' assertion line OR a non-zero failed-count in a
# 'TOTAL/summary: N passed, M failed' line (M>0). Different harnesses print different tokens
# (parity/contract-audit/witness use 'FAIL', qa-verdict-flip uses 'NO '); requiring rc!=0 AND any
# of these keeps the judge strict (a guard that DOESN'T bite leaves rc=0 / M=0) while not
# false-reporting DEAD on a harness whose only failure token is 'NO ' (SREV: do not weaken — both
# conditions, rc!=0 AND positive evidence, must hold).
_judge() {
  local name="$1" rc="$2" out="$3"
  local has_evidence=0
  if printf '%s' "$out" | grep -qE '(^|[^A-Za-z])(FAIL|NO)( |:|\b)'; then has_evidence=1; fi
  if printf '%s' "$out" | grep -qE '[0-9]+ +passed, +[1-9][0-9]* +failed'; then has_evidence=1; fi
  if [ "$rc" -ne 0 ] && [ "$has_evidence" -eq 1 ]; then
    echo "ok   $name: live PASS, mutant FAIL — guard is alive [rc=$rc]"; PASS=$((PASS+1))
  else
    echo "FAIL $name: mutant did NOT fail the harness — the regression guard is DEAD [rc=$rc]"; FAIL=$((FAIL+1))
  fi
}

# _control <name> <harness> -> 0 if the harness passes on live code.
_control() {
  local name="$1" harness="$2" _marker
  # Cache the LIVE-code result per harness (identical across all guards using it) — run it once.
  _marker="$_CTRL_DIR/$(printf '%s' "$harness" | tr -c 'A-Za-z0-9' '_')"
  if [ -f "$_marker" ]; then
    [ "$(cat "$_marker" 2>/dev/null)" = pass ] && return 0
    echo "FAIL $name: CONTROL — harness does NOT pass on live code (cached; cannot trust the mutant result)"
    return 1
  fi
  if "${ENVU[@]}" bash "$harness" >/dev/null 2>&1; then
    printf pass > "$_marker"; return 0
  fi
  printf fail > "$_marker"
  echo "FAIL $name: CONTROL — harness does NOT pass on live code (cannot trust the mutant result)"
  return 1
}

# gate <name> <harness> <override_var> <mutant_fixture>   (frozen-fixture mode)
gate() {
  local name="$1" harness="$2" var="$3" mut="$4"
  if [ ! -f "$harness" ]; then echo "FAIL $name: harness missing ($harness)"; FAIL=$((FAIL+1)); return; fi
  if [ ! -f "$mut" ]; then echo "FAIL $name: mutant fixture missing ($mut)"; FAIL=$((FAIL+1)); return; fi
  _check_override_integrity "$name" "$harness" "$var" || { FAIL=$((FAIL+1)); return; }
  _control "$name" "$harness" || { FAIL=$((FAIL+1)); return; }
  local out rc
  out="$("${ENVU[@]}" "$var=$mut" bash "$harness" 2>&1)"; rc=$?
  _judge "$name" "$rc" "$out"
}

# gate_patch <name> <harness> <override_var> <target_live_file> <perl_revert_expr>   (patch mode)
gate_patch() {
  local name="$1" harness="$2" var="$3" target="$4" patch="$5"
  if [ ! -f "$harness" ]; then echo "FAIL $name: harness missing ($harness)"; FAIL=$((FAIL+1)); return; fi
  if [ ! -f "$target" ]; then echo "FAIL $name: target file missing ($target)"; FAIL=$((FAIL+1)); return; fi
  _check_override_integrity "$name" "$harness" "$var" || { FAIL=$((FAIL+1)); return; }
  _control "$name" "$harness" || { FAIL=$((FAIL+1)); return; }
  # Build the mutant in a temp dir, preserving the basename (so .py/.sh loaders still resolve it).
  local tmpd mut out rc
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/mutgate.XXXXXX")"
  # RETURN trap: clean up tmpd on EVERY exit path of this function — including a SIGINT/crash between
  # mktemp and the run (SREV-001). Covers the early-return below without a separate rm at each site.
  trap 'rm -rf "$tmpd" 2>/dev/null' RETURN
  mut="$tmpd/$(basename "$target")"
  cp "$target" "$mut"
  perl -0pi -e "$patch" "$mut"
  if cmp -s "$target" "$mut"; then
    echo "FAIL $name: patch did NOT modify the target — the revert expression has rotted (live code"
    echo "     changed). Update the perl expression in mutation-gate.sh so it reverts the guard again."
    FAIL=$((FAIL+1)); return
  fi
  out="$("${ENVU[@]}" "$var=$mut" bash "$harness" 2>&1)"; rc=$?
  _judge "$name" "$rc" "$out"
}

# ── Registered guards ───────────────────────────────────────────────────────────────────────────
# Snapshot note: the live system registers 52 guards. This published snapshot keeps the 8 whose
# test harnesses ship with it, so every row below runs here; the other 44 need harnesses that are
# not part of the snapshot.

# E2E cross-step INDEPENDENCE (audit 2026-06-18, Phase 2): the SAME _independence_verdict accept-all
# bypass as A1, but proven end-to-end through the FULL Stop-hook chain (incident #4 — abandonment /
# no-provenance). The lifecycle harness forwards $V_VALIDATION_LIB into its real Stop-hook runs, so a
# mutant validation.sh that short-circuits the verdict to 'dispatched' makes scenario H1's forged
# 'subagent-dispatched' review (with NO DISPATCH_PROVENANCE) SILENTLY PASS — H1 must flip red. This is
# the non-redundant integration complement to the parity-unit guard: it proves the abandonment class is
# caught at the real enforcement seam, not just in the parity fixture set.
gate_patch "e2e-lifecycle-independence" "$REFS/v-e2e-lifecycle-test.sh" V_VALIDATION_LIB \
     "$CDIR/hooks/lib/validation.sh" \
     's/(_independence_verdict\(\) \{\n  local _file="\$1" _agent="\$2"\n)/$1  echo "dispatched"; return  # mutation-gate revert\n/'

# B — survival-gate-via-unified-injection (audit 2026-06-18, Phase 1 survivor close).
# Distinct from e2e-lifecycle-survival (which tests the merge-back clobber path via V_MERGE_BACK_OVERRIDE).
# This guard proves the SURVIVAL GATE itself (_survival_verdict in validation.sh) is reachable via
# V_VALIDATION_LIB, so a regression in the survival logic can be detected by the mutation suite.
# Mutant: _survival_verdict() immediately returns "skip:mutant" (never signals lost:*).
# Harness: v-e2e-lifecycle-test.sh Scenario C — the Stop hook must block a wrote-without-trace
# session (C/S1). With the mutant, the skip arm fires and C/S1 is NOT blocked (rc != 2, no SURVIVAL
# message) → harness goes red. C/S2 (no-false-positive control) still passes (mutant produces no
# false SURVIVAL message). V_VALIDATION_LIB is inherited by run_stop_hook (it does not strip it),
# so check-review-artifact.sh sources the mutant and the verdict is neutered end-to-end.
gate_patch "survival-gate-disabled" "$REFS/v-e2e-lifecycle-test.sh" V_VALIDATION_LIB \
     "$CDIR/hooks/lib/validation.sh" \
     's/(_survival_verdict\(\) \{  # <sid> <repo>\n)/$1  echo "skip:mutant"; return  # mutation-gate revert (survival gate disabled)\n/'

# ── Audit 2026-06-19 (P1): per-field negative fixtures for every validate_* contract. ────────────
# Survivors S-A through S-F were invisible to the suite because v-contract-audit-test.sh planted
# ONLY valid fixtures — no harness called the validators with per-field NEGATIVE inputs. A mutation
# that removes a single field-check (size floor, Overall Verdict, Model header, subsystems anchor,
# Mode:, or Status:blocked-rejection) was never caught. v-contract-negative-test.sh is the
# dedicated per-field negative harness; it honors V_VALIDATION_LIB injection so the mutation gate
# can inject a mutant validation.sh. Each guard below is the canonical "this survivor is closed" proof.

# S-A — VALIDATION_MIN_SIZE floor neutered: set the floor to 0 so 1-byte stubs pass all three
# artifact types (AGENT_REVIEW, PRE_FLIGHT_REPORT, VERIFY_DONE_REPORT).
gate_patch "contract-size-floor" "$REFS/v-contract-negative-test.sh" V_VALIDATION_LIB \
     "$CDIR/hooks/lib/validation.sh" \
     's/(?m)^VALIDATION_MIN_SIZE=\d+/VALIDATION_MIN_SIZE=0/'

# S-B — validate_verify_done_w53_contract Overall Verdict check removed: convert the echo
# message + return 1 pair into a silent return 0 so a VERIFY_DONE without an Overall Verdict
# is accepted without raising an error. E1 (2026-07-05) batched these validators' independent
# checks into per-function manifest accumulators (_vd_add/_qa_add/_im_add/_pf_add in
# hooks/lib/validation.sh) — the old `echo "<msg>"; return 1` anchors no longer exist, so S-B..S-E
# now splice the ACCUMULATOR CALL SITE instead: replace the unique `_xx_add "<msg prefix>"` call
# with an immediate `return 0`, which accepts the bad artifact at exactly the same check. The
# accumulator names are per-function (unlike the Model:-header message text, which three validators
# share), so each mutant still hits ONLY its own validator.
gate_patch "contract-verify-done-verdict" "$REFS/v-contract-negative-test.sh" V_VALIDATION_LIB \
     "$CDIR/hooks/lib/validation.sh" \
     's/_vd_add "verify-done: final non-empty line/echo "SBMUTANT"; return 0; _vd_add "XVERIFY/'

# S-C — validate_qa_report_structure Model header check removed: convert the awk Model check's
# error-accumulation into an immediate accept so a QA report without Model: in the first 5 lines
# passes. Anchor on `_qa_add` + the message prefix (unique to this validator — _ux_add/_wv_add
# carry the same message text in their own functions).
gate_patch "contract-qa-model-header" "$REFS/v-contract-negative-test.sh" V_VALIDATION_LIB \
     "$CDIR/hooks/lib/validation.sh" \
     "s|_qa_add \"missing 'Model:' header in first 5 lines\"|echo 'SCMUTANT'; return 0  # sc-revert (Model check)|"

# S-D — validate_impact_map_semantics subsystems: anchor check removed: convert the
# "missing 'subsystems:' checklist block" error-accumulation into an immediate accept so an
# IMPACT_MAP without the subsystems: anchor is accepted.
gate_patch "contract-impact-subsystems" "$REFS/v-contract-negative-test.sh" V_VALIDATION_LIB \
     "$CDIR/hooks/lib/validation.sh" \
     "s/_im_add \"missing 'subsystems:' checklist block\"/echo 'SDMUTANT'; return 0  # sd-revert (subsystems check)/"

# S-E — validate_pre_flight_w53_contract Mode: check removed: convert the unique
# "pre-flight: missing 'Mode:' line in first 12 lines" error-accumulation into an immediate
# accept so a PRE_FLIGHT without Mode: is accepted.
gate_patch "contract-preflight-mode" "$REFS/v-contract-negative-test.sh" V_VALIDATION_LIB \
     "$CDIR/hooks/lib/validation.sh" \
     "s/_pf_add \"pre-flight: missing 'Mode:' line in first 12 lines\"/echo 'SEMUTANT'; return 0  # se-revert (Mode check)/"

# S-F — validate_review_semantics Status:blocked accepted: move 'blocked' to the accepted arm
# so a review with Status: blocked is treated as a completed/pass status.
gate_patch "contract-review-status-blocked" "$REFS/v-contract-negative-test.sh" V_VALIDATION_LIB \
     "$CDIR/hooks/lib/validation.sh" \
     's/completed\|pass\|passed\|approved\)/completed|pass|passed|approved|blocked)  # sf-revert/'

# ── MIN_GUARDS floor — single-sourced HERE (audit 2026-06-18) so every way of running the gate also
#    catches registry shrinkage. The
#    floor counts ALL gate/gate_patch registrations above; deleting a guard to dodge the gate trips
#    this. Raise it whenever a guard is added; lower it ONLY for a deliberate, reviewed retirement.
MIN_GUARDS="${MIN_GUARDS:-8}"   # snapshot floor: the 8 guards above (live registry: 52)
TOTAL_GUARDS=$((PASS + FAIL))
echo "═══════════ mutation-gate: $PASS passed, $FAIL failed ═══════════"
if [ "$TOTAL_GUARDS" -lt "$MIN_GUARDS" ]; then
  echo "FAIL mutation-gate: only $TOTAL_GUARDS guards registered (< MIN_GUARDS=$MIN_GUARDS floor) —"
  echo "     the registry shrank. If a guard was legitimately retired, lower MIN_GUARDS deliberately."
  exit 1
fi
[ "$FAIL" -eq 0 ]
