#!/usr/bin/env bash
# v-gauntlet-attest-source-staleness-test.sh — Item 19 regression test (2026-07-03, R1 HIGH-3 / R3 M-3).
#
# The pre-existing freshness check compares each gauntlet artifact's mtime against this
# INVOCATION'S START MARKER, so it only catches "artifact left over from a PRIOR /v invocation".
# It does NOT catch: touch a source file AFTER PRE_FLIGHT_REPORT is written, still within the SAME
# invocation — both the touch and the artifact postdate invocation start, so the marker check stays
# green while the artifact now grades a stale tree. Item 19 adds a SEPARATE check against the
# session's OWN write ledger (hooks/track-session-writes.sh's per-SID file at
# ${git_common_dir}/claude-session-writes-<sid>.txt). This test drives a real git repo + the real
# script end to end (not just an extracted awk block) since the behavior depends on git-common-dir
# resolution and real file mtimes.
set -u
# ATTEST_UNDER_TEST lets this harness be pointed at a pre-fix copy to prove its assertions are RED
# before the fix (W-ATTEST-ENUM, 2026-08-09). Defaults to the live script.
SCRIPT="${ATTEST_UNDER_TEST:-$HOME/.claude/skills/v/references/v-gauntlet-attest.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$SCRIPT" ] || { echo "NO v-gauntlet-attest.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email test@test.local 2>/dev/null
git -C "$REPO" config user.name test 2>/dev/null
echo "seed" > "$REPO/README.md"
git -C "$REPO" add -A 2>/dev/null
git -C "$REPO" commit -qm seed 2>/dev/null

SID="11111111-2222-3333-4444-555555555555"
mkdir -p "$REPO/.v/artifacts"
BODY="$(head -c 260 < /dev/zero | tr '\0' 'x')"

write_artifacts() {
  printf 'Mode: full\n%s\n' "$BODY" > "$REPO/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
  printf 'Dispatch mode: orchestrator-inline (test)\n%s\n' "$BODY" > "$REPO/.v/artifacts/AGENT_REVIEW_${SID}.md"
  printf 'Convention check\n%s\n' "$BODY" > "$REPO/.v/artifacts/VERIFY_DONE_REPORT_${SID}.md"
}

run_attest() {
  # V_VALIDATION_LIB pointed at a nonexistent path: this test targets ONLY the item-19
  # source-staleness check in isolation, not the (separately-owned, separately-tested) H4-6
  # semantic validation layer that runs before it — see v-gauntlet-attest-semantic-gate-test.sh
  # for that gate's own coverage.
  ( cd "$REPO" && PROJECT_ROOT="$REPO" GW_LIB="$HOME/.claude/hooks/lib/gauntlet-witness.sh" \
    V_VALIDATION_LIB="/nonexistent-skip-semantic-validation-for-this-test" \
    bash "$SCRIPT" "$SID" >/tmp/attest-out.$$.log 2>/tmp/attest-err.$$.log )
  echo $?
}

echo "== Item 19 :: attest staleness vs LAST SOURCE MUTATION =="

# Case 1: artifacts written, no source touch afterward -> should NOT fail on the item-19 check
# (may still fail earlier for unrelated reasons like semantic validation lib absence -- tolerate
# any rc OTHER than 8, since this test targets the NEW check specifically).
write_artifacts
mkdir -p "$REPO/.git"
GCD="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
printf 'src/app.php\n' > "$GCD/claude-session-writes-${SID}.txt"
touch -d '2020-01-01' "$REPO/src/app.php" 2>/dev/null || true
mkdir -p "$REPO/src"; echo "old" > "$REPO/src/app.php"
touch -t 202001010000 "$REPO/src/app.php" 2>/dev/null || touch -d '2020-01-01' "$REPO/src/app.php" 2>/dev/null || true

rc1="$(run_attest)"
[ "$rc1" != "8" ] \
  && ok "artifacts newer than the last tracked write ⇒ item-19 check does not fire (rc=$rc1, not 8)" \
  || no "false-positive: item-19 fired even though the artifact postdates the write" "rc=$rc1"

# Case 2: touch the tracked source file AFTER the artifacts exist -> item-19 must fire (rc=8),
# even though both postdate this invocation's start marker (simulating same-invocation re-touch).
sleep 1
echo "changed after pre-flight" >> "$REPO/src/app.php"
rc2="$(run_attest)"
[ "$rc2" = "8" ] \
  && ok "source touched AFTER artifact write ⇒ attest FAILS with rc=8 (the bite)" \
  || no "source touched after artifact write did NOT trip the staleness gate" "rc=$rc2 (expected 8) — $(cat /tmp/attest-err.$$.log 2>/dev/null | tail -5)"

# === W-ATTEST-ENUM (2026-08-09) — every stale artifact reported in ONE run =====================
#
# The loop used to `exit 8` on the FIRST stale artifact. The session re-ran that one gauntlet step,
# re-invoked attest, and was told about the NEXT one — against the SAME source file. Measured on
# the 2026-08-06..09 corpus: the witness was 30.6% of all Stop-gate violations (77 of 252) across
# 11 of 12 blocked sessions, with 24 failed attest invocations before success.
#
# WHY IT IS EXPENSIVE RATHER THAN MERELY VERBOSE: rearm_gate escapes at STOP_REARM_MAX_SAME=2
# (the 3rd identical block) and this loop can serially reject exactly 3 artifacts. A session owing
# all three refreshes therefore spends its entire deadlock budget on DISCOVERY and trips the escape
# while it is legitimately converging — 17 of 17 escapes since 2026-08-02 were followed by a
# successful attestation, shortest gap 53 seconds.
#
# All three artifacts are currently stale (case 2 left src/app.php newer than every one of them),
# so a correct implementation names all three. The count assertion is what bites: reporting only
# the first would still exit 8 and still print the header.
err="$(cat /tmp/attest-err.$$.log 2>/dev/null)"
named=0
for art in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT; do
  printf '%s' "$err" | grep -q "${art}_${SID}.md" && named=$((named+1))
done
[ "$named" -eq 3 ] \
  && ok "all 3 stale artifacts named in ONE failure (was 1 — cost a round each)" \
  || no "enumeration regressed: only $named of 3 stale artifacts named in a single run" \
        "$(printf '%s' "$err" | head -6)"

# The count must be stated, so the session knows how many steps to re-run before re-attesting.
printf '%s' "$err" | grep -qE '3 artifact\(s\) STALE' \
  && ok "failure states the stale COUNT (3)" \
  || no "failure does not state the stale count" "$(printf '%s' "$err" | head -3)"

# And it must tell the session to fix them all in one round — the whole point of enumerating.
# W-REMEDIATE-SIDECAR (2026-08-17): the exact wording changed (now points at v-remediate-stale.sh
# and its "ONE blocking Bash call" framing) but the underlying claim — batch, don't serialize — is
# the same; assert the current wording, don't weaken the check to something vaguer.
printf '%s' "$err" | grep -qE 'ONE blocking Bash call|v-remediate-stale\.sh' \
  && ok "failure instructs a single remediation round (via v-remediate-stale.sh)" \
  || no "failure omits the one-round/remediation-script instruction" "$(printf '%s' "$err" | head -8)"

# Exit code is part of the contract and must NOT have moved: this is a reporting change only.
[ "$rc2" = "8" ] \
  && ok "exit code still 8 (reporting change only, gate semantics untouched)" \
  || no "exit code changed" "rc=$rc2"

# Mutation check: prove the enumeration assertion is not vacuous. Make exactly ONE artifact stale
# and confirm the harness sees exactly one — if this reported 3, the grep above would pass no
# matter what the script did.
sleep 1
write_artifacts                       # all three artifacts now NEWER than src/app.php
sleep 1
touch "$REPO/.v/artifacts/../../src/app.php" 2>/dev/null || touch "$REPO/src/app.php"
sleep 1
printf 'Mode: full\n%s\n' "$BODY" > "$REPO/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"   # refresh ONE
rc3="$(run_attest)"
err3="$(cat /tmp/attest-err.$$.log 2>/dev/null)"
named3=0
for art in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT; do
  printf '%s' "$err3" | grep -q "${art}_${SID}.md" && named3=$((named3+1))
done
[ "$rc3" = "8" ] && [ "$named3" -eq 2 ] \
  && ok "mutation check: refreshing 1 of 3 leaves exactly 2 named (count tracks reality)" \
  || no "mutation check: expected rc=8 with 2 artifacts named" "rc=$rc3 named=$named3"

# === W-OPT-STALE (2026-08-11) — IMPACT_MAP / QA_REPORT are freshness-checked too ===============
#
# THE GAP. Every artifact loop in v-gauntlet-attest.sh iterated exactly
# PRE_FLIGHT/AGENT_REVIEW/VERIFY_DONE; IMPACT_MAP and QA_REPORT appeared NOWHERE in the script
# (`grep -cE 'IMPACT_MAP|QA_REPORT'` returned 0), and check-review-artifact.sh only ever checked
# them for PRESENCE. Measured on one long session: QA_REPORT written once on 2026-08-09 and
# IMPACT_MAP once later that day, then never rewritten while many further commits landed and the
# three core artifacts were refreshed on 2026-08-11. The structural board reported both
# "ok" throughout — so a long multi-feature session shipped under a QA acceptance and an impact
# analysis that had only ever graded its FIRST feature.
#
# WHY THE FIXTURE LOOKS LIKE THIS: the three core artifacts are deliberately made the NEWEST
# files, so the only thing that can produce rc=8 is an optional artifact. Without that isolation
# the case would pass even with the fix reverted, since the core three would be stale anyway.
echo ""
echo "== W-OPT-STALE :: IMPACT_MAP / QA_REPORT freshness =="

sleep 1
printf 'Impact analysis\n%s\n' "$BODY" > "$REPO/.v/artifacts/IMPACT_MAP_${SID}.md"
printf 'verdict: pass\n%s\n' "$BODY" > "$REPO/.v/artifacts/QA_REPORT_${SID}.md"
sleep 1
echo "source changed after the optional artifacts were written" >> "$REPO/src/app.php"
sleep 1
write_artifacts                     # core three are now the NEWEST files — they are NOT stale

rc4="$(run_attest)"
err4="$(cat /tmp/attest-err.$$.log 2>/dev/null)"
opt4=0
for art in IMPACT_MAP QA_REPORT; do
  printf '%s' "$err4" | grep -q "${art}_${SID}.md" && opt4=$((opt4+1))
done
core4=0
for art in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT; do
  printf '%s' "$err4" | grep -q "${art}_${SID}.md" && core4=$((core4+1))
done
[ "$rc4" = "8" ] && [ "$opt4" -eq 2 ] && [ "$core4" -eq 0 ] \
  && ok "IMPACT_MAP + QA_REPORT stale vs a source write ⇒ rc=8, both named, core three untouched" \
  || no "optional-artifact staleness NOT caught" \
        "rc=$rc4 optional_named=$opt4 core_named=$core4 — $(printf '%s' "$err4" | head -6)"

# FP-SAFETY. This is the assertion most likely to catch a careless implementation of the fix.
# _resolve_artifact returns a DEFAULT path when it finds nothing, and the loop's
# `[ -z "$_art_mt" ] => stale` rule would therefore mark an ABSENT optional artifact as stale —
# blocking every session that legitimately never owed an IMPACT_MAP or QA_REPORT (LIGHT tier, or
# any diff the Stop hook does not charge for them). Removing both must restore a clean run.
rm -f "$REPO/.v/artifacts/IMPACT_MAP_${SID}.md" "$REPO/.v/artifacts/QA_REPORT_${SID}.md"
sleep 1
write_artifacts
rc5="$(run_attest)"
[ "$rc5" != "8" ] \
  && ok "ABSENT IMPACT_MAP/QA_REPORT ⇒ no staleness failure (attest never invents a requirement)" \
  || no "FALSE POSITIVE: absent optional artifacts reported stale" \
        "rc=$rc5 — $(cat /tmp/attest-err.$$.log 2>/dev/null | head -6)"

# === W-NOGATE (2026-08-17) — PRE_FLIGHT is exempt from source-staleness when the repo has =======
# === no gate-bearing stack, and ONLY then ======================================================
#
# THE MEASURED WASTE. One session (2026-08-17, rooted at a non-project workspace directory)
# dispatched v-pre-flight-runner 14 times. Every run wrote a gate-summary reading
# TSC/PHPSTAN/COMPOSER_AUDIT/NPM_AUDIT/LINT/BUILD/PEST/VITEST = SKIP with
# PHASES_TOTAL_WALLCLOCK_SEC=0, because that directory has no package.json, composer.json or
# tests/ — there is no gate to run. `ALL_PASS=1` was vacuous. Six of the runs were
# byte-identical in scope (SCOPE_N=99) and verdict.
#
# SCOPE — corrected 2026-08-17 after a transcript pass; the first draft of this header overstated it.
# The item-19 loop fired 5 times in that session and twice in an orchestrator session, NOT once per
# round; the rest of the 14 dispatches came from the GAUNTLET_STALE tree-hash path and ordinary /v flow.
# It is also NOT a cost fix: the pre-flight lane was a negligible share of spend across all 15
# dispatches (Haiku). What it reclaims is round-trips and Stop-hook churn, not money.
#
# THE ARGUMENT. A gate that executes nothing cannot detect anything, so re-running pre-flight
# against a different tree cannot change its verdict. AGENT_REVIEW / VERIFY_DONE / IMPACT_MAP /
# QA_REPORT all READ THE DIFF and must stay fully staleness-bound — the exemption is PRE_FLIGHT-only.
#
# THE TWO CONDITIONS (both required — either alone is unsafe):
#   1. CORROBORATION: this SID's gate-summary exists and shows every *_RC=SKIP with
#      PHASES_TOTAL_WALLCLOCK_SEC=0. Absence of a summary is NOT evidence of absence of gates —
#      it means no runner has reported yet, so the exemption must fail CLOSED.
#   2. RE-ARM: no gate-bearing stack sentinel exists in the tree AT ATTEST TIME. A package.json
#      or composer.json appearing mid-session makes the gates real again and must instantly
#      revoke the exemption — which is why this is re-derived from the tree, never cached.
echo ""
echo "== W-NOGATE :: PRE_FLIGHT staleness exemption on a stackless repo =="

ngs_reset() {
  # Core three + a corroborating gate-summary, then a source touch that postdates all of them.
  rm -f "$REPO/.v/artifacts/IMPACT_MAP_${SID}.md" "$REPO/.v/artifacts/QA_REPORT_${SID}.md"
  rm -f "$REPO/package.json" "$REPO/composer.json" "$REPO/composer.lock" "$REPO/tsconfig.json"
  rm -rf "$REPO/vendor"
  write_artifacts
  sleep 1
  echo "doc edit after the gauntlet graded the tree" >> "$REPO/src/app.php"
}

ngs_summary() {  # $1 = extra line(s) to append, e.g. a non-SKIP RC
  { printf 'TSC_RC=SKIP\nPHPSTAN_RC=SKIP\nCOMPOSER_AUDIT_RC=SKIP\nNPM_AUDIT_RC=SKIP\n'
    printf 'LINT_RC=SKIP\nBUILD_RC=SKIP\nPEST_RC=SKIP\nVITEST_RC=SKIP\n'
    printf 'PHASES_TOTAL_WALLCLOCK_SEC=0\nMODE=scoped\n'
    [ -n "${1:-}" ] && printf '%s\n' "$1"
  } > "$REPO/.v/artifacts/gate-summary-${SID}.txt"
}

names_in_err() {  # $1 = artifact prefix -> 0 if named in the last stderr
  grep -q "${1}_${SID}.md" /tmp/attest-err.$$.log 2>/dev/null
}

# Case A — the fix. Stackless repo + corroborating all-SKIP summary: PRE_FLIGHT is exempt,
# the two diff-reading artifacts are still named, and the run still fails (rc=8) because of them.
ngs_reset
ngs_summary
rcA="$(run_attest)"
if [ "$rcA" = "8" ] && ! names_in_err PRE_FLIGHT_REPORT \
   && names_in_err AGENT_REVIEW && names_in_err VERIFY_DONE_REPORT; then
  ok "stackless repo + all-SKIP summary ⇒ PRE_FLIGHT exempt, AGENT_REVIEW/VERIFY_DONE still stale"
else
  no "PRE_FLIGHT staleness exemption did not apply as specified" \
     "rc=$rcA pre_named=$(names_in_err PRE_FLIGHT_REPORT && echo yes || echo no) — $(tail -6 /tmp/attest-err.$$.log 2>/dev/null)"
fi

# Case B — the RE-ARM guard the operator conditioned approval on. A package.json appears
# mid-session: the gates are real again, so PRE_FLIGHT must go back to being staleness-checked.
ngs_reset
ngs_summary
printf '{"name":"appeared-mid-session"}\n' > "$REPO/package.json"
rcB="$(run_attest)"
if [ "$rcB" = "8" ] && names_in_err PRE_FLIGHT_REPORT; then
  ok "package.json appears mid-session ⇒ exemption REVOKED, PRE_FLIGHT named stale again"
else
  no "stale-cache hazard: exemption survived a stack appearing mid-session" \
     "rc=$rcB pre_named=$(names_in_err PRE_FLIGHT_REPORT && echo yes || echo no)"
fi
rm -f "$REPO/package.json"

# Case B2 — same guard, PHP side (composer.json is the sentinel a Laravel repo grows first).
ngs_reset
ngs_summary
printf '{"require":{}}\n' > "$REPO/composer.json"
rcB2="$(run_attest)"
if [ "$rcB2" = "8" ] && names_in_err PRE_FLIGHT_REPORT; then
  ok "composer.json appears mid-session ⇒ exemption REVOKED (PHP sentinel honored too)"
else
  no "composer.json did not re-arm the PRE_FLIGHT staleness check" \
     "rc=$rcB2 pre_named=$(names_in_err PRE_FLIGHT_REPORT && echo yes || echo no)"
fi
rm -f "$REPO/composer.json"

# Case B3 — SENTINEL PARITY (2026-08-17 adversarial review). The re-arm guard is only as good as its
# sentinel list, and the first version of it did NOT mirror v-run-gates.sh. That script runs TSC when
# ANY of tsconfig.json / tsconfig.base.json / tsconfig.app.json exists, OR when node_modules/.bin/tsc
# is executable; and it runs npm audit off a CHANGED LOCKFILE with no package.json guard at all. A
# sentinel list carrying only tsconfig.json therefore grants the exemption to a repo whose TSC gate
# would really run — the unsafe direction (PRE_FLIGHT never re-runs, a real TSC regression goes
# ungraded). Each sentinel below is one v-run-gates.sh guard; drift here silently re-opens the hole.
#
# F1 (2026-08-29) — THIS CASE USED TO BE ONE-DIRECTIONAL AND SELF-REFERENTIAL. It iterated a
# HARDCODED 6-element list and never read v-run-gates.sh at all (grep for
# RUN_GATES|references/v-run-gates|bash .*v-run-gates exited 1 with ZERO matches; the string
# appeared only in the comments above). So it failed if a sentinel was DELETED from the attest
# list, and passed SILENTLY if v-run-gates.sh GREW a new file trigger -- the direction that caused
# the original defect, i.e. it failed UNSAFE.
#
# Two changes close that:
#   (a) the live-fire list is now DERIVED from hooks/lib/stack-sentinels.sh, the single source of
#       truth v-gauntlet-attest.sh itself consumes -- not restated here;
#   (b) case B4 below adds the MISSING DIRECTION: it extracts v-run-gates.sh's own triggers from
#       source (v-run-gates-triggers.sh) and fails on any trigger with no covering sentinel.
#
# Routine runs live-fire the historical 6 (each is a real v-run-gates.sh guard). Set
# V_ATTEST_FULL_SENTINEL_FIRE=1 to live-fire all 15 -- that is real harness runtime (a full attest
# invocation per sentinel), which is why the exhaustive sweep is opt-in rather than the default.
SENTINEL_LIB="$HOME/.claude/hooks/lib/stack-sentinels.sh"
ALL_SENTINELS=""
FIRE_LIST=""
if [ ! -f "$SENTINEL_LIB" ]; then
  no "sentinel parity: $SENTINEL_LIB missing" "cannot derive the sentinel list -- parity is UNVERIFIED, not passing"
else
  ALL_SENTINELS="$(bash -c ". '$SENTINEL_LIB'; stack_sentinel_list" 2>/dev/null)"
  n_all=$(printf '%s\n' "$ALL_SENTINELS" | grep -c . || true)
  if [ "${n_all:-0}" -lt 10 ]; then
    # A parse failure must be RED, never a silently-passing empty loop.
    no "sentinel parity: derived only ${n_all:-0} sentinels from $SENTINEL_LIB" "extractor broken -- parity UNVERIFIED"
    ALL_SENTINELS=""
  else
    ok "sentinel parity: derived $n_all sentinels from the shared lib (no hardcoded list)"
    if [ "${V_ATTEST_FULL_SENTINEL_FIRE:-0}" = "1" ]; then
      FIRE_LIST="$ALL_SENTINELS"
      echo "  --  V_ATTEST_FULL_SENTINEL_FIRE=1: live-firing all $n_all sentinels"
    else
      FIRE_LIST="$(printf '%s\n' "$ALL_SENTINELS" | grep -xE 'tsconfig\.base\.json|tsconfig\.app\.json|node_modules/\.bin/tsc|package-lock\.json|yarn\.lock|pnpm-lock\.yaml' || true)"
      echo "  --  live-firing 6 of $n_all sentinels; set V_ATTEST_FULL_SENTINEL_FIRE=1 for all $n_all"
    fi
  fi
fi
for sent in $FIRE_LIST; do
  ngs_reset
  ngs_summary
  mkdir -p "$REPO/$(dirname "$sent")" 2>/dev/null
  printf '{}\n' > "$REPO/$sent"
  [ "$sent" = "node_modules/.bin/tsc" ] && chmod +x "$REPO/$sent"
  rcS="$(run_attest)"
  if [ "$rcS" = "8" ] && names_in_err PRE_FLIGHT_REPORT; then
    ok "sentinel parity: $sent present ⇒ exemption REVOKED"
  else
    no "sentinel parity GAP: $sent does not re-arm PRE_FLIGHT staleness" \
       "rc=$rcS pre_named=$(names_in_err PRE_FLIGHT_REPORT && echo yes || echo no) — v-run-gates.sh WOULD run a gate here"
  fi
  rm -rf "${REPO:?}/$sent"
done

# Case B4 — DERIVED PARITY (F1, 2026-08-29). The missing direction: extract v-run-gates.sh's own
# file triggers FROM SOURCE and require each to be covered by a sentinel. A new gate guard added to
# v-run-gates.sh now fails HERE instead of silently widening the W-NOGATE exemption.
#
# DOCUMENTED EXCEPTIONS (a trigger that legitimately needs no sentinel of its own):
#   phpstan.neon / phpstan.neon.dist / phpstan.dist.neon -- gated behind an AND with
#     [ -x vendor/bin/phpstan ] (v-run-gates.sh ~788), and that binary IS a sentinel, so the gate
#     cannot run unless a sentinel is present.
#   vendor/bin/paratest -- never an independent trigger: both occurrences (~420, ~1116) are nested
#     INSIDE [ -x "./vendor/bin/pest" ] and only select the pest command variant. Verified by
#     reading both call sites, not assumed.
TRIG_SH="$HOME/.claude/skills/v/references/v-run-gates-triggers.sh"
RG_SRC_FOR_B5="${V_RUN_GATES_SRC:-$HOME/.claude/skills/v/references/v-run-gates.sh}"
if [ ! -f "$TRIG_SH" ]; then
  no "B4 derived parity: $TRIG_SH missing" "the run-gates side cannot be derived -- parity UNVERIFIED"
elif [ -z "$ALL_SENTINELS" ]; then
  no "B4 derived parity: sentinel list unavailable" "skipped comparison -- parity UNVERIFIED"
else
  TRIGGERS="$(bash "$TRIG_SH" 2>/dev/null)"
  trc=$?
  if [ "$trc" != "0" ]; then
    # rc 2 = extraction looked broken (too few triggers); rc 1 = source unreadable. Either way this
    # is RED: an empty/parse-failed extraction must never read as "no drift found".
    no "B4 derived parity: trigger extraction FAILED (rc=$trc)" "a silently-empty extraction would pass this case while proving nothing"
  else
    n_trig=$(printf '%s\n' "$TRIGGERS" | grep -c . || true)
    ok "B4 derived parity: extracted $n_trig file triggers from v-run-gates.sh source"
    gaps=0
    for t in $TRIGGERS; do
      printf '%s\n' "$ALL_SENTINELS" | grep -qxF "$t" && continue
      case "$t" in
        phpstan.neon|phpstan.neon.dist|phpstan.dist.neon|vendor/bin/paratest) continue ;;
      esac
      no "B4 SENTINEL DRIFT: v-run-gates.sh triggers on '$t' but no sentinel covers it" \
         "a repo carrying only '$t' would be granted the W-NOGATE exemption while its gate really runs -- add it to hooks/lib/stack-sentinels.sh"
      gaps=$((gaps+1))
    done
    [ "$gaps" -eq 0 ] && ok "B4 every v-run-gates.sh file trigger is covered by a sentinel or a documented exception" \
                      || no "B4 $gaps uncovered trigger(s)" "sentinel drift -- the exemption is wider than the gate surface"
  fi
