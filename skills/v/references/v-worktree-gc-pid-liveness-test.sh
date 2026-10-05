#!/usr/bin/env bash
# v-worktree-gc-pid-liveness-test.sh — F3-item4 (2026-07-05) pinning bite.
#
# The OLD `_lock_is_fresh` gated purely on the .claude-session-lock FILE's mtime age
# (V_WT_GC_LOCK_AGE_MIN, default 240 min). A long multi-hour session that has not rewritten its
# own lock within that window read as "session done" by age ALONE, even though its owning PID
# was still genuinely alive (kill -0 succeeds) — this GC would then remove its merged worktree
# out from under it. The fix wires the shared session-lock-parse.sh `lock_alive()` (PID kill -0 +
# transcript liveness, falling back to age only when neither is resolvable) into
# `_lock_is_fresh`, so an OLD-by-mtime lock naming a still-running PID is correctly kept ALIVE.
#
# Bite: restore v-worktree-gc.sh.pre-f3f4-bak (old mtime-only _lock_is_fresh) -> RED (the
# ALIVE-real-PID worktree gets WOULD-PRUNEd / pruned instead of kept).
# Re-run: env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GC="$HERE/v-worktree-gc.sh"
[ -f "$GC" ] || { echo "SKIP: missing v-worktree-gc.sh"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 -- $2"; }

_run_case() {  # <gc_script> -> prints GC output for the fixture below
  local _gc="$1"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP" 2>/dev/null' EXIT
  R="$TMP/main"; mkdir -p "$R"
  ( cd "$R" && git init -q -b main && printf 'a\n' > f.txt && git add -A && git -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1

  # merged + done worktree, no lock at all -> control, should still prune.
  ( cd "$R" && git worktree add -q -b b-done "$TMP/wt-done" ) >/dev/null 2>&1
  ( cd "$TMP/wt-done" && printf 'x\n' > done.txt && git add -A && git -c commit.gpgsign=false commit -qm featdone ) >/dev/null 2>&1
  ( cd "$R" && git -c commit.gpgsign=false merge -q --no-edit b-done ) >/dev/null 2>&1

  # merged worktree whose lock's recorded PID is a REAL, currently-alive process (this test's own
  # shell, $$) but whose lock FILE is artificially aged past AGE_MIN via `touch -t`.
  ( cd "$R" && git worktree add -q -b b-alive "$TMP/wt-alive" ) >/dev/null 2>&1
  ( cd "$TMP/wt-alive" && printf 'y\n' > alive.txt && git add -A && git -c commit.gpgsign=false commit -qm featalive ) >/dev/null 2>&1
  ( cd "$R" && git -c commit.gpgsign=false merge -q --no-edit b-alive ) >/dev/null 2>&1
  printf 'aaaaaaaa-1111-4222-8333-444455556666 %s %s\n' "$$" "$(date +%s)" > "$TMP/wt-alive/.claude-session-lock"
  # Backdate the lock FILE's mtime well past AGE_MIN (240min default) so the OLD mtime-only check
  # would read it as "done" — but the PID ($$) is this very test process, unambiguously alive.
  _old_ts="$(date -v-6H +%Y%m%d%H%M.%S 2>/dev/null || date -d '-6 hours' +%Y%m%d%H%M.%S 2>/dev/null || echo '')"
  [ -n "$_old_ts" ] && touch -t "$_old_ts" "$TMP/wt-alive/.claude-session-lock" 2>/dev/null

  bash "$_gc" "$R" 2>&1
  rm -rf "$TMP" 2>/dev/null; trap - EXIT
}

echo "== v-worktree-gc :: PID-alive-but-old-mtime lock must be KEPT (not pruned) =="
OUT="$(_run_case "$GC")"

printf '%s' "$OUT" | grep -q 'PRUNE.*wt-done' \
  && ok "control: merged+no-lock worktree still flagged for prune (GC path is live)" \
  || no "control: merged+no-lock worktree not flagged — GC path inert, this test proves nothing" "$OUT"

if printf '%s' "$OUT" | grep -qE '(WOULD )?PRUNE.*wt-alive'; then
  no "DATA-LOSS RISK: merged worktree with a confirmed-ALIVE PID ($$) was flagged for prune purely on stale lock mtime" "$OUT"
else
  ok "merged worktree with confirmed-ALIVE PID kept (not flagged for prune) despite a stale-by-mtime lock"
fi
printf '%s' "$OUT" | grep -qiE 'ACTIVE.*wt-alive' \
  && ok "reported as ACTIVE (kill-0-alive PID recognized via lock_alive)" \
  || no "did not report the alive-PID worktree as ACTIVE" "$OUT"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
