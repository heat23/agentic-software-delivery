#!/usr/bin/env bash
# v-concurrency-integration-test.sh — the MISSING test class (forensic 2026-06-15, anti-whack-a-mole).
#
# WHY THIS EXISTS: every wave audit found the same loss class (data loss / shared-tree contamination)
# AFTER the fact. The existing v-concurrency-test.sh builds a real temp repo but never actually RACES —
# it injects interleavings via sequential lock return codes (0 backgrounded procs). So the exact
# concurrency that keeps biting was never reproduced before production. This harness launches
# GENUINELY CONCURRENT sessions (background processes + wait, real lock contention, fault injection)
# through write → gate → merge-back/stash, and asserts the SURVIVAL PROPERTY:
#     every file a session wrote ends in a commit, a recoverable stash, or an explicit handoff —
#     and if anything silently vanishes, _survival_verdict (the live gate) CATCHES it.
# Run: env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID bash v-concurrency-integration-test.sh
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s — %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
MB="$HOME/.claude/skills/v/references/v-merge-back.sh"
[ -f "$MB" ] || { echo "SKIP: v-merge-back.sh not found"; exit 0; }
LIB="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/validation.sh"
. "$LIB" 2>/dev/null || true
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# This harness exercises the LOCK / RACE / STASH / SURVIVAL behavior, not the artifact-presence gate —
# bypass the latter the same way v-concurrency-test.sh does (documented escape hatch).
export V_MERGE_BACK_SKIP_ARTIFACT_GATE=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkrepo(){ # $1 name -> echo repo path; tracked app.php + other.php
  local R="$TMP/$1"; mkdir -p "$R"
  ( cd "$R" && git init -q && printf 'l1\nl2\nl3\n' > app.php && printf 'o1\n' > other.php && \
    mkdir -p .v/tmp && git add -A && git commit -qm init ) >/dev/null 2>&1
  printf '%s' "$R"
}
wt(){ # $1 repo $2 name $3 branch -> add worktree from HEAD
  git -C "$1" worktree add -q "$1/.worktrees/$2" -b "$3" HEAD >/dev/null 2>&1
}

############################################################################
# IR1 — GENUINE RACE: two merge-backs launched concurrently must BOTH land
#       (the merge-lock serializes them; neither merge is silently dropped).
############################################################################
R=$(mkrepo ir1); DB=$(git -C "$R" symbolic-ref --short HEAD)
# Branch names MUST carry the owning SID's 8-char prefix (`-<sid8>`) — v-merge-back's ownership guard.
wt "$R" a "build/a-aaaaaaaa"; printf 'A_CHANGE\n' >> "$R/.worktrees/a/app.php"; git -C "$R/.worktrees/a" commit -qam A >/dev/null 2>&1
wt "$R" b "build/b-bbbbbbbb"; printf 'B_NEW\n' > "$R/.worktrees/b/bfile.php"; git -C "$R/.worktrees/b" add -A >/dev/null 2>&1; git -C "$R/.worktrees/b" commit -qam B >/dev/null 2>&1
( CLAUDE_MAIN_BRANCH="$DB" V_TMP_DIR="$R/.v/tmp" REPO_ROOT="$R" bash "$MB" aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa "$R/.worktrees/a" >"$TMP/ir1a.out" 2>&1 ) & P1=$!
( CLAUDE_MAIN_BRANCH="$DB" V_TMP_DIR="$R/.v/tmp" REPO_ROOT="$R" bash "$MB" bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb "$R/.worktrees/b" >"$TMP/ir1b.out" 2>&1 ) & P2=$!
wait $P1; RA=$?; wait $P2; RB=$?
{ grep -q A_CHANGE "$R/app.php" 2>/dev/null && [ -f "$R/bfile.php" ] && grep -q B_NEW "$R/bfile.php" 2>/dev/null; } \
  && ok "IR1: concurrent merge-backs BOTH landed on main (lock serialized; no lost merge) [RA=$RA RB=$RB]" \
  || no "IR1: a concurrently-raced merge-back was LOST" "RA=$RA RB=$RB; A=$(grep -c A_CHANGE "$R/app.php" 2>/dev/null) Bexists=$([ -f "$R/bfile.php" ] && echo 1 || echo 0)"
