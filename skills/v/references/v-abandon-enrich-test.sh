#!/usr/bin/env bash
# v-abandon-enrich-test.sh — behavioral harness for the ABANDON-ENRICH classifier + gates
# (2026-07-02, SME-panel plan v3). Covers: the no-completion-language early-exit extension
# (both 2026-07-01 canaries slipped there), Part-B message enrichment, the Part-A
# HANDOFF-laundering check (SME-A-1/D1), stale-capture nulling (SME-L-1/L2-3), capture
# CACHING for rearm-fingerprint stability (SME-L2-1), warn/block/off dial (SME-A-3), and
# the HISTORICAL canary final-messages as fixed regression fixtures (SME-S-8).
set -u
REF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REAL_HOME="$HOME"
HOOK="${V_HOOK_OVERRIDE:-$REAL_HOME/.claude/hooks/check-review-artifact.sh}"   # override = mutation-gate protocol
[ -f "$HOOK" ] || { echo "FAIL: hook missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

BASE=$(mktemp -d /tmp/abenrich.XXXXXX); trap 'rm -rf "$BASE" 2>/dev/null' EXIT
FHOME="$BASE/home"; mkdir -p "$FHOME/.claude/runtime"
ln -s "$REAL_HOME/.claude/hooks" "$FHOME/.claude/hooks"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
SID="abadf00d-1111-4111-8111-1111111111aa"
TASK='fix the typo in the greeting string in hello.js ("Helo" should be "Hello")'

# HISTORICAL FIXTURES (verbatim excerpts from the 2026-07-01 canary sessions)
FABLE_MSG='I did not find any actual task to execute. My real system instructions are explicit: I am a subagent. There is no real task in this session for me to act on.'
SONNET_MSG='I attempted to resolve a task for this /v invocation. All of them came back empty — there is no task content in this conversation to route. Could you tell me what you would like done?'
# Completion-wordLESS no-task ending (the early-exit path both canaries actually took: without
# a completion word the hook previously exit-0'd at the completion-language gate, before Part B).
WORDLESS_MSG='Every channel came back empty. There is no task content in this conversation. What would you like me to do?'

new_repo(){ local R="$BASE/$1"; mkdir -p "$R"; ( cd "$R" && git init -q && echo x>.keep && git add -A && git commit -qm init ) >/dev/null 2>&1; REPLY="$(cd "$R" && pwd -P)"; }
plant_v_history(){ printf '{"sessionId":"%s","display":"/v fix"}\n' "$1" >> "$FHOME/.claude/history.jsonl"; }
seed_capture(){ printf '/v %s\n' "$TASK" > "$FHOME/.claude/runtime/last-user-prompt-${1}.txt"; }
clear_session(){ rm -f "$FHOME/.claude/runtime/last-user-prompt-${1}.txt" "$FHOME/.claude/runtime/last-skill-args-${1}.txt" "$FHOME/.claude/runtime/v-resolved-task-${1}.txt" "$FHOME/.claude/abandonments.jsonl" 2>/dev/null; : > "$FHOME/.claude/history.jsonl"; }
run_stop(){ # repo sid msg [extra_env...]
  local repo="$1" sid="$2" msg="$3"; shift 3
  local j; j=$(jq -nc --arg s "$sid" --arg m "$msg" '{session_id:$s,last_assistant_message:$m,stop_hook_active:false}')
  ( cd "$repo" && env -i HOME="$FHOME" PATH="$PATH" HOOKS_LIB_DIR="$FHOME/.claude/hooks/lib" CLAUDE_PROJECT_DIR="$repo" "$@" bash "$HOOK" <<<"$j" )
}

echo "=== A1: completion-wordLESS no-task msg + captured task + warn(default) → exit 0 + ABANDON_SUSPECT + ledger ==="
clear_session "$SID"; new_repo a1; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
ERR=$( run_stop "$R" "$SID" "$WORDLESS_MSG" 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -q 'ABANDON-ENRICH warn' && [ -f "$R/ABANDON_SUSPECT_${SID}.md" ] && grep -q '"event":"abandon-enrich"' "$FHOME/.claude/abandonments.jsonl"; } \
  && ok "A1 warn soak: previously-silent early-exit now warns + marks (class=no-task)" \
  || no "A1" "rc=$RC marker=$([ -f "$R/ABANDON_SUSPECT_${SID}.md" ] && echo y || echo n) err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 160)]"

echo "=== A1b: wordless msg + capture + block → exit 2 via Part-B enriched (early-exit fall-through) ==="
clear_session "$SID"; new_repo a1b; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
ERR=$( run_stop "$R" "$SID" "$WORDLESS_MSG" V_ABANDON_GATE=block 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'abandon-enrich/no-task' && printf '%s' "$ERR" | grep -qF 'Helo'; } \
  && ok "A1b block: wordless abandonment no longer slips out — enriched Part-B block" \
  || no "A1b" "rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 200)]"

echo "=== A2: same + V_ABANDON_GATE=block → exit 2 with the QUOTED task + W25-F11 line ==="
clear_session "$SID"; new_repo a2; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
ERR=$( run_stop "$R" "$SID" "$SONNET_MSG" V_ABANDON_GATE=block 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'abandon-enrich/no-task' && printf '%s' "$ERR" | grep -qF 'Helo' && printf '%s' "$ERR" | grep -q 'W25-F11'; } \
  && ok "A2 block: Part-B enriched block quotes the real task" \
  || no "A2" "rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 200)]"

echo "=== A3: HISTORICAL Fable-canary msg (role-confusion phrasing) + capture + block → exit 2 ==="
clear_session "$SID"; new_repo a3; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
ERR=$( run_stop "$R" "$SID" "$FABLE_MSG" V_ABANDON_GATE=block 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'abandon-enrich'; } \
  && ok "A3 Fable fixture: refusal message is caught and blocked" \
  || no "A3" "rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 160)]"

echo "=== A4: pure role-confusion sentence + capture + block → exit 2, class=role-confusion ==="
clear_session "$SID"; new_repo a4; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
ERR=$( run_stop "$R" "$SID" 'I am a research sub-agent — handing this back to the parent agent to re-invoke as needed.' V_ABANDON_GATE=block 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'abandon-enrich/role-confusion'; } \
  && ok "A4 role-confusion class fires with W25-F11 recovery" \
  || no "A4" "rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 160)]"

echo "=== A5a: WORDLESS no-task msg + EMPTY capture → clean exit 0, NO marker (sanctioned clarify) ==="
clear_session "$SID"; new_repo a5; R="$REPLY"; plant_v_history "$SID"
ERR=$( run_stop "$R" "$SID" "$WORDLESS_MSG" V_ABANDON_GATE=block 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ] && [ ! -f "$R/ABANDON_SUSPECT_${SID}.md" ]; } \
  && ok "A5a empty capture: no fire even in block mode (sanctioned clarify path untouched)" \
  || no "A5a" "rc=$RC marker=$([ -f "$R/ABANDON_SUSPECT_${SID}.md" ] && echo y || echo n)"

