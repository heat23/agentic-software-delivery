#!/usr/bin/env bash
# v-preflight-staleness-test.sh — F1 (forensic 2026-06-17, two production sessions).
#
# A concurrent batch of /v sessions shares main. Two real failures:
#   - session A: pre-flight pinned a SIBLING's BASE_SHA (another session's commit) → `git diff base..HEAD` saw
#     0 PHP → all PHP gates SKIP → reported PASS → it SHIPPED PHP its own pre-flight never executed.
#   - session B: scoped to a stale file set that EXCLUDED 2 of the real changed prod files.
# F1 adds two guards to v-run-gates.sh, exercised here against the REAL script in a throwaway git repo
# with every gate command stubbed to `true` (fast, deterministic):
#   (1) STALE-BASE: a BASE_SHA that is not an ancestor of HEAD is discarded + recomputed via merge-base.
#   (2) BLIND-SCOPE: a scoped run with 0 changed files across ALL sources is INCONCLUSIVE (Overall Status
#       FAIL + an INCONCLUSIVE Scope row), never a clean PASS. A real scoped change must still PASS (no FP).
#
# ITEM1-BASE-EQ-HEAD (2026-07-05) supersedes case (2) specifically for BASE_SHA==HEAD (the classic
# post-merge shape): instead of leaving the run scoped+blind+INCONCLUSIVE (needing a manual re-dispatch),
# v-run-gates.sh now (a) recovers the durable session-start head-baseline as the real diff base when one
# is available (BASE_SHA_FOR_DIFF gets replaced, guard logic unchanged), or (b) when no baseline is
# recoverable, escalates PFM scoped->full so gates run FOR REAL instead of silently SKIPping (self-healing
# instead of stalling on INCONCLUSIVE). Test 1 below asserts (b); test 5 asserts (a).
set -u
GATES="$HOME/.claude/skills/v/references/v-run-gates.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$GATES" ] || { echo "NO v-run-gates.sh missing"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; mkdir -p "$REPO"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
( cd "$REPO" && git init -q -b main && echo base > base.txt && git add -A && git commit -qm init ) >/dev/null 2>&1
BASE_COMMIT=$(cd "$REPO" && git rev-parse HEAD)

# Run v-run-gates.sh against $REPO with all gate commands stubbed to `true` (fast, always-pass) so the
# ONLY variable under test is the F1 scope/base logic. Returns the emitted skeleton on stdout via $SKEL.
run_gates(){  # $1=sid  $2=PRE_FLIGHT_MODE  $3=BASE_SHA(optional)
  local sid="$1" mode="$2" base="${3:-}"
  rm -rf "$REPO/.v"; mkdir -p "$REPO/.v/tmp"
  ( cd "$REPO" && env \
      SESSION_ID="$sid" V_TMP_DIR="$REPO/.v/tmp" PRE_FLIGHT_MODE="$mode" MAIN_BRANCH=main \
      ${base:+BASE_SHA="$base"} \
      TSC_CMD=true LINT_CMD=true BUILD_CMD=true PEST_CMD=true VITEST_CMD=true \
      V_RUN_GATES_TIMEOUT_SEC=120 \
      bash "$GATES" ) > "$TMP/stdout-$sid.log" 2>"$TMP/stderr-$sid.log"
  SKEL="$REPO/.v/tmp/pre-flight-skeleton-${sid}.md"
}

echo "== pre-flight staleness/blind-scope guard (F1) =="

# 1. BASE==HEAD, no recoverable head-baseline -> ITEM1 escalates scoped->full (self-healing: TSC/Pest/
#    Vitest/Lint/Build all run UNCONDITIONALLY under PFM=full elsewhere in this script — see the
#    scoped|dirty-tree vs full|* case split — so escalating actually causes gates to run for real
#    instead of the old scoped+0-file path leaving them SKIPped) rather than an unhelpful INCONCLUSIVE.
S1="11111111-aaaa-bbbb-cccc-111111111111"
run_gates "$S1" scoped "$BASE_COMMIT"
if [ -f "$SKEL" ]; then
  { grep -q 'ITEM1 — BASE_SHA_FOR_DIFF collapsed to HEAD.*auto-escalating' "$TMP/stderr-$S1.log" \
    && grep -q '^Mode: full' "$SKEL" && grep -q '^Overall Status: PASS' "$SKEL" \
    && ! grep -q 'INCONCLUSIVE | Scope' "$SKEL"; } \
    && ok "1 scoped + 0 changed files + no head-baseline -> ITEM1 escalates to full (self-healing, not a stalled INCONCLUSIVE)" \
    || no "1 base==HEAD escalation NOT applied (stderr: $(grep -i item1 "$TMP/stderr-$S1.log" | tr '\n' ' '); skeleton: $(grep -E 'Mode:|Overall Status|Scope' "$SKEL" | tr '\n' ' '))"
else no "1 no skeleton emitted (stderr: $(tail -2 "$TMP/stderr-$S1.log" | tr '\n' ' '))"; fi

# 2. NOT BLIND (FP guard): scoped mode with a REAL committed change since base → must NOT be blind, PASS.
S2="22222222-aaaa-bbbb-cccc-222222222222"
( cd "$REPO" && echo '<?php // real' > real.php && git add -A && git commit -qm realchange ) >/dev/null 2>&1
HEAD2=$(cd "$REPO" && git rev-parse HEAD)
run_gates "$S2" scoped "$BASE_COMMIT"
if [ -f "$SKEL" ]; then
  { grep -q '^Overall Status: PASS' "$SKEL" && ! grep -q 'INCONCLUSIVE | Scope' "$SKEL"; } \
    && ok "2 scoped + real change -> NOT blind (Overall Status PASS, no Scope INCONCLUSIVE)" \
    || no "2 real scoped change wrongly flagged blind/FAIL ($(grep -E 'Overall Status|Scope' "$SKEL" | tr '\n' ' '))"
else no "2 no skeleton emitted"; fi
# reset HEAD back to base so later cases start clean
( cd "$REPO" && git reset -q --hard "$BASE_COMMIT" ) >/dev/null 2>&1

# 3. STALE BASE: pass a BASE_SHA that is NOT an ancestor of HEAD (a divergent/sibling commit on another
#    branch). v-run-gates must DETECT it (stderr) and recompute via merge-base.
S3="33333333-aaaa-bbbb-cccc-333333333333"
# make a sibling commit on a divergent branch, then return to main (sibling is NOT an ancestor of main HEAD)
( cd "$REPO" && git checkout -q -b sibling && echo sib > sib.txt && git add -A && git commit -qm sibling ) >/dev/null 2>&1
SIBLING=$(cd "$REPO" && git rev-parse HEAD)
( cd "$REPO" && git checkout -q main ) >/dev/null 2>&1
run_gates "$S3" scoped "$SIBLING"
grep -q "is NOT an ancestor of HEAD" "$TMP/stderr-$S3.log" \
  && ok "3 sibling/divergent BASE_SHA -> detected + recomputed via merge-base (stale-base guard)" \
  || no "3 stale sibling base NOT detected (stderr: $(grep -i base "$TMP/stderr-$S3.log" | tr '\n' ' '))"

# 4. STALE-BASE NEGATIVE CONTROL: a LEGITIMATE ancestor base must NOT trip the stale-base recompute.
S4="44444444-aaaa-bbbb-cccc-444444444444"
run_gates "$S4" scoped "$BASE_COMMIT"   # BASE_COMMIT IS an ancestor of HEAD (main)
grep -q "is NOT an ancestor of HEAD" "$TMP/stderr-$S4.log" \
  && no "4 legit ancestor base wrongly flagged stale (false-positive)" \
  || ok "4 legit ancestor base -> no stale-base recompute (FP-safe)"

# 5. BASE==HEAD, but a durable session-start head-baseline IS recoverable and genuinely predates HEAD
#    (a real commit landed since session start) -> ITEM1 recovers it as BASE_SHA_FOR_DIFF instead of
#    escalating to full; the F1 blind-scope guard then runs the ORIGINAL (non-escalated) scoped path
#    against the recovered base and correctly finds a real change -> stays scoped, PASS, no INCONCLUSIVE.
S5="55555555-aaaa-bbbb-cccc-555555555555"
( cd "$REPO" && echo '<?php // baseline-recoverable' > recov.php && git add -A && git commit -qm recov ) >/dev/null 2>&1
HEAD5=$(cd "$REPO" && git rev-parse HEAD)
rm -rf "$REPO/.v"; mkdir -p "$REPO/.v/tmp"
printf '%s\n' "$BASE_COMMIT" > "$REPO/.v/tmp/main-head-at-start-${S5}.txt"
( cd "$REPO" && env SESSION_ID="$S5" V_TMP_DIR="$REPO/.v/tmp" PRE_FLIGHT_MODE=scoped MAIN_BRANCH=main BASE_SHA="$HEAD5" \
    TSC_CMD=true LINT_CMD=true BUILD_CMD=true PEST_CMD=true VITEST_CMD=true V_RUN_GATES_TIMEOUT_SEC=120 \
    bash "$GATES" ) > "$TMP/stdout-$S5.log" 2>"$TMP/stderr-$S5.log"
SKEL5="$REPO/.v/tmp/pre-flight-skeleton-${S5}.md"
( cd "$REPO" && git reset -q --hard "$BASE_COMMIT" ) >/dev/null 2>&1
if [ -f "$SKEL5" ]; then
  { grep -q "recovered the durable session-start head baseline" "$TMP/stderr-$S5.log" \
    && grep -q '^Mode: scoped' "$SKEL5" && grep -q '^Overall Status: PASS' "$SKEL5" \
    && ! grep -q 'INCONCLUSIVE | Scope' "$SKEL5"; } \
    && ok "5 base==HEAD + recoverable head-baseline -> BASE_SHA recovered (stays scoped, real change found, no escalation needed)" \
    || no "5 head-baseline recovery NOT applied (stderr: $(grep -i baseline "$TMP/stderr-$S5.log" | tr '\n' ' '); skeleton: $(grep -E 'Mode:|Overall Status|Scope' "$SKEL5" | tr '\n' ' '))"
else no "5 no skeleton emitted"; fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