fi

# Case B5 — SELF-VERIFYING DRIFT CHECK (close-out audit, 2026-08-29). B4 above reports "no drift"
# today. A check that has never failed proves nothing (this tree's own "verify the verifier" rule),
# and v-run-gates-triggers.sh's V_RUN_GATES_SRC seam existed for exactly this but no harness used
# it. Inject a synthetic new gate trigger into a COPY of v-run-gates.sh and require the extractor to
# surface it — so B4's green is evidence, not an assumption.
if [ -f "$TRIG_SH" ] && [ -f "$RG_SRC_FOR_B5" ]; then
  _b5_copy="$WORK/v-run-gates-MUTATED.sh"
  cp "$RG_SRC_FOR_B5" "$_b5_copy" 2>/dev/null
  printf '\nif [ -f "b5-synthetic-newgate.config" ]; then echo "new gate"; fi\n' >> "$_b5_copy"
  _b5_out="$(V_RUN_GATES_SRC="$_b5_copy" bash "$TRIG_SH" 2>/dev/null || true)"
  if printf '%s\n' "$_b5_out" | grep -qx 'b5-synthetic-newgate.config'; then
    ok "B5 self-check: an injected NEW gate trigger IS extracted (B4's drift detection actually bites)"
  else
    no "B5 self-check: injected trigger 'b5-synthetic-newgate.config' was NOT extracted" "B4 cannot detect real drift — its green means nothing"
  fi
  # ...and that the injected trigger is uncovered by the sentinel list, i.e. B4 would report it.
  if [ -n "$ALL_SENTINELS" ] && ! printf '%s\n' "$ALL_SENTINELS" | grep -qxF 'b5-synthetic-newgate.config'; then
    ok "B5b the injected trigger is covered by NO sentinel, so B4 would flag it as drift"
  else
    no "B5b could not confirm the injected trigger would be flagged" ""
  fi
