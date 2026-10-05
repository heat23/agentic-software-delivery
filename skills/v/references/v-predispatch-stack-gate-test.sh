#!/usr/bin/env bash
# v-predispatch-stack-gate-test.sh — F7 harness (2026-08-29).
#
# DEFECT: v-emit-prompt.sh had NO pre-dispatch stack gate, so a tree carrying none of the 15
# gate-bearing stack sentinels still emitted a full runner prompt and the orchestrator spawned a
# v-pre-flight-runner subagent purely to learn there was nothing to run (18 such dispatches; 32
# per-gate logs with zero tool output, largest 135 bytes).
#
# FIX: source hooks/lib/stack-sentinels.sh (the SINGLE sentinel list, shared with
# v-gauntlet-attest.sh) and, when stackless, run v-run-gates.sh directly, write
# PRE_FLIGHT_REPORT_<sid>.md MECHANICALLY from its skeleton, and exit 10 with a DO-NOT-DISPATCH
# instruction on stdout instead of a dispatch prompt.
#
# RED oracle: skills/v/references/v-emit-prompt.sh.pre-fix20260829-bak — case A against it must
# exit 0 and emit a runner prompt (the defect: it dispatches into an empty tree).
#
# Contract asserted here is FAIL-CLOSED: every doubt must dispatch normally.
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

# V_F7_EMIT_UNDER_TEST lets the operator point this harness at the pre-fix .bak to PROVE it
# goes RED there (bite evidence). Default is the live script.
EMIT="${V_F7_EMIT_UNDER_TEST:-$HOME/.claude/skills/v/references/v-emit-prompt.sh}"
BAK="$HOME/.claude/skills/v/references/v-emit-prompt.sh.pre-fix20260829-bak"
SENTLIB="$HOME/.claude/hooks/lib/stack-sentinels.sh"
ATTEST="$HOME/.claude/skills/v/references/v-gauntlet-attest.sh"
SID="7f7f7f7f-1111-4111-8111-000000000f70"

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT

# mkrepo <dir> — a real git repo with a commit and NO stack sentinel of any kind.
mkrepo() {
  local d="$1"
  mkdir -p "$d" && cd "$d" || return 1
  git init -q . 2>/dev/null
  git config user.email t@t.local; git config user.name t
  printf '# doc\n' > README.md
  mkdir -p .v/tmp .v/artifacts
  git add README.md 2>/dev/null
  git commit -qm init 2>/dev/null
  cd - >/dev/null || return 1
}

# run_emit <script> <repo> -> prints "rc=<n>" then stdout, into $TD/out.txt
run_emit() {
  local script="$1" repo="$2"
  ( cd "$repo" && env -u MODE -u WORKFLOW -u DIRTY_COUNT \
      CLAUDE_SESSION_ID="$SID" SESSION_ID="$SID" \
      PROJECT_ROOT="$repo" WORKTREE_PATH="" V_TMP_DIR="$repo/.v/tmp" \
      V_ARTIFACT_DIR="$repo/.v/artifacts" \
      bash "$script" v-pre-flight ) > "$TD/out.txt" 2> "$TD/err.txt"
  echo "$?"
}

echo "== F7 :: pre-dispatch stack gate =="

# ── A. stackless tree -> NO dispatch, mechanical report, reason recorded ────────────────
R="$TD/a"; mkrepo "$R"
rc=$(run_emit "$EMIT" "$R")
REPORT="$R/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
[ "$rc" = "10" ] && ok "A1 stackless tree -> exit 10 (no dispatch)" \
                 || no "A1 expected exit 10, got '$rc' (stderr: $(head -3 "$TD/err.txt" | tr '\n' ' '))"
grep -q 'DO NOT DISPATCH' "$TD/out.txt" 2>/dev/null \
  && ok "A2 stdout carries a DO-NOT-DISPATCH instruction (not a runner prompt)" \
  || no "A2 stdout lacks the DO-NOT-DISPATCH instruction"
grep -q '^You are v-pre-flight' "$TD/out.txt" 2>/dev/null \
  && no "A3 stdout still contains the runner prompt sentinel (it would be dispatched)" \
  || ok "A3 stdout contains NO runner prompt sentinel"
[ -f "$REPORT" ] && ok "A4 PRE_FLIGHT_REPORT written at $REPORT" \
                 || no "A4 PRE_FLIGHT_REPORT missing at $REPORT"
