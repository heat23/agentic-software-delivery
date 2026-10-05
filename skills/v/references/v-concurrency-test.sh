#!/usr/bin/env bash
# v-concurrency-test.sh — regression harness for the W-conc-fix concurrency hardening.
#
# Runs the REAL v-merge-back.sh against a throwaway git repo with two worktrees that
# made OVERLAPPING and NON-OVERLAPPING edits, and asserts:
#   T1  overlapping CODE file → second merge-back ESCALATES (exit!=0 + WORKTREE_HANDOFF),
#       and the first session's change is NOT silently lost (lost-update guard).
#   T2  non-overlapping       → second merge-back SUCCEEDS and emits
#       MERGE_BACK_REVERIFY_REQUIRED=1 (main advanced since fork → combined re-verify).
#
# This replaces "validate on your next run" for the merge-back path. Re-run anytime:
#   bash ~/.claude/skills/v/references/v-concurrency-test.sh
# Exit 0 = all assertions passed.

set -u
# W-GATE (P0-batch 2026-06-04): this suite tests merge-back CONCURRENCY mechanics (locks,
# conflict resolution, ownership) with synthetic worktrees that carry no gauntlet artifacts.
# The artifact-presence merge precondition is covered by its OWN suite
# (v-merge-artifact-gate-test.sh) — skip it here so every fixture doesn't need fake artifacts.
export V_MERGE_BACK_SKIP_ARTIFACT_GATE=1
# V_MERGE_BACK_OVERRIDE: point the harness at a different v-merge-back.sh (the mutation gate uses this
# to run a pre-fix mutant against the LIVE siblings/locks — hermetic, no live file is touched).
MB="${V_MERGE_BACK_OVERRIDE:-$HOME/.claude/skills/v/references/v-merge-back.sh}"
SL="$HOME/.claude/skills/v/references/v-suite-lock.sh"
# Per-invocation fixture root (P0.3 determinism fix, audit 2026-06-18): the fixtures used to live at
# FIXED paths ($CONC_BASE/tNN). When two instances of THIS harness run concurrently — the mutation gate
# runs it as both the merge-back-fnd3-defer CONTROL and the mutant, and the vitest wrapper can run it
# in parallel — they shared $CONC_BASE/t13 etc., so the suite-lock tests (T13–T15) acquired/released a
# lock in a directory another instance was simultaneously `rm -rf`-ing and re-creating, and the
# bulk-dirty T18d shared its repo too → non-deterministic CONTROL failures ("does NOT pass on live
# code") under clean-env load. Namespacing every fixture under a unique mktemp root makes each
# invocation hermetic; no assertion logic changes. Cleaned up on exit.
CONC_BASE="$(mktemp -d "${TMPDIR:-/tmp}/conc-run.XXXXXX")"
trap 'rm -rf "$CONC_BASE" 2>/dev/null' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

mk_repo() {  # $1=dir
  local d="$1"; rm -rf "$d"; mkdir -p "$d"; cd "$d" || return 1
  git init -q; git config user.email t@t.local; git config user.name t
  printf 'line1\nline2\nline3\n' > app.php
  printf 'other1\n' > other.php
  git add -A; git commit -qm init
  mkdir -p .v/tmp
}

writes_log() {  # $1=repo $2=sid $3=file  — mark file as session-owned
  printf '%s\n' "$3" > "$1/.v/tmp/session-writes-$2.txt"
}

echo "═══════════ T1: overlapping code file → escalate, no lost update ═══════════"
R=$CONC_BASE/t1
mk_repo "$R" || { echo "setup failed"; exit 1; }
SIDA="aaaaaaaa-1111-2222-3333-444444444444"
SIDB="bbbbbbbb-1111-2222-3333-444444444444"
git -C "$R" worktree add -q "$R/.worktrees/a" -b "build/a-$SIDA" HEAD
git -C "$R" worktree add -q "$R/.worktrees/b" -b "build/b-$SIDB" HEAD
# Both edit the SAME line (line2) of app.php → real overlap
printf 'line1\nAAA_from_session_A\nline3\n' > "$R/.worktrees/a/app.php"
git -C "$R/.worktrees/a" commit -qam "A edits line2"
printf 'line1\nBBB_from_session_B\nline3\n' > "$R/.worktrees/b/app.php"
git -C "$R/.worktrees/b" commit -qam "B edits line2"
writes_log "$R" "$SIDA" "app.php"
writes_log "$R" "$SIDB" "app.php"

cd "$R"
V_TMP_DIR="$R/.v/tmp" REPO_ROOT="$R" bash "$MB" "$SIDA" "$R/.worktrees/a" >$CONC_BASE/t1-a.out 2>&1
RC_A=$?
[ $RC_A -eq 0 ] && ok "A merges cleanly (rc=0)" || no "A should merge cleanly (rc=$RC_A)"
grep -q "AAA_from_session_A" "$R/app.php" && ok "main has A's change after A merge" || no "main missing A's change"

V_TMP_DIR="$R/.v/tmp" REPO_ROOT="$R" bash "$MB" "$SIDB" "$R/.worktrees/b" >$CONC_BASE/t1-b.out 2>&1
RC_B=$?
[ $RC_B -ne 0 ] && ok "B merge ESCALATES on overlap (rc=$RC_B != 0)" || no "B should escalate, not silently merge (rc=$RC_B)"
# Artifact relocation Phase 2 (2026-07-06): v-merge-back.sh writes WORKTREE_HANDOFF to
# $REPO_ROOT/.v/artifacts/ first, falling back to repo root only when mkdir fails — accept both.
{ [ -f "$R/.v/artifacts/WORKTREE_HANDOFF_$SIDB.md" ] || [ -f "$R/WORKTREE_HANDOFF_$SIDB.md" ]; } && ok "B wrote WORKTREE_HANDOFF (surfaced for resolution)" || no "B should write WORKTREE_HANDOFF"
# CRITICAL: A's change must survive — B must NOT have silently overwritten app.php on main
grep -q "AAA_from_session_A" "$R/app.php" && ok "LOST-UPDATE GUARD: A's change preserved (B did NOT silently win)" || no "A's change was LOST (silent overwrite!)"

echo ""
echo "═══════════ T2: non-overlapping → succeed + reverify signal ═══════════"
R2=$CONC_BASE/t2
mk_repo "$R2" || { echo "setup failed"; exit 1; }
SIDC="cccccccc-1111-2222-3333-444444444444"
SIDD="dddddddd-1111-2222-3333-444444444444"
# Both worktrees fork off ORIGINAL main (before either merges) so D sees main advance
git -C "$R2" worktree add -q "$R2/.worktrees/c" -b "build/c-$SIDC" HEAD
git -C "$R2" worktree add -q "$R2/.worktrees/d" -b "build/d-$SIDD" HEAD
printf 'other1\nC_added\n' > "$R2/.worktrees/c/other.php"   # C edits other.php
git -C "$R2/.worktrees/c" commit -qam "C edits other.php"
printf 'line1\nline2\nD_added\n' > "$R2/.worktrees/d/app.php"  # D edits app.php (different file)
git -C "$R2/.worktrees/d" commit -qam "D edits app.php"
writes_log "$R2" "$SIDC" "other.php"
writes_log "$R2" "$SIDD" "app.php"