else
  no "B5 self-check: cannot run" "TRIG_SH or the run-gates source is unavailable"
fi

# Case C — fail-CLOSED. No gate-summary at all means no runner has reported "nothing to run".
# Stack-absence alone must NOT buy the exemption: absence of evidence is not evidence of absence.
ngs_reset
rm -f "$REPO/.v/artifacts/gate-summary-${SID}.txt"
rcC="$(run_attest)"
if [ "$rcC" = "8" ] && names_in_err PRE_FLIGHT_REPORT; then
  ok "no gate-summary ⇒ exemption fails CLOSED (PRE_FLIGHT still staleness-checked)"
else
  no "exemption fired without corroborating evidence a runner observed no gates" \
     "rc=$rcC pre_named=$(names_in_err PRE_FLIGHT_REPORT && echo yes || echo no)"
fi

# Case D — non-vacuity. A summary carrying a REAL gate result (PEST actually ran and passed)
# describes a repo that HAS a gate surface; the exemption must not fire no matter what the tree
# looks like. Without this, any summary file whatsoever would be treated as corroboration.
ngs_reset
ngs_summary 'PEST_RC=0'
rcD="$(run_attest)"
if [ "$rcD" = "8" ] && names_in_err PRE_FLIGHT_REPORT; then
  ok "summary with a non-SKIP RC (PEST_RC=0) ⇒ exemption does not fire"