if [ -f "$REPORT" ]; then
  grep -q 'no gate-bearing stack sentinel found' "$REPORT" \
    && ok "A5 report records the REASON" || no "A5 report does not record the reason"
  grep -q 'mechanically generated' "$REPORT" \
    && ok "A6 report is marked mechanically generated (no model prose)" || no "A6 not marked mechanical"
  # Structural contract the Stop hook validators enforce (validate_pre_flight_w53_contract):
  head -12 "$REPORT" | grep -qE '^Mode: (full|scoped|dirty-tree|user-owned-maintenance)' \
    && ok "A7 'Mode:' line present within first 12 lines (w53 contract)" \
    || no "A7 'Mode:' line missing from first 12 lines"
  last=$(awk 'NF { last=$0 } END { print last }' "$REPORT")
  echo "$last" | grep -qE '^Overall Status: (PASS|FAIL)$' \
    && ok "A8 final non-empty line is 'Overall Status: PASS|FAIL' (w53 contract)" \
    || no "A8 final non-empty line is '$last'"
  grep -qE '^##[[:space:]]+Gates' "$REPORT" \
    && ok "A9 carries the '## Gates' section header" || no "A9 missing '## Gates'"
  # Independence: no runner was dispatched, so the report MUST declare honestly or the Stop
  # hook's _independence_verdict returns 'silent' (= BLOCK) on a claimed clean pass.
  grep -qiE '^[[:space:]#>*-]*dispatch[[:space:]]+mode[[:space:]]*:[[:space:]]*(orchestrator[_-]?inline|inline|degraded|manual)' "$REPORT" \
    && ok "A10 carries an honest 'Dispatch mode:' declaration (-> declared, not silent)" \
    || no "A10 missing the honest Dispatch mode declaration"
fi
grep -q 'F7: NO DISPATCH' "$TD/err.txt" 2>/dev/null \
  && ok "A11 reason recorded on stderr" || no "A11 stderr lacks the F7 reason"

# ── A-RED. the pre-fix script dispatches into the same empty tree ───────────────────────
if [ -f "$BAK" ]; then
  R2="$TD/ared"; mkrepo "$R2"
  rc=$(run_emit "$BAK" "$R2")
  if [ "$rc" = "0" ] && grep -q '^You are v-pre-flight' "$TD/out.txt" 2>/dev/null; then
    ok "A-RED oracle: pre-fix v-emit-prompt.sh emits a runner prompt (exit 0) — the defect bites"
  else
    no "A-RED oracle: expected exit 0 + runner prompt from the backup, got rc='$rc'"
  fi
  [ -f "$R2/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md" ] \
    && no "A-RED oracle: pre-fix unexpectedly wrote a report" \
    || ok "A-RED oracle: pre-fix wrote NO report (the runner would have had to)"
else
  echo "  skip A-RED oracle — pre-fix backup not shipped in the public snapshot ($BAK)"
fi

# ── B. EACH of the 15 sentinels present -> dispatch happens normally ────────────────────
if [ ! -f "$SENTLIB" ]; then
  no "B: $SENTLIB missing — cannot enumerate sentinels"
else
  n_sent=0; n_disp=0
  while IFS= read -r sent; do
    [ -n "$sent" ] || continue
    n_sent=$((n_sent+1))
    RB="$TD/b$n_sent"; mkrepo "$RB"
    mkdir -p "$RB/$(dirname "$sent")" 2>/dev/null
    printf '{}\n' > "$RB/$sent"
    rc=$(run_emit "$EMIT" "$RB")
    if [ "$rc" = "0" ] && grep -q '^You are v-pre-flight' "$TD/out.txt" 2>/dev/null; then
      n_disp=$((n_disp+1))
    else
      no "B: sentinel '$sent' present but the gate did NOT dispatch (rc=$rc) — FAILS OPEN"
    fi
  done < <(bash -c ". '$SENTLIB'; stack_sentinel_list")
  [ "$n_sent" -eq 15 ] && ok "B1 sentinel list has 15 entries" || no "B1 expected 15 sentinels, got $n_sent"
  [ "$n_disp" -eq "$n_sent" ] && [ "$n_sent" -gt 0 ] \
    && ok "B2 all $n_sent sentinels individually force a NORMAL dispatch (never fails open)" \
    || no "B2 only $n_disp of $n_sent sentinels forced a dispatch"
fi