cd "$R2"
V_TMP_DIR="$R2/.v/tmp" REPO_ROOT="$R2" bash "$MB" "$SIDC" "$R2/.worktrees/c" >$CONC_BASE/t2-c.out 2>&1
RC_C=$?
[ $RC_C -eq 0 ] && ok "C merges cleanly (rc=0)" || no "C should merge cleanly (rc=$RC_C)"
# D forked before C merged → main advanced → expect success + reverify signal
V_TMP_DIR="$R2/.v/tmp" REPO_ROOT="$R2" bash "$MB" "$SIDD" "$R2/.worktrees/d" >$CONC_BASE/t2-d.out 2>&1
RC_D=$?
[ $RC_D -eq 0 ] && ok "D merges cleanly (non-overlap, rc=0)" || no "D should merge cleanly (rc=$RC_D)"
grep -q "^MERGE_BACK_REVERIFY_REQUIRED=1" $CONC_BASE/t2-d.out && ok "D emits MERGE_BACK_REVERIFY_REQUIRED (main advanced → combined re-verify)" || no "D should signal reverify (main advanced)"
grep -q "C_added" "$R2/other.php" && grep -q "D_added" "$R2/app.php" && ok "both C and D changes present on main" || no "combined main missing a change"

echo ""
echo "═══════════ T3: worktree merge-back BLOCKS while an inline-on-main sibling is active ═══════════"
R3=$CONC_BASE/t3
mk_repo "$R3" || { echo "setup failed"; exit 1; }
SIDW="eeeeeeee-1111-2222-3333-444444444444"   # worktree session
SIDI="ffffffff-1111-2222-3333-444444444444"   # active inline-on-main sibling
git -C "$R3" worktree add -q "$R3/.worktrees/w" -b "build/w-$SIDW" HEAD
printf 'line1\nWT_change\nline3\n' > "$R3/.worktrees/w/app.php"; git -C "$R3/.worktrees/w" commit -qam w
printf '%s %s\n' "$SIDI" "$(date +%s)" > "$R3/.v/tmp/inline-main-lock-$SIDI"   # sibling editing main
cd "$R3"
V_TMP_DIR="$R3/.v/tmp" REPO_ROOT="$R3" bash "$MB" "$SIDW" "$R3/.worktrees/w" >$CONC_BASE/t3.out 2>&1
RC_W=$?
[ $RC_W -ne 0 ] && ok "merge-back BLOCKS with active inline sibling (rc=$RC_W != 0)" || no "should block (rc=$RC_W)"
{ [ -f "$R3/.v/artifacts/WORKTREE_HANDOFF_$SIDW.md" ] || [ -f "$R3/WORKTREE_HANDOFF_$SIDW.md" ]; } && ok "handoff written (deferred, not tangled)" || no "should write handoff"
grep -q "WT_change" "$R3/app.php" 2>/dev/null && no "main was clobbered (inline session's work at risk!)" || ok "main untouched — inline session protected"
# control: clear the inline lock → merge-back now succeeds
rm -f "$R3/.v/tmp/inline-main-lock-$SIDI" "$R3/WORKTREE_HANDOFF_$SIDW.md" "$R3/.v/artifacts/WORKTREE_HANDOFF_$SIDW.md"
V_TMP_DIR="$R3/.v/tmp" REPO_ROOT="$R3" bash "$MB" "$SIDW" "$R3/.worktrees/w" >$CONC_BASE/t3b.out 2>&1
grep -q "WT_change" "$R3/app.php" 2>/dev/null && ok "merge-back succeeds once inline lock cleared" || no "should merge after lock cleared"

echo ""
echo "═══════════ T4: dependency-recover — main NOT advanced → NOT_APPLICABLE ═══════════"
DR="$HOME/.claude/skills/v/references/v-dependency-recover.sh"
R4=$CONC_BASE/t4
mk_repo "$R4" || { echo "setup failed"; exit 1; }
SID4="44444444-1111-2222-3333-444444444444"
git -C "$R4" worktree add -q "$R4/.worktrees/b" -b "build/b-$SID4" HEAD
printf 'line1\nline2\nB_only\n' > "$R4/.worktrees/b/app.php"; git -C "$R4/.worktrees/b" commit -qam "B change"
# main untouched since fork → not a dependency situation
DR4=$(bash "$DR" "$R4" "$R4/.worktrees/b" "build/b-$SID4" auto "$SID4" 2>&1)
echo "$DR4" | grep -q '^DEP_RECOVER=NOT_APPLICABLE' && ok "main not advanced → NOT_APPLICABLE" || { no "expected NOT_APPLICABLE"; echo "$DR4"; }

echo ""
echo "═══════════ T5: dependency-recover — main advanced + no active sibling → rebase → RETRY_GATES ═══════════"
R5=$CONC_BASE/t5
mk_repo "$R5" || { echo "setup failed"; exit 1; }
SID5="55555555-1111-2222-3333-444444444444"
git -C "$R5" worktree add -q "$R5/.worktrees/b" -b "build/b-$SID5" HEAD   # B forks @ C0
printf 'other1\nB_added\n' > "$R5/.worktrees/b/other.php"; git -C "$R5/.worktrees/b" commit -qam "B edits other.php"
# Sibling A merged a NON-overlapping change to main (app.php) after B forked → main advances, lock gone
printf 'line1\nline2\nA_added\n' > "$R5/app.php"; git -C "$R5" commit -qam "A merged to main"
DR5=$(bash "$DR" "$R5" "$R5/.worktrees/b" "build/b-$SID5" auto "$SID5" 2>&1)
echo "$DR5" | grep -q '^DEP_RECOVER=RETRY_GATES' && ok "main advanced, no sibling → RETRY_GATES" || { no "expected RETRY_GATES"; echo "$DR5"; }
grep -q "A_added" "$R5/.worktrees/b/app.php" 2>/dev/null && ok "B rebased onto updated main (has A's change)" || no "B should contain A's merged change after rebase"

echo ""
echo "═══════════ T6: dependency-recover — sibling never clears + tiny timeout → BLOCKED ═══════════"
R6=$CONC_BASE/t6
mk_repo "$R6" || { echo "setup failed"; exit 1; }
SID6="66666666-1111-2222-3333-444444444444"
SIB6="aaaa6666-1111-2222-3333-444444444444"
git -C "$R6" worktree add -q "$R6/.worktrees/b" -b "build/b-$SID6" HEAD
printf 'other1\nB_added\n' > "$R6/.worktrees/b/other.php"; git -C "$R6/.worktrees/b" commit -qam "B"
printf 'line1\nline2\nA_added\n' > "$R6/app.php"; git -C "$R6" commit -qam "main advanced"   # main advanced
mkdir -p "$R6/.worktrees/sib"; printf '%s %s %s\n' "$SIB6" "$$" "$(date +%s)" > "$R6/.worktrees/sib/.claude-session-lock"  # sibling stays active
DR6=$(DEP_POLL_INTERVAL=1 DEP_POLL_TIMEOUT=2 bash "$DR" "$R6" "$R6/.worktrees/b" "build/b-$SID6" auto "$SID6" 2>&1)
echo "$DR6" | grep -q '^DEP_RECOVER=BLOCKED' && ok "sibling never clears + timeout → BLOCKED" || { no "expected BLOCKED (timeout)"; echo "$DR6"; }
echo "$DR6" | grep -qi 'poll timeout' && ok "BLOCKED reason cites poll timeout (bounded, no deadlock)" || no "BLOCKED should cite poll timeout"