else
  no "a summary containing a real gate verdict still bought the exemption" \
     "rc=$rcD pre_named=$(names_in_err PRE_FLIGHT_REPORT && echo yes || echo no)"
fi

# Case E — the exemption must not become a blanket pass. With NOTHING stale, the run must not
# fail on item-19 at all; and with only PRE_FLIGHT stale on a stackless repo, item-19 must go
# quiet rather than exit 8 on an artifact it just exempted.
ngs_reset
ngs_summary
sleep 1
printf 'Dispatch mode: orchestrator-inline (test)\n%s\n' "$BODY" > "$REPO/.v/artifacts/AGENT_REVIEW_${SID}.md"
printf 'Convention check\n%s\n' "$BODY" > "$REPO/.v/artifacts/VERIFY_DONE_REPORT_${SID}.md"
rcE="$(run_attest)"
[ "$rcE" != "8" ] \
  && ok "only PRE_FLIGHT stale on a stackless repo ⇒ item-19 clears (no round burned)" \
  || no "item-19 still exited 8 with only the exempt artifact stale" \
        "rc=$rcE — $(tail -6 /tmp/attest-err.$$.log 2>/dev/null)"

# Case F — observability. A silently-applied exemption is how a gate quietly stops gating;
# the script must SAY it exempted PRE_FLIGHT and why.
ngs_reset
ngs_summary
run_attest >/dev/null
grep -qiE 'W-NOGATE|no gate-bearing stack|pre-?flight.*exempt' /tmp/attest-err.$$.log 2>/dev/null \
  && ok "exemption is announced on stderr (never silent)" \
  || no "exemption applied silently — no stderr note" "$(tail -4 /tmp/attest-err.$$.log 2>/dev/null)"

