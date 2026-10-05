#!/usr/bin/env bash
# stop-rearm-escape-marker-test.sh — F4-item3 (2026-07-05), "next-session-visible debt marker".
#
# rearm_gate()'s deadlock-escape path writes a durable STOP_REARM_ESCAPE_<sid>.md so a future
# session can see there is unresolved gauntlet debt from a prior session. It used to resolve the
# write location via `git rev-parse --show-toplevel` — for a session isolated in a `.worktrees/*`
# linked worktree, that is the THROWAWAY worktree's own root, not the shared main checkout.
# worktree-remove.sh's artifact-rescue only globs maxdepth-1 *.md files at the worktree root (never
# descending into `.v/artifacts/`), so the marker was silently destroyed the instant the worktree
# was cleaned up — never actually visible to a FUTURE session in the same repo. The fix resolves
# the SHARED main repo root via git-common-dir instead (same convention worktree-safety.sh /
# v-drain-deferred-merges.sh already use), so the marker survives worktree teardown.
#
# Bite: restore stop-rearm.sh.pre-f3f4-bak (show-toplevel only) -> RED (from inside a linked
# worktree, the marker lands in the worktree's OWN .v/artifacts, not the shared main root's).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REARM_LIB="${V_REARMLIB_OVERRIDE:-$HERE/stop-rearm.sh}"
[ -f "$REARM_LIB" ] || { echo "SKIP: missing $REARM_LIB"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" 2>/dev/null' EXIT
R="$TMP/main"; mkdir -p "$R"
( cd "$R" && git init -q -b main && echo base > f && git add f && git -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1
git -C "$R" worktree add -q "$TMP/wt" -b br-wt HEAD >/dev/null 2>&1
WT="$TMP/wt"

drive_escape(){  # <cwd> <sid> -> drives rearm_gate to a deadlock escape from within <cwd>
  local cwd="$1" sid="$2"
  ( cd "$cwd"
    export CLAUDE_STOP_REARM_DIR="$TMP/rearm-state-$$-$RANDOM"
    # shellcheck disable=SC1090
    . "$REARM_LIB"
    rearm_init testhook "$sid" false
    rearm_gate testhook "$sid" false "same violation" >/dev/null 2>&1
    rearm_gate testhook "$sid" true  "same violation" >/dev/null 2>&1
    rearm_gate testhook "$sid" true  "same violation" >/dev/null 2>&1   # 3rd identical -> escapes (default MAX_SAME=2)
  )
}

echo "== stop-rearm.sh :: STOP_REARM_ESCAPE marker lands at the SHARED main root, not a worktree's throwaway root =="

SID_WT="aaaa0001-1111-4222-8333-444455556666"
drive_escape "$WT" "$SID_WT"

if [ -f "$WT/.v/artifacts/STOP_REARM_ESCAPE_${SID_WT}.md" ]; then
  no "marker written to the WORKTREE's own (throwaway) .v/artifacts -- lost the instant the worktree is removed" "$(ls "$WT/.v/artifacts" 2>/dev/null)"
else
  ok "marker NOT written to the worktree's own .v/artifacts (would be lost on worktree teardown)"
fi
if [ -f "$R/.v/artifacts/STOP_REARM_ESCAPE_${SID_WT}.md" ]; then
  ok "marker written to the SHARED main repo root's .v/artifacts (survives worktree teardown, next-session-visible)"
else
  no "marker missing from the shared main root entirely -- debt is invisible to a future session" "$(ls "$R/.v/artifacts" 2>/dev/null)"
fi
grep -q "STOP_REARM_ESCAPE" "$R/.v/artifacts/STOP_REARM_ESCAPE_${SID_WT}.md" 2>/dev/null \
  && ok "marker header present and readable at the durable location" \
  || no "marker at the durable location is missing/unreadable" ""

echo "-- teardown simulation: removing the worktree must NOT destroy the debt record --"
git -C "$R" worktree remove --force "$WT" >/dev/null 2>&1
[ -f "$R/.v/artifacts/STOP_REARM_ESCAPE_${SID_WT}.md" ] \
  && ok "marker SURVIVES worktree removal (still visible to a future session in this repo)" \
  || no "marker was lost when the worktree was removed -- exactly the failure mode this fix targets" ""

echo "-- parity: inline-on-main sessions are unaffected (same behavior as before) --"
SID_MAIN="aaaa0002-2222-4222-8333-444455556667"
drive_escape "$R" "$SID_MAIN"
[ -f "$R/.v/artifacts/STOP_REARM_ESCAPE_${SID_MAIN}.md" ] \
  && ok "inline-on-main escape still writes its marker at the repo root (unchanged behavior)" \
  || no "inline-on-main escape marker missing -- regression in the common case" "$(ls "$R/.v/artifacts" 2>/dev/null)"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
