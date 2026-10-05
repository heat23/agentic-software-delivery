#!/usr/bin/env bash
# v-merge-back-worktree-gc-test.sh — P6 (fleet forensic 2026-06-20): a successful merge-back must
# opportunistically GC OTHER leaked worktrees whose branch is SAFELY merged (ancestor of main) AND whose
# session is done (no fresh lock) — while NEVER touching an ahead-of-main (unmerged) worktree. This fixes
# the cross-fleet worktree accumulation without ever orphaning unmerged work.
# Re-run: bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
MB="$HOME/.claude/skills/v/references/v-merge-back.sh"
[ -f "$MB" ] || { echo "SKIP: missing $MB"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID SESSION_ID 2>/dev/null || true

BASE=$(mktemp -d); trap 'rm -rf "$BASE" 2>/dev/null' EXIT
R="$BASE/repo"; mkdir -p "$R"
git init -q -b main "$R" >/dev/null 2>&1
( cd "$R" && echo base > f.txt && git add -A && git -c commit.gpgsign=false commit -qm init ) >/dev/null 2>&1

SIDA="aaaaaaaa-1111-4111-8111-111111111111"   # the merging session
SIDB="bbbbbbbb-2222-4222-8222-222222222222"   # a LEAKED, fully-merged, unlocked worktree -> should be reaped
SIDC="cccccccc-3333-4333-8333-333333333333"   # an AHEAD-of-main (unmerged) worktree -> must be KEPT

# Worktree A: the session's own — a build branch with one new commit to merge back.
( cd "$R" && git worktree add -q -b "build/feat-$SIDA" "$BASE/wtA" >/dev/null 2>&1
  cd "$BASE/wtA" && echo a > a.txt && git add -A && git -c commit.gpgsign=false commit -qm "feat A" ) >/dev/null 2>&1
# Worktree B: branch points at main HEAD (0 commits ahead = already merged), NO lock.
( cd "$R" && git worktree add -q -b "build/old-$SIDB" "$BASE/wtB" >/dev/null 2>&1 ) >/dev/null 2>&1
# Worktree C: AHEAD of main by a commit (unmerged), NO lock — the data-loss trap the GC must avoid.
( cd "$R" && git worktree add -q -b "build/ahead-$SIDC" "$BASE/wtC" >/dev/null 2>&1
  cd "$BASE/wtC" && echo c > c.txt && git add -A && git -c commit.gpgsign=false commit -qm "ahead C" ) >/dev/null 2>&1

echo "== v-merge-back :: P6 opportunistic worktree GC =="
[ -d "$BASE/wtB" ] && [ -d "$BASE/wtC" ] || { echo "SKIP: worktree setup failed"; exit 0; }

OUT=$( cd "$R" && V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 bash "$MB" "$SIDA" "$BASE/wtA" 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok "merge-back of A succeeded (rc=0)" || no "merge-back failed rc=$RC" "$OUT"
[ ! -d "$BASE/wtA" ] && ok "session's own worktree A removed (normal cleanup)" || no "A not removed" "$(ls "$BASE")"
[ ! -d "$BASE/wtB" ] && ok "leaked MERGED+unlocked worktree B reaped by the wired GC (P6)" || no "B not reaped — GC not wired/ran" "$(ls "$BASE")"
[ -d "$BASE/wtC" ] && ok "AHEAD-of-main (unmerged) worktree C KEPT (no data loss)" || no "C wrongly removed — GC orphaned unmerged work!" "$(ls "$BASE")"

# Opt-out honored: with V_NO_WORKTREE_GC=1 a fresh merged-leak survives.
( cd "$R" && git worktree add -q -b "build/old2-$SIDB" "$BASE/wtB2" >/dev/null 2>&1 ) >/dev/null 2>&1
( cd "$R" && git worktree add -q -b "build/feat2-$SIDA" "$BASE/wtA2" >/dev/null 2>&1
  cd "$BASE/wtA2" && echo a2 > a2.txt && git add -A && git -c commit.gpgsign=false commit -qm "feat A2" ) >/dev/null 2>&1
( cd "$R" && V_NO_WORKTREE_GC=1 V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 bash "$MB" "$SIDA" "$BASE/wtA2" >/dev/null 2>&1 )
[ -d "$BASE/wtB2" ] && ok "V_NO_WORKTREE_GC=1 opt-out honored (merged leak B2 survives)" || no "opt-out not honored" "$(ls "$BASE")"

# M2 (SME review 2026-06-21): the IDEMPOTENCY cleanup (already-merged branch) must NOT --force-remove a worktree
# that still holds UNCOMMITTED/UNTRACKED work — the same data-loss class as GC-DIRTY-WORKTREE. Merged + dirty
# -> KEEP, not destroyed. Bite: remove the porcelain guard at v-merge-back.sh idempotency path -> wtM force-gone.
SIDM="dddddddd-4444-4444-8444-444444444444"
( cd "$R" && git worktree add -q -b "build/merged-$SIDM" "$BASE/wtM" >/dev/null 2>&1 ) >/dev/null 2>&1   # 0 ahead = already merged
printf 'IRREPLACEABLE UNCOMMITTED WORK\n' > "$BASE/wtM/uncommitted.txt"                                   # untracked work
( cd "$R" && V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 V_NO_WORKTREE_GC=1 bash "$MB" "$SIDM" "$BASE/wtM" >/dev/null 2>&1 )
{ [ -d "$BASE/wtM" ] && [ -f "$BASE/wtM/uncommitted.txt" ] && [ "$(cat "$BASE/wtM/uncommitted.txt" 2>/dev/null)" = "IRREPLACEABLE UNCOMMITTED WORK" ]; } \
  && ok "M2: merged worktree with UNCOMMITTED work KEPT by the idempotency path (not force-destroyed)" \
  || no "M2 DATA-LOSS: merge-back idempotency force-removed a dirty merged worktree" "$(ls "$BASE/wtM" 2>&1)"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
