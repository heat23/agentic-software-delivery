#!/usr/bin/env bash
# v-worktree-adopt-or-create-test.sh — A-2 fix (a) class test (HANDOFF_orchestrator-hardening-3.md).
#
# Class test per the plan's own spec: "run bootstrap twice with the same SID in a temp repo -> one
# registered worktree; marker resolves to it; pre-flight path-resolution fixture returns it."
#
# SECTION 1 pins the RED repro: the OLD raw unconditional `git worktree add` pattern (no adoption
# check — byte-identical to the pre-fix v-build-workflows.md inline block) mints a SECOND worktree
# for the same SID across a simulated compaction-restart with slug drift. This documents the bug this
# file's SECTION 2/3 fix; it is not itself "fixed" (the raw pattern is retired, not patched in place).
#
# SECTION 2 proves v-worktree-adopt-or-create.sh: called twice with the SAME SID (different slug the
# 2nd call, simulating slug drift after a restart) -> ONE worktree total, both calls resolve to the
# SAME path, second call reports WORKTREE_ADOPTED=true with a refreshed lock pid.
#
# SECTION 3 proves the per-SID bootstrap marker + v-emit-prompt.sh WORKTREE_PATH resolution correctly
# binds to the single adopted worktree (not main), using the same emit_wt harness pattern as
# canary2-fix4-worktree-context-test.sh.
#
# Re-run: bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; exit 0; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ADOPT="$HERE/v-worktree-adopt-or-create.sh"
EMIT="$HERE/v-emit-prompt.sh"
[ -f "$ADOPT" ] || { echo "SKIP: v-worktree-adopt-or-create.sh missing"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

CLEANUP_LIST=""
_track(){ CLEANUP_LIST="$CLEANUP_LIST $1"; }
# W71 hygiene (2026-07-02): the script-under-test writes $HOME/.claude/runtime/active-worktree-<sid>
# on every successful create — sweep this suite's fixture-SID markers too (a20000xx prefix is
# strictly fixture-shaped), or every run leaks live-sibling signals into the real runtime dir
# (observed: 8 stale fixture markers, some read by v-bootstrap.sh's liveness checks).
trap 'for d in $CLEANUP_LIST; do rm -rf "$d"; done; rm -f "$HOME/.claude/runtime/active-worktree-a20000"*' EXIT

mk_repo(){
  local tmp; tmp=$(mktemp -d); _track "$tmp"
  local r="$tmp/repo"; mkdir -p "$r"
  ( cd "$r" && git init -q -b main && echo x>f && git add -A && git -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1
  (cd "$r" && pwd -P)
}

echo "== SECTION 1: RED repro — raw unconditional worktree-add pattern mints 2 worktrees for 1 SID =="
R1=$(mk_repo)
SID1="a2000001-1111-4111-8111-111111111111"
WT1="$R1/.worktrees/fix-alpha-${SID1}"
git -C "$R1" worktree add -q "$WT1" -b "fix/alpha-${SID1}" >/dev/null 2>&1
printf '%s %s %s\n' "$SID1" "$$" "$(date +%s)" > "$WT1/.claude-session-lock"
# simulated restart: same SID, model picks a DIFFERENT slug, raw pattern has no adoption check
WT2="$R1/.worktrees/fix-beta-${SID1}"
git -C "$R1" worktree add -q "$WT2" -b "fix/beta-${SID1}" >/dev/null 2>&1
printf '%s %s %s\n' "$SID1" "$$" "$(date +%s)" > "$WT2/.claude-session-lock"
_COUNT=$(git -C "$R1" worktree list --porcelain | grep -c '^worktree ')
if [ "$_COUNT" -eq 3 ]; then   # main + WT1 + WT2
  ok "RED confirmed: raw pattern produces 2 worktrees ($_COUNT git-worktree-list entries incl. main) for 1 SID across slug drift"
else
  no "RED not reproduced (unexpected worktree count $_COUNT — investigate before trusting the fix below)" "expected 3, got $_COUNT"
fi

echo "== SECTION 2: v-worktree-adopt-or-create.sh — same SID adopts instead of minting a 2nd worktree =="
R2=$(mk_repo)
SID2="a2000002-2222-4222-8222-222222222222"
export WORKTREES_EXTERNAL_BASE="$R2/.worktrees-ext"
OUT1=$(cd "$R2" && bash "$ADOPT" fix "alpha" "$SID2" "$R2" 2>"$R2/.err1")
ADOPTED1=$(printf '%s\n' "$OUT1" | grep '^WORKTREE_ADOPTED=' | cut -d= -f2)
PATH1=$(printf '%s\n' "$OUT1" | grep '^WORKTREE_ABS_PATH=' | cut -d= -f2- | tr -d "'")
if [ "$ADOPTED1" = "false" ] && [ -n "$PATH1" ] && [ -d "$PATH1" ]; then
  ok "first call creates a fresh worktree (WORKTREE_ADOPTED=false), path exists: $PATH1"
else
  no "first call did not create as expected" "ADOPTED1=$ADOPTED1 PATH1=$PATH1 stderr=$(cat "$R2/.err1" 2>/dev/null)"
fi

# simulated restart: SAME SID, model picks a DIFFERENT slug ("beta") the second time
OUT2=$(cd "$R2" && bash "$ADOPT" fix "beta" "$SID2" "$R2" 2>"$R2/.err2")
ADOPTED2=$(printf '%s\n' "$OUT2" | grep '^WORKTREE_ADOPTED=' | cut -d= -f2)
PATH2=$(printf '%s\n' "$OUT2" | grep '^WORKTREE_ABS_PATH=' | cut -d= -f2- | tr -d "'")
if [ "$ADOPTED2" = "true" ]; then
  ok "second call (slug drift, same SID) ADOPTS instead of creating (WORKTREE_ADOPTED=true)"
else
  no "second call did not adopt" "ADOPTED2=$ADOPTED2 stderr=$(cat "$R2/.err2" 2>/dev/null)"
fi
if [ "$PATH1" = "$PATH2" ]; then
  ok "both calls resolve to the SAME worktree path ($PATH2)"
else
  no "paths diverged — a second worktree was minted" "PATH1=$PATH1 PATH2=$PATH2"
fi
_COUNT2=$(git -C "$R2" worktree list --porcelain | grep -c '^worktree ')
if [ "$_COUNT2" -eq 2 ]; then   # main + the one adopted worktree
  ok "exactly ONE worktree registered for the SID after 2 calls with slug drift (git worktree list: $_COUNT2 entries incl. main)"
else
  no "wrong worktree count after adopt" "expected 2 (main+1), got $_COUNT2"
fi
# lock refreshed on adopt: PIDs can coincidentally repeat (OS reuses a just-exited PID on a fast
# sequential launch — observed live, not a meaningful signal). Prove the WRITE actually happened by
# mtime instead: touch a sentinel strictly before call 3 (below re-adopts the same worktree again),
# then assert the lock file's mtime is >= the sentinel's — i.e. the adopt path re-wrote it, rather
# than silently skipping the write and leaving call 1's file untouched.
sleep 1
SENTINEL="$R2/.sentinel"; touch "$SENTINEL"
sleep 1
bash "$ADOPT" fix "delta" "$SID2" "$R2" >/dev/null 2>"$R2/.err3b"
if [ "$PATH2/.claude-session-lock" -nt "$SENTINEL" ]; then
  ok "adopted worktree's lock file re-written on a subsequent adopt call (mtime newer than pre-call sentinel)"
else
  no "lock file NOT re-written on adopt" "$(cat "$R2/.err3b" 2>/dev/null)"
fi

echo "== SECTION 2b: different SID never adopts another session's worktree =="
SID3="a2000003-3333-4333-8333-333333333333"
OUT3=$(cd "$R2" && bash "$ADOPT" fix "gamma" "$SID3" "$R2" 2>/dev/null)
ADOPTED3=$(printf '%s\n' "$OUT3" | grep '^WORKTREE_ADOPTED=' | cut -d= -f2)
PATH3=$(printf '%s\n' "$OUT3" | grep '^WORKTREE_ABS_PATH=' | cut -d= -f2- | tr -d "'")
if [ "$ADOPTED3" = "false" ] && [ "$PATH3" != "$PATH2" ]; then
  ok "a DIFFERENT SID creates its own worktree, never adopts SID2's ($PATH3)"
else
  no "cross-SID adoption leak" "ADOPTED3=$ADOPTED3 PATH3=$PATH3 PATH2=$PATH2"
fi

echo "== SECTION 3: WORKTREE_PATH resolution binds to the single adopted worktree (not main) =="
if [ -f "$EMIT" ]; then
  mkdir -p "$PATH2/.v/tmp"
  printf '%s\n' "$(git -C "$R2" rev-parse HEAD)" > "$PATH2/.v/tmp/head-baseline-${SID2}.txt"
  OUT4=$(cd "$R2" && CLAUDE_SESSION_ID="$SID2" SESSION_ID="$SID2" PROJECT_ROOT="$R2" V_TMP_DIR="$R2/.v/tmp" \
      bash "$EMIT" v-pre-flight 2>"$R2/.err4")
  RESOLVED_WT=$(grep -oE "$(printf '%s' "$PATH2" | sed 's/[.[\*^$/]/\\&/g')" "$R2/.err4" "$R2/.out4" 2>/dev/null | head -1)
  # fall back: scan stderr diagnostic line directly
  [ -z "$RESOLVED_WT" ] && RESOLVED_WT=$(grep -F "$PATH2" "$R2/.err4" 2>/dev/null | head -1)
  if [ -n "$RESOLVED_WT" ]; then
    ok "v-emit-prompt.sh resolved WORKTREE_PATH to the adopted worktree, not main"
  else
    no "v-emit-prompt.sh did not resolve to the adopted worktree" "$(cat "$R2/.err4" 2>/dev/null | tail -5)"
  fi
else
  echo "  SKIP: v-emit-prompt.sh missing, skipping Section 3"
fi

echo "== SECTION 4 (codex CDX-2): free-text slug/SID inputs are sanitized, never fed raw to git =="
R4=$(mk_repo)
SID4="a2000004-4444-4444-8444-444444444444"
export WORKTREES_EXTERNAL_BASE="$R4/.worktrees-ext"
# 4a: a slug with a space (realistic free-text model output) must NOT fail deep inside
# `git worktree add` — the helper sanitizes it to a valid ref/path and succeeds.
OUT4A=$(cd "$R4" && bash "$ADOPT" fix "fix login bug" "$SID4" "$R4" 2>"$R4/.err4a"); RC4A=$?
PATH4A=$(printf '%s\n' "$OUT4A" | grep '^WORKTREE_ABS_PATH=' | cut -d= -f2- | tr -d "'")
if [ "$RC4A" -eq 0 ] && [ -n "$PATH4A" ] && [ -d "$PATH4A" ]; then
  case "$PATH4A" in
    *" "*) no "slug sanitization left a space in the worktree path" "$PATH4A" ;;
    *) ok "slug with a space sanitized and created cleanly ($PATH4A)" ;;
  esac