# ── C. helper unavailable -> dispatch happens (fail-closed) ─────────────────────────────
RC1="$TD/c"; mkrepo "$RC1"
rc=$( ( cd "$RC1" && env -u MODE -u WORKFLOW -u DIRTY_COUNT \
        CLAUDE_SESSION_ID="$SID" SESSION_ID="$SID" PROJECT_ROOT="$RC1" WORKTREE_PATH="" \
        V_TMP_DIR="$RC1/.v/tmp" V_ARTIFACT_DIR="$RC1/.v/artifacts" \
        HOOKS_LIB_DIR="$TD/nonexistent-lib-dir" \
        bash "$EMIT" v-pre-flight ) > "$TD/out.txt" 2> "$TD/err.txt"; echo $? )
{ [ "$rc" = "0" ] && grep -q '^You are v-pre-flight' "$TD/out.txt" 2>/dev/null; } \
  && ok "C1 sentinel helper unavailable -> dispatches normally (fail-closed)" \
  || no "C1 helper unavailable but rc='$rc' (must fail closed to a dispatch)"
grep -q 'stack-sentinels.sh unavailable' "$TD/err.txt" 2>/dev/null \
  && ok "C2 the fail-closed reason is on stderr" || no "C2 no fail-closed reason on stderr"

# ── C3. v-run-gates.sh unusable -> dispatch happens (fail-closed) ───────────────────────
# Simulate by pointing HOME at a shadow tree whose v-run-gates.sh is absent while the sentinel
# lib is still reachable via HOOKS_LIB_DIR.
RC3="$TD/c3"; mkrepo "$RC3"
SHADOW="$TD/shadowhome"; mkdir -p "$SHADOW/.claude/skills/v/references"
rc=$( ( cd "$RC3" && env -u MODE -u WORKFLOW -u DIRTY_COUNT \
        CLAUDE_SESSION_ID="$SID" SESSION_ID="$SID" PROJECT_ROOT="$RC3" WORKTREE_PATH="" \
        V_TMP_DIR="$RC3/.v/tmp" V_ARTIFACT_DIR="$RC3/.v/artifacts" \
        HOOKS_LIB_DIR="$HOME/.claude/hooks/lib" HOME="$SHADOW" \
        bash "$EMIT" v-pre-flight ) > "$TD/out.txt" 2> "$TD/err.txt"; echo $? )
{ [ "$rc" = "0" ] && grep -q '^You are v-pre-flight' "$TD/out.txt" 2>/dev/null; } \
  && ok "C3 v-run-gates.sh unavailable -> dispatches normally (fail-closed)" \
  || no "C3 gates runner unavailable but rc='$rc' (must fail closed to a dispatch)"

# ── D. an existing PRE_FLIGHT_REPORT is never clobbered; gate defers to a dispatch ──────
RD="$TD/d"; mkrepo "$RD"
printf 'PRE-EXISTING REAL REPORT — must not be overwritten\n' > "$RD/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
rc=$(run_emit "$EMIT" "$RD")
{ [ "$rc" = "0" ] && grep -q '^You are v-pre-flight' "$TD/out.txt" 2>/dev/null; } \
  && ok "D1 existing report -> dispatches normally (first-dispatch-only scope)" \
  || no "D1 existing report but rc='$rc'"
grep -q 'PRE-EXISTING REAL REPORT' "$RD/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md" \
  && ok "D2 the pre-existing report was NOT clobbered" || no "D2 pre-existing report was overwritten"

# ── E. opt-out honoured ─────────────────────────────────────────────────────────────────
RE="$TD/e"; mkrepo "$RE"
rc=$( ( cd "$RE" && env -u MODE -u WORKFLOW -u DIRTY_COUNT \
        CLAUDE_SESSION_ID="$SID" SESSION_ID="$SID" PROJECT_ROOT="$RE" WORKTREE_PATH="" \
        V_TMP_DIR="$RE/.v/tmp" V_ARTIFACT_DIR="$RE/.v/artifacts" V_PREDISPATCH_STACK_GATE=0 \
        bash "$EMIT" v-pre-flight ) > "$TD/out.txt" 2> "$TD/err.txt"; echo $? )
{ [ "$rc" = "0" ] && grep -q '^You are v-pre-flight' "$TD/out.txt" 2>/dev/null; } \
  && ok "E1 V_PREDISPATCH_STACK_GATE=0 forces a normal dispatch" \
  || no "E1 opt-out ignored (rc='$rc')"