# === W-REMEDIATE-SIDECAR (2026-08-17) — sidecar file written on stale, from the SAME computation ===
echo "== Item 19 :: sidecar mirrors _stale_list, no second staleness computation =="
# Clear state the preceding W-NOGATE section left behind (a gate-summary file with all-SKIP RCs) —
# left in place it would exempt PRE_FLIGHT_REPORT here too via W-NOGATE, which is CORRECT behavior
# but not what this section means to exercise (genuine staleness across all 3 core artifacts).
rm -f "$REPO/.v/artifacts/gate-summary-${SID}.txt"
write_artifacts
touch -t 202001010000 "$REPO/src/app.php" 2>/dev/null || touch -d '2020-01-01' "$REPO/src/app.php"
sleep 1
echo "changed after pre-flight" >> "$REPO/src/app.php"
rcS="$(run_attest)"
SIDECAR="$REPO/.v/artifacts/GAUNTLET_STALE_LIST_${SID}.txt"
[ "$rcS" = "8" ] && [ -f "$SIDECAR" ] \
  && ok "sidecar file written on the same exit-8 staleness FAIL" \
  || no "sidecar not written on staleness FAIL" "rc=$rcS sidecar_exists=$([ -f "$SIDECAR" ] && echo yes || echo no)"
grep -qF "PRE_FLIGHT_REPORT_${SID}.md" "$SIDECAR" 2>/dev/null \
  && ok "sidecar names the actually-stale artifact by full path" \
  || no "sidecar missing the stale artifact path" "$(cat "$SIDECAR" 2>/dev/null)"
grep -q 'v-remediate-stale.sh' /tmp/attest-err.$$.log 2>/dev/null \
  && ok "FAIL message points at v-remediate-stale.sh (not the retired 'mutually independent' claim)" \
  || no "message did not name the remediation script" ""
grep -qi 'mutually independent of every other artifact in this set' /tmp/attest-err.$$.log 2>/dev/null \
  && ok "message scopes the independence claim (no longer a blanket claim over all 5)" \
  || no "message still makes an unscoped independence claim" "$(cat /tmp/attest-err.$$.log)"

rm -f /tmp/attest-out.$$.log /tmp/attest-err.$$.log 2>/dev/null

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
