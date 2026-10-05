#!/usr/bin/env bash
# check-session-branch-test.sh — behavioral + negative coverage for the Step-(-1) branch gate
# (audit 2026-06-18, P4). BEFORE this, check-session-branch.sh had only an existence/sentinel check
# (v-hook-integration.test.ts), so a rewrite could silently stop warning on the wrong branch — or
# start warning on main — and the suite stayed green. These cases drive the REAL hook against
# throwaway repos and assert the actual warn/skip behavior, plus the negative (does NOT over-warn on
# main / when suppressed). Lives in hooks/ so harness-test-sweep.sh auto-runs it (no orphan).
set -u
HOOK="$HOME/.claude/hooks/check-session-branch.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s — %s\n' "$1" "$2"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git absent"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq absent";  echo "TOTAL: 0 passed, 0 failed"; exit 0; }
[ -f "$HOOK" ] || { echo "FAIL check-session-branch: hook missing ($HOOK)"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

mkrepo(){ local d; d=$(mktemp -d "${TMPDIR:-/tmp}/csb.XXXXXX")
  git -C "$d" init -q -b main 2>/dev/null || { git -C "$d" init -q; git -C "$d" checkout -q -b main 2>/dev/null; }
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init; echo "$d"; }
# run the hook with CWD inside the repo (it resolves REPO_ROOT from CWD); pass extra env as KEY=VAL args
run(){ local r="$1"; shift; ( cd "$r"; env "$@" bash "$HOOK" 2>/dev/null ); }
warns(){ printf '%s' "$1" | jq -e '.hookSpecificOutput.additionalContext | test("SESSION BRANCH WARNING")' >/dev/null 2>&1; }

# T1 (behavioral): on a feature branch, the hook MUST emit the warning JSON.
R=$(mkrepo); git -C "$R" checkout -q -b feature/x
out=$(run "$R")
warns "$out" && ok "T1 warns on a non-main branch (feature/x)" || no "T1 warns on non-main branch" "no warning JSON emitted: [$out]"

# NOTE: on every skip path the hook `exit 0`s BEFORE the jq emit, so stdout is strictly EMPTY. The
# negatives below assert emptiness STRICTLY (not just "no warning") — a broken hook that emits a
# non-JSON error or a different JSON would then fail here instead of passing as a false "silent".

# T2 (NEGATIVE — must not over-warn): on main, the hook MUST stay silent (strictly empty stdout).
git -C "$R" checkout -q main
out=$(run "$R")
[ -z "$out" ] && ok "T2 silent on main (no false warning)" || no "T2 silent on main" "expected empty output on main, got: [$out]"

# T3 (NEGATIVE — suppression): CLAUDE_ALLOW_NON_MAIN=1 on a feature branch suppresses the warning.
git -C "$R" checkout -q -b feature/y
out=$(run "$R" CLAUDE_ALLOW_NON_MAIN=1)
[ -z "$out" ] && ok "T3 CLAUDE_ALLOW_NON_MAIN=1 suppresses the warning" || no "T3 suppression" "expected empty output, got: [$out]"

# T4 (behavioral — renamed default): CLAUDE_MAIN_BRANCH=develop, sitting on develop → no warning.
git -C "$R" checkout -q -b develop
out=$(run "$R" CLAUDE_MAIN_BRANCH=develop)
[ -z "$out" ] && ok "T4 honors CLAUDE_MAIN_BRANCH override (no warn on configured main)" || no "T4 main-branch override" "expected empty output on configured main 'develop', got: [$out]"

# T5 (NEGATIVE — detached HEAD): a detached HEAD is skipped (no warning).
git -C "$R" checkout -q --detach
out=$(run "$R")
[ -z "$out" ] && ok "T5 detached HEAD skipped (no warning)" || no "T5 detached HEAD" "expected empty output on detached HEAD, got: [$out]"

rm -rf "$R"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