echo ""
echo "═══════════ T7: dependency-recover — main advanced with SAME-region change → rebase conflict → BLOCKED ═══════════"
R7=$CONC_BASE/t7
mk_repo "$R7" || { echo "setup failed"; exit 1; }
SID7="77777777-1111-2222-3333-444444444444"
git -C "$R7" worktree add -q "$R7/.worktrees/b" -b "build/b-$SID7" HEAD
printf 'line1\nB_edits_line2\nline3\n' > "$R7/.worktrees/b/app.php"; git -C "$R7/.worktrees/b" commit -qam "B edits line2"
printf 'line1\nMAIN_edits_line2\nline3\n' > "$R7/app.php"; git -C "$R7" commit -qam "main edits same line2"  # overlap
DR7=$(bash "$DR" "$R7" "$R7/.worktrees/b" "build/b-$SID7" auto "$SID7" 2>&1)
echo "$DR7" | grep -q '^DEP_RECOVER=BLOCKED' && ok "rebase conflict (code overlap) → BLOCKED" || { no "expected BLOCKED (rebase conflict)"; echo "$DR7"; }
# rebase must be aborted cleanly (no dangling rebase state in the worktree)
[ ! -d "$R7/.worktrees/b/.git/rebase-merge" ] && [ ! -d "$(git -C "$R7" rev-parse --git-common-dir)/worktrees/b/rebase-merge" ] && ok "rebase aborted cleanly (no dangling rebase state)" || no "rebase state left dangling after BLOCKED"

echo ""
echo "═══════════ T8: universal-worktree — no inline-on-main code path remains in SKILL.md ═══════════"
SKILL="$HOME/.claude/skills/v/SKILL.md"
grep -qE '^\s*STAGED_INTENT=' "$SKILL" && no "STAGED_INTENT= assignment still present (inline path not deleted)" || ok "no STAGED_INTENT= assignment in SKILL.md"
grep -qE 'inline-main-lock-\$\{?SESSION_ID' "$SKILL" && no "inline-main-lock WRITE still present in SKILL.md" || ok "no inline-main-lock write path in SKILL.md"
# Behavioral (not syntax-coupled): v-active-siblings must report worktree locks but NOT inline locks.
AS="$HOME/.claude/skills/v/references/v-active-siblings.sh"
R8=$CONC_BASE/t8; mk_repo "$R8" >/dev/null 2>&1
WT_SID="8888wt00-1111-2222-3333-444444444444"; IN_SID="8888in00-1111-2222-3333-444444444444"
mkdir -p "$R8/.worktrees/x" "$R8/.v/tmp"
printf '%s %s\n' "$WT_SID" "$(date +%s)" > "$R8/.worktrees/x/.claude-session-lock"
printf '%s %s\n' "$IN_SID" "$(date +%s)" > "$R8/.v/tmp/inline-main-lock-$IN_SID"
AS_OUT=$(bash "$AS" "$R8" "selfselfself" 2>/dev/null)
echo "$AS_OUT" | grep -q "$WT_SID" && ok "v-active-siblings reports the active worktree sibling" || no "should report worktree sibling"
echo "$AS_OUT" | grep -q "$IN_SID" && no "v-active-siblings still reports inline-main-lock (should be worktree-only)" || ok "v-active-siblings does NOT report inline-main-lock (worktree-only)"
rm -rf "$R8"

echo ""
echo "═══════════ T9: merge-lock stale-expiry — crashed session's lock is stolen, merge proceeds ═══════════"
R9=$CONC_BASE/t9
mk_repo "$R9" || { echo "setup failed"; exit 1; }
SID9="99999999-1111-2222-3333-444444444444"
git -C "$R9" worktree add -q "$R9/.worktrees/w" -b "build/w-$SID9" HEAD
printf 'line1\nline2\nW_added\n' > "$R9/.worktrees/w/app.php"; git -C "$R9/.worktrees/w" commit -qam w
writes_log "$R9" "$SID9" "app.php"
# Simulate a crashed session's leftover lock, with an OLD mtime (> LOCK_STALE 600s). merge-back uses
# flock where it exists (Linux) and an mkdir mutex elsewhere (macOS); plant the state its path reads.
if command -v flock >/dev/null 2>&1; then
  : > "$R9/.worktrees/.merge-lock"; touch -t 202001010000 "$R9/.worktrees/.merge-lock"
else
  mkdir -p "$R9/.worktrees/.merge-lock.d"; printf 'deadbeef 12345 1\n' > "$R9/.worktrees/.merge-lock.d/owner"
  touch -t 202001010000 "$R9/.worktrees/.merge-lock.d"   # ancient → stale
fi
cd "$R9"
_t9_start=$(date +%s)
MB_OUT=$(V_TMP_DIR="$R9/.v/tmp" REPO_ROOT="$R9" bash "$MB" "$SID9" "$R9/.worktrees/w" 2>&1)
if command -v flock >/dev/null 2>&1; then
  # The kernel releases a dead holder's flock, so there is nothing to steal: the merge must simply not
  # wait out the 120s lock timeout.
  [ $(( $(date +%s) - _t9_start )) -lt 60 ] && ok "stale flock lock file did not block the merge (flock path)" \
    || { no "should not wait on a stale flock lock file"; echo "$MB_OUT" | tail -3; }
else
  echo "$MB_OUT" | grep -qi 'stale merge-lock' && ok "stale merge-lock detected + stolen" || { no "should detect+steal stale lock"; echo "$MB_OUT" | tail -3; }
fi
grep -q "W_added" "$R9/app.php" 2>/dev/null && ok "merge proceeded after stealing stale lock" || no "merge should proceed once stale lock stolen"

echo ""
echo "═══════════ T10: merge-back tolerates the untracked .claude-session-lock (no false 'uncommitted' fail) ═══════════"
R10=$CONC_BASE/t10
mk_repo "$R10" || { echo "setup failed"; exit 1; }
SID10="aaaa1010-1111-2222-3333-444444444444"
git -C "$R10" worktree add -q "$R10/.worktrees/w" -b "build/w-$SID10" HEAD
printf 'line1\nline2\nW_added\n' > "$R10/.worktrees/w/app.php"; git -C "$R10/.worktrees/w" commit -qam w
printf '%s %s\n' "$SID10" "$(date +%s)" > "$R10/.worktrees/w/.claude-session-lock"  # real worktrees carry this untracked lock
writes_log "$R10" "$SID10" "app.php"
cd "$R10"
MB10=$(V_TMP_DIR="$R10/.v/tmp" REPO_ROOT="$R10" bash "$MB" "$SID10" "$R10/.worktrees/w" 2>&1); RC10=$?
[ $RC10 -eq 0 ] && ok "merge-back succeeds with only the session-lock untracked (rc=0)" || { no "lock falsely treated as uncommitted (rc=$RC10)"; echo "$MB10" | tail -3; }
grep -q "W_added" "$R10/app.php" 2>/dev/null && ok "change merged to main despite lock present" || no "merge did not land"