# ── F. the gate is scoped to v-pre-flight only ──────────────────────────────────────────
RF="$TD/f"; mkrepo "$RF"
rc=$( ( cd "$RF" && env -u MODE -u WORKFLOW -u DIRTY_COUNT \
        CLAUDE_SESSION_ID="$SID" SESSION_ID="$SID" PROJECT_ROOT="$RF" WORKTREE_PATH="" \
        V_TMP_DIR="$RF/.v/tmp" V_ARTIFACT_DIR="$RF/.v/artifacts" \
        bash "$EMIT" v-verify-done ) > "$TD/out.txt" 2> "$TD/err.txt"; echo $? )
{ [ "$rc" = "0" ] && grep -q '^You are v-verify-done' "$TD/out.txt" 2>/dev/null; } \
  && ok "F1 v-verify-done is unaffected by the gate" || no "F1 v-verify-done rc='$rc'"

# ── G. SINGLE SOURCE: the sentinel list exists in exactly one place ─────────────────────
# Both call sites must SOURCE stack-sentinels.sh, never restate the list (this is the
# constraint that stops F7 from recreating the drift defect F1 exists to catch).
grep -q 'stack-sentinels.sh' "$ATTEST" \
  && ok "G1 v-gauntlet-attest.sh sources the shared sentinel lib" \
  || no "G1 v-gauntlet-attest.sh does not reference stack-sentinels.sh"
grep -q 'stack-sentinels.sh' "$EMIT" \
  && ok "G2 v-emit-prompt.sh sources the shared sentinel lib" \
  || no "G2 v-emit-prompt.sh does not reference stack-sentinels.sh"
# No consumer may carry its own copy: a bare sentinel literal outside the lib is drift.
# G3 was UNREACHABLE against the restatement it existed to catch (close-out audit, 2026-08-29):
# it grepped for the literal 'pnpm-lock.yaml', while the prose copy in v-gauntlet-attest.sh wrote the
# lockfiles brace-abbreviated as '{package-lock,yarn,pnpm,bun}' — so the check passed while a full
# 9-line restatement sat in the file. Count DISTINCT sentinel literals instead, derived from the lib:
# a pointer mentions a handful incidentally, a restatement carries most of the 15. Threshold 6.
dup=0
for f in "$ATTEST" "$EMIT"; do
  _n=0
  while IFS= read -r _s; do
    [ -n "$_s" ] || continue
    grep -qF "$_s" "$f" 2>/dev/null && _n=$((_n+1))
  done < <(bash -c ". '$SENTLIB'; stack_sentinel_list")
  if [ "$_n" -ge 6 ]; then
    no "G3 $f carries $_n of the 15 sentinel literals — that is a second copy of the list, not a pointer"
    dup=1
  fi
done
[ "$dup" -eq 0 ] && ok "G3 neither call site restates the sentinel list (counted sentinel literals, not one grep)"
grep -qE 'pnpm-lock\.yaml' "$SENTLIB" \
  && ok "G4 the list itself lives in stack-sentinels.sh" || no "G4 sentinel lib has no list"

# ── H. ROOT-CONFUSION ATTACKS (adversarial self-review, 2026-08-29) ─────────────────────
# The highest-severity failure available here is manufacturing a clean PASS gate artifact for a
# tree that DOES have gates. The gate consults THREE roots (RUN_ROOT, PROJECT_ROOT, MAIN_TOP) and
# a sentinel under ANY of them forces a normal dispatch. These pin that: each case puts a real
# stack in one root and an empty tree in another, and NONE may fire the gate.
HREAL="$TD/h-real"; mkrepo "$HREAL"; printf '{"name":"x"}\n' > "$HREAL/package.json"
HDEC="$TD/h-decoy";  mkrepo "$HDEC"

