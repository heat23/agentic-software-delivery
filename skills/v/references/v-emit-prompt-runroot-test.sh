#!/usr/bin/env bash
# v-emit-prompt-runroot-test.sh — W71-F9 (forensic 2026-07-02).
#
# CLASS UNDER TEST: dispatch-prompt cd-target ambiguity. The templates used to ask
# the RUNNER MODEL to interpret a "set/non-empty/not-literal" sentinel condition on
# WORKTREE_PATH; two gate subprocesses (pre-flight run #2, verify-done run #1)
# mis-cd'd into the main root and produced false results. The fix: v-emit-prompt.sh
# resolves RUN_ROOT deterministically (worktree if one exists, else PROJECT_ROOT)
# and the emitted prompt cds to it UNCONDITIONALLY.
#
# Pins:
#   1. emitted prompt contains the resolved RUN_ROOT as the cd target
#   2. RUN_ROOT == WORKTREE_PATH when a worktree is dispatched
#   3. RUN_ROOT == PROJECT_ROOT when no worktree exists
#   4. no "not-literal" sentinel language survives in any emitted prompt
#   5. no unsubstituted {{RUN_ROOT}} remains (emit exits 0)
#
# Run: bash v-emit-prompt-runroot-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
EMIT="${V_EMIT_PROMPT_SCRIPT:-$HERE/v-emit-prompt.sh}"
# F7 SCOPING (2026-08-29): this harness builds STACKLESS fixture repos (no package.json,
# composer.json, tsconfig, lockfile or vendor bin). v-emit-prompt.sh's F7 pre-dispatch stack gate
# correctly fires there and exits 10 with a DO-NOT-DISPATCH notice instead of a runner prompt —
# which is the intended production behavior, not a defect. This harness asserts MODE / RUN_ROOT
# SUBSTITUTION, a different concern that F7 short-circuits before reaching. Opt out via the gate's
# own documented switch so the assertions below keep testing exactly what they were written to test.
# F7's own behavior is covered by v-predispatch-stack-gate-test.sh (45 assertions).
export V_PREDISPATCH_STACK_GATE=0

[ -f "$EMIT" ] || { echo "SKIP: script-under-test not found ($EMIT)"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }

SID=a7777777-7777-4777-8777-777777777777
# SID2 has NO worktree anywhere — exercises the RUN_ROOT→PROJECT_ROOT fallback
# (with SID's own worktree registered, the dispatcher's SID-scan CORRECTLY finds
# it even when WORKTREE_PATH env is empty — that's the FIX-4 behavior, not a bug).
SID2=b8888888-8888-4888-8888-888888888888

# Fixture: a main repo + an external worktree (mirrors the fleet's real layout).
# pwd -P canonicalizes the mktemp path (macOS /var → /private/var) so the emit
# script's cwd-toplevel comparison sees the same physical path as $PROJECT_ROOT.
R=$(cd "$(mktemp -d)" && pwd -P); WT_DIR=$(cd "$(mktemp -d)" && pwd -P)/wt
( cd "$R" && git init -q . && git symbolic-ref HEAD refs/heads/main \
  && echo base > f.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm base ) || { echo "FATAL: fixture repo"; exit 2; }
git -C "$R" branch -q "fix/thing-$SID"
git -C "$R" worktree add -q "$WT_DIR" "fix/thing-$SID"
mkdir -p "$R/.v/tmp" "$WT_DIR/.v/tmp"

emit(){ # $1=skill $2=worktree-path-or-empty $3=cwd $4=sid
  ( cd "$3" && env CLAUDE_SESSION_ID="${4:-$SID}" PROJECT_ROOT="$R" WORKTREE_PATH="$2" V_TMP_DIR="$R/.v/tmp" \
      bash "$EMIT" "$1" 2>/dev/null )
}

for SKILL in v-pre-flight v-verify-done v-handoff; do
  # Case A: worktree dispatched → RUN_ROOT must be the worktree
  OUT=$(emit "$SKILL" "$WT_DIR" "$R"); RC=$?
  [ "$RC" -eq 0 ] && ok "$SKILL emits cleanly with a worktree (rc=0)" || no "$SKILL emit rc=$RC with a worktree"
  printf '%s' "$OUT" | grep -qF "RUN_ROOT=$WT_DIR" && ok "$SKILL RUN_ROOT header = worktree path" || no "$SKILL RUN_ROOT header missing/wrong (want $WT_DIR)"
  # the OPERATIVE sentinel instruction must be gone (a historical mention in a
  # forensic note is fine — the class is the model-interpreted cd condition)
  printf '%s' "$OUT" | grep -qE 'If WORKTREE_PATH is set/non-empty/not-literal[^,]*, cd' && no "$SKILL still carries the model-interpreted sentinel cd condition" || ok "$SKILL sentinel cd condition removed"
  printf '%s' "$OUT" | grep -q "{{RUN_ROOT}}" && no "$SKILL unsubstituted {{RUN_ROOT}} remains" || ok "$SKILL RUN_ROOT fully substituted"

  # Case B: SID with no worktree anywhere → RUN_ROOT must be PROJECT_ROOT
  OUT=$(emit "$SKILL" "" "$R" "$SID2")
  printf '%s' "$OUT" | grep -qF "RUN_ROOT=$R" && ok "$SKILL RUN_ROOT falls back to PROJECT_ROOT" || no "$SKILL RUN_ROOT fallback wrong (want $R)"
done

# The two gate templates must carry the unconditional cd directive
for SKILL in v-pre-flight v-verify-done; do
  OUT=$(emit "$SKILL" "$WT_DIR" "$R")
  printf '%s' "$OUT" | grep -qF "cd \"$WT_DIR\"" && ok "$SKILL emitted prompt cds unconditionally to RUN_ROOT" || no "$SKILL missing unconditional cd to RUN_ROOT"
done

# W71-review L1: a stale/deleted WORKTREE_PATH fails loudly at emit time (exit 9),
# never emitting a prompt that would cd into a dead path.
emit v-verify-done "$R/no-such-worktree-anywhere" "$R" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 9 ] && ok "stale WORKTREE_PATH refused at emit time (exit 9)" || no "stale WORKTREE_PATH not refused (rc=$RC, want 9)"

git -C "$R" worktree remove --force "$WT_DIR" 2>/dev/null || true
rm -rf "$R" "$(dirname "$WT_DIR")" 2>/dev/null || true

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