echo ""
echo "═══════════ T11: dependency-recover checkpoints UNCOMMITTED worktree work before rebase (lock not committed) ═══════════"
R11=$CONC_BASE/t11
mk_repo "$R11" || { echo "setup failed"; exit 1; }
SID11="aaaa1111-1111-2222-3333-444444444444"
git -C "$R11" worktree add -q "$R11/.worktrees/b" -b "build/b-$SID11" HEAD   # B forks @ C0
printf 'other1\nB_uncommitted\n' > "$R11/.worktrees/b/other.php"            # B modifies a TRACKED file but does NOT commit
printf '%s %s\n' "$SID11" "$(date +%s)" > "$R11/.worktrees/b/.claude-session-lock"  # untracked lock present
printf 'line1\nline2\nA_added\n' > "$R11/app.php"; git -C "$R11" commit -qam "A merged to main"  # main advances (different file)
DR11=$(bash "$DR" "$R11" "$R11/.worktrees/b" "build/b-$SID11" auto "$SID11" 2>&1)
echo "$DR11" | grep -q '^DEP_RECOVER=RETRY_GATES' && ok "uncommitted work checkpointed + rebased → RETRY_GATES" || { no "expected RETRY_GATES with uncommitted work"; echo "$DR11"; }
grep -q "A_added" "$R11/.worktrees/b/app.php" 2>/dev/null && ok "B worktree has A's merged change after rebase" || no "B missing A's change"
grep -q "B_uncommitted" "$R11/.worktrees/b/other.php" 2>/dev/null && ok "B's previously-uncommitted work preserved (checkpointed)" || no "B's uncommitted work lost"
git -C "$R11/.worktrees/b" ls-files --error-unmatch .claude-session-lock >/dev/null 2>&1 && no "session-lock was wrongly committed" || ok "session-lock NOT committed (excluded from checkpoint)"

echo ""
echo "═══════════ T12: dependency-recover — sibling active but main NEVER advances → timeout → NOT_APPLICABLE (no false BLOCKED) ═══════════"
R12=$CONC_BASE/t12
mk_repo "$R12" || { echo "setup failed"; exit 1; }
SID12="aaaa1212-1111-2222-3333-444444444444"
SIB12="bbbb1212-1111-2222-3333-444444444444"
git -C "$R12" worktree add -q "$R12/.worktrees/b" -b "build/b-$SID12" HEAD   # B forks @ C0
printf 'other1\nB_added\n' > "$R12/.worktrees/b/other.php"; git -C "$R12/.worktrees/b" commit -qam "B (own bug, no dependency)"
# A sibling is active but main is NEVER advanced (the sibling is independent / its gates also failed)
mkdir -p "$R12/.worktrees/sib"; printf '%s %s %s\n' "$SIB12" "$$" "$(date +%s)" > "$R12/.worktrees/sib/.claude-session-lock"
DR12=$(DEP_POLL_INTERVAL=1 DEP_POLL_TIMEOUT=2 bash "$DR" "$R12" "$R12/.worktrees/b" "build/b-$SID12" auto "$SID12" 2>&1)
echo "$DR12" | grep -q '^DEP_RECOVER=NOT_APPLICABLE' && ok "independent sibling + main-never-advanced → NOT_APPLICABLE (falls through to fix loop, not false BLOCKED)" || { no "expected NOT_APPLICABLE, not BLOCKED"; echo "$DR12" | grep '^DEP_RECOVER'; }

echo ""
echo "═══════════ T13: suite-lock — concurrent full suites serialize (2nd waits for 1st) ═══════════"
R13=$CONC_BASE/t13
mk_repo "$R13" || { echo "setup failed"; exit 1; }
bash "$SL" acquire "$R13" sid13a 30 60 >/dev/null                       # session 1 holds
( sleep 3; bash "$SL" release "$R13" sid13a >/dev/null 2>&1 ) &         # release after 3s
_t0=$(date +%s)
OUT13=$(bash "$SL" acquire "$R13" sid13b 90 60)                         # session 2 must wait (90s timeout: load-tolerant — under a saturated CI/parallel-vitest machine the 3s background release can lag; the assertion below still requires it actually WAITED >=2s then acquired, so a wider timeout never weakens the serialization check, it only removes the false-red flake)
_dt=$(( $(date +%s) - _t0 ))
{ [ "$OUT13" = "SUITE_LOCK=acquired" ] && [ "$_dt" -ge 2 ]; } && ok "2nd full suite waited ${_dt}s for 1st, then acquired (serialized)" || no "expected serialized acquire, got '$OUT13' after ${_dt}s"
bash "$SL" release "$R13" sid13b >/dev/null

echo ""
echo "═══════════ T14: suite-lock — owner-checked release + fail-open timeout ═══════════"
R14=$CONC_BASE/t14
mk_repo "$R14" || { echo "setup failed"; exit 1; }
bash "$SL" acquire "$R14" owner14 30 999 >/dev/null
NR=$(bash "$SL" release "$R14" intruder14)
{ echo "$NR" | grep -q 'not-owner-skip-release' && [ -d "$R14/.worktrees/.suite-lock.d" ]; } && ok "non-owner release refused; lock survived (no cross-session steal)" || no "owner-check failed: $NR"
OUT14=$(bash "$SL" acquire "$R14" late14 2 999); RC14=$?                # owner still holds → waiter fails open
case "$OUT14" in *timeout-proceeding*) [ "$RC14" -eq 0 ] && ok "held lock → waiter fails open (timeout-proceeding, exit 0, never blocks gate)" || no "fail-open wrong rc=$RC14";; *) no "expected timeout-proceeding, got $OUT14";; esac
bash "$SL" release "$R14" owner14 >/dev/null

echo ""
echo "═══════════ T15: suite-lock — stale (dead holder) stolen; V_NO_SUITE_LOCK opt-out ═══════════"
R15=$CONC_BASE/t15
mk_repo "$R15" || { echo "setup failed"; exit 1; }
bash "$SL" acquire "$R15" dead15 30 999 >/dev/null
touch -t 202001010000 "$R15/.worktrees/.suite-lock.d" 2>/dev/null      # make the held lock look ancient
OUT15=$(bash "$SL" acquire "$R15" fresh15 5 1)                         # stale=1s → steal the dead lock
[ "$OUT15" = "SUITE_LOCK=acquired" ] && ok "stale lock (presumed-dead holder) stolen by fresh waiter" || no "stale-steal failed: $OUT15"
bash "$SL" release "$R15" fresh15 >/dev/null
OUT15b=$(V_NO_SUITE_LOCK=1 bash "$SL" acquire "$R15" x15 5 5)
[ "$OUT15b" = "SUITE_LOCK=disabled" ] && ok "V_NO_SUITE_LOCK=1 opt-out honored (no lock taken)" || no "opt-out failed: $OUT15b"

