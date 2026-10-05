#!/usr/bin/env bash
# record-agent-dispatch-provenance-test.sh — P2: the PostToolUse-Agent hook must write a gate-readable
# DISPATCH_PROVENANCE line ONLY for a genuinely-completed reviewer dispatch (anti-forgery), and that line
# must satisfy _agent_was_dispatched (the check whose false-negative caused the churn).
# Re-run: bash <thisfile>
set -u
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
HOOK="$HOME/.claude/hooks/record-agent-dispatch-provenance.sh"
[ -f "$HOOK" ] || { echo "SKIP: missing $HOOK"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP" 2>/dev/null' EXIT
export V_ARTIFACT_DIR="$TMP/.v/artifacts"
SID="11112222-3333-4444-8555-666677778888"
LOG="$V_ARTIFACT_DIR/DISPATCH_PROVENANCE_${SID}.log"
# Item 7 (2026-07-05): the hook now SID-binds the payload session_id against this process's local
# identity (CLAUDE_SESSION_ID/CLAUDE_CODE_SESSION_ID/runtime-file) to reject foreign-SID rows. This
# test's fixture payload SID must match the local identity it runs under, or every case below would
# be (correctly) rejected as foreign — export/unset so the fixture SID IS the local identity.
export CLAUDE_SESSION_ID="$SID"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

mkin(){ # $1=subagent_type  $2=response_content  $3=is_error(bool)
  jq -nc --arg sa "$1" --arg resp "$2" --arg sid "$SID" --argjson err "${3:-false}" \
    '{tool_name:"Agent", session_id:$sid, tool_input:{subagent_type:$sa, prompt:"x", model:"haiku"}, tool_response:{content:$resp, is_error:$err}}'
}
run(){ printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; }

echo "== record-agent-dispatch-provenance :: P2 Agent-tool provenance =="

run "$(mkin codex-adversarial-reviewer 'review: no issues found' false)"
{ grep -qE 'agent=codex-adversarial-reviewer\|mode=agent-tool\|status=ok' "$LOG" 2>/dev/null \
  && ! grep -q 'mode=agent-self' "$LOG"; } && ok "real reviewer dispatch -> gate-readable provenance line" || no "no/invalid provenance line" "$(cat "$LOG" 2>&1)"

rm -f "$LOG"; run "$(mkin general-purpose 'did some stuff' false)"
[ ! -s "$LOG" ] && ok "non-reviewer subagent -> NO provenance (not a gauntlet reviewer)" || no "wrote provenance for non-reviewer" "$(cat "$LOG")"

rm -f "$LOG"; run "$(mkin codex-adversarial-reviewer '' true)"
[ ! -s "$LOG" ] && ok "ERROR dispatch -> NO provenance (anti-forgery)" || no "wrote provenance for errored dispatch" "$(cat "$LOG")"

rm -f "$LOG"; run "$(mkin codex-adversarial-reviewer '   ' false)"
[ ! -s "$LOG" ] && ok "empty response -> NO provenance (anti-forgery)" || no "wrote provenance for empty response" "$(cat "$LOG")"

rm -f "$LOG"; run '{"tool_name":"Bash","session_id":"x","tool_input":{}}'
[ ! -s "$LOG" ] && ok "non-Agent tool -> NO provenance" || no "wrote on non-Agent tool" "$(cat "$LOG")"

rm -f "$LOG"; IN="$(mkin v-qa-reviewer 'qa verdict: pass' false)"; run "$IN"; run "$IN"
[ "$(grep -c 'agent=v-qa-reviewer' "$LOG" 2>/dev/null)" = "1" ] && ok "idempotent (same dispatch recorded once)" || no "duplicate provenance" "$(cat "$LOG")"

# Schema robustness — the live PostToolUse tool_response shape is the one uncertainty; the parser must
# extract a non-empty result from EVERY plausible shape (and accept the Task tool_name defensively).
rm -f "$LOG"; printf '{"tool_name":"Agent","session_id":"%s","tool_input":{"subagent_type":"logic-reviewer"},"tool_response":"bare string result"}' "$SID" | bash "$HOOK" >/dev/null 2>&1
grep -q 'agent=logic-reviewer|mode=agent-tool|status=ok' "$LOG" 2>/dev/null && ok "shape: bare-string tool_response" || no "bare-string not handled" "$(cat "$LOG" 2>&1)"

rm -f "$LOG"; printf '{"tool_name":"Agent","session_id":"%s","tool_input":{"subagent_type":"logic-reviewer"},"tool_response":{"content":[{"type":"text","text":"content-block review"}],"is_error":false}}' "$SID" | bash "$HOOK" >/dev/null 2>&1
grep -q 'agent=logic-reviewer' "$LOG" 2>/dev/null && ok "shape: {content:[{text}]} content-block array" || no "content-block array not handled" "$(cat "$LOG" 2>&1)"

rm -f "$LOG"; printf '{"tool_name":"Task","session_id":"%s","tool_input":{"subagent_type":"security-reviewer"},"tool_response":{"content":"obj content"}}' "$SID" | bash "$HOOK" >/dev/null 2>&1
grep -q 'agent=security-reviewer' "$LOG" 2>/dev/null && ok "tool_name 'Task' + {content:string} handled" || no "Task/{content} not handled" "$(cat "$LOG" 2>&1)"

rm -f "$LOG"; printf '{"tool_name":"Agent","session_id":"%s","tool_input":{"subagent_type":"logic-reviewer"},"tool_response":{"content":[{"type":"text","text":"x"}],"is_error":true}}' "$SID" | bash "$HOOK" >/dev/null 2>&1
[ ! -s "$LOG" ] && ok "is_error in content-block shape still blocks (anti-forgery across shapes)" || no "errored content-block wrote provenance" "$(cat "$LOG")"

# KEY integration: the written line must satisfy _agent_was_dispatched (the false-negative that caused churn).
rm -f "$LOG"; run "$(mkin codex-adversarial-reviewer 'review: no issues found' false)"
( . "$HOME/.claude/hooks/lib/validation.sh" 2>/dev/null
  SESSION_ID="$SID"; ARTIFACT_SEARCH_DIRS=("$V_ARTIFACT_DIR")
  _agent_was_dispatched "codex-adversarial-reviewer" ) \
  && ok "provenance SATISFIES _agent_was_dispatched -> closes the forgery-block churn" || no "gate still sees no dispatch" "$(cat "$LOG" 2>&1)"

# PROV-1 (audit 2026-06-21): is_error=true with NON-EMPTY STRING content must be rejected by the is_error
# guard (hook line 38). The earlier ERROR case uses EMPTY content (caught by the empty-response check, NOT
# the is_error guard); the content-block case exercises the array path. This pins the realistic string shape —
# without the is_error guard a forged status=ok line would be written for an errored dispatch carrying text.
rm -f "$LOG"; run "$(mkin codex-adversarial-reviewer 'a real, non-empty review body — but the run errored' true)"
[ ! -s "$LOG" ] && ok "PROV-1: is_error=true + NON-EMPTY string content -> NO provenance (is_error guard bites)" || no "PROV-1: forged status=ok written for an errored dispatch carrying content" "$(cat "$LOG")"

# G1 (telemetry 2026-06-21): the DISPATCH_LEDGER records EVERY Agent-tool dispatch (deterministic agent_type for
# cost-tally), reviewer or not — SEPARATE from gate-provenance. Non-reviewer -> ledger yes, gate-provenance no.
LEDGER="$V_ARTIFACT_DIR/DISPATCH_LEDGER.jsonl"
rm -f "$LOG" "$LEDGER"; run "$(mkin general-purpose 'did some stuff' false)"
{ grep -q '"agent_type":"general-purpose"' "$LEDGER" 2>/dev/null && [ ! -s "$LOG" ]; } \
  && ok "G1: non-reviewer dispatch -> DISPATCH_LEDGER line written; gate-provenance NOT (separate concerns)" \
  || no "G1: ledger missing for non-reviewer OR gate-provenance leaked" "$(cat "$LEDGER" "$LOG" 2>/dev/null)"
rm -f "$LOG" "$LEDGER"; run "$(mkin v-verify-done-runner 'verdict: pass' false)"
{ grep -q '"agent_type":"v-verify-done-runner"' "$LEDGER" 2>/dev/null && grep -q '"dispatch_path":"agent-tool"' "$LEDGER" 2>/dev/null && grep -q '"model_requested":"haiku"' "$LEDGER" 2>/dev/null; } \
  && ok "G1: reviewer/runner dispatch ALSO ledgered (agent_type + model_requested + dispatch_path)" \
  || no "G1: ledger line malformed/missing for reviewer" "$(cat "$LEDGER" 2>/dev/null)"
# C2/G1-4 (telemetry 2026-06-21): the ledger row carries model_used (here request==haiku for v-verify-done).
grep -q '"model_used":"haiku"' "$LEDGER" 2>/dev/null \
  && ok "C2: ledger row carries model_used" \
  || no "C2: model_used missing/wrong in the Agent-tool ledger row" "$(cat "$LEDGER" 2>/dev/null)"
# T1 (post-batch live-validation 2026-06-21): a SONNET-pinned agent dispatched with a haiku runtime override
# must record model_used=haiku (the BILLED request), NOT the sonnet pin. The pin-wins bug recorded sonnet
# on several live reviewer rows (pin=sonnet but billed=haiku). v-qa-reviewer pins sonnet; mkin sends model:haiku.
rm -f "$LOG" "$LEDGER"; run "$(mkin v-qa-reviewer 'qa verdict: pass' false)"
{ grep -q '"model_requested":"haiku"' "$LEDGER" 2>/dev/null && grep -q '"model_used":"haiku"' "$LEDGER" 2>/dev/null && ! grep -q '"model_used":"sonnet"' "$LEDGER" 2>/dev/null; } \
  && ok "T1: sonnet-PINNED agent + haiku override -> model_used=haiku (request wins over the pin)" \
  || no "T1: model_used recorded the PIN (sonnet) instead of the billed request (haiku)" "$(cat "$LEDGER" 2>/dev/null)"

# C1 (telemetry 2026-06-21): the live PRODUCTION ledger must NEVER carry this test-fixture SID — the
# test writes only under V_ARTIFACT_DIR (set at the top). stale fixture rows had leaked into
# ~/.claude/.v/artifacts/DISPATCH_LEDGER.jsonl before isolation existed (purged 2026-06-21); this
# ratchet fails if a future test run (or a missing V_ARTIFACT_DIR export) re-pollutes production.
_LIVE_LEDGER="$HOME/.claude/.v/artifacts/DISPATCH_LEDGER.jsonl"
if [ -f "$_LIVE_LEDGER" ]; then
  grep -q "$SID" "$_LIVE_LEDGER" 2>/dev/null \
    && no "C1: live production ledger CARRIES the test-fixture SID — isolation leaked (re-purge + ensure V_ARTIFACT_DIR)" "$_LIVE_LEDGER" \
    || ok "C1: live production ledger has ZERO test-fixture rows (V_ARTIFACT_DIR isolation + purge held)"
fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