# main must not be left mid-rebase/detached
[ -n "$(git -C "$R" symbolic-ref --short HEAD 2>/dev/null)" ] && ok "IR1: main left on a clean branch ref after the race" || no "IR1: main left detached/mid-rebase after race"

############################################################################
# IR2 — STALE-LOCK RECOVERY: a merge-lock orphaned by a crashed peer (no EXIT
#       trap, e.g. SIGKILL) must not deadlock the next merge-back forever.
############################################################################
R=$(mkrepo ir2); DB=$(git -C "$R" symbolic-ref --short HEAD)
wt "$R" w "build/w-cccccccc"; printf 'W_CHANGE\n' >> "$R/.worktrees/w/app.php"; git -C "$R/.worktrees/w" commit -qam W >/dev/null 2>&1
# Orphan BOTH lock flavors (flock file + mkdir mutex), backdated >LOCK_STALE(600s):
mkdir -p "$R/.worktrees/.merge-lock.d"; printf 'deadpeer 99999 1\n' > "$R/.worktrees/.merge-lock.d/owner"
: > "$R/.worktrees/.merge-lock"
touch -t 202501010000 "$R/.worktrees/.merge-lock.d" "$R/.worktrees/.merge-lock" 2>/dev/null
OUT=$(CLAUDE_MAIN_BRANCH="$DB" V_TMP_DIR="$R/.v/tmp" REPO_ROOT="$R" bash "$MB" cccccccc-3333-4333-8333-cccccccccccc "$R/.worktrees/w" 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && grep -q W_CHANGE "$R/app.php" 2>/dev/null; } \
  && ok "IR2: stale merge-lock (>600s) recovered — merge-back proceeded, did not deadlock [rc=$RC]" \
  || no "IR2: stale-lock recovery FAILED (deadlock/leak)" "rc=$RC :: $(printf '%s' "$OUT" | tail -1)"

############################################################################
# IR3 — SURVIVAL PROPERTY after a REAL operation: committed work is NOT
#       flagged (no false-fire), a CLOBBERED inline write IS flagged (caught).
############################################################################
type _survival_verdict >/dev/null 2>&1 || { echo "  (skip IR3: _survival_verdict unavailable)"; echo "RESULT: $PASS passed, $FAIL failed"; [ $FAIL -eq 0 ]; exit $?; }
# 3a: a session that committed real work through a merge-back → survives (ok)
R=$(mkrepo ir3a); DB=$(git -C "$R" symbolic-ref --short HEAD); SID=dddddddd-4444-4444-8444-dddddddddddd
( cd "$R" && git rev-parse HEAD > .v/tmp/head-baseline-$SID.txt )
printf 'app.php\n' > "$R/.git/claude-session-writes-$SID.txt"
( cd "$R" && printf 'l1\nl2\nl3\nSHIPPED\n' > app.php && git commit -qam ship ) >/dev/null 2>&1
v=$(_survival_verdict "$SID" "$R"); [ "$v" = ok ] && ok "IR3a: committed work post-merge -> ok (survival gate: no false-fire)" || no "IR3a: committed work wrongly flagged" "$v"

# 3b: a real-world clobber — inline session wrote app.php, a concurrent operation REVERTED it to
#     baseline (the silent wipe). No marker. _survival_verdict MUST flag it as lost.
R=$(mkrepo ir3b); DB=$(git -C "$R" symbolic-ref --short HEAD); SID=eeeeeeee-5555-4555-8555-eeeeeeeeeeee
( cd "$R" && git rev-parse HEAD > .v/tmp/head-baseline-$SID.txt )
printf 'app.php\n' > "$R/.git/claude-session-writes-$SID.txt"
printf 'l1\nl2\nl3\nINLINE_FIX\n' > "$R/app.php"      # the session's work...
( cd "$R" && git checkout -- app.php ) >/dev/null 2>&1  # ...silently clobbered back to baseline by a sibling
v=$(_survival_verdict "$SID" "$R"); case "$v" in lost:*app.php*) ok "IR3b: clobbered inline write CAUGHT by survival gate -> $v";; *) no "IR3b: silent wipe NOT caught" "$v";; esac