echo "=== A5b: completion-worded no-task msg + EMPTY capture → pre-existing GENERIC Part-B block, unenriched ==="
clear_session "$SID"; new_repo a5b; R="$REPLY"; plant_v_history "$SID"
ERR=$( run_stop "$R" "$SID" "$SONNET_MSG" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && ! printf '%s' "$ERR" | grep -q 'abandon-enrich' && [ ! -f "$R/ABANDON_SUSPECT_${SID}.md" ]; } \
  && ok "A5b baseline preserved: generic Part-B block, no enrichment without capture" \
  || no "A5b" "rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 160)]"

echo "=== A6: STALE capture (older than session-start marker) → nulled → behaves as no-capture ==="
clear_session "$SID"; new_repo a6; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
mkdir -p "$R/.v/tmp"; touch "$R/.v/tmp/session-start-${SID}.txt"
touch -t 202601010000 "$FHOME/.claude/runtime/last-user-prompt-${SID}.txt"
ERR=$( run_stop "$R" "$SID" "$WORDLESS_MSG" V_ABANDON_GATE=block 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ] && [ ! -f "$R/ABANDON_SUSPECT_${SID}.md" ]; } \
  && ok "A6 stale capture nulled: no quote, no block, no marker (SME-L-1/L2-3)" \
  || no "A6" "rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 160)]"

