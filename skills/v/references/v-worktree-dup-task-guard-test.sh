#!/usr/bin/env bash
# v-worktree-dup-task-guard-test.sh — W71-F11 (forensic 2026-07-02).
#
# CLASS UNDER TEST: duplicate-task dispatch reaching worktree creation. On 2026-07-02 the same
# finding was implemented THREE times in parallel — three same-slug branches under different
# session suffixes — with two mutually incompatible schema designs: a near-miss
# double-migration on merge plus ~2 full gauntlets of wasted cost. Upstream causes are fixed at
# their own layers (W25-F14/W71-F1 paste claims, W71-F5 capture split); this pins the LAST-LINE
# belt in v-worktree-adopt-or-create.sh: creating a worktree for a task whose EXACT slug already
# has an UNMERGED branch under a DIFFERENT session exits 7 with guidance, creating nothing.
#
# Run: bash v-worktree-dup-task-guard-test.sh [/path/to/v-worktree-adopt-or-create.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
AOC="${1:-${V_ADOPT_OR_CREATE_OVERRIDE:-$HERE/v-worktree-adopt-or-create.sh}}"
AOC_BAK="$HERE/v-worktree-adopt-or-create.sh.pre-w71f11-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }

[ -f "$AOC" ] || { echo "FATAL: script-under-test not found ($AOC)"; exit 2; }
SID_A="a11df110-1111-4222-8333-444455556666"   # "our" session (fixture-unique hex, see cleanup trap)
SID_B="b22df111-1111-4222-8333-444455556666"   # the sibling that already has a branch
SID_A2="c33df112-2222-4222-8333-444455556666"  # distinct "our" session for a repeated-slug scenario
SID_A3="c44df113-3333-4222-8333-444455556666"  # ditto — avoids colliding WORKTREES_EXTERNAL_BASE paths
TMP=$(mktemp -d)
# the script-under-test writes $HOME/.claude/runtime/active-worktree-<sid> on every successful
# create — sweep OUR fixture SID's markers too, or every run leaks one (observed 2026-07-02).
trap 'rm -rf "$TMP"; rm -f "$HOME/.claude/runtime/active-worktree-${SID_A}" "$HOME/.claude/runtime/active-worktree-${SID_A2}" "$HOME/.claude/runtime/active-worktree-${SID_A3}"' EXIT
export WORKTREES_EXTERNAL_BASE="$TMP/worktrees"

_mkrepo(){ # $1=path — fresh repo with one commit on main
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
}
_mkbranch(){ # $1=repo $2=branch $3=merged(0|1) — branch with one commit, optionally ff-merged
  git -C "$1" checkout -q -b "$2"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "work on $2"
  git -C "$1" checkout -q main
  [ "${3:-0}" = "1" ] && git -C "$1" merge -q --ff-only "$2"
}
_run(){ # $1=repo $2=slug $3=sid [env…] — runs script, captures rc + output
  local repo="$1" slug="$2" sid="$3"; shift 3
  _OUT=$(env "$@" bash "$AOC" fix "$slug" "$sid" "$repo" 2>&1); _RC=$?
}

echo "== W71-F11 :: duplicate-task guard at worktree creation =="

bash -n "$AOC" && ok "script parses (bash -n)" || no "syntax error"

# 1. clean repo — no duplicate — creates normally
R1="$TMP/r1"; _mkrepo "$R1"
_run "$R1" "alpha-task" "$SID_A"
[ "$_RC" -eq 0 ] && printf '%s' "$_OUT" | grep -q 'WORKTREE_ABS_PATH=' \
  && ok "no duplicate → creates worktree (rc=0)" \
  || no "clean create broke (rc=$_RC): $_OUT"

# 2. THE INCIDENT SHAPE: unmerged same-slug branch under another full-UUID SID → exit 7, nothing minted
R2="$TMP/r2"; _mkrepo "$R2"; _mkbranch "$R2" "fix/beta-task-$SID_B" 0
_run "$R2" "beta-task" "$SID_A"
[ "$_RC" -eq 7 ] \
  && ok "unmerged same-slug sibling branch → blocked (rc=7)" \
  || no "duplicate NOT blocked (rc=$_RC): $_OUT"
[ ! -d "$WORKTREES_EXTERNAL_BASE/fix-beta-task-$SID_A" ] \
  && ok "blocked path minted no worktree" \
  || no "blocked path still created a worktree"
printf '%s' "$_OUT" | grep -q 'V_DUP_TASK_OK=1' \
  && ok "block message names the explicit override" \
  || no "block message lacks override guidance"

