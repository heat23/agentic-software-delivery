#!/usr/bin/env bash
# v-worktree-gc-dirty-test.sh — CRITICAL pinning bite (audit GC-DIRTY-WORKTREE 2026-06-21).
# "0 commits ahead of main" proves only that COMMITTED ancestry is merged; the working tree may still hold
# uncommitted/untracked work that `git worktree remove --force` destroys IRREVERSIBLY. A merged-but-DIRTY
# worktree MUST be KEPT. The clean control proves the GC still prunes (so the dirty-KEEP isn't a broken-GC pass).
# Bite: delete the `git status --porcelain` dirty guard in v-worktree-gc.sh → Case 1 prunes → DATA LOSS → RED.
# Re-run: env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
GC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/v-worktree-gc.sh"
[ -f "$GC" ] || { echo "SKIP: missing v-worktree-gc.sh"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP" 2>/dev/null' EXIT
R="$TMP/main"; mkdir -p "$R"
( cd "$R" && git init -q -b main && printf 'a\n' > f.txt && git add -A && git -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1

mk_merged_wt(){ # <name> <branch> -> a worktree whose branch is fully merged into main (0 ahead), no lock
  local wt="$TMP/$1" br="$2"
  ( cd "$R" && git worktree add -q -b "$br" "$wt" ) >/dev/null 2>&1
  ( cd "$wt" && printf 'x\n' > "feat_$1.php" && git add -A && git -c commit.gpgsign=false commit -qm "feat $1" ) >/dev/null 2>&1
  ( cd "$R" && git -c commit.gpgsign=false merge -q --no-edit "$br" ) >/dev/null 2>&1   # main now contains br → 0 ahead
  printf '%s' "$wt"
}

DIRTY_WT="$(mk_merged_wt dirtywt featA)"
printf 'IRREPLACEABLE UNCOMMITTED WORK\n' > "$DIRTY_WT/uncommitted_scratch.txt"   # untracked → would be lost by --force
CLEAN_WT="$(mk_merged_wt cleanwt featB)"   # merged + clean (no extra files)

echo "== v-worktree-gc :: merged+DIRTY KEPT, merged+CLEAN pruned =="
OUT="$(bash "$GC" "$R" --apply 2>&1)"

if [ -d "$DIRTY_WT" ] && [ -f "$DIRTY_WT/uncommitted_scratch.txt" ] && [ "$(cat "$DIRTY_WT/uncommitted_scratch.txt" 2>/dev/null)" = "IRREPLACEABLE UNCOMMITTED WORK" ]; then
  ok "merged-but-DIRTY worktree KEPT — untracked work survived"
else
  no "DATA LOSS: merged dirty worktree pruned / work destroyed" "$OUT"
fi
printf '%s' "$OUT" | grep -qiE 'KEEP.*DIRTY' && ok "reported KEEP-DIRTY loudly" || no "did not warn KEEP-DIRTY" "$OUT"
# Control: the clean merged worktree SHOULD be pruned (proves the GC path is live, so the dirty-KEEP is real).
if [ ! -d "$CLEAN_WT" ]; then ok "merged+CLEAN worktree pruned (GC path live — dirty-KEEP is a real guard, not a no-op)"
else no "clean merged worktree NOT pruned — GC inert, dirty-KEEP would be a false pass" "$OUT"; fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
