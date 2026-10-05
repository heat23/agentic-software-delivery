#!/usr/bin/env bash
# v-worktree-gc-dirty-dryrun-test.sh — pinning bite for the DRY-RUN widening of the dirty guard
# (false-landed-by-reset, 2026-07-04). The 2026-06-21 dirty guard only ran inside the --apply branch;
# in DRY-RUN a merged-but-DIRTY (ahead==0, staged/untracked) worktree printed "WOULD PRUNE …" —
# an explicit invitation for a human to run the destructive `--force` removal on staged-only work.
# The fix moves the `git status --porcelain` dirty check AHEAD of the --apply branch so BOTH modes
# report KEEP — DIRTY. This companion (v-worktree-gc-dirty-test.sh only covers --apply) pins DRY-RUN.
# Bite: restore v-worktree-gc.sh.pre-dirtydry0704-bak → the merged+dirty worktree prints WOULD PRUNE → RED.
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
printf 'IRREPLACEABLE UNCOMMITTED WORK\n' > "$DIRTY_WT/uncommitted_scratch.txt"   # untracked → --force would destroy
CLEAN_WT="$(mk_merged_wt cleanwt featB)"   # merged + clean control

echo "== v-worktree-gc DRY-RUN :: merged+DIRTY reports KEEP-DIRTY (never WOULD PRUNE); merged+CLEAN reports WOULD PRUNE =="
OUT="$(bash "$GC" "$R" 2>&1)"   # DRY-RUN (default, no --apply)

# 1. dry-run must NOT mislabel the dirty worktree as prunable
if printf '%s' "$OUT" | grep -qiE "WOULD PRUNE.*$(basename "$DIRTY_WT")"; then
  no "DRY-RUN mislabeled merged+DIRTY worktree as WOULD PRUNE (invites destructive --force on staged-only work)" "$OUT"
else
  ok "DRY-RUN did NOT print WOULD PRUNE for the merged+DIRTY worktree"
fi
# 2. dry-run must loudly report KEEP-DIRTY for it
printf '%s' "$OUT" | grep -qiE 'KEEP.*DIRTY' \
  && ok "DRY-RUN reported KEEP-DIRTY loudly" \
  || no "DRY-RUN did not warn KEEP-DIRTY" "$OUT"
# 3. nothing was actually removed (dry-run is non-destructive) — the dirty work survives on disk
if [ -f "$DIRTY_WT/uncommitted_scratch.txt" ] && [ "$(cat "$DIRTY_WT/uncommitted_scratch.txt" 2>/dev/null)" = "IRREPLACEABLE UNCOMMITTED WORK" ]; then
  ok "dry-run non-destructive — untracked work still on disk"
else
  no "dry-run destroyed on-disk work (must never remove anything)" "$OUT"
fi
# 4. CONTROL: the clean merged worktree SHOULD read WOULD PRUNE in dry-run (proves the GC path is live,
#    so the dirty-KEEP above is a real guard and not a blanket "keep everything" no-op).
if printf '%s' "$OUT" | grep -qiE "WOULD PRUNE.*$(basename "$CLEAN_WT")"; then
  ok "merged+CLEAN worktree reads WOULD PRUNE (GC dry-run path live — dirty-KEEP is a real discriminating guard)"
else
  no "merged+CLEAN worktree did NOT read WOULD PRUNE — GC path inert, dirty-KEEP would be a false pass" "$OUT"
fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