# 3. short-8-hex sibling SID (the short-suffix naming shape) → blocked
R3="$TMP/r3"; _mkrepo "$R3"; _mkbranch "$R3" "fix/gamma-task-89abcdef" 0
_run "$R3" "gamma-task" "$SID_A"
[ "$_RC" -eq 7 ] \
  && ok "short-hex sibling SID suffix → blocked (rc=7)" \
  || no "short-hex duplicate not blocked (rc=$_RC)"

# 4. MERGED same-slug branch (historical, landed) → never blocks
R4="$TMP/r4"; _mkrepo "$R4"; _mkbranch "$R4" "fix/delta-task-$SID_B" 1
_run "$R4" "delta-task" "$SID_A"
[ "$_RC" -eq 0 ] \
  && ok "merged historical branch does not block (rc=0)" \
  || no "false-blocked on a MERGED branch (rc=$_RC): $_OUT"

# 5. longer slug sharing this slug as a prefix (different task) → never blocks
R5="$TMP/r5"; _mkrepo "$R5"; _mkbranch "$R5" "fix/eps-task-extra-scope-$SID_B" 0
_run "$R5" "eps-task" "$SID_A"
[ "$_RC" -eq 0 ] \
  && ok "prefix-overlapping LONGER slug (different task) does not block (rc=0)" \
  || no "false-blocked on a different task sharing a slug prefix (rc=$_RC): $_OUT"

# 6. explicit override proceeds despite the duplicate
R6="$TMP/r6"; _mkrepo "$R6"; _mkbranch "$R6" "fix/zeta-task-$SID_B" 0
_run "$R6" "zeta-task" "$SID_A" V_DUP_TASK_OK=1
[ "$_RC" -eq 0 ] \
  && ok "V_DUP_TASK_OK=1 override proceeds (rc=0)" \
  || no "override did not proceed (rc=$_RC): $_OUT"

# 7b. review F2: UPPERCASE sibling SID suffix must still block (case-insensitive match)
R9="$TMP/r9"; _mkrepo "$R9"; _mkbranch "$R9" "fix/iota-task-DEADBEEF" 0
_run "$R9" "iota-task" "$SID_A"
[ "$_RC" -eq 7 ] \
  && ok "UPPERCASE sibling SID suffix → blocked (rc=7, case-insensitive)" \
  || no "uppercase SID suffix bypassed the guard (rc=$_RC)"

# 7. never weaken: a real git failure still errors (existing branch for OUR sid, no worktree)
R7="$TMP/r7"; _mkrepo "$R7"; _mkbranch "$R7" "fix/eta-task-$SID_A" 0
_run "$R7" "eta-task" "$SID_A"
[ "$_RC" -eq 4 ] \
  && ok "own-SID leftover branch skips dup-guard, still fails at worktree add (rc=4, pre-existing contract)" \
  || no "own-SID leftover branch handling changed (rc=$_RC): $_OUT"

# 8. W71-F11-B (forensic 2026-07-03, parallel-fanout incident): a same-slug sibling branch created off
# main with ZERO commits (the "leave staged, don't commit" fleet shape) is trivially --is-ancestor
# main — but its worktree holds a LIVE session lock (our own $$ pid, genuinely alive) with staged
# WIP. The old exemption would silently skip this as "historical, landed"; the fix must block it.
R10="$TMP/r10"; _mkrepo "$R10"
WT10="$TMP/wt-r10-live"
git -C "$R10" worktree add -q "$WT10" -b "fix/theta-task-$SID_B" >/dev/null 2>&1
echo "x" > "$WT10/staged.txt"
git -C "$WT10" add staged.txt >/dev/null 2>&1
printf '%s %s %s\n' "$SID_B" "$$" "$(date +%s)" > "$WT10/.claude-session-lock"
_run "$R10" "theta-task" "$SID_A"
[ "$_RC" -eq 7 ] \
  && ok "zero-commit ancestor branch w/ live-lock+staged WIP → blocked (rc=7)" \
  || no "landed-exemption swallowed a live-lock zero-commit sibling (rc=$_RC): $_OUT"
git -C "$R10" worktree remove --force "$WT10" >/dev/null 2>&1

