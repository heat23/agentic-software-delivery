#!/usr/bin/env bash
# fork-payload-guard-test.sh — ORCHFIX-D/H5 class harness (forensics 2026-07-02).
# CLASS: task-identity loss + fork-work duplication. (D) a /v fork that returns "no task" although
# the parent passed args is a FAILED dispatch — marker + re-invoke directive, never proceed-inline.
# (H5) when a fork returns normally but its SID worktree holds dirty/ahead work, surface it BEFORE
# the parent duplicates 40 minutes of its own fork's finished work.
# RED oracle: hooks are NEW — pre-fix settings carried no Skill-matcher guard.
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

HOOK="$HOME/.claude/hooks/fork-payload-guard.sh"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
SID="77770000-aaaa-4aaa-8aaa-000000000001"
ARGS="Fix FINDING TEST-999: a sufficiently long task payload for the forty-char floor check"

fire(){ # <cwd> <resp>
  printf '{"tool_name":"Skill","session_id":"%s","cwd":"%s","tool_input":{"skill":"v","args":"%s"},"tool_response":"%s"}' "$SID" "$1" "$ARGS" "$2" | bash "$HOOK"
}

git -C "$TD" init -q; git -C "$TD" commit -q --allow-empty -m base

# T1: production no-payload signature -> directive + durable marker.
out=$(fire "$TD" "Result: I do not see an actual task or question in your message — it only contains system-reminder context")
echo "$out" | grep -q 'F-PAYLOAD' && ok "T1: no-payload response -> re-invoke directive injected" || no "T1: no directive"
[ -f "$TD/.v/artifacts/V_FORK_NO_PAYLOAD_${SID}.md" ] && ok "T1b: durable V_FORK_NO_PAYLOAD marker written" || no "T1b: marker missing"
rm -f "$TD/.v/artifacts/V_FORK_NO_PAYLOAD_${SID}.md"

# T2: normal completion, no worktree -> silent.
out=$(fire "$TD" "implemented, gauntlet green, merged.")
[ -z "$out" ] && ok "T2: normal fork return -> silent" || no "T2: unexpected output"

# T3 (H5): normal return + dirty SID worktree -> FORK-WORK surfacing context.
WTB="$HOME/.claude/worktrees/$(basename "$TD")"
mkdir -p "$WTB"
git -C "$TD" worktree add -q "$WTB/fix-thing-${SID%%-*}" -b "fix/thing-${SID%%-*}" 2>/dev/null
printf 'fork did this\n' > "$WTB/fix-thing-${SID%%-*}/done.txt"
out=$(fire "$TD" "implemented, waiting on a background test run.")
echo "$out" | grep -q 'FORK-WORK' && ok "T3: dirty SID worktree surfaced before parent re-implements (fork-work duplication class)" \
                                  || no "T3: worktree not surfaced"
git -C "$TD" worktree remove --force "$WTB/fix-thing-${SID%%-*}" 2>/dev/null || true
rm -rf "$WTB"

# T4: non-v skill -> no-op.
out=$(printf '{"tool_name":"Skill","session_id":"%s","cwd":"%s","tool_input":{"skill":"deep-research","args":"%s"},"tool_response":"no task"}' "$SID" "$TD" "$ARGS" | bash "$HOOK")
[ -z "$out" ] && ok "T4: non-/v skill ignored" || no "T4: fired on wrong skill"

# T5: bare /v with no args (legitimate ask-for-task) -> no-op even on a no-task response.
out=$(printf '{"tool_name":"Skill","session_id":"%s","cwd":"%s","tool_input":{"skill":"v","args":""},"tool_response":"I do not see an actual task"}' "$SID" "$TD" | bash "$HOOK")
[ -z "$out" ] && ok "T5: argless /v exempt (asking for a task is legitimate)" || no "T5: fired on argless /v"

# Registration (dual) + RED oracle.
grep -q 'fork-payload-guard' "$HOME/.claude/settings.json" && grep -q 'fork-payload-guard' "$HOME/.claude/settings.headless.json" \
  && ok "dual registration present" || no "not dual-registered"
BAKS="$HOME/.claude/settings.json.pre-orchfix0702-bak"
[ -f "$BAKS" ] && { grep -q 'fork-payload-guard' "$BAKS" && no "T-RED: backup already registered?!" || ok "T-RED oracle: pre-fix settings have no Skill guard (payload loss was invisible)"; }

echo; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