echo ""
echo "═══════════ T16: merge-back guard accepts 8-char SHORT prefix (real orchestrator naming) ═══════════"
# 2026-05-26: the orchestrator names worktree branches `<type>/<slug>-<short8>` (8-char SID
# prefix), but v-completion.md passes the FULL UUID to v-merge-back.sh. The old guard required
# the full UUID as a branch substring → ALWAYS failed → orchestrator fell back to a MANUAL,
# UNLOCKED `git merge`, bypassing merge-lock serialization. Guard now also
# accepts the 8-char prefix. (All prior harness tests use full-UUID branches, so they never
# exercised this real-world path — hence this dedicated case.)
R16=$CONC_BASE/t16
mk_repo "$R16" || { echo "setup failed"; exit 1; }
SID16="0a0a0a0a-1111-4111-8111-00000000c004"
DB16=$(git -C "$R16" symbolic-ref --short HEAD)
git -C "$R16" worktree add -q "$R16/.worktrees/w" -b "build/feature-${SID16:0:8}" HEAD
printf 'other1\nT16_added\n' > "$R16/.worktrees/w/other.php"; git -C "$R16/.worktrees/w" commit -qam "wt change"
O16=$(CLAUDE_MAIN_BRANCH="$DB16" V_TMP_DIR="$R16/.v/tmp" REPO_ROOT="$R16" bash "$MB" "$SID16" "$R16/.worktrees/w" 2>&1); RC16=$?
{ [ "$RC16" -eq 0 ] && grep -q "T16_added" "$R16/other.php"; } && ok "short-prefix branch passes guard + merges (no manual-unlocked-merge fallback)" || { no "short-prefix merge failed (rc=$RC16)"; echo "$O16" | grep -i 'session' | head -1; }
git -C "$R16" worktree add -q "$R16/.worktrees/x" -b "build/foo-cafebabe" HEAD
printf 'x\n' > "$R16/.worktrees/x/other.php"; git -C "$R16/.worktrees/x" commit -qam "foreign change"
O16b=$(CLAUDE_MAIN_BRANCH="$DB16" V_TMP_DIR="$R16/.v/tmp" REPO_ROOT="$R16" bash "$MB" "$SID16" "$R16/.worktrees/x" 2>&1); RC16b=$?
{ [ "$RC16b" -eq 2 ] && echo "$O16b" | grep -q "does not contain SESSION_ID"; } && ok "foreign-prefix branch still REJECTED (exit 2) — anti-clobber preserved" || no "foreign branch not rejected (rc=$RC16b)"