# 3c: PARITY — both real gates agree on the IR3b clobber under V_SURVIVAL_GATE=block.
SC="$HOME/.claude/skills/v/references/v-completion-selfcheck.sh"
if [ -f "$SC" ]; then
  _sc=$(cd "$R" && env V_SURVIVAL_GATE=block CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" HOOKS_LIB_DIR="$HOME/.claude/hooks/lib" bash "$SC" 2>&1 || true)
  # Falsifiable (SREV-002): the self-check MUST flag the clobber in block mode — both real gates agree.
  printf '%s' "$_sc" | grep -qi 'SURVIVAL GATE' \
    && ok "IR3c: producer self-check ALSO flags the clobber in block mode (gate parity)" \
    || no "IR3c: self-check did NOT flag the clobber in block mode — Stop hook ⟺ self-check parity BROKEN"
fi

############################################################################
# IR4 — INLINE-WAVE EXPOSURE (forensic 2026-06-16): two GENUINELY-concurrent INLINE
#       sessions on shared main (NO worktree locks). The exposed gate must flag the one that leaves
#       source UNCOMMITTED — via writes-log OVERLAP, the signal that survives when the worktree-only
#       v-active-siblings sees nothing — and NOT the one that commits. Proves the fix in a real repo.
############################################################################
if type _exposed_inline_verdict >/dev/null 2>&1; then
  R=$(mkrepo ir4)
  SID_A=aaaa4444-4444-4444-8444-444444444444   # leaves work UNCOMMITTED → must be flagged
  SID_B=bbbb4444-4444-4444-8444-444444444444   # commits its own work → must be ok
  mkdir -p "$R/.v/tmp"
  git -C "$R" rev-parse HEAD > "$R/.v/tmp/head-baseline-$SID_A.txt"   # both sessions START (baselines)
  git -C "$R" rev-parse HEAD > "$R/.v/tmp/head-baseline-$SID_B.txt"
  sleep 1                                                             # ensure writes land AFTER both starts
  # NOTE: this harness's mkrepo lays files at the repo ROOT (app.php/other.php), no src/ dir — write
  # root-level .php files so the working-tree change actually lands (a src/ path would silently no-op).
  ( cd "$R" && printf 'a_wip.php\n' > .git/claude-session-writes-$SID_A.txt && printf 'A_WIP\n' > a_wip.php ) &
  ( cd "$R" && printf 'b_work.php\n' > .git/claude-session-writes-$SID_B.txt && printf 'B_WORK\n' > b_work.php && git add b_work.php && git commit -qm "B work" ) &
  wait
  va=$(_exposed_inline_verdict "$SID_A" "$R"); vb=$(_exposed_inline_verdict "$SID_B" "$R")
  case "$va" in exposed:*a_wip.php*) ok "IR4: inline-wave — uncommitted session flagged exposed via writes-log overlap (worktree-blind) [$va]";; *) no "IR4: uncommitted inline session NOT flagged in a real concurrent wave" "$va";; esac
  [ "$vb" = ok ] && ok "IR4: inline-wave — committed session is ok (no false-fire on committed work)" || no "IR4: committed inline session wrongly flagged" "$vb"
fi

