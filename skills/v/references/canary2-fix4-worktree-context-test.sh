#!/usr/bin/env bash
# canary2-fix4-worktree-context-test.sh — FIX-4 (forensic 2026-06-22).
# v-emit-prompt must resolve WORKTREE_PATH for a session whose worktree is named by TASK slug (no SID in the
# path/branch) so the dispatched pre-flight runner grades the session's WORKTREE, not main. It binds by the
# per-SID bootstrap marker (.v/tmp/head-baseline-<SID>.txt) which the path/branch SID-grep would miss.
# Re-run: bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; exit 0; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
EMIT="$HERE/v-emit-prompt.sh"; BAK="$EMIT.pre-canary2-bak"
[ -f "$EMIT" ] || { echo "SKIP: v-emit-prompt missing"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

# main repo + a TASK-SLUG-named worktree (no SID) carrying the per-SID bootstrap marker. Run v-emit-prompt
# from MAIN; echo the resolved WORKTREE_PATH (parsed from stderr + the emitted prompt).
emit_wt(){
  local emit="$1" sid="$2" tmp R WT
  tmp=$(mktemp -d); R="$tmp/repo"; mkdir -p "$R"
  ( cd "$R" && git init -q -b main && echo x>f && git add -A && git -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1
  RP=$(cd "$R" && pwd -P)
  # worktree named by TASK slug — NO SID anywhere in the path or branch
  git -C "$R" worktree add -q "$R/.worktrees/demo-some-task" -b build/demo-some-task >/dev/null 2>&1
  mkdir -p "$R/.worktrees/demo-some-task/.v/tmp"
  printf '%s\n' "$(cd "$R" && git rev-parse HEAD)" > "$R/.worktrees/demo-some-task/.v/tmp/head-baseline-${sid}.txt"
  ( cd "$RP" && CLAUDE_SESSION_ID="$sid" SESSION_ID="$sid" PROJECT_ROOT="$RP" V_TMP_DIR="$RP/.v/tmp" \
      bash "$emit" v-pre-flight ) >"$tmp/out.txt" 2>"$tmp/err.txt"
  # resolved WT: prefer the stderr diagnostic; else grep the emitted prompt's WORKTREE_PATH line
  grep -oE '/[^ ]*/\.worktrees/demo-some-task' "$tmp/err.txt" "$tmp/out.txt" 2>/dev/null | head -1
  echo "$tmp" >> /tmp/.f4-cleanup
}
: > /tmp/.f4-cleanup
trap 'while read -r d; do rm -rf "$d"; done < /tmp/.f4-cleanup 2>/dev/null; rm -f /tmp/.f4-cleanup' EXIT

echo "== FIX-4 :: task-slug worktree (no SID in name) resolved via per-SID bootstrap marker =="
WT=$(emit_wt "$EMIT" "f4440001-1111-4111-8111-111111111111")
case "$WT" in
  */.worktrees/demo-some-task) ok "WORKTREE_PATH resolved to the session's worktree (pre-flight will grade it, not main)" ;;
  "") no "WORKTREE_PATH NOT resolved — pre-flight would run in main (the task-slug worktree bug)" "(empty)" ;;
  *) no "unexpected WT: $WT" "$WT" ;;
esac

# RED: pre-FIX-4 v-emit-prompt only greps the path/branch for the SID -> task-slug worktree missed -> empty.
if [ -f "$BAK" ]; then
  WTR=$(emit_wt "$BAK" "f4440002-2222-4222-8222-222222222222")
  case "$WTR" in
    */.worktrees/demo-some-task) no "RED: pre-FIX-4 already resolved it?! bite not isolating FIX-4" "$WTR" ;;
    *) ok "RED: pre-FIX-4 leaves WORKTREE_PATH unresolved for a task-slug worktree (bite proven — pre-flight grades main)" ;;
  esac
fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