echo ""
echo "═══════════ T17: FND-1b stash-drop reliability + FND-2 foreign-WIP witness (forensic 2026-06-15) ═══════════"
# A worktree session merges while main carries FOREIGN uncommitted WIP — a concurrent no-isolation
# sibling editing shared main (a data-loss class seen in a production session). Asserts:
#   (1) the foreign WIP is RESTORED after the merge (apply works);
#   (2) FND-1b: the auto-stash is actually DROPPED. The old `git stash drop <sha>` errored
#       ('not a stash reference') under the `||`, so every auto-stash leaked. Net
#       stash count must return to baseline.
#   (3) FND-2: a durable witness names the stashed foreign file + recoverable stash SHA;
#   (4) FND-2 NEGATIVE: artifact-only dirty main writes NO witness (no false-positive noise).
R17=$CONC_BASE/t17
mk_repo "$R17" || { echo "setup failed"; exit 1; }
SID17="abcdef01-1111-2222-3333-444455556666"
DB17=$(git -C "$R17" symbolic-ref --short HEAD)
git -C "$R17" worktree add -q "$R17/.worktrees/w" -b "build/feature-${SID17:0:8}" HEAD
printf 'line1\nline2\nline3\nWT_app_change\n' > "$R17/.worktrees/w/app.php"; git -C "$R17/.worktrees/w" commit -qam "wt app change"
# A PRE-EXISTING UNRELATED stash must survive (FND-1b index-shift): the auto-stash drop must resolve
# its OWN sha to the shifted index, never blindly drop stash@{0}.
printf 'extra\n' > "$R17/extra.txt"; git -C "$R17" add extra.txt; git -C "$R17" commit -qm "add extra"
printf 'extra\nUNRELATED_pre_stash\n' > "$R17/extra.txt"
git -C "$R17" stash push -m "pre-existing-unrelated-stash" -- extra.txt >/dev/null 2>&1
# Foreign no-isolation sibling WIP on main (tracked file, uncommitted, NON-overlapping with worktree):
printf 'other1\nFOREIGN_sibling_wip\n' > "$R17/other.php"
STASHES_BEFORE=$(git -C "$R17" stash list | wc -l | tr -d ' ')   # == 1 (the unrelated stash)
O17=$(CLAUDE_MAIN_BRANCH="$DB17" V_TMP_DIR="$R17/.v/tmp" REPO_ROOT="$R17" bash "$MB" "$SID17" "$R17/.worktrees/w" 2>&1); RC17=$?
STASHES_AFTER=$(git -C "$R17" stash list | wc -l | tr -d ' ')
{ [ "$RC17" -eq 0 ] && grep -q "WT_app_change" "$R17/app.php"; } && ok "T17: worktree change merged to main (rc=0)" || no "T17: merge failed (rc=$RC17)"
grep -q "FOREIGN_sibling_wip" "$R17/other.php" && ok "T17: foreign sibling WIP RESTORED after merge" || no "T17: foreign WIP LOST (not restored!)"
[ "$STASHES_AFTER" -eq "$STASHES_BEFORE" ] && ok "T17/FND-1b: auto-stash DROPPED — no leak (before=$STASHES_BEFORE after=$STASHES_AFTER)" || no "T17/FND-1b: stash LEAKED (before=$STASHES_BEFORE after=$STASHES_AFTER — drop-by-SHA failed)"
git -C "$R17" stash list | grep -q "pre-existing-unrelated-stash" && ok "T17/FND-1b index-shift: pre-existing unrelated stash SURVIVED (drop resolved own SHA, not blind stash@{0})" || no "T17/FND-1b index-shift: unrelated stash was WRONGLY dropped"
WIT="$R17/.v/tmp/main-wip-stashed-$SID17.md"
{ [ -f "$WIT" ] && grep -q "other.php" "$WIT" && grep -q "stash_sha:" "$WIT"; } && ok "T17/FND-2: durable foreign-WIP witness written (names file + recoverable stash SHA)" || no "T17/FND-2: witness missing/incomplete"
echo "$O17" | grep -q "FND-2" && ok "T17/FND-2: loud WARN emitted on merge output" || no "T17/FND-2: no loud WARN"
# CODEX-001: foreign UNTRACKED new file must also be witnessed. The auto-stash --include-untracked
# captures it; a tracked-only ^1..W scan misses it (a sibling's NEW test file was untracked).
R17c=$CONC_BASE/t17c
mk_repo "$R17c" || { echo "setup failed"; exit 1; }
SID17c="abcdef03-1111-2222-3333-444455556666"
DB17c=$(git -C "$R17c" symbolic-ref --short HEAD)
git -C "$R17c" worktree add -q "$R17c/.worktrees/w" -b "build/feature-${SID17c:0:8}" HEAD
printf 'line1\nline2\nline3\nWT_app_change\n' > "$R17c/.worktrees/w/app.php"; git -C "$R17c/.worktrees/w" commit -qam "wt change"
printf '<?php // brand new sibling file\n' > "$R17c/NewSiblingService.php"   # UNTRACKED foreign file
O17c=$(CLAUDE_MAIN_BRANCH="$DB17c" V_TMP_DIR="$R17c/.v/tmp" REPO_ROOT="$R17c" bash "$MB" "$SID17c" "$R17c/.worktrees/w" 2>&1)
WITc="$R17c/.v/tmp/main-wip-stashed-$SID17c.md"
{ [ -f "$WITc" ] && grep -q "NewSiblingService.php" "$WITc"; } && ok "T17/CODEX-001: UNTRACKED foreign file witnessed (^3 scan)" || no "T17/CODEX-001: untracked foreign file MISSED (no ^3 scan)"
grep -q "brand new sibling file" "$R17c/NewSiblingService.php" 2>/dev/null && ok "T17/CODEX-001: untracked foreign file restored after merge" || no "T17/CODEX-001: untracked foreign file lost"
# CODEX-002: a real source file whose name resembles an artifact prefix but has a CODE extension
# (monthly_REPORT.php) must be WITNESSED — the doc-extension anchor must not exclude it.
R17d=$CONC_BASE/t17d
mk_repo "$R17d" || { echo "setup failed"; exit 1; }
SID17d="abcdef04-1111-2222-3333-444455556666"
DB17d=$(git -C "$R17d" symbolic-ref --short HEAD)
git -C "$R17d" worktree add -q "$R17d/.worktrees/w" -b "build/feature-${SID17d:0:8}" HEAD
printf 'line1\nline2\nline3\nWT_app_change\n' > "$R17d/.worktrees/w/app.php"; git -C "$R17d/.worktrees/w" commit -qam "wt change"
mkdir -p "$R17d/app/Services"; printf '<?php // r1\n' > "$R17d/app/Services/monthly_REPORT.php"
git -C "$R17d" add app/Services/monthly_REPORT.php; git -C "$R17d" commit -qm "add report-named source"
printf '<?php // r2 foreign edit\n' > "$R17d/app/Services/monthly_REPORT.php"   # tracked foreign WIP
O17d=$(CLAUDE_MAIN_BRANCH="$DB17d" V_TMP_DIR="$R17d/.v/tmp" REPO_ROOT="$R17d" bash "$MB" "$SID17d" "$R17d/.worktrees/w" 2>&1)
WITd="$R17d/.v/tmp/main-wip-stashed-$SID17d.md"
{ [ -f "$WITd" ] && grep -q "monthly_REPORT.php" "$WITd"; } && ok "T17/CODEX-002: artifact-NAMED source (.php) witnessed — doc-ext anchor not over-broad" || no "T17/CODEX-002: real source wrongly EXCLUDED (over-broad regex)"
# CODEX cycle-2: TRACKED-ONLY foreign WIP (no untracked → stash has NO ^3 parent) — the production
# case (.v/ + .worktrees/ gitignored). Guards the `ls-tree ^3 2>/dev/null` degradation: if the
# `2>/dev/null` were ever removed, ^3's "not a valid object" would surface and break detection.
R17e=$CONC_BASE/t17e
mk_repo "$R17e" || { echo "setup failed"; exit 1; }
SID17e="abcdef05-1111-2222-3333-444455556666"
DB17e=$(git -C "$R17e" symbolic-ref --short HEAD)
printf '.v/\n.worktrees/\n' > "$R17e/.gitignore"; git -C "$R17e" add .gitignore; git -C "$R17e" commit -qm "gitignore infra (matches prod)"
git -C "$R17e" worktree add -q "$R17e/.worktrees/w" -b "build/feature-${SID17e:0:8}" HEAD
printf 'line1\nline2\nline3\nWT_app_change\n' > "$R17e/.worktrees/w/app.php"; git -C "$R17e/.worktrees/w" commit -qam "wt change"
printf 'other1\nFOREIGN_tracked_only\n' > "$R17e/other.php"   # ONLY a tracked modification, no untracked
STASHES_BEFORE_E=$(git -C "$R17e" stash list | wc -l | tr -d ' ')
O17e=$(CLAUDE_MAIN_BRANCH="$DB17e" V_TMP_DIR="$R17e/.v/tmp" REPO_ROOT="$R17e" bash "$MB" "$SID17e" "$R17e/.worktrees/w" 2>&1); RC17e=$?
STASHES_AFTER_E=$(git -C "$R17e" stash list | wc -l | tr -d ' ')
WITe="$R17e/.v/tmp/main-wip-stashed-$SID17e.md"
{ [ "$RC17e" -eq 0 ] && grep -q "FOREIGN_tracked_only" "$R17e/other.php"; } && ok "T17/cycle2: tracked-only (no-^3) merge ok + WIP restored (degrades safely)" || no "T17/cycle2: tracked-only path failed (rc=$RC17e — ^3 error surfaced?)"
{ [ -f "$WITe" ] && grep -q "other.php" "$WITe"; } && ok "T17/cycle2: tracked-only foreign WIP witnessed (no spurious ^3 error)" || no "T17/cycle2: tracked-only witness missing"
[ "$STASHES_AFTER_E" -eq "$STASHES_BEFORE_E" ] && ok "T17/cycle2: no stash leak on tracked-only path" || no "T17/cycle2: stash leaked (before=$STASHES_BEFORE_E after=$STASHES_AFTER_E)"
# NEGATIVE: artifact-only dirty main → no witness (exclusion grep covers .v/ + *_REPORT etc.)
R17b=$CONC_BASE/t17b
mk_repo "$R17b" || { echo "setup failed"; exit 1; }
SID17b="abcdef02-1111-2222-3333-444455556666"
DB17b=$(git -C "$R17b" symbolic-ref --short HEAD)
git -C "$R17b" worktree add -q "$R17b/.worktrees/w" -b "build/feature-${SID17b:0:8}" HEAD
printf 'line1\nline2\nline3\nWT_app_change\n' > "$R17b/.worktrees/w/app.php"; git -C "$R17b/.worktrees/w" commit -qam "wt change"
printf 'old\n' > "$R17b/PRE_FLIGHT_REPORT_x.md"; git -C "$R17b" add PRE_FLIGHT_REPORT_x.md; git -C "$R17b" commit -qm "add report"
printf 'changed\n' >> "$R17b/PRE_FLIGHT_REPORT_x.md"   # dirty ARTIFACT only (no source WIP)
CLAUDE_MAIN_BRANCH="$DB17b" V_TMP_DIR="$R17b/.v/tmp" REPO_ROOT="$R17b" bash "$MB" "$SID17b" "$R17b/.worktrees/w" >$CONC_BASE/t17b.out 2>&1
[ ! -f "$R17b/.v/tmp/main-wip-stashed-$SID17b.md" ] && ok "T17/FND-2 NEG: artifact-only dirty main writes NO witness (no false-positive)" || no "T17/FND-2 NEG: false-positive witness on artifact-only dirty"

echo "═══════════ T18: FND-3 — DEFER (not stash-over) when foreign main WIP + active sibling (forensic 2026-06-15) ═══════════"
# Full PREVENTION of that data-loss class: when main carries a concurrent sibling's uncommitted
# SOURCE WIP AND a /v sibling session is active, the merge-back must DEFER (exit 3) and leave that WIP
# UNTOUCHED — never stash over it (that is where wave churn orphans it). The solo-user case (no active
# sibling) MUST still auto-stash transparently (UX-FND-4) — proven by T18b below + all of T17.