echo "=== A7: HANDOFF laundering, warn(default) → HANDOFF accepted (exit 0) + marker + stderr warn ==="
clear_session "$SID"; new_repo a7; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
printf '# Handoff\n\nNo task was provided in this session; nothing to defer. This handoff records a clean stop with no pending work items.\n' > "$R/HANDOFF_${SID}.md"
ERR=$( run_stop "$R" "$SID" "$SONNET_MSG" 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -q 'does not reference the captured task' && [ -f "$R/ABANDON_SUSPECT_${SID}.md" ]; } \
  && ok "A7 laundering soak: accepted but marked + warned (SME-A-1)" \
  || no "A7" "rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 200)]"

echo "=== A8: HANDOFF laundering + block → exit 2 AT the Part-A site (SME-A-D1) ==="
clear_session "$SID"; new_repo a8; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
printf '# Handoff\n\nNo task was provided in this session; nothing to defer. This handoff records a clean stop with no pending work items.\n' > "$R/HANDOFF_${SID}.md"
ERR=$( run_stop "$R" "$SID" "$SONNET_MSG" V_ABANDON_GATE=block 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'does NOT reference'; } \
  && ok "A8 laundering blocked at Part-A site with enriched message" \
  || no "A8" "rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 200)]"

echo "=== A9: HANDOFF that QUOTES the task → accepted clean, no marker, no warn ==="
clear_session "$SID"; new_repo a9; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
printf '# Handoff\n\nCould not execute: fix the typo in the greeting string in hello.js — blocked on missing repo access; deferring with full task quoted.\n' > "$R/HANDOFF_${SID}.md"
ERR=$( run_stop "$R" "$SID" "$SONNET_MSG" V_ABANDON_GATE=block 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ] && [ ! -f "$R/ABANDON_SUSPECT_${SID}.md" ] && ! printf '%s' "$ERR" | grep -q 'ABANDON-ENRICH warn'; } \
  && ok "A9 task-quoting HANDOFF passes untouched (recovery contract works)" \
  || no "A9" "rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 160)]"

echo "=== A10a: off dial + WORDLESS msg → pre-change behavior: silent clean exit 0 ==="
clear_session "$SID"; new_repo a10; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
ERR=$( run_stop "$R" "$SID" "$WORDLESS_MSG" V_ABANDON_GATE=off 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ] && [ ! -f "$R/ABANDON_SUSPECT_${SID}.md" ]; } \
  && ok "A10a off dial: wordless ending exits clean exactly as pre-change" \
  || no "A10a" "rc=$RC"

echo "=== A10b: off dial + completion-worded msg → pre-existing GENERIC Part-B block, no enrichment ==="
clear_session "$SID"; new_repo a10b; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
ERR=$( run_stop "$R" "$SID" "$SONNET_MSG" V_ABANDON_GATE=off 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && ! printf '%s' "$ERR" | grep -q 'abandon-enrich'; } \
  && ok "A10b off dial: Part-B blocks generic (no enrichment) exactly as pre-change" \
  || no "A10b" "rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 160)]"

echo "=== A11: capture CACHED across runs → quote stays stable when the runtime file churns (SME-L2-1) ==="
clear_session "$SID"; new_repo a11; R="$REPLY"; plant_v_history "$SID"; seed_capture "$SID"
ERR1=$( run_stop "$R" "$SID" "$SONNET_MSG" V_ABANDON_GATE=block 2>&1 )
printf '/v a COMPLETELY different task that must not appear in re-arm quotes\n' > "$FHOME/.claude/runtime/last-user-prompt-${SID}.txt"
ERR2=$( run_stop "$R" "$SID" "$SONNET_MSG" V_ABANDON_GATE=block 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && printf '%s' "$ERR2" | grep -qF 'Helo' && ! printf '%s' "$ERR2" | grep -q 'COMPLETELY different'; } \
  && ok "A11 cache: second block quotes the ORIGINAL task (stable rearm fingerprint)" \
  || no "A11" "rc=$RC err2=[$(printf '%s' "$ERR2" | tr '\n' '|' | head -c 200)]"

echo "=== A12: non-/v session with no-task msg → untouched (cond-1 gate) ==="
clear_session "$SID"; new_repo a12; R="$REPLY"; seed_capture "$SID"   # NO /v history
ERR=$( run_stop "$R" "$SID" "$SONNET_MSG" V_ABANDON_GATE=block 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ] && [ ! -f "$R/ABANDON_SUSPECT_${SID}.md" ]; } \
  && ok "A12 non-/v chat is never gated" \
  || no "A12" "rc=$RC"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
