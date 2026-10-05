#!/usr/bin/env bash
# v-merge-back-evidence-reconcile-test.sh — R4c (forensic 2026-06-20). Drives the REAL
# v-merge-back.sh and asserts the session's .v/tmp EVIDENCE (head-baseline + commit witness) is
# reconciled from the worktree into MAIN's .v/tmp BEFORE the prune destroys it — so the post-prune
# /v-session-log gather can resolve BASE_SHA instead of collapsing to merge_base_fallback → base==end →
# files_changed=[] → HIGH-5 hollow-log finalize BLOCK (the class that lost ~90% of worktree-session
# telemetry). Also proves the "never clobber main's authoritative copy" guard.
set -u
MB="$HOME/.claude/skills/v/references/v-merge-back.sh"
MBBAK="$HOME/.claude/skills/v/references/v-merge-back.sh.pre-p1batch-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
skip(){ printf '  skip %s — %s\n' "$1" "${2:-}"; }   # pre-fix backups are not shipped in the public snapshot
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$MB" ] || { echo "NO v-merge-back.sh missing"; exit 1; }
export V_MERGE_BACK_SKIP_ARTIFACT_GATE=1   # isolate evidence reconciliation from the artifact-presence gate

SID="abcd1234-5678-9012-3456-7890abcdef12"; S8=$(printf '%s' "$SID" | cut -c1-8)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mk_repo(){ rm -rf "$1"; mkdir -p "$1/.v/tmp"
  # .v/ is gitignored (as in real projects) so worktree .v/tmp evidence isn't "uncommitted changes".
  ( cd "$1" && git init -q && git symbolic-ref HEAD refs/heads/main \
    && printf '.v/\n' > .gitignore \
    && printf 'l1\nl2\n' > app.php && git add -A && git commit -qm init ) >/dev/null 2>&1; }
wt_setup(){ git -C "$1" worktree add -q "$2" -b "$3" HEAD 2>/dev/null
  ( cd "$2" && echo new > "$4" && git add "$4" && git commit -qm "wt work" ) >/dev/null 2>&1
  mkdir -p "$2/.v/tmp"; printf '%s\n' "$4" > "$1/.v/tmp/session-writes-${SID}.txt"; }
run_mb(){ ( cd "$1" && V_TMP_DIR="$1/.v/tmp" REPO_ROOT="$1" bash "$MB" "$SID" "$2" ) > "$TMP/out" 2>&1; }

echo "== v-merge-back evidence reconciliation (R4c) =="

# 1. head-baseline written ONLY in the worktree -> after a clean merge+prune it must exist in MAIN .v/tmp.
R1="$TMP/r1"; mk_repo "$R1"
PRE1="$(git -C "$R1" rev-parse HEAD)"                         # pre-session HEAD = the session's true BASE
wt_setup "$R1" "$R1/.worktrees/wt-${S8}" "fix/work-${S8}" "f1.php"
printf '%s\n' "$PRE1" > "$R1/.worktrees/wt-${S8}/.v/tmp/head-baseline-${SID}.txt"   # worktree-only
printf '2026-06-20T00:00:00Z\n' > "$R1/.worktrees/wt-${S8}/.v/tmp/session-start-${SID}.txt"  # worktree-only (defensive)
[ ! -e "$R1/.v/tmp/head-baseline-${SID}.txt" ] || no "precondition: main already had head-baseline"
run_mb "$R1" "$R1/.worktrees/wt-${S8}"
[ ! -d "$R1/.worktrees/wt-${S8}" ] && ok "worktree pruned (merge completed)" || no "worktree not pruned" "$(cat "$TMP/out")"
if [ -s "$R1/.v/tmp/head-baseline-${SID}.txt" ] && [ "$(cat "$R1/.v/tmp/head-baseline-${SID}.txt")" = "$PRE1" ]; then
  ok "head-baseline reconciled worktree -> main .v/tmp with the correct pre-session SHA (HIGH-5 root closed)"