# T18a: foreign source WIP + ACTIVE sibling worktree lock → DEFER (exit 3); nothing stashed or merged.
R18=$CONC_BASE/t18
mk_repo "$R18" || { echo "setup failed"; exit 1; }
SID18="abcdef11-1111-2222-3333-444455556666"
SIB18="abcdef99-9999-8888-7777-666655554444"
DB18=$(git -C "$R18" symbolic-ref --short HEAD)
git -C "$R18" worktree add -q "$R18/.worktrees/w" -b "build/feature-${SID18:0:8}" HEAD
printf 'line1\nline2\nline3\nWT_app_change\n' > "$R18/.worktrees/w/app.php"; git -C "$R18/.worktrees/w" commit -qam "wt app change"
# ACTIVE sibling worktree lock (different SID, fresh mtime) — the wave signal v-active-siblings.sh sees:
mkdir -p "$R18/.worktrees/sib"; printf '%s %s %s\n' "$SIB18" "$$" "$(date +%s)" > "$R18/.worktrees/sib/.claude-session-lock"
# Foreign no-isolation sibling WIP on main (tracked source, uncommitted, NON-overlapping):
printf 'other1\nFOREIGN_sibling_wip\n' > "$R18/other.php"
# FND3-ORPHAN escape (2026-07-04): the defer now fires only when the WIP is write-ledger-CLAIMED
# by a LIVE sibling — unclaimed WIP is user-owned (UX-FND-4) and auto-stashes through. Claim it.
printf 'other.php\n' > "$R18/.git/claude-session-writes-$SIB18.txt"
STASHES_BEFORE18=$(git -C "$R18" stash list | wc -l | tr -d ' ')
O18=$(CLAUDE_MAIN_BRANCH="$DB18" V_TMP_DIR="$R18/.v/tmp" REPO_ROOT="$R18" bash "$MB" "$SID18" "$R18/.worktrees/w" 2>&1); RC18=$?
STASHES_AFTER18=$(git -C "$R18" stash list | wc -l | tr -d ' ')
WIT18="$R18/.v/tmp/merge-deferred-$SID18.md"
[ "$RC18" -eq 3 ] && ok "T18a/FND-3: merge-back DEFERS (exit 3) on foreign WIP + active sibling" || no "T18a/FND-3: expected exit 3, got $RC18"
[ "$STASHES_AFTER18" -eq "$STASHES_BEFORE18" ] && ok "T18a/FND-3: nothing stashed — sibling WIP untouched (before=$STASHES_BEFORE18 after=$STASHES_AFTER18)" || no "T18a/FND-3: a stash was created (before=$STASHES_BEFORE18 after=$STASHES_AFTER18)"
{ grep -q "FOREIGN_sibling_wip" "$R18/other.php" && [ -n "$(git -C "$R18" status --porcelain other.php)" ]; } && ok "T18a/FND-3: foreign WIP left in place + still uncommitted on main" || no "T18a/FND-3: foreign WIP was moved/committed/stashed"
grep -q "WT_app_change" "$R18/app.php" 2>/dev/null && no "T18a/FND-3: worktree was MERGED despite defer (app.php advanced)" || ok "T18a/FND-3: worktree NOT merged (deferred cleanly, main unchanged)"
{ [ -f "$WIT18" ] && grep -q "other.php" "$WIT18" && grep -q "$SIB18" "$WIT18"; } && ok "T18a/FND-3: defer witness names the foreign file + the active sibling SID" || no "T18a/FND-3: defer witness missing/incomplete"
echo "$O18" | grep -qi "DEFERRED" && ok "T18a/FND-3: loud DEFERRED warning emitted on output" || no "T18a/FND-3: no DEFERRED warning"
git -C "$R18" worktree list --porcelain 2>/dev/null | grep -q "/.worktrees/w" && ok "T18a/FND-3: worktree INTACT after defer (retryable)" || no "T18a/FND-3: worktree was removed on defer"

# T18b: SOLO USER (UX-FND-4) — foreign source WIP on main but NO active sibling → must NOT defer;
# auto-stash + merge proceeds exactly as before (exit 0, WIP restored, NO defer witness).
R18b=$CONC_BASE/t18b
mk_repo "$R18b" || { echo "setup failed"; exit 1; }
SID18b="abcdef12-1111-2222-3333-444455556666"
DB18b=$(git -C "$R18b" symbolic-ref --short HEAD)
git -C "$R18b" worktree add -q "$R18b/.worktrees/w" -b "build/feature-${SID18b:0:8}" HEAD
printf 'line1\nline2\nline3\nWT_app_change\n' > "$R18b/.worktrees/w/app.php"; git -C "$R18b/.worktrees/w" commit -qam "wt change"
printf 'other1\nUSER_OWN_wip\n' > "$R18b/other.php"   # the user's OWN uncommitted main WIP, no sibling active
O18b=$(CLAUDE_MAIN_BRANCH="$DB18b" V_TMP_DIR="$R18b/.v/tmp" REPO_ROOT="$R18b" bash "$MB" "$SID18b" "$R18b/.worktrees/w" 2>&1); RC18b=$?
{ [ "$RC18b" -eq 0 ] && grep -q "WT_app_change" "$R18b/app.php" && grep -q "USER_OWN_wip" "$R18b/other.php"; } && ok "T18b/FND-3 NEG: solo user (no sibling) still auto-stashes + merges (UX-FND-4 intact, rc=0)" || no "T18b/FND-3 NEG: solo path broke (rc=$RC18b — false defer?)"
[ ! -f "$R18b/.v/tmp/merge-deferred-$SID18b.md" ] && ok "T18b/FND-3 NEG: NO defer witness for solo user (no false-block)" || no "T18b/FND-3 NEG: false defer witness written for solo user"

# T18c: artifact-only dirty main + ACTIVE sibling → must NOT defer (foreign SOURCE WIP is empty after
# the doc/artifact exclusion); a stray gate-artifact during a wave must not block every merge.
R18c=$CONC_BASE/t18c
mk_repo "$R18c" || { echo "setup failed"; exit 1; }
SID18c="abcdef13-1111-2222-3333-444455556666"
SIB18c="abcdef98-9999-8888-7777-666655554444"
DB18c=$(git -C "$R18c" symbolic-ref --short HEAD)
git -C "$R18c" worktree add -q "$R18c/.worktrees/w" -b "build/feature-${SID18c:0:8}" HEAD
printf 'line1\nline2\nline3\nWT_app_change\n' > "$R18c/.worktrees/w/app.php"; git -C "$R18c/.worktrees/w" commit -qam "wt change"
mkdir -p "$R18c/.worktrees/sib"; printf '%s %s %s\n' "$SIB18c" "$$" "$(date +%s)" > "$R18c/.worktrees/sib/.claude-session-lock"  # sibling active
printf 'old\n' > "$R18c/PRE_FLIGHT_REPORT_x.md"; git -C "$R18c" add PRE_FLIGHT_REPORT_x.md; git -C "$R18c" commit -qm "add report"
printf 'changed\n' >> "$R18c/PRE_FLIGHT_REPORT_x.md"   # ONLY an excluded artifact is dirty (no source WIP)
O18c=$(CLAUDE_MAIN_BRANCH="$DB18c" V_TMP_DIR="$R18c/.v/tmp" REPO_ROOT="$R18c" bash "$MB" "$SID18c" "$R18c/.worktrees/w" 2>&1); RC18c=$?
{ [ "$RC18c" -eq 0 ] && grep -q "WT_app_change" "$R18c/app.php"; } && ok "T18c/FND-3 NEG: artifact-only dirty + sibling does NOT defer (excluded paths gate the defer, rc=0)" || no "T18c/FND-3 NEG: false defer on artifact-only dirty (rc=$RC18c)"
[ ! -f "$R18c/.v/tmp/merge-deferred-$SID18c.md" ] && ok "T18c/FND-3 NEG: NO defer witness when only artifacts are dirty" || no "T18c/FND-3 NEG: false defer witness on artifact-only dirty"