attack() { # <label> <cwd> <project_root> <worktree_path> <sid>
  local lbl="$1" cwd="$2" pr="$3" wt="$4" sid="$5" rc
  rc=$( ( cd "$cwd" && env -u MODE -u WORKFLOW -u DIRTY_COUNT \
            CLAUDE_SESSION_ID="$sid" SESSION_ID="$sid" PROJECT_ROOT="$pr" WORKTREE_PATH="$wt" \
            V_TMP_DIR="$pr/.v/tmp" bash "$EMIT" v-pre-flight ) >"$TD/out.txt" 2>"$TD/err.txt"; echo $? )
  if [ "$rc" = "0" ] && grep -q '^You are v-pre-flight' "$TD/out.txt" 2>/dev/null; then
    ok "H $lbl -> dispatched normally (gate refused to fire)"
  else
    no "H $lbl -> gate FIRED (rc=$rc) on a tree with a real stack — manufactured a clean PASS artifact"
  fi
  if find "$HREAL" "$HDEC" -name "PRE_FLIGHT_REPORT_${sid}.md" 2>/dev/null | grep -q .; then
    no "H $lbl -> a PRE_FLIGHT_REPORT was written despite a real stack being present"
  fi
}
attack "cwd=stacked, PROJECT_ROOT=empty"      "$HREAL" "$HDEC"  ""       "aaaa0000-1111-4111-8111-00000000000a"
attack "cwd=empty, PROJECT_ROOT=stacked"      "$HDEC"  "$HREAL" ""       "aaaa0000-1111-4111-8111-00000000000b"
attack "WORKTREE_PATH forced to empty decoy"  "$HREAL" "$HREAL" "$HDEC"  "aaaa0000-1111-4111-8111-00000000000c"

# H4 — when the gate DOES legitimately fire, the report must land in the SAME tree the gates ran
# in. A report written into tree A describing a gate run in tree B is a false attestation.
SIDH="aaaa0000-1111-4111-8111-00000000000d"
rcH=$( ( cd "$HDEC" && env -u MODE -u WORKFLOW -u DIRTY_COUNT \
           CLAUDE_SESSION_ID="$SIDH" SESSION_ID="$SIDH" PROJECT_ROOT="$HDEC" WORKTREE_PATH="" \
           V_TMP_DIR="$HDEC/.v/tmp" bash "$EMIT" v-pre-flight ) >/dev/null 2>&1; echo $? )
[ "$rcH" = "10" ] && ok "H4 genuinely stackless tree still fires (control)" || no "H4 control did not fire (rc=$rcH)"
[ -f "$HDEC/.v/artifacts/PRE_FLIGHT_REPORT_${SIDH}.md" ] \
  && ok "H4b report landed in the same tree the gates ran in" \
  || no "H4b report did not land in the tested tree"
[ -f "$HREAL/.v/artifacts/PRE_FLIGHT_REPORT_${SIDH}.md" ] \
  && no "H4c report LEAKED into the other (stacked) repo" \
  || ok "H4c nothing leaked into the unrelated stacked repo"

# H5 — the gate must also write the gate-summary W-NOGATE depends on. Without it, W-NOGATE fails
# CLOSED and attest keeps demanding a fresh PRE_FLIGHT: the exact loop F7 exists to end.
GS="$HDEC/.v/artifacts/gate-summary-${SIDH}.txt"
[ -f "$GS" ] && ok "H5 gate-summary written to .v/artifacts (W-NOGATE precondition satisfied)" \
             || no "H5 no gate-summary at $GS — W-NOGATE would fail closed and re-demand PRE_FLIGHT"
if [ -f "$GS" ]; then
  grep -qE '^[A-Z_]+_RC=' "$GS" && [ -z "$(grep -E '^[A-Z_]+_RC=' "$GS" | grep -v '=SKIP$' | head -1)" ] \
    && ok "H5b every *_RC in the summary is SKIP (W-NOGATE condition 1)" \
    || no "H5b summary carries a non-SKIP gate result"
  grep -q '^PHASES_TOTAL_WALLCLOCK_SEC=0$' "$GS" \
    && ok "H5c PHASES_TOTAL_WALLCLOCK_SEC=0 (W-NOGATE condition 2)" \
    || no "H5c wallclock is not 0"
fi