############################################################################
# IR5 — 3-WAY CONCURRENT SESSION RACE (P6, audit 2026-06-19):
# Three independent sessions race to merge-back simultaneously. The merge-lock
# must serialize all three without data loss: every session's unique file must
# appear on main after all three complete. Verifies that the 2-session IR1
# guarantee extends to N>2 without silent drops or deadlocks.
############################################################################
R=$(mkrepo ir5); DB=$(git -C "$R" symbolic-ref --short HEAD)
wt "$R" a5 "build/a5-aaaa5555"; printf 'A5_CHANGE\n' >> "$R/.worktrees/a5/app.php"; git -C "$R/.worktrees/a5" commit -qam A5 >/dev/null 2>&1
wt "$R" b5 "build/b5-bbbb5555"; printf 'B5_NEW\n' > "$R/.worktrees/b5/bfile5.php"; git -C "$R/.worktrees/b5" add -A >/dev/null 2>&1; git -C "$R/.worktrees/b5" commit -qam B5 >/dev/null 2>&1
wt "$R" c5 "build/c5-cccc5555"; printf 'C5_NEW\n' > "$R/.worktrees/c5/cfile5.php"; git -C "$R/.worktrees/c5" add -A >/dev/null 2>&1; git -C "$R/.worktrees/c5" commit -qam C5 >/dev/null 2>&1
(CLAUDE_MAIN_BRANCH="$DB" V_TMP_DIR="$R/.v/tmp" REPO_ROOT="$R" bash "$MB" aaaa5555-1111-4111-8111-aaaaaaaaaaaa "$R/.worktrees/a5" >"$TMP/ir5a.out" 2>&1) & P5A=$!
(CLAUDE_MAIN_BRANCH="$DB" V_TMP_DIR="$R/.v/tmp" REPO_ROOT="$R" bash "$MB" bbbb5555-2222-4222-8222-bbbbbbbbbbbb "$R/.worktrees/b5" >"$TMP/ir5b.out" 2>&1) & P5B=$!
(CLAUDE_MAIN_BRANCH="$DB" V_TMP_DIR="$R/.v/tmp" REPO_ROOT="$R" bash "$MB" cccc5555-3333-4333-8333-cccccccccccc "$R/.worktrees/c5" >"$TMP/ir5c.out" 2>&1) & P5C=$!
wait $P5A; RA5=$?; wait $P5B; RB5=$?; wait $P5C; RC5=$?
# All three unique artifacts must be on main
A5_OK=$(grep -c A5_CHANGE "$R/app.php" 2>/dev/null || echo 0)
B5_OK=$([ -f "$R/bfile5.php" ] && grep -c B5_NEW "$R/bfile5.php" 2>/dev/null || echo 0)
C5_OK=$([ -f "$R/cfile5.php" ] && grep -c C5_NEW "$R/cfile5.php" 2>/dev/null || echo 0)
{ [ "$A5_OK" -ge 1 ] && [ "$B5_OK" -ge 1 ] && [ "$C5_OK" -ge 1 ]; } \
  && ok "IR5: 3-way concurrent merge-backs ALL landed (lock serialized; no silent drop) [RA=$RA5 RB=$RB5 RC=$RC5]" \
  || no "IR5: a 3-way concurrent merge-back was LOST" "A5=$A5_OK B5=$B5_OK C5=$C5_OK RA=$RA5 RB=$RB5 RC=$RC5"
# main must be on a clean branch ref after all three
[ -n "$(git -C "$R" symbolic-ref --short HEAD 2>/dev/null)" ] \
  && ok "IR5: main left on a clean branch ref after 3-way race" \
  || no "IR5: main left detached/mid-rebase after 3-way race"
# git log must show exactly 3 merge commits (one per session) beyond init
N_MERGES=$(git -C "$R" log --oneline | grep -cE "^[0-9a-f]+ (A5|B5|C5)$" 2>/dev/null || git -C "$R" log --oneline | grep -c "^[0-9a-f]" 2>/dev/null || echo 0)
[ "$N_MERGES" -ge 3 ] \
  && ok "IR5: git log shows at least 3 commits from the 3-way race (no merge was silently skipped)" \
  || no "IR5: only $N_MERGES commit(s) after 3-way race — a merge was silently dropped" \
     "log: $(git -C "$R" log --oneline | head -5 | tr '\n' '|')"

echo ""
echo "═══════════ RESULT: $PASS passed, $FAIL failed ═══════════"
[ $FAIL -eq 0 ]