# 9. Same shape, but the WIP is staged with NO lock file at all (dead-or-absent lock) — dirty
# worktree state alone must still block; liveness isn't the only signal.
R11="$TMP/r11"; _mkrepo "$R11"
WT11="$TMP/wt-r11-wip"
git -C "$R11" worktree add -q "$WT11" -b "fix/kappa-task-$SID_B" >/dev/null 2>&1
echo "y" > "$WT11/staged2.txt"
git -C "$WT11" add staged2.txt >/dev/null 2>&1
_run "$R11" "kappa-task" "$SID_A"
[ "$_RC" -eq 7 ] \
  && ok "zero-commit ancestor branch w/ staged WIP, no lock → blocked (rc=7)" \
  || no "landed-exemption swallowed a lockless zero-commit WIP sibling (rc=$_RC): $_OUT"
git -C "$R11" worktree remove --force "$WT11" >/dev/null 2>&1

# 10. Same shape, but the worktree was torn down entirely (a sibling's self-cleanup) — nothing
# left behind → must remain exempt (never block a genuinely abandoned, empty branch).
R12="$TMP/r12"; _mkrepo "$R12"
WT12="$TMP/wt-r12-gone"
git -C "$R12" worktree add -q "$WT12" -b "fix/lambda-task-$SID_B" >/dev/null 2>&1
git -C "$R12" worktree remove --force "$WT12" >/dev/null 2>&1
_run "$R12" "lambda-task" "$SID_A"
[ "$_RC" -eq 0 ] \
  && ok "zero-commit ancestor branch, worktree torn down → still exempt (rc=0)" \
  || no "false-blocked a self-cleaned, torn-down sibling worktree (rc=$_RC): $_OUT"

