#!/usr/bin/env bash
# v-worktree-gc-test.sh — regression harness for v-worktree-gc.sh (forensic 2026-06-19).
# Proves the GC reclaims MERGED+done worktrees but NEVER prunes an UNMERGED one (pruning unmerged work
# is the data-loss class) and skips MERGED-but-active (fresh-lock) worktrees.
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
HERE="$(cd "$(dirname "$0")" && pwd)"
GC="$HERE/v-worktree-gc.sh"
[ -f "$GC" ] || { echo "NO v-worktree-gc.sh missing"; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }

T="$(mktemp -d)"; trap 'rm -rf "$T" 2>/dev/null' EXIT
R="$T/repo"; mkdir -p "$R"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
( cd "$R" && git init -q -b main && echo base > f && git add f && git commit -qm base ) >/dev/null 2>&1

# MERGED + done: branch work lands in main, no lock -> reclaimable.
git -C "$R" worktree add -q "$R/.worktrees/wt-merged" -b b-merged HEAD >/dev/null 2>&1
( cd "$R/.worktrees/wt-merged" && echo m > m && git add m && git commit -qm merged ) >/dev/null 2>&1
git -C "$R" merge -q --no-edit b-merged >/dev/null 2>&1

# UNMERGED: branch is ahead of main -> MUST be kept (stranded-work protection).
git -C "$R" worktree add -q "$R/.worktrees/wt-ahead" -b b-ahead HEAD >/dev/null 2>&1
( cd "$R/.worktrees/wt-ahead" && echo a > a && git add a && git commit -qm ahead ) >/dev/null 2>&1

# MERGED but ACTIVE (fresh lock) -> kept.
git -C "$R" worktree add -q "$R/.worktrees/wt-active" -b b-active HEAD >/dev/null 2>&1
( cd "$R/.worktrees/wt-active" && echo c > c && git add c && git commit -qm active ) >/dev/null 2>&1
git -C "$R" merge -q --no-edit b-active >/dev/null 2>&1
printf 'somesid now\n' > "$R/.worktrees/wt-active/.claude-session-lock"

OUT=$(bash "$GC" "$R" 2>&1)
# codex HIGH: the main checkout ($R, on the main branch) must NEVER be a GC target (would prune the
# repo root if MAIN_ROOT extraction ever failed; main..main==0 looks "merged"). It must not appear as a
# PRUNE/KEEP decision target for the bare main root path.
printf '%s' "$OUT" | grep -qE "(PRUNE|KEEP[^—]*): ${R}$" && no "main checkout ($R) appeared as a GC target" "$OUT" \
  || ok "main-branch checkout never a GC target (repo root protected)"
printf '%s' "$OUT" | grep -q 'WOULD PRUNE.*wt-merged' && ok "merged+done -> WOULD PRUNE (dry-run)" || no "merged+done not flagged for prune" "$OUT"
printf '%s' "$OUT" | grep -q 'KEEP — UNMERGED.*wt-ahead' && ok "unmerged (ahead of main) -> KEEP (never strand)" || no "unmerged worktree not protected" "$OUT"
printf '%s' "$OUT" | grep -q 'ACTIVE.*wt-active' && ok "merged but fresh-lock -> KEEP (active session)" || no "active worktree not protected" "$OUT"

# --apply: the merged+done one is actually removed; the unmerged one SURVIVES.
bash "$GC" "$R" --apply >/dev/null 2>&1
[ ! -d "$R/.worktrees/wt-merged" ] && ok "--apply removed the merged+done worktree" || no "merged worktree not removed on --apply"
[ -d "$R/.worktrees/wt-ahead" ] && ok "--apply PRESERVED the unmerged worktree (no data loss)" || no "UNMERGED worktree was destroyed by GC (data loss!)"
git -C "$R" rev-list --count main..b-ahead >/dev/null 2>&1 && ok "unmerged branch b-ahead still intact after --apply" || no "unmerged branch lost"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