# T18d (MED-1, codex 2026-06-15): BULK dirty main must not abort the merge-back. The old
# `git status --porcelain | head -1` SIGPIPE-aborted git (rc 141) under `set -euo pipefail` when main
# carried thousands of dirty paths; the fix captures porcelain ONCE (no head pipe) + reuses it for the
# FND-3 scan. This exercises the bulk-porcelain capture/extraction path (many lines) end-to-end: the
# defer must still fire cleanly (exit 3), not abort with a SIGPIPE/other rc.
R18d=$CONC_BASE/t18d
mk_repo "$R18d" || { echo "setup failed"; exit 1; }
SID18d="abcdef14-1111-2222-3333-444455556666"
SIB18d="abcdef97-9999-8888-7777-666655554444"
DB18d=$(git -C "$R18d" symbolic-ref --short HEAD)
git -C "$R18d" worktree add -q "$R18d/.worktrees/w" -b "build/feature-${SID18d:0:8}" HEAD
printf 'line1\nline2\nline3\nWT_app_change\n' > "$R18d/.worktrees/w/app.php"; git -C "$R18d/.worktrees/w" commit -qam "wt change"
mkdir -p "$R18d/.worktrees/sib"; printf '%s %s %s\n' "$SIB18d" "$$" "$(date +%s)" > "$R18d/.worktrees/sib/.claude-session-lock"  # sibling active
# Bulk foreign WIP: 600 untracked source files (a no-isolation sibling that churned a generated tree).
for i in $(seq 1 600); do printf 'x\n' > "$R18d/bulk_foreign_$i.php"; done
# FND3-ORPHAN escape (2026-07-04): one live-sibling write-ledger claim is required for the defer.
printf 'bulk_foreign_1.php\n' > "$R18d/.git/claude-session-writes-$SIB18d.txt"
O18d=$(CLAUDE_MAIN_BRANCH="$DB18d" V_TMP_DIR="$R18d/.v/tmp" REPO_ROOT="$R18d" bash "$MB" "$SID18d" "$R18d/.worktrees/w" 2>&1); RC18d=$?
{ [ "$RC18d" -eq 3 ] && echo "$O18d" | grep -qi "DEFERRED"; } && ok "T18d/MED-1: bulk-dirty main (600 files) defers cleanly (exit 3, no SIGPIPE/abort)" || no "T18d/MED-1: bulk-dirty merge-back rc=$RC18d (expected 3 — head-pipe SIGPIPE regression?)"
grep -q "WT_app_change" "$R18d/app.php" 2>/dev/null && no "T18d/MED-1: worktree merged despite bulk-dirty defer" || ok "T18d/MED-1: bulk-dirty defer left main unmerged (intact)"

# T18e (B-1, forensic 2026-06-15): a P2 session-log QUARANTINE artifact (`<x>.yaml` → `<x>.yaml.invalid`)
# left UNTRACKED on main must NOT count as foreign source WIP. Before B-1 the trailing `.invalid` defeated
# the `\.(ext)$` exclusion anchor, so a persisting quarantine file DEFERRED every merge-back during a wave
# (observed in production sessions — orchestrators named "a stale .invalid log"). The
# `(\.invalid)?` tail on _FND_EXCLUDE_RE now excludes it; this is the regression lock.
R18e=$CONC_BASE/t18e
mk_repo "$R18e" || { echo "setup failed"; exit 1; }
SID18e="abcdef15-1111-2222-3333-444455556666"
SIB18e="abcdef96-9999-8888-7777-666655554444"
DB18e=$(git -C "$R18e" symbolic-ref --short HEAD)
git -C "$R18e" worktree add -q "$R18e/.worktrees/w" -b "build/feature-${SID18e:0:8}" HEAD
printf 'line1\nline2\nline3\nWT_app_change\n' > "$R18e/.worktrees/w/app.php"; git -C "$R18e/.worktrees/w" commit -qam "wt change"
mkdir -p "$R18e/.worktrees/sib"; printf '%s %s\n' "$SIB18e" "$(date +%s)" > "$R18e/.worktrees/sib/.claude-session-lock"  # sibling active
# ONLY a quarantined session-log is dirty (untracked) — exactly the P2 integrity-sweep output:
printf 'invalid yaml\n' > "$R18e/SESSION_LOG_deadbeef-1111-2222-3333-444455556666.yaml.invalid"
O18e=$(CLAUDE_MAIN_BRANCH="$DB18e" V_TMP_DIR="$R18e/.v/tmp" REPO_ROOT="$R18e" bash "$MB" "$SID18e" "$R18e/.worktrees/w" 2>&1); RC18e=$?
{ [ "$RC18e" -eq 0 ] && grep -q "WT_app_change" "$R18e/app.php"; } && ok "T18e/B-1: .yaml.invalid quarantine artifact does NOT defer (excluded, rc=0 merged through)" || no "T18e/B-1: false defer on quarantine .yaml.invalid (rc=$RC18e — exclusion missing (\\.invalid)? tail?)"
[ ! -f "$R18e/.v/tmp/merge-deferred-$SID18e.md" ] && ok "T18e/B-1: NO defer witness when only a .yaml.invalid quarantine is dirty" || no "T18e/B-1: false defer witness on quarantine artifact"

echo ""
echo "═══════════ RESULT: $PASS passed, $FAIL failed ═══════════"
rm -rf $CONC_BASE/t1 $CONC_BASE/t2 $CONC_BASE/t3 $CONC_BASE/t4 $CONC_BASE/t5 $CONC_BASE/t6 $CONC_BASE/t7 $CONC_BASE/t9 $CONC_BASE/t10 $CONC_BASE/t11 $CONC_BASE/t12 $CONC_BASE/t13 $CONC_BASE/t14 $CONC_BASE/t15 $CONC_BASE/t16 $CONC_BASE/t17 $CONC_BASE/t17b $CONC_BASE/t17c $CONC_BASE/t17d $CONC_BASE/t17e $CONC_BASE/t18 $CONC_BASE/t18b $CONC_BASE/t18c $CONC_BASE/t18d $CONC_BASE/t18e \
       $CONC_BASE/t1-*.out $CONC_BASE/t2-*.out $CONC_BASE/t3*.out $CONC_BASE/t17b.out 2>/dev/null
[ $FAIL -eq 0 ]