# 11. W71-F11-B inline-on-main duplicate (forensic 2026-07-03): SID_B stages a file INLINE ON
# MAIN (no branch at all) whose basename matches the task slug; SID_B has no SESSION_LOG (presumed
# still-live). A worktree adopter for the SAME slug must block even though Step 1.5's branch scan
# has nothing to see.
R13="$TMP/r13"; _mkrepo "$R13"
mkdir -p "$R13/app/Services"
echo "<?php // wip" > "$R13/app/Services/ApiClientAdapter.php"
git -C "$R13" add app/Services/ApiClientAdapter.php >/dev/null 2>&1
GCD13="$(git -C "$R13" rev-parse --git-common-dir 2>/dev/null)"
case "$GCD13" in /*) ;; *) GCD13="$R13/$GCD13" ;; esac
printf 'app/Services/ApiClientAdapter.php\n' > "$GCD13/claude-session-writes-${SID_B}.txt"
_run "$R13" "api-client-adapter" "$SID_A"
[ "$_RC" -eq 7 ] \
  && ok "inline-on-main same-slug staged file (different, live SID) → blocked (rc=7)" \
  || no "inline-on-main duplicate NOT blocked (rc=$_RC): $_OUT"

# 12. Same inline shape, but SID_B already has a SESSION_LOG (finished) → must NOT block (not live).
R14="$TMP/r14"; _mkrepo "$R14"
mkdir -p "$R14/app/Services"
echo "<?php // wip" > "$R14/app/Services/ApiClientAdapter.php"
git -C "$R14" add app/Services/ApiClientAdapter.php >/dev/null 2>&1
GCD14="$(git -C "$R14" rev-parse --git-common-dir 2>/dev/null)"
case "$GCD14" in /*) ;; *) GCD14="$R14/$GCD14" ;; esac
printf 'app/Services/ApiClientAdapter.php\n' > "$GCD14/claude-session-writes-${SID_B}.txt"
: > "$R14/SESSION_LOG_${SID_B}.yaml"
_run "$R14" "api-client-adapter" "$SID_A2"
[ "$_RC" -eq 0 ] \
  && ok "inline-on-main staged file from a FINISHED sibling → does not block (rc=0)" \
  || no "false-blocked a finished sibling's inline file (rc=$_RC): $_OUT"

# 13. Inline dirty file present but its name has nothing to do with the slug → must NOT block.
R15="$TMP/r15"; _mkrepo "$R15"
mkdir -p "$R15/app/Services"
echo "<?php // wip" > "$R15/app/Services/UnrelatedThing.php"
git -C "$R15" add app/Services/UnrelatedThing.php >/dev/null 2>&1
GCD15="$(git -C "$R15" rev-parse --git-common-dir 2>/dev/null)"
case "$GCD15" in /*) ;; *) GCD15="$R15/$GCD15" ;; esac
printf 'app/Services/UnrelatedThing.php\n' > "$GCD15/claude-session-writes-${SID_B}.txt"
_run "$R15" "api-client-adapter" "$SID_A3"
[ "$_RC" -eq 0 ] \
  && ok "inline-on-main staged file with an unrelated name → does not block (rc=0)" \
  || no "false-blocked an unrelated inline file (rc=$_RC): $_OUT"

# 14. Hostile-review finding (2026-07-03): the script's OWN `.claude-session-lock` write must not
# defeat its own "clean worktree -> exempt" case. A worktree for a zero-commit ancestor branch that
# has ONLY the routine lock file present (no other WIP, no live PID) must stay exempt — before the
# exclude_session_lock_from_git fix, `git status --porcelain` saw `?? .claude-session-lock` and the
# guard treated that as WIP, blocking ANY landed/merged sibling whose worktree hadn't been torn down.
R16="$TMP/r16"; _mkrepo "$R16"
WT16="$TMP/wt-r16-lockonly"
git -C "$R16" worktree add -q "$WT16" -b "fix/mu-task-$SID_B" >/dev/null 2>&1
# simulate what this script itself does on create/adopt: write the lock, then exclude it.
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 99999 0\n' > "$WT16/.claude-session-lock"
( . "$HOME/.claude/hooks/lib/worktree-lock-exclude.sh" 2>/dev/null; exclude_session_lock_from_git "$WT16" ) >/dev/null 2>&1
_run "$R16" "mu-task" "$SID_A"
[ "$_RC" -eq 0 ] \
  && ok "zero-commit ancestor branch, worktree has ONLY the excluded lock file → still exempt (rc=0)" \
  || no "lock-file-only worktree false-blocked a landed/merged sibling (rc=$_RC): $_OUT"
git -C "$R16" worktree remove --force "$WT16" >/dev/null 2>&1

# 15. Hostile-review finding (2026-07-03): a generic single-word slug must NOT false-positive against
# an unrelated file that merely contains that word as a substring (e.g. slug "migration" vs a file
# named "AddMigrationHelper.php" from a completely different task).
R17="$TMP/r17"; _mkrepo "$R17"
mkdir -p "$R17/app/Services"
echo "<?php // wip" > "$R17/app/Services/AddMigrationHelper.php"
git -C "$R17" add app/Services/AddMigrationHelper.php >/dev/null 2>&1
GCD17="$(git -C "$R17" rev-parse --git-common-dir 2>/dev/null)"
case "$GCD17" in /*) ;; *) GCD17="$R17/$GCD17" ;; esac
printf 'app/Services/AddMigrationHelper.php\n' > "$GCD17/claude-session-writes-${SID_B}.txt"
_run "$R17" "migration" "$SID_A"
[ "$_RC" -eq 0 ] \
  && ok "generic single-word slug 'migration' does not false-positive on an unrelated file (rc=0)" \
  || no "generic single-word slug false-blocked an unrelated file (rc=$_RC): $_OUT"

# 16. Same shape but a real multi-token match (the actual incident shape) must still block.
R18="$TMP/r18"; _mkrepo "$R18"
mkdir -p "$R18/app/Services"
echo "<?php // wip" > "$R18/app/Services/ApiClientAdapter.php"
git -C "$R18" add app/Services/ApiClientAdapter.php >/dev/null 2>&1
GCD18="$(git -C "$R18" rev-parse --git-common-dir 2>/dev/null)"
case "$GCD18" in /*) ;; *) GCD18="$R18/$GCD18" ;; esac
printf 'app/Services/ApiClientAdapter.php\n' > "$GCD18/claude-session-writes-${SID_B}.txt"
_run "$R18" "api-client-adapter" "$SID_A2"
[ "$_RC" -eq 7 ] \
  && ok "multi-token slug match (real incident shape) still blocks (rc=7)" \
  || no "multi-token match regressed — no longer blocks the real incident shape (rc=$_RC): $_OUT"

# RED: pre-fix backup must mint the duplicate silently
echo "-- RED: pre-fix backup --"
if [ -f "$AOC_BAK" ]; then
  R8="$TMP/r8"; _mkrepo "$R8"; _mkbranch "$R8" "fix/beta-task-$SID_B" 0
  _OUT=$(bash "$AOC_BAK" fix "beta-task" "$SID_A" "$R8" 2>&1); _RC=$?
  if [ "$_RC" -eq 0 ]; then
    ok "backup: duplicate sailed through (rc=0 — confirms the guard is new)"
  else
    no "backup unexpectedly blocked (rc=$_RC — guard not new?)"
  fi
else
  echo "  SKIP: no backup at $AOC_BAK"
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