else
  no "slug with a space failed the helper (rc=$RC4A) — the CDX-1/CDX-2 silent-contamination trigger" "$(cat "$R4/.err4a" 2>/dev/null)"
fi
# 4b: an SID carrying ref/path-hostile characters must exit LOUDLY at validation (exit 2),
# never reach git worktree add.
(cd "$R4" && bash "$ADOPT" fix "delta" "bad sid/with hostile chars" "$R4" >/dev/null 2>"$R4/.err4b"); RC4B=$?
if [ "$RC4B" -eq 2 ] && grep -qi 'sid' "$R4/.err4b" 2>/dev/null; then
  ok "hostile SID rejected at validation (exit 2 with a clear SID diagnostic)"
else
  no "hostile SID not rejected at validation" "rc=$RC4B stderr=$(cat "$R4/.err4b" 2>/dev/null)"
fi

echo "== SECTION 5 (codex CDX-3): concurrent same-SID invocations mint exactly ONE worktree =="
R5=$(mk_repo)
SID5="a2000005-5555-4555-8555-555555555555"
export WORKTREES_EXTERNAL_BASE="$R5/.worktrees-ext"
# Two truly-parallel invocations racing the scan->create window (the fork/subagent race, distinct
# from the serial restart Section 2 covers).
(cd "$R5" && bash "$ADOPT" fix "alpha" "$SID5" "$R5" >/dev/null 2>&1) &
_P1=$!
(cd "$R5" && bash "$ADOPT" fix "beta" "$SID5" "$R5" >/dev/null 2>&1) &
_P2=$!
wait "$_P1" "$_P2" 2>/dev/null
_COUNT5=$(git -C "$R5" worktree list --porcelain | grep -c '^worktree ')
if [ "$_COUNT5" -eq 2 ]; then   # main + exactly one
  ok "parallel same-SID race -> exactly ONE worktree (git worktree list: $_COUNT5 entries incl. main)"