else
  no "head-baseline NOT on main after prune -> gather would hit base==end" "main=$(cat "$R1/.v/tmp/head-baseline-${SID}.txt" 2>/dev/null)"
fi
# and the commit witness exists on main (reconstructed L971 and/or reconciled) -> HIGH-5 has its source
[ -s "$R1/.v/tmp/commits-${SID}.txt" ] && ok "commit witness present on main (files_changed source)" || no "no commit witness on main" "$(cat "$TMP/out")"
[ -s "$R1/.v/tmp/session-start-${SID}.txt" ] && ok "session-start reconciled worktree -> main (defensive depth)" || no "session-start not reconciled" "$(ls "$R1/.v/tmp" 2>/dev/null | tr '\n' ' ')"
# DUC durability (2026-06-23): session-start ALSO lands in main's DURABLE .v/artifacts so a later .v/tmp sweep
# can't strand the gather's start grounding (the gather now reads .v/artifacts/session-start as a fallback).
[ -s "$R1/.v/artifacts/session-start-${SID}.txt" ] && ok "session-start written to DURABLE .v/artifacts (DUC sweep-survival)" || no "session-start NOT in durable .v/artifacts" "$(ls "$R1/.v/artifacts" 2>/dev/null | tr '\n' ' ')"
# DUC merge-resolve member (2026-06-23): the merge-resolve log (worktree.created evidence) also lands durably.
[ -s "$R1/.v/artifacts/merge-resolve-${SID}.log" ] && ok "merge-resolve log written to DURABLE .v/artifacts (worktree.created survives a .v/tmp sweep)" || no "merge-resolve NOT in durable .v/artifacts" "$(ls "$R1/.v/artifacts" 2>/dev/null | tr '\n' ' ')"

# 2. don't-clobber: main ALREADY has a head-baseline (the authoritative one) -> the worktree's must NOT
#    overwrite it.
R2="$TMP/r2"; mk_repo "$R2"
PRE2="$(git -C "$R2" rev-parse HEAD)"
wt_setup "$R2" "$R2/.worktrees/wt-${S8}" "fix/work-${S8}" "f2.php"
printf 'MAIN-AUTHORITATIVE\n' > "$R2/.v/tmp/head-baseline-${SID}.txt"          # main copy already present
printf '%s\n' "$PRE2"         > "$R2/.worktrees/wt-${S8}/.v/tmp/head-baseline-${SID}.txt"  # worktree copy differs
run_mb "$R2" "$R2/.worktrees/wt-${S8}"
[ "$(cat "$R2/.v/tmp/head-baseline-${SID}.txt")" = "MAIN-AUTHORITATIVE" ] \
  && ok "existing main head-baseline NOT clobbered by the worktree copy (guard holds)" \
  || no "worktree copy clobbered main's authoritative head-baseline" "$(cat "$R2/.v/tmp/head-baseline-${SID}.txt")"

# 3. RED oracle (DUC): the pre-p1batch backup reconciles session-start only into .v/tmp, NOT .v/artifacts.
if [ -f "$MBBAK" ]; then
  R3="$TMP/r3"; mk_repo "$R3"
  wt_setup "$R3" "$R3/.worktrees/wt-${S8}" "fix/work-${S8}" "f3.php"
  printf '2026-06-20T00:00:00Z\n' > "$R3/.worktrees/wt-${S8}/.v/tmp/session-start-${SID}.txt"
  ( cd "$R3" && V_TMP_DIR="$R3/.v/tmp" REPO_ROOT="$R3" bash "$MBBAK" "$SID" "$R3/.worktrees/wt-${S8}" ) >/dev/null 2>&1
  [ -s "$R3/.v/artifacts/session-start-${SID}.txt" ] \
    && no "RED: .pre-p1batch-bak wrote the durable .v/artifacts copy" "fix not new" \
    || ok "RED: .pre-p1batch-bak does NOT write session-start to .v/artifacts (DUC bite proven)"
else
  skip "RED oracle absent" "$MBBAK"
fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
