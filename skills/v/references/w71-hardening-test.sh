#!/usr/bin/env bash
# w71-hardening-test.sh — regression harness for the 2026-05-29 Opus-4.8 reliability
# pass (W71), derived from three real Sonnet-4.6 /v production sessions.
#
# Groups:
#   L — session-lock git-invisibility (worktree-lock-exclude.sh) + merge-back robust
#       filter. Root cause of a stray-commit-on-main corruption.
#   R — destructive-git Rule 10b in worktree-safety.sh: branch-pointer-moving resets
#       (`git reset --mixed <sha>`) blocked; safe unstage/own-history allowed. Portable
#       (no GNU-only `\b`).
#   T — truth gate: a code-changing session whose final report claims "no-op / already
#       fixed / not a real bug" gets a non-blocking TRUTH-GATE warning.
#   P — pre-flight skip-as-pass: a code-changing session may NOT pass with the FULL TEST
#       SUITE skipped for time/budget; baseline-less "pre-existing" claims warn.
#   I — gate independence: QA/UX/WF artifacts must show an INDEPENDENT dispatch (Agent/
#       Task subagent_type, claude -p subprocess, or DISPATCH_PROVENANCE), else an honest
#       degraded declaration; a silently hand-authored verdict is blocked.
#   M — model guard: a code-changing /v session on a non-Opus model warns (the frontmatter
#       `model: opus` is not honored for inline /v).
#
# Re-run: bash <thisfile>. Self-contained; isolated $HOME for the Stop-hook tests.
set -uo pipefail
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

REF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REAL_HOME="$HOME"
HOOK="$REAL_HOME/.claude/hooks/check-review-artifact.sh"
WTS="$REAL_HOME/.claude/hooks/worktree-safety.sh"
LOCK_EXCL_LIB="$REAL_HOME/.claude/hooks/lib/worktree-lock-exclude.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

BASE=$(mktemp -d /tmp/w71.XXXXXX); trap 'rm -rf "$BASE" 2>/dev/null' EXIT
FHOME="$BASE/home"; mkdir -p "$FHOME/.claude/runtime"
ln -s "$REAL_HOME/.claude/hooks" "$FHOME/.claude/hooks"
[ -d "$REAL_HOME/.claude/agents" ] && ln -s "$REAL_HOME/.claude/agents" "$FHOME/.claude/agents"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
SID="ffff1111-2222-4333-8444-555566667777"

new_repo(){ local R="$BASE/$1"; mkdir -p "$R"; ( cd "$R" && git init -q && echo x>.keep && git add -A && git commit -qm init ) >/dev/null 2>&1; REPLY="$(cd "$R" && pwd -P)"; }

# run_stop repo sid [last_msg] [transcript_path]
run_stop(){
  local repo="$1" sid="$2" msg="${3:-Implementation complete. Done.}" tx="${4:-}" j
  if [ -n "$tx" ]; then
    j=$(jq -nc --arg s "$sid" --arg m "$msg" --arg t "$tx" '{session_id:$s,last_assistant_message:$m,transcript_path:$t,stop_hook_active:false}')
  else
    j=$(jq -nc --arg s "$sid" --arg m "$msg" '{session_id:$s,last_assistant_message:$m,stop_hook_active:false}')
  fi
  ( cd "$repo" && env -i HOME="$FHOME" PATH="$PATH" HOOKS_LIB_DIR="$FHOME/.claude/hooks/lib" CLAUDE_PROJECT_DIR="$repo" bash "$HOOK" <<<"$j" )
}
plant_v_history(){ printf '{"sessionId":"%s","display":"/v fix"}\n' "$1" >> "$FHOME/.claude/history.jsonl"; }
make_code_changed(){ # repo sid — commit a .ts since a planted head-baseline → CODE_CHANGED=1
  local R="$1" sid="$2" b; b=$(cd "$R" && git rev-parse HEAD)
  mkdir -p "$R/.v/tmp"; printf '%s\n' "$b" > "$R/.v/tmp/head-baseline-${sid}.txt"
  ( cd "$R" && mkdir -p src && echo 'export const x=1;' > src/foo.ts && git add -A && git commit -qm code ) >/dev/null 2>&1
}
valid_qa(){ printf 'Model: haiku\n\n## QA Acceptance\n\nverdict: pass\n\nChecked everything thoroughly across the full acceptance surface and it holds.\n' > "$1"; }

# ════════════════════════════════════════════════════════════════════════════
# Group L — session-lock git-invisibility
# ════════════════════════════════════════════════════════════════════════════
echo "=== L1: lock-exclude hides an untracked .claude-session-lock from git status ==="
new_repo Lrepo; LR="$REPLY"
( cd "$LR" && git worktree add -q .worktrees/wt -b wt HEAD ) >/dev/null 2>&1
echo "$SID 1700000000" > "$LR/.worktrees/wt/.claude-session-lock"
before=$(git -C "$LR/.worktrees/wt" status --porcelain)
( source "$LOCK_EXCL_LIB"; exclude_session_lock_from_git "$LR/.worktrees/wt" ) >/dev/null 2>&1
after=$(git -C "$LR/.worktrees/wt" status --porcelain)
{ [ -n "$before" ] && [ -z "$after" ]; } \
  && ok "untracked lock visible before, invisible after exclude" \
  || no "L1: lock still visible after exclude (before='$before' after='$after')"