else
  no "parallel same-SID race minted $((_COUNT5-1)) worktrees (TOCTOU window open)" "expected 2 incl. main, got $_COUNT5"
fi
# Wiring: the mutex must follow the established portable mkdir-lock pattern (macOS has no flock)
# and must be RELEASED on exit so a crashed holder cannot deadlock later invocations forever.
if grep -q 'adopt-.*lock' "$ADOPT" && grep -qE 'trap .*rmdir' "$ADOPT"; then
  ok "per-SID mkdir-mutex present with trap-based release (matches v-merge-back/v-suite-lock convention)"
else
  no "no mkdir-mutex + trap release found in the helper — scan->create critical section unguarded" ""
fi

echo "== SECTION 6 (codex CDX-1/CDX-4): call sites guard failure loudly; outputs fully documented =="
WF="$HERE/v-build-workflows.md"
if [ -f "$WF" ]; then
  _SITES=$(grep -c 'v-worktree-adopt-or-create.sh' "$WF")
  _GUARDED=$(grep -c '_wt_rc' "$WF")
  if [ "$_SITES" -ge 3 ] && [ "$_GUARDED" -ge "$_SITES" ]; then
    ok "all $_SITES call sites carry the rc + WORKTREE_ABS_PATH guard (helper failure can no longer be swallowed by eval \"\")"
  else
    no "call sites unguarded — a helper failure evals empty output and the workflow proceeds on an unset WORKTREE_ABS_PATH" "sites=$_SITES guarded=$_GUARDED"
  fi
  _BR_DOC=$(grep -c 'WORKTREE_BRANCH' "$WF")
  if [ "$_BR_DOC" -ge 3 ]; then
    ok "WORKTREE_BRANCH documented at all call sites (SKILL.md Step 4.1 depends on it being set)"
  else
    no "WORKTREE_BRANCH undocumented — a future cleanup could drop the output SKILL.md Step 4.1 reads" "mentions=$_BR_DOC"
  fi
else
  no "v-build-workflows.md missing" ""
fi

echo "== SUMMARY: $PASS ok / $FAIL failed =="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