# ── I. POST-REVIEW HARDENING (adversarial review, 2026-08-29) ───────────────────────────
# I1 — ROOT CONTAINMENT (PANEL-SECURITY-001, reproduced by the reviewer as CRITICAL).
# The gate picks the tree to TEST from PROJECT_ROOT/WORKTREE_PATH but v-artifact-dir.sh picks
# WHERE TO WRITE independently (CWD-based git resolution, or $V_ARTIFACT_DIR verbatim). Unreconciled,
# that files an "Overall Status: PASS" for tree A as tree B's gate evidence.
IREAL="$TD/i-real"; mkrepo "$IREAL"
IDEC="$TD/i-decoy"; mkrepo "$IDEC"
SIDI="bbbb0000-1111-4111-8111-00000000000a"
rcI=$( ( cd "$IREAL" && env -u MODE -u WORKFLOW -u DIRTY_COUNT \
           CLAUDE_SESSION_ID="$SIDI" SESSION_ID="$SIDI" PROJECT_ROOT="$IDEC" WORKTREE_PATH="$IDEC" \
           V_TMP_DIR="$IDEC/.v/tmp" V_ARTIFACT_DIR="$IREAL/.v/artifacts" \
           bash "$EMIT" v-pre-flight ) >"$TD/out.txt" 2>"$TD/err.txt"; echo $? )
{ [ "$rcI" = "0" ] && grep -q '^You are v-pre-flight' "$TD/out.txt" 2>/dev/null; } \
  && ok "I1 artifact dir outside the tested tree -> dispatches normally (fail-closed)" \
  || no "I1 rc='$rcI' — a verdict may have been filed for a tree it does not describe"
[ -f "$IREAL/.v/artifacts/PRE_FLIGHT_REPORT_${SIDI}.md" ] \
  && no "I1b a PASS report was filed into a project whose tree was never tested" \
  || ok "I1b no report filed outside the tested tree"
grep -q 'OUTSIDE every tree this gate tested' "$TD/err.txt" 2>/dev/null \
  && ok "I1c the containment refusal is explained on stderr" || no "I1c no containment message on stderr"

# I2 — IFS POISONING (PANEL-SECURITY-004). Word-splitting the sentinel list must not be steerable
# from outside; with IFS='' the whole list collapses to one word and the predicate reports "no
# stack" on a tree that visibly contains package.json — fail-OPEN for the W-NOGATE exemption.
IFSD="$TD/i-ifs"; mkdir -p "$IFSD"; printf '{}\n' > "$IFSD/package.json"
r=$(bash -c 'export IFS=""; . "'"$SENTLIB"'"; stack_has_gate_bearing_stack "'"$IFSD"'" && echo STACK || echo NONE')
[ "$r" = "STACK" ] && ok "I2 poisoned IFS cannot hide a real stack (list split is IFS-pinned)" \
                   || no "I2 IFS='' made the predicate report '$r' — the sentinel list collapsed"
r=$(bash -c 'export IFS=""; . "'"$SENTLIB"'"; stack_sentinel_list | grep -c .')
[ "$r" = "15" ] && ok "I2b stack_sentinel_list still yields 15 entries under a poisoned IFS" \
                || no "I2b list yielded $r entries under IFS=''"

# I3 — DISPATCHER REFUSAL (PANEL-CORRECTNESS-001). The documented consumer check is
# `[ -s "$DISPATCH_FILE" ]`, which PASSES for the exit-10 notice because it writes to stdout — so
# the runner would be dispatched with the DO-NOT-DISPATCH banner as its task, and --mode capture
# could overwrite the correct report. v-dispatch-subagent.sh must refuse that prompt file outright.
DISP="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
IR="$TD/i-run"; mkrepo "$IR"
SIDJ="bbbb0000-1111-4111-8111-00000000000b"
( cd "$IR" && env -u MODE -u WORKFLOW -u DIRTY_COUNT CLAUDE_SESSION_ID="$SIDJ" SESSION_ID="$SIDJ" \
    PROJECT_ROOT="$IR" WORKTREE_PATH="" V_TMP_DIR="$IR/.v/tmp" \
    bash "$EMIT" v-pre-flight ) > "$TD/notice.txt" 2>/dev/null
if [ -s "$TD/notice.txt" ] && grep -q 'DO NOT DISPATCH' "$TD/notice.txt"; then
  ok "I3 exit-10 notice is non-empty (so the documented [ -s ] check would NOT have aborted)"
  rcD=$( bash "$DISP" --agent v-pre-flight-runner --prompt-file "$TD/notice.txt" \
           --artifact "$IR/.v/artifacts/PRE_FLIGHT_REPORT_${SIDJ}.md" --mode capture >/dev/null 2>"$TD/derr.txt"; echo $? )
  [ "$rcD" = "3" ] && ok "I3b v-dispatch-subagent.sh REFUSES the F7 notice as a prompt (exit 3)" \
                   || no "I3b dispatcher accepted the DO-NOT-DISPATCH notice as a runner prompt (rc=$rcD)"
  grep -q 'F7 DO-NOT-DISPATCH notice' "$TD/derr.txt" 2>/dev/null \
    && ok "I3c refusal names the cause" || no "I3c refusal message missing"
