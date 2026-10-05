#!/usr/bin/env bash
# v-merge-back-ownership-test.sh — P1d (forensic 2026-06-17 / NEW-CI-003).
#
# The merge-back ownership guard required the worktree BRANCH name to contain the SID (or -<sid8>).
# NEW-CI-003's branch was `fix/new-ci-003-sample-task` (no SID) -> the guard hard-refused (exit 2)
# -> the orchestrator fell back to a MANUAL, UNLOCKED `git merge` (the exact bypass the guard exists to
# prevent). P1d adds three branch-name-independent ownership proofs before refusing. This harness drives
# the REAL v-merge-back.sh and asserts:
#   1  branch lacks SID, but worktree PATH carries it          -> merges (path proof)
#   2  branch+path lack SID, but .claude-session-lock has it    -> merges (session-lock proof)
#   3  branch+path+lock ALL lack SID                            -> REFUSES (ownership unprovable)
#   5  branch contains -<sid8> (the normal convention)          -> merges (regression, unchanged)
# (FOREIGN-branch rejection — a branch belonging to ANOTHER session — is covered by v-concurrency-test.sh
#  T16. There is intentionally NO "no active sibling -> proceed" path: a foreign branch must be rejected
#  whether or not a peer is currently active.)
set -u
MB="$HOME/.claude/skills/v/references/v-merge-back.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$MB" ] || { echo "NO v-merge-back.sh missing"; exit 1; }
export V_MERGE_BACK_SKIP_ARTIFACT_GATE=1   # isolate the ownership check from the artifact-presence gate

SID="5e55a000-0000-1111-2222-333344445555"; S8=$(printf '%s' "$SID" | cut -c1-8)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
OUTF="$TMP/out"; RC=0

mk_repo(){  # $1=dir
  rm -rf "$1"; mkdir -p "$1"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main && printf 'l1\nl2\n' > app.php && git add -A && git commit -qm init ) >/dev/null 2>&1
  mkdir -p "$1/.v/tmp"
}
# create a worktree, commit a NON-overlapping change there, register the session-writes
wt_setup(){  # $1=repo $2=wt-abs-path $3=branch $4=newfile
  git -C "$1" worktree add -q "$2" -b "$3" HEAD 2>/dev/null
  ( cd "$2" && echo new > "$4" && git add "$4" && git commit -qm "wt work" ) >/dev/null 2>&1
  printf '%s\n' "$4" > "$1/.v/tmp/session-writes-${SID}.txt"
}
run_mb(){  # $1=repo $2=wt-abs-path
  ( cd "$1" && V_TMP_DIR="$1/.v/tmp" REPO_ROOT="$1" bash "$MB" "$SID" "$2" ) > "$OUTF" 2>&1
  RC=$?
}

echo "== v-merge-back ownership fallback (P1d / NEW-CI-003) =="

# 1. PATH proof: branch has no SID, but the worktree path carries -<sid8>.
R1="$TMP/r1"; mk_repo "$R1"
wt_setup "$R1" "$R1/.worktrees/fix-sample-${S8}" "fix/sample-task" "f1.php"
run_mb "$R1" "$R1/.worktrees/fix-sample-${S8}"
{ [ "$RC" -eq 0 ] && grep -q "new" "$R1/f1.php" 2>/dev/null; } \
  && ok "1 path carries SID -> merges (path proof)" || no "1 path-proof merge failed (rc=$RC)"

# 2. SESSION-LOCK proof: branch + path lack SID, but the worktree's .claude-session-lock has it.
R2="$TMP/r2"; mk_repo "$R2"
wt_setup "$R2" "$R2/.worktrees/plainname" "fix/sample-task" "f2.php"
printf '%s %s %s\n' "$SID" "pid" "ts" > "$R2/.worktrees/plainname/.claude-session-lock"
run_mb "$R2" "$R2/.worktrees/plainname"
{ [ "$RC" -eq 0 ] && grep -q "new" "$R2/f2.php" 2>/dev/null; } \
  && ok "2 session-lock carries SID -> merges (lock proof)" || no "2 lock-proof merge failed (rc=$RC)"

# 3. UNPROVABLE: branch + path + lock all lack the SID -> REFUSE (ownership cannot be proven; no
#    'solo-safe' shortcut — a foreign branch must never be merged under this SID).
R3="$TMP/r3"; mk_repo "$R3"
wt_setup "$R3" "$R3/.worktrees/plainname" "fix/sample-task" "f3.php"
run_mb "$R3" "$R3/.worktrees/plainname"
{ [ "$RC" -ne 0 ] && ! grep -q "new" "$R3/f3.php" 2>/dev/null; } \
  && ok "3 no SID binding anywhere -> REFUSE (exit $RC, not merged)" || no "3 should refuse when ownership unprovable (rc=$RC)"

# 4. FOREIGN LOCK: the worktree has a .claude-session-lock but bound to a DIFFERENT session's SID ->
#    REFUSE (the lock proves it's NOT ours). SREV-004: guards against a future widening of the lock match.
R4="$TMP/r4"; mk_repo "$R4"
wt_setup "$R4" "$R4/.worktrees/plainname" "fix/sample-task" "f4.php"
printf '%s %s %s\n' "deadbeef-dead-dead-dead-deaddeaddead" "pid" "ts" > "$R4/.worktrees/plainname/.claude-session-lock"
run_mb "$R4" "$R4/.worktrees/plainname"
{ [ "$RC" -ne 0 ] && ! grep -q "new" "$R4/f4.php" 2>/dev/null; } \
  && ok "4 foreign lock (other session's SID) -> REFUSE (exit $RC, not merged)" || no "4 foreign lock should refuse (rc=$RC)"

# 5. REGRESSION: branch carries -<sid8> (normal convention) -> merges as before.
R5="$TMP/r5"; mk_repo "$R5"
wt_setup "$R5" "$R5/.worktrees/wt" "fix/sample-task-${S8}" "f5.php"
run_mb "$R5" "$R5/.worktrees/wt"
{ [ "$RC" -eq 0 ] && grep -q "new" "$R5/f5.php" 2>/dev/null; } \
  && ok "5 branch has -<sid8> -> merges (regression: unchanged)" || no "5 SID-branch merge regressed (rc=$RC)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