echo "=== L2: exclude is idempotent (one line, not N) ==="
( source "$LOCK_EXCL_LIB"; exclude_session_lock_from_git "$LR/.worktrees/wt"; exclude_session_lock_from_git "$LR/.worktrees/wt" ) >/dev/null 2>&1
EXCL=$(cd "$LR/.worktrees/wt" && git rev-parse --git-path info/exclude)
case "$EXCL" in /*) : ;; *) EXCL="$LR/.worktrees/wt/$EXCL";; esac
n=$(grep -c 'claude-session-lock' "$EXCL" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "exclude entry present exactly once after repeated calls" || no "L2: exclude has $n lock lines (want 1)"

echo "=== L3: merge-back robust filter ignores a TRACKED+modified lock (old anchor missed it) ==="
( cd "$LR/.worktrees/wt" && git add -f .claude-session-lock && git commit -qm "tracked lock" ) >/dev/null 2>&1
echo "$SID 9999999999" > "$LR/.worktrees/wt/.claude-session-lock"   # now ' M .claude-session-lock'
old_anchor=$(git -C "$LR/.worktrees/wt" status --porcelain | grep -vE '^\?\? \.claude-session-lock$')
new_anchor=$(git -C "$LR/.worktrees/wt" status --porcelain | grep -vE '[[:space:]]\.claude-session-lock$')
{ [ -n "$old_anchor" ] && [ -z "$new_anchor" ]; } \
  && ok "tracked-modified lock: old anchor false-fails, W71 anchor sees clean" \
  || no "L3: filter wrong (old='$old_anchor' new='$new_anchor')"

# ════════════════════════════════════════════════════════════════════════════
# Group R — destructive-git Rule 10b (reset guard) via the REAL hook
# ════════════════════════════════════════════════════════════════════════════
# Feed worktree-safety.sh a tool_input.command and read the permissionDecision.
wts(){ local _o; _o=$(jq -nc --arg c "$1" '{tool_input:{command:$c}}' | env HOME="$FHOME" bash "$WTS" 2>/dev/null); printf '%s' "$_o" | grep -qE '"permissionDecision":[[:space:]]*"deny"' && echo DENY || echo ALLOW; }

echo "=== R1: git reset --mixed <sha> is DENIED (branch-pointer move) ==="
[ "$(wts 'git reset --mixed abc12345')" = DENY ] && ok "reset --mixed <sha> denied" || no "R1: reset --mixed <sha> NOT denied"
echo "=== R2: git reset <sha> (default mixed) is DENIED ==="
[ "$(wts 'git reset deadbeef')" = DENY ] && ok "reset <sha> denied" || no "R2: reset <sha> NOT denied"
echo "=== R3: git reset --soft origin/main is DENIED ==="
[ "$(wts 'git reset --soft origin/main')" = DENY ] && ok "reset --soft <branch> denied" || no "R3: reset --soft <branch> NOT denied"
echo "=== R4: git reset (unstage) is ALLOWED ==="
[ "$(wts 'git reset')" = ALLOW ] && ok "bare reset allowed" || no "R4: bare reset wrongly denied"
echo "=== R5: git reset HEAD -- file is ALLOWED (unstage one file) ==="
[ "$(wts 'git reset HEAD -- src/foo.ts')" = ALLOW ] && ok "reset HEAD -- file allowed" || no "R5: reset HEAD -- file wrongly denied"
echo "=== R6: git reset --soft HEAD~1 is ALLOWED (own recent history) ==="
[ "$(wts 'git reset --soft HEAD~1')" = ALLOW ] && ok "reset --soft HEAD~1 allowed" || no "R6: reset --soft HEAD~1 wrongly denied"
echo "=== R7: echo MENTIONING reset is ALLOWED (not segment-start) ==="
[ "$(wts 'echo "remember to git reset main"')" = ALLOW ] && ok "echo mentioning reset allowed" || no "R7: benign echo of reset wrongly denied"

# ════════════════════════════════════════════════════════════════════════════
# Group T — truth gate (warning)
# ════════════════════════════════════════════════════════════════════════════
echo "=== T1: code changed + 'already fixed / not in executable code' report -> TRUTH-GATE warning ==="
new_repo Trepo; TR="$REPLY"; plant_v_history "$SID"; make_code_changed "$TR" "$SID"
ERR=$( run_stop "$TR" "$SID" "This bug is already fixed — the error does not exist in executable code, only in the test file. Clear your cache." 2>&1 )
echo "$ERR" | grep -q 'TRUTH GATE' && ok "denial-narrative + code change -> truth-gate warning" || no "T1: truth-gate warning absent"

echo "=== T2: code changed + honest 'I implemented the fix' report -> NO truth-gate warning ==="
new_repo Trepo2; TR2="$REPLY"; plant_v_history "$SID"; make_code_changed "$TR2" "$SID"
ERR=$( run_stop "$TR2" "$SID" "Implemented the idempotent re-surface in the controller and added 4 tests. Done." 2>&1 )
echo "$ERR" | grep -q 'TRUTH GATE' && no "T2: truth-gate FALSE-fired on an honest report" || ok "honest report -> no truth-gate warning"

echo "=== T3: NO code change + denial language -> NO truth-gate warning (clean chat) ==="
new_repo Trepo3; TR3="$REPLY"
ERR=$( run_stop "$TR3" "$SID" "There was nothing to fix; not a real bug." 2>&1 )
echo "$ERR" | grep -q 'TRUTH GATE' && no "T3: truth-gate fired without a code change" || ok "no code change -> no truth-gate warning"

# ════════════════════════════════════════════════════════════════════════════
# Group P — pre-flight skip-as-pass
# ════════════════════════════════════════════════════════════════════════════
echo "=== T4: code changed + 'already fixed upstream — I ADDED a regression test' -> NO warning (mixed report) ==="
new_repo Trepo4; TR4="$REPLY"; plant_v_history "$SID"; make_code_changed "$TR4" "$SID"
ERR=$( run_stop "$TR4" "$SID" "This was already fixed upstream; I added a regression test to lock it in." 2>&1 )
echo "$ERR" | grep -q 'TRUTH GATE' && no "T4: workclaim suppression failed (mixed report warned)" || ok "denial + work-claim (added a test) -> suppressed, no truth-gate warning"

echo "=== P1: code changed + PRE_FLIGHT skips full suite for wall-clock budget -> BLOCK ==="
new_repo Prepo; PR="$REPLY"; plant_v_history "$SID"; make_code_changed "$PR" "$SID"
printf 'Model: haiku\n\n| PASS | Lint | ok |\n| PASS | TSC | ok |\n| SKIP | Full Test Suite (Pest) | exceeds wall-clock budget |\n' > "$PR/PRE_FLIGHT_REPORT_${SID}.md"
ERR=$( run_stop "$PR" "$SID" 2>&1 )
echo "$ERR" | grep -q 'skipped the FULL TEST SUITE for time/budget' && ok "time/budget full-suite skip -> blocked" || no "P1: full-suite time-skip not blocked"

echo "=== P2: code changed + legit build skip (no JS changed) -> NO skip-block ==="
new_repo Prepo2; PR2="$REPLY"; plant_v_history "$SID"; make_code_changed "$PR2" "$SID"
printf 'Model: haiku\n\n| PASS | PHP Tests | 1200 passed |\n| SKIP | Build (npm run build) | no CSS/JS changes in modified files |\n' > "$PR2/PRE_FLIGHT_REPORT_${SID}.md"
ERR=$( run_stop "$PR2" "$SID" 2>&1 )
echo "$ERR" | grep -q 'skipped the FULL TEST SUITE for time/budget' && no "P2: legit build skip wrongly blocked" || ok "legit non-time skip -> not blocked"

echo "=== P3: pre-existing failures claimed with NO baseline -> warning ==="
new_repo Prepo3; PR3="$REPLY"; plant_v_history "$SID"; make_code_changed "$PR3" "$SID"
printf 'Model: haiku\n\n| PASS | PHP Tests | 11192 passed, 150 pre-existing failures |\n| PASS | Build | ok |\n' > "$PR3/PRE_FLIGHT_REPORT_${SID}.md"
ERR=$( run_stop "$PR3" "$SID" 2>&1 )
echo "$ERR" | grep -q "claims 'pre-existing' failures without a baseline" && ok "pre-existing w/o baseline -> warning" || no "P3: pre-existing-no-baseline warning absent"

echo "=== P4: pre-existing WITH a baseline reference -> NO warning ==="
new_repo Prepo4; PR4="$REPLY"; plant_v_history "$SID"; make_code_changed "$PR4" "$SID"
printf 'Model: haiku\n\n| PASS | PHP Tests | 150 pre-existing (confirmed vs baseline diff against clean HEAD/merge-base) |\n| PASS | Build | ok |\n' > "$PR4/PRE_FLIGHT_REPORT_${SID}.md"
ERR=$( run_stop "$PR4" "$SID" 2>&1 )
echo "$ERR" | grep -q "claims 'pre-existing' failures without a baseline" && no "P4: baseline ref still warned" || ok "pre-existing WITH baseline -> no warning"

# ════════════════════════════════════════════════════════════════════════════
# Group I — gate independence (QA_REPORT)
# ════════════════════════════════════════════════════════════════════════════
mk_tx(){ printf '%s\n' "$1" > "$2"; }   # content path

echo "=== I1: valid QA_REPORT, readable transcript, NO dispatch, no declaration -> BLOCK (hand-authored) ==="
new_repo Irepo1; IR1="$REPLY"; plant_v_history "$SID"; make_code_changed "$IR1" "$SID"
valid_qa "$IR1/QA_REPORT_${SID}.md"
TX1="$BASE/tx1.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":"wrote the qa report myself"}}' "$TX1"
ERR=$( run_stop "$IR1" "$SID" "Done." "$TX1" 2>&1 )
echo "$ERR" | grep -q 'appears hand-authored' && ok "hand-authored QA verdict (transcript shows no dispatch) -> blocked" || no "I1: hand-authored QA not blocked"

echo "=== I2: valid QA_REPORT + transcript shows Agent dispatch subagent_type=v-qa-reviewer -> NOT hand-authored ==="
new_repo Irepo2; IR2="$REPLY"; plant_v_history "$SID"; make_code_changed "$IR2" "$SID"
valid_qa "$IR2/QA_REPORT_${SID}.md"
TX2="$BASE/tx2.jsonl"; mk_tx '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"v-qa-reviewer"}}]}}' "$TX2"
ERR=$( run_stop "$IR2" "$SID" "Done." "$TX2" 2>&1 )
echo "$ERR" | grep -q 'appears hand-authored' && no "I2: legit Agent-tool dispatch wrongly blocked" || ok "Agent-tool dispatch recognized -> QA not blocked as hand-authored"

echo "=== I3: valid QA_REPORT + DISPATCH_PROVENANCE log (claude -p path) -> NOT hand-authored ==="
new_repo Irepo3; IR3="$REPLY"; plant_v_history "$SID"; make_code_changed "$IR3" "$SID"
valid_qa "$IR3/QA_REPORT_${SID}.md"
printf 'DISPATCH|ts=2026-05-29T00:00:00Z|agent=v-qa-reviewer|mode=self-write|status=ok|submodel=haiku|cost_usd=|duration_ms=|artifact=QA_REPORT_%s.md\n' "$SID" > "$IR3/DISPATCH_PROVENANCE_${SID}.log"
TX3="$BASE/tx3.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}' "$TX3"
ERR=$( run_stop "$IR3" "$SID" "Done." "$TX3" 2>&1 )
echo "$ERR" | grep -q 'appears hand-authored' && no "I3: provenance-log dispatch wrongly blocked" || ok "DISPATCH_PROVENANCE recognized -> QA not blocked"

echo "=== I4: valid QA_REPORT + honest 'dispatch: inline' declaration, no dispatch -> WARNING not block ==="
new_repo Irepo4; IR4="$REPLY"; plant_v_history "$SID"; make_code_changed "$IR4" "$SID"
printf 'Model: haiku\ndispatch: inline (forked context — Agent tool unavailable)\n\n## QA Acceptance\n\nverdict: pass\n\nSelf-reviewed acceptance against the original request; dispatch was unavailable.\n' > "$IR4/QA_REPORT_${SID}.md"
TX4="$BASE/tx4.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}' "$TX4"
ERR=$( run_stop "$IR4" "$SID" "Done." "$TX4" 2>&1 )
{ ! echo "$ERR" | grep -q 'appears hand-authored'; } && echo "$ERR" | grep -q 'declares a self-authored/degraded fallback' \
  && ok "honest inline declaration -> warning, not block" || no "I4: declaration not honored as warning"

echo "=== I6: QA verdict:escalated + BLOCKED companion, no dispatch -> NOT independence-blocked ==="
new_repo Irepo6; IR6="$REPLY"; plant_v_history "$SID"; make_code_changed "$IR6" "$SID"
printf 'Model: haiku\n\n## QA Acceptance\n\nverdict: escalated\n\nDispatch was unavailable after 3 attempts; surfacing unresolved findings honestly.\n' > "$IR6/QA_REPORT_${SID}.md"
printf '# BLOCKED\n\nUnresolved QA findings + SME analyses; dispatch could not run.\n' > "$IR6/BLOCKED_${SID}.md"
TX6="$BASE/tx6.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}' "$TX6"
ERR=$( run_stop "$IR6" "$SID" "Escalated." "$TX6" 2>&1 )
echo "$ERR" | grep -q 'appears hand-authored' && no "I6: honest escalation false-blocked as hand-authored" || ok "verdict:escalated + BLOCKED is not independence-blocked"

echo "=== I5: valid QA_REPORT, NO transcript AND NO provenance baseline -> I1 fail-close (BLOCK) ==="
# I1 (forensic 2026-06-17): verdict:pass + transcript unreadable + ZERO sha baseline = no
# tamper-evidence (a later fail->pass flip would be invisible) -> recoverable BLOCK. This case USED to be
# a warn (it enshrined the exact hole); the baseline fail-close now closes it.
new_repo Irepo5; IR5="$REPLY"; plant_v_history "$SID"; make_code_changed "$IR5" "$SID"
valid_qa "$IR5/QA_REPORT_${SID}.md"   # NO DISPATCH_PROVENANCE at all
ERR=$( run_stop "$IR5" "$SID" "Done." "$BASE/does-not-exist.jsonl" 2>&1 )
echo "$ERR" | grep -q 'tamper-evidence baseline' \
  && ok "no transcript + no baseline -> I1 fail-close (block on missing tamper baseline)" || no "I5: zero-evidence QA not fail-closed"

echo "=== I5b: I1 NEGATIVE CONTROL — no transcript BUT a sha baseline IS on record -> unverifiable WARN, not block ==="
new_repo Irepo5b; IR5B="$REPLY"; plant_v_history "$SID"; make_code_changed "$IR5B" "$SID"
valid_qa "$IR5B/QA_REPORT_${SID}.md"
# a v-qa-reviewer self-record line WITH a sha256 baseline (mode=agent-self stays out of independence, but
# the sha is the tamper baseline) — independence is still 'unverifiable' (no transcript) but evidence exists.
printf 'DISPATCH|ts=2026-05-29T00:00:00Z|agent=v-qa-reviewer|mode=agent-self|status=ok|submodel=haiku|cost_usd=0|duration_ms=0|artifact=QA_REPORT_%s.md|sha256=%s\n' \
  "$SID" "0000000000000000000000000000000000000000000000000000000000000000" > "$IR5B/DISPATCH_PROVENANCE_${SID}.log"
ERR=$( run_stop "$IR5B" "$SID" "Done." "$BASE/does-not-exist.jsonl" 2>&1 )
{ ! echo "$ERR" | grep -q 'tamper-evidence baseline'; } && echo "$ERR" | grep -q 'independence could not be verified' \
  && ok "no transcript BUT baseline present -> unverifiable warning, not block (I1 FP-safe)" || no "I5b: baseline-present unverifiable wrongly blocked"

# ════════════════════════════════════════════════════════════════════════════
# Group PI — PRE_FLIGHT independence (no silent inline degradation; W-perf-runner)
# A CLEAN pre-flight on a code-changing session must come from an INDEPENDENT
# v-pre-flight-runner dispatch, OR honestly declare the degraded-inline fallback.
# A hand-written clean PRE_FLIGHT after a runner failure (a past incident) is blocked.
# Mirrors Group I. CRITICAL false-block guards: dispatched/declared/unverifiable never block.
# ════════════════════════════════════════════════════════════════════════════
valid_preflight_pass(){ printf 'Model: haiku\n\n## Gates\n\n| PASS | Lint | ok |\n| PASS | TSC | ok |\n| PASS | Build | ok |\n| PASS | Full Test Suite (Pest) | 1200 passed |\n\nOverall Status: PASS\n' > "$1"; }

echo "=== PI1: clean PRE_FLIGHT, readable transcript, NO dispatch, no declaration -> BLOCK (hand-authored) ==="
new_repo PIrepo1; PI1R="$REPLY"; plant_v_history "$SID"; make_code_changed "$PI1R" "$SID"
valid_preflight_pass "$PI1R/PRE_FLIGHT_REPORT_${SID}.md"
TXP1="$BASE/txp1.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-opus-4-8","content":"ran the gates inline myself and wrote the report"}}' "$TXP1"
ERR=$( run_stop "$PI1R" "$SID" "Done." "$TXP1" 2>&1 )
echo "$ERR" | grep -q 'PRE_FLIGHT_REPORT appears hand-authored' && ok "hand-authored clean pre-flight (no dispatch) -> blocked" || no "PI1: hand-authored pre-flight not blocked"

echo "=== PI2: clean PRE_FLIGHT + DISPATCH_PROVENANCE agent=v-pre-flight-runner status=ok -> NOT blocked ==="
new_repo PIrepo2; PI2R="$REPLY"; plant_v_history "$SID"; make_code_changed "$PI2R" "$SID"
valid_preflight_pass "$PI2R/PRE_FLIGHT_REPORT_${SID}.md"
printf 'DISPATCH|ts=2026-05-31T00:00:00Z|agent=v-pre-flight-runner|mode=capture|status=ok|submodel=haiku|cost_usd=|duration_ms=|artifact=PRE_FLIGHT_REPORT_%s.md\n' "$SID" > "$PI2R/DISPATCH_PROVENANCE_${SID}.log"
TXP2="$BASE/txp2.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-opus-4-8"}}' "$TXP2"
ERR=$( run_stop "$PI2R" "$SID" "Done." "$TXP2" 2>&1 )
echo "$ERR" | grep -q 'PRE_FLIGHT_REPORT appears hand-authored' && no "PI2: provenance-log dispatch wrongly blocked" || ok "DISPATCH_PROVENANCE status=ok -> pre-flight not blocked"

echo "=== PI3: clean PRE_FLIGHT + transcript shows v-dispatch-subagent.sh --agent v-pre-flight-runner -> NOT blocked ==="
new_repo PIrepo3; PI3R="$REPLY"; plant_v_history "$SID"; make_code_changed "$PI3R" "$SID"
valid_preflight_pass "$PI3R/PRE_FLIGHT_REPORT_${SID}.md"
TXP3="$BASE/txp3.jsonl"; mk_tx '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash ~/.claude/skills/v/references/v-dispatch-subagent.sh --agent v-pre-flight-runner --prompt-file p"}}]}}' "$TXP3"
ERR=$( run_stop "$PI3R" "$SID" "Done." "$TXP3" 2>&1 )
echo "$ERR" | grep -q 'PRE_FLIGHT_REPORT appears hand-authored' && no "PI3: transcript --agent dispatch wrongly blocked" || ok "transcript --agent v-pre-flight-runner -> pre-flight not blocked"

echo "=== PI4: clean PRE_FLIGHT + honest 'Dispatch: degraded-inline' declaration, no dispatch -> WARNING not block ==="
new_repo PIrepo4; PI4R="$REPLY"; plant_v_history "$SID"; make_code_changed "$PI4R" "$SID"
printf 'Model: haiku\nDispatch: degraded-inline (subprocess errored, independence lost)\n\n## Gates\n\n| PASS | Lint | ok |\n| PASS | Build | ok |\n| PASS | Full Test Suite (Pest) | 1200 passed |\n\nOverall Status: PASS\n' > "$PI4R/PRE_FLIGHT_REPORT_${SID}.md"
TXP4="$BASE/txp4.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-opus-4-8"}}' "$TXP4"
ERR=$( run_stop "$PI4R" "$SID" "Done." "$TXP4" 2>&1 )
{ ! echo "$ERR" | grep -q 'PRE_FLIGHT_REPORT appears hand-authored'; } && echo "$ERR" | grep -q 'declares a degraded-inline fallback' \
  && ok "honest degraded-inline declaration -> warning, not block" || no "PI4: degraded declaration not honored as warning"

echo "=== PI5: clean PRE_FLIGHT, NO transcript available -> unverifiable WARNING, not block ==="
new_repo PIrepo5; PI5R="$REPLY"; plant_v_history "$SID"; make_code_changed "$PI5R" "$SID"
valid_preflight_pass "$PI5R/PRE_FLIGHT_REPORT_${SID}.md"
ERR=$( run_stop "$PI5R" "$SID" "Done." "$BASE/no-such-tx.jsonl" 2>&1 )
{ ! echo "$ERR" | grep -q 'PRE_FLIGHT_REPORT appears hand-authored'; } && echo "$ERR" | grep -q 'PRE_FLIGHT_REPORT independence could not be verified' \
  && ok "no transcript -> unverifiable warning, not block" || no "PI5: missing-transcript not degraded to warning"

echo "=== PI6: FAILING PRE_FLIGHT + no dispatch -> blocked for the FAILURE, NOT independence-blocked (scoping) ==="
new_repo PIrepo6; PI6R="$REPLY"; plant_v_history "$SID"; make_code_changed "$PI6R" "$SID"
printf 'Model: haiku\n\n## Gates\n\n❌ tests FAILED: 3 failed (Pest)\n| PASS | Build | ok |\n\nOverall Status: FAIL\n' > "$PI6R/PRE_FLIGHT_REPORT_${SID}.md"
TXP6="$BASE/txp6.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-opus-4-8"}}' "$TXP6"
ERR=$( run_stop "$PI6R" "$SID" "Done." "$TXP6" 2>&1 )
{ echo "$ERR" | grep -q 'PRE_FLIGHT_REPORT has FAILED gates'; } && { ! echo "$ERR" | grep -q 'PRE_FLIGHT_REPORT appears hand-authored'; } \
  && ok "failing pre-flight blocked for the failure, not double-blocked on independence" || no "PI6: independence check wrongly fired on a failing (non-claimed-pass) report"

echo "=== PI7: canonical \$HELPER-variable dispatch form (transcript signal blind per SREV-001) + valid provenance -> NOT blocked ==="
# Locks the adversarial-review finding: under SKILL.md's documented dispatch (HELPER=...;
# bash "\$HELPER" --agent v-pre-flight-runner), the _TX_SIGNALS extractor matches nothing
# (the literal .sh and --agent land on different lines), so the DISPATCH_PROVENANCE log is
# the load-bearing independence signal. This proves a real-world dispatch is NOT false-blocked.
new_repo PIrepo7; PI7R="$REPLY"; plant_v_history "$SID"; make_code_changed "$PI7R" "$SID"
valid_preflight_pass "$PI7R/PRE_FLIGHT_REPORT_${SID}.md"
printf 'DISPATCH|ts=2026-05-31T00:00:00Z|agent=v-pre-flight-runner|mode=capture|status=ok|submodel=haiku|cost_usd=|duration_ms=|artifact=PRE_FLIGHT_REPORT_%s.md\n' "$SID" > "$PI7R/DISPATCH_PROVENANCE_${SID}.log"
TXP7="$BASE/txp7.jsonl"
{ printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"HELPER=~/.claude/skills/v/references/v-dispatch-subagent.sh"}]}}';
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash \"$HELPER\" --agent v-pre-flight-runner --prompt-file p"}}]}}'; } > "$TXP7"
ERR=$( run_stop "$PI7R" "$SID" "Done." "$TXP7" 2>&1 )
echo "$ERR" | grep -q 'PRE_FLIGHT_REPORT appears hand-authored' && no "PI7: canonical dispatch form false-blocked (provenance not load-bearing!)" || ok "provenance carries the load under \$HELPER-form dispatch -> not blocked"

# ════════════════════════════════════════════════════════════════════════════
# Group M — model policy telemetry
# ════════════════════════════════════════════════════════════════════════════
echo "=== M1: code-changing /v session on Sonnet-only transcript -> Sonnet expected policy ==="
new_repo Mrepo; MR="$REPLY"; plant_v_history "$SID"; make_code_changed "$MR" "$SID"
TXM="$BASE/txm.jsonl"; { echo '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}'; echo '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}'; } > "$TXM"
ERR=$( run_stop "$MR" "$SID" "Done." "$TXM" 2>&1 )
{ echo "$ERR" | grep -q 'V_MODEL_POLICY=sonnet_active_expected' && ! echo "$ERR" | grep -qE 'MODEL — this code-changing /v session ran on|/model opus'; } \
  && ok "Sonnet /v code session -> expected-cost telemetry, no Opus nudge" || no "M1: Sonnet policy telemetry absent or Opus nudge still present"

echo "=== M2: transcript shows Opus -> high-cost policy telemetry ==="
new_repo Mrepo2; MR2="$REPLY"; plant_v_history "$SID"; make_code_changed "$MR2" "$SID"
TXM2="$BASE/txm2.jsonl"; { echo '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}'; echo '{"type":"assistant","message":{"model":"claude-opus-4-8"}}'; } > "$TXM2"
ERR=$( run_stop "$MR2" "$SID" "Done." "$TXM2" 2>&1 )
{ echo "$ERR" | grep -q 'V_MODEL_POLICY=opus_active_high_cost' && ! echo "$ERR" | grep -q '/model opus'; } \
  && ok "Opus present -> high-cost telemetry, no switch-to-Opus nudge" || no "M2: Opus policy telemetry absent or legacy nudge fired"

# ════════════════════════════════════════════════════════════════════════════
# Group FA — F3-a: false "codex ran" claim detection in _independence_verdict
# Tests the _independence_verdict function logic directly by wiring up only the
# AGENT_REVIEW signal (PRE_FLIGHT is omitted so those tests block on MISSING_PREFLIGHT,
# and we check specifically whether the AGENT_REVIEW error message is the F3-a
# "silent" path vs. the expected outcome). FA1 checks the F3-a block fires; FA2
# checks that an honest declared fallback does NOT trip F3-a; FA3 checks that a
# real codex dispatch (DISPATCH_PROVENANCE) + "ran" claim is accepted.
# ════════════════════════════════════════════════════════════════════════════

# FA tests use a full-sized preflight and complete QA/IMPACT/VERIFY artifacts
# so the ONLY variable is the AGENT_REVIEW independence verdict.
make_full_artifacts() {
  local R="$1" sid="$2"
  # PRE_FLIGHT: padded to > 1024B with realistic content
  { printf 'Model: haiku\n\n## Gates\n\n'; printf '| PASS | Lint | ok |\n| PASS | TSC | 0 errors |\n| PASS | Build | ok |\n| PASS | Full Test Suite (Pest) | 1200 passed, 0 failed |\n| PASS | Security audit | no critical |\n\nOverall Status: PASS\n\nGate details:\n'; printf '%.0sLine of test output detail.\n' {1..40}; } > "$R/PRE_FLIGHT_REPORT_${sid}.md"
  printf 'DISPATCH|ts=2026-05-31T00:00:00Z|agent=v-pre-flight-runner|mode=capture|status=ok|submodel=haiku|cost_usd=|duration_ms=|artifact=PRE_FLIGHT_REPORT_%s.md\n' "$sid" >> "$R/DISPATCH_PROVENANCE_${sid}.log"
  # IMPACT_MAP: minimal valid
  printf 'subsystems:\n  api: {impacted: no, reason: no route changes}\n  jobs: {impacted: no, reason: no job changes}\n' > "$R/IMPACT_MAP_${sid}.md"
  # QA_REPORT: minimal valid with dispatch provenance
  printf 'Model: haiku\n\n## QA Acceptance\n\nverdict: pass\n\nAll acceptance criteria verified.\n' > "$R/QA_REPORT_${sid}.md"
  printf 'DISPATCH|ts=2026-05-31T00:00:00Z|agent=v-qa-reviewer|mode=capture|status=ok|submodel=haiku|cost_usd=|duration_ms=|artifact=QA_REPORT_%s.md\n' "$sid" >> "$R/DISPATCH_PROVENANCE_${sid}.log"
  # VERIFY_DONE_REPORT: minimal valid
  printf 'Model: haiku\n\n## Convention check\n\nOverall: PASS\n\nAll conventions satisfied.\n' > "$R/VERIFY_DONE_REPORT_${sid}.md"
}

echo "=== FA1: AGENT_REVIEW claims 'Codex adversarial reviewer: ran' + 'Dispatch mode: orchestrator_inline' -> AGENT_REVIEW blocked (false claim) ==="
new_repo FArepo1; FA1R="$REPLY"; plant_v_history "$SID"; make_code_changed "$FA1R" "$SID"
make_full_artifacts "$FA1R" "$SID"
# AGENT_REVIEW: inline dispatch but falsely claims codex ran
printf 'Model: haiku\nDispatch mode: orchestrator_inline (codex unavailable)\n\n## Findings\n\nCodex adversarial reviewer: ran\n\nNo critical issues found.\n\nOverall: SAFE\nstatus: pass\n' > "$FA1R/AGENT_REVIEW_${SID}.md"
TXFA1="$BASE/txfa1.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":"ran codex inline"}}' "$TXFA1"
ERR=$( run_stop "$FA1R" "$SID" "Done." "$TXFA1" 2>&1 )
echo "$ERR" | grep -qiE 'AGENT_REVIEW.*not semantically valid|appears.*orchestrator.inline self-review|appears hand-authored' \
  && ok "false 'codex ran' claim + orchestrator_inline -> blocked as silent (not declared)" \
  || no "FA1: false 'codex ran' claim not blocked (F3-a regression)"

echo "=== FA2: AGENT_REVIEW with honest 'dispatch: inline' declaration + superpowers mention, NO false 'ran' claim -> NOT F3-a blocked ==="
new_repo FArepo2; FA2R="$REPLY"; plant_v_history "$SID"; make_code_changed "$FA2R" "$SID"
make_full_artifacts "$FA2R" "$SID"
# AGENT_REVIEW: honest declared fallback using the syntax _independence_verdict recognizes,
# mentions superpowers (as the mandatory fallback), no false "codex ran" claim — F3-a must NOT fire.
printf 'Model: haiku\ndispatch: inline (codex unavailable, superpowers fallback attempted: timed out)\n\n## Findings\n\nNo critical issues found.\n\nOverall: SAFE\nstatus: pass\n' > "$FA2R/AGENT_REVIEW_${SID}.md"
TXFA2="$BASE/txfa2.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}' "$TXFA2"
ERR=$( run_stop "$FA2R" "$SID" "Done." "$TXFA2" 2>&1 )
# F3-a must not have fired — the error, if any, should NOT be about a false "ran" claim
# (the "appears hand-authored / orchestrator-inline self-review" message is the silent path)
echo "$ERR" | grep -qiE 'appears.*orchestrator.inline self-review.*false claim|F3.a' \
  && no "FA2: honest declared fallback triggered F3-a (false positive)" \
  || ok "honest 'dispatch: inline' (no false ran claim) -> F3-a did not fire"

echo "=== FA3: AGENT_REVIEW with real codex dispatch (DISPATCH_PROVENANCE) + 'Codex adversarial reviewer: ran' -> NOT blocked ==="
new_repo FArepo3; FA3R="$REPLY"; plant_v_history "$SID"; make_code_changed "$FA3R" "$SID"
make_full_artifacts "$FA3R" "$SID"
# DISPATCH_PROVENANCE: real codex dispatch entry
printf 'DISPATCH|ts=2026-05-31T00:00:01Z|agent=codex-adversarial-reviewer|mode=capture|status=ok|submodel=haiku|cost_usd=|duration_ms=|artifact=AGENT_REVIEW_%s.md\n' "$SID" >> "$FA3R/DISPATCH_PROVENANCE_${SID}.log"
# AGENT_REVIEW: real dispatch, mentions ran — F3-a must NOT fire (dispatch evidence exists)
printf 'Model: haiku\n\n## Findings\n\nCodex adversarial reviewer: ran\n\nNo critical issues found.\n\nOverall: SAFE\nstatus: pass\n' > "$FA3R/AGENT_REVIEW_${SID}.md"
TXFA3="$BASE/txfa3.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}' "$TXFA3"
ERR=$( run_stop "$FA3R" "$SID" "Done." "$TXFA3" 2>&1 )
echo "$ERR" | grep -qiE 'AGENT_REVIEW.*not semantically valid.*appears.*orchestrator.inline self-review|appears hand-authored' \
  && no "FA3: real codex dispatch + 'ran' claim wrongly blocked (F3-a false positive)" \
  || ok "real codex dispatch (DISPATCH_PROVENANCE) -> 'ran' claim accepted, not blocked"

echo "=== FA4: AGENT_REVIEW claims 'Codex adversarial reviewer: ran' + STRONG proxy evidence (review-diff) present, NO DISPATCH_PROVENANCE -> NOT blocked ==="
# Forensic: bash-subprocess codex dispatch writes review-diff / codex-review log to
# .v/artifacts/ but does NOT call v-dispatch-subagent.sh -> no DISPATCH_PROVENANCE.
# Fix A in _agent_was_dispatched detects these proxy files as dispatch evidence.
# F3 (audit 2026-06-17): the proxy must bind to REAL session content (a diff), not the
# generic codex-review-prompt template — see FA4b for the negative case.
new_repo FArepo4; FA4R="$REPLY"; plant_v_history "$SID"; make_code_changed "$FA4R" "$SID"
make_full_artifacts "$FA4R" "$SID"
# Remove the DISPATCH_PROVENANCE for codex to simulate bash-subprocess dispatch
grep -v 'codex-adversarial-reviewer' "$FA4R/DISPATCH_PROVENANCE_${SID}.log" > "$FA4R/DISPATCH_PROVENANCE_${SID}.log.tmp" \
  && mv "$FA4R/DISPATCH_PROVENANCE_${SID}.log.tmp" "$FA4R/DISPATCH_PROVENANCE_${SID}.log"
# Write STRONG proxy evidence: review-diff file (the session's real diff, unforgeable without the changes)
printf 'diff --git a/app.php b/app.php\n@@ -1 +1 @@\n-old\n+new\n' > "$FA4R/review-diff-${SID:0:8}.patch"
# AGENT_REVIEW: real dispatch path, claims ran — Fix A proxy evidence must prevent block
printf 'Model: haiku\n\n## Findings\n\nCodex adversarial reviewer: ran — foreground; gpt-5.5; 3 candidates, 3 accepted, 0 rejected\n\nNo critical issues found.\n\nOverall: SAFE\nstatus: pass\n' > "$FA4R/AGENT_REVIEW_${SID}.md"
TXFA4="$BASE/txfa4.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}' "$TXFA4"
ERR=$( run_stop "$FA4R" "$SID" "Done." "$TXFA4" 2>&1 )
echo "$ERR" | grep -qiE 'AGENT_REVIEW.*not semantically valid.*appears.*orchestrator.inline self-review|appears hand-authored' \
  && no "FA4: strong proxy evidence (review-diff) falsely blocked by F3-a (Fix A regression)" \
  || ok "strong proxy evidence (review-diff, no DISPATCH_PROVENANCE) -> 'ran' claim accepted via Fix A"

echo "=== FA4b: 'Codex adversarial reviewer: ran' + ONLY codex-review-prompt present (codex never ran), NO DISPATCH_PROVENANCE -> STILL blocked ==="
# F3 (audit 2026-06-17): a lone codex-review-prompt is a generic template written BEFORE codex
# exec — it proves nothing ran. It must NOT satisfy 'dispatched'. Negative of FA4.
new_repo FArepo4b; FA4BR="$REPLY"; plant_v_history "$SID"; make_code_changed "$FA4BR" "$SID"
make_full_artifacts "$FA4BR" "$SID"
grep -v 'codex-adversarial-reviewer' "$FA4BR/DISPATCH_PROVENANCE_${SID}.log" > "$FA4BR/DISPATCH_PROVENANCE_${SID}.log.tmp" \
  && mv "$FA4BR/DISPATCH_PROVENANCE_${SID}.log.tmp" "$FA4BR/DISPATCH_PROVENANCE_${SID}.log"
# ONLY the prompt template — no diff, no log, no provenance
printf 'You are a codex adversarial reviewer. Review the diff below...\n' > "$FA4BR/codex-review-prompt-${SID:0:8}.txt"
printf 'Model: haiku\n\n## Findings\n\nCodex adversarial reviewer: ran — foreground; gpt-5.5; 3 candidates, 3 accepted, 0 rejected\n\nNo critical issues found.\n\nOverall: SAFE\nstatus: pass\n' > "$FA4BR/AGENT_REVIEW_${SID}.md"
TXFA4B="$BASE/txfa4b.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}' "$TXFA4B"
ERR=$( run_stop "$FA4BR" "$SID" "Done." "$TXFA4B" 2>&1 )
echo "$ERR" | grep -qiE 'AGENT_REVIEW.*not semantically valid|appears.*orchestrator.inline self-review|appears hand-authored' \
  && ok "prompt-only proxy (codex never ran) -> 'ran' claim correctly BLOCKED (F3 hardening)" \
  || no "FA4b: prompt-only proxy wrongly accepted as dispatch proof (F3 regression — codex-review-prompt should not count)"

echo "=== FA5: 'Codex adversarial reviewer: ran' + NO proof of any kind -> still blocked ==="
# No DISPATCH_PROVENANCE, no proxy evidence, no TX signal -> Fix A finds nothing -> Fix #2 blocks
new_repo FArepo5; FA5R="$REPLY"; plant_v_history "$SID"; make_code_changed "$FA5R" "$SID"
make_full_artifacts "$FA5R" "$SID"
# Remove codex DISPATCH_PROVENANCE entry
grep -v 'codex-adversarial-reviewer' "$FA5R/DISPATCH_PROVENANCE_${SID}.log" > "$FA5R/DISPATCH_PROVENANCE_${SID}.log.tmp" \
  && mv "$FA5R/DISPATCH_PROVENANCE_${SID}.log.tmp" "$FA5R/DISPATCH_PROVENANCE_${SID}.log"
# No proxy files written
printf 'Model: haiku\n\n## Findings\n\nCodex adversarial reviewer: ran — foreground; gpt-5.5; 2 candidates\n\nNo critical issues found.\n\nOverall: SAFE\nstatus: pass\n' > "$FA5R/AGENT_REVIEW_${SID}.md"
TXFA5="$BASE/txfa5.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}' "$TXFA5"
ERR=$( run_stop "$FA5R" "$SID" "Done." "$TXFA5" 2>&1 )
echo "$ERR" | grep -qiE 'AGENT_REVIEW.*not semantically valid|appears hand-authored' \
  && ok "'ran' claim + no dispatch evidence + no proxy files -> still blocked (Fix #2 preserved)" \
  || no "FA5: 'ran' claim with zero evidence not blocked (Fix #2 regression)"

# ════════════════════════════════════════════════════════════════════════════
# Group FB — F8-b: PRE_FLIGHT size minimum is blocking (< 1024B)
# A real gate report for a non-trivial project is at least 1024B. A stub or
# wrong-project artifact (the W3-31 incident: a 960B report from the wrong repo)
# must be rejected, not just warned about.
# ════════════════════════════════════════════════════════════════════════════

echo "=== FB1: PRE_FLIGHT structurally valid (has ## Gates) but < 1024B -> BLOCK (too small) ==="
new_repo FBrepo1; FB1R="$REPLY"; plant_v_history "$SID"; make_code_changed "$FB1R" "$SID"
# Write a small but structurally valid PRE_FLIGHT (< 1024B)
printf 'Model: haiku\n\n## Gates\n\n| PASS | Lint | ok |\n| PASS | Build | ok |\n\nOverall Status: PASS\n' > "$FB1R/PRE_FLIGHT_REPORT_${SID}.md"
_fb1_size=$(wc -c < "$FB1R/PRE_FLIGHT_REPORT_${SID}.md" | tr -d ' ')
TXFB1="$BASE/txfb1.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}' "$TXFB1"
ERR=$( run_stop "$FB1R" "$SID" "Done." "$TXFB1" 2>&1 )
echo "$ERR" | grep -qiE 'PRE_FLIGHT_REPORT.*too small|PRE_FLIGHT_REPORT not found' \
  && ok "PRE_FLIGHT ${_fb1_size}B (< 1024B) blocked even with ## Gates header" \
  || no "FB1: small PRE_FLIGHT (${_fb1_size}B) not blocked (F8-b regression)"

echo "=== FB2: PRE_FLIGHT >= 1024B -> NOT blocked by F8-b size gate ==="
new_repo FBrepo2; FB2R="$REPLY"; plant_v_history "$SID"; make_code_changed "$FB2R" "$SID"
# Write a large enough PRE_FLIGHT (>= 1024B)
valid_preflight_pass "$FB2R/PRE_FLIGHT_REPORT_${SID}.md"
# Pad it to ensure it's >= 1024B if the helper function is small
_fb2_size=$(wc -c < "$FB2R/PRE_FLIGHT_REPORT_${SID}.md" | tr -d ' ')
if [ "${_fb2_size:-0}" -lt 1024 ]; then
  printf '\n\nTest output:\n%s\n' "$(printf 'x%.0s' {1..900})" >> "$FB2R/PRE_FLIGHT_REPORT_${SID}.md"
fi
_fb2_size=$(wc -c < "$FB2R/PRE_FLIGHT_REPORT_${SID}.md" | tr -d ' ')
printf 'DISPATCH|ts=2026-05-31T00:00:00Z|agent=v-pre-flight-runner|mode=capture|status=ok|submodel=haiku|cost_usd=|duration_ms=|artifact=PRE_FLIGHT_REPORT_%s.md\n' "$SID" > "$FB2R/DISPATCH_PROVENANCE_${SID}.log"
TXFB2="$BASE/txfb2.jsonl"; mk_tx '{"type":"assistant","message":{"model":"claude-sonnet-4-6"}}' "$TXFB2"
ERR=$( run_stop "$FB2R" "$SID" "Done." "$TXFB2" 2>&1 )
echo "$ERR" | grep -qiE 'PRE_FLIGHT_REPORT.*too small' \
  && no "FB2: adequate PRE_FLIGHT (${_fb2_size}B) wrongly blocked by F8-b size gate" \
  || ok "PRE_FLIGHT ${_fb2_size}B (>= 1024B) not size-blocked"

echo
echo "═══════════ RESULT: $PASS passed, $FAIL failed ═══════════"
[ "$FAIL" -eq 0 ]