else
  no "I3 could not produce an exit-10 notice fixture"
fi

# I4 — the documented consumer contract must now branch on the EXIT CODE, not on file size.
VD="$HOME/.claude/skills/v/references/v-verbatim-dispatch.md"
grep -q '_emit_rc' "$VD" 2>/dev/null && grep -q '10)' "$VD" 2>/dev/null \
  && ok "I4 v-verbatim-dispatch.md branches on the helper exit code incl. an explicit 10) arm" \
  || no "I4 v-verbatim-dispatch.md still relies on [ -s ] alone — exit 10 would dispatch the runner"
# Wording-independent on purpose: an earlier version grepped the exact phrase "Exit 10 is SUCCESS"
# and broke the moment SKILL.md was compressed to "Exit 10 = SUCCESS" for its token ratchet. Assert
# the CONTRACT (exit 10 named, and named as a success), not one phrasing of it.
if grep -qiE 'exit 10[^.]{0,20}(=|is)[[:space:]]*\*{0,2}SUCCESS' "$HOME/.claude/skills/v/SKILL.md" 2>/dev/null; then
  ok "I4b SKILL.md documents exit 10 as success, not failure"
else
  no "I4b SKILL.md does not document exit 10 as a success outcome"
fi

# I5 — CONFIG-DIR LEAK-GUARD (close-out audit, 2026-08-29). Containment alone is insufficient when
# the tested tree IS the config dir: v-artifact-dir.sh honors $V_ARTIFACT_DIR verbatim, bypassing its
# own strict-descendant snap, so a skill-source path under the config dir passes containment. That is
# the documented leak class (114 stray files over 8 weeks). Build a FAKE stackless config dir so this
# is testable regardless of whether the real ~/.claude happens to carry a lockfile.
CFG="$TD/fakecfg"; mkdir -p "$CFG/skills/v/references/.v/artifacts" "$CFG/.v/tmp"
( cd "$CFG" && git init -q . 2>/dev/null; echo x > R.md ) >/dev/null 2>&1
SIDL="aaaa0000-1111-4111-8111-00000000000e"
rcL=$( ( cd "$CFG/skills/v/references" && env -u MODE -u WORKFLOW -u DIRTY_COUNT -u PROJECT_ROOT \
           CLAUDE_CONFIG_DIR="$CFG" CLAUDE_SESSION_ID="$SIDL" SESSION_ID="$SIDL" WORKTREE_PATH="" \
           V_ARTIFACT_DIR="$CFG/skills/v/references/.v/artifacts" V_TMP_DIR="$CFG/.v/tmp" \
           bash "$EMIT" v-pre-flight ) >"$TD/out.txt" 2>"$TD/err.txt"; echo $? )
grep -q 'source subdirectory of the config dir' "$TD/err.txt" 2>/dev/null \
  && ok "I5 artifact dir inside a config-dir SOURCE subtree is refused (LEAK-GUARD)" \
  || no "I5 leak-guard did not fire (rc=$rcL) — a gate verdict could be nested in a skill source tree"
find "$CFG/skills" -name "PRE_FLIGHT_REPORT_*" 2>/dev/null | grep -q . \
  && no "I5b a report was written INTO the skill source tree" \
  || ok "I5b nothing written into the config-dir source tree"
# And the legitimate case must still work: the config dir's OWN .v/artifacts is allowed.
SIDM="aaaa0000-1111-4111-8111-00000000000f"
rcM=$( ( cd "$CFG" && env -u MODE -u WORKFLOW -u DIRTY_COUNT -u PROJECT_ROOT \
           CLAUDE_CONFIG_DIR="$CFG" CLAUDE_SESSION_ID="$SIDM" SESSION_ID="$SIDM" WORKTREE_PATH="" \
           V_ARTIFACT_DIR="$CFG/.v/artifacts" V_TMP_DIR="$CFG/.v/tmp" \
           bash "$EMIT" v-pre-flight ) >/dev/null 2>&1; echo $? )
[ "$rcM" = "10" ] && [ -f "$CFG/.v/artifacts/PRE_FLIGHT_REPORT_${SIDM}.md" ] \
  && ok "I5c the config dir's OWN .v/artifacts is still allowed (guard is not over-broad)" \
  || no "I5c legitimate config-dir artifact write was blocked (rc=$rcM) — guard is over-broad"

echo; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
