#!/usr/bin/env bash
# v-dispatch-subagent-reattach-test.sh — W-REATTACH (2026-09-05): a dispatch whose helper is killed
# by the Bash tool's timeout keeps its child alive (own session) and the next identical dispatch
# RE-ATTACHES instead of re-running the work.
# CLASS: cohort 2026-08-31..09-03 — many aborted dispatches, hours of work discarded, most restarted from scratch.
# RED ORACLE: v-dispatch-subagent.sh.pre-fix20260905-bak → `aborted` row, json deleted, work re-run.
set -uo pipefail
SRC="${DISPATCH_UNDER_TEST:-$HOME/.claude/skills/v/references/v-dispatch-subagent.sh}"
BAK="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh.pre-fix20260905-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl unavailable"; exit 0; }
[ -f "$SRC" ] || { echo "NO dispatcher missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
SID="2e2e2e2e-2222-4222-8222-000000000002"
W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"; trap 'pkill -f "$W/bin/claude" >/dev/null 2>&1; rm -rf "$W"' EXIT
mkdir -p "$W/.v/artifacts" "$W/.v/tmp" "$W/bin"
cat > "$W/bin/claude" <<'FC'
#!/usr/bin/env bash
# reattach-fake-claude
cat > /dev/null
sleep "${FAKE_SLEEP:-6}"
echo 1 >> "$FAKE_COUNT"
jq -n '{is_error:false, result:"Model: sonnet\nWrote correctly.\n", total_cost_usd:0.001, duration_ms:10, modelUsage:{"m":{}}, session_id:"dddddddd-4444-4444-8444-dddddddddddd"}'
FC
chmod +x "$W/bin/claude"; printf 'p\n' > "$W/prompt.md"
PROV="$W/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log"
run_fg(){ # <artifact> <outfile> [extra env assignments...] -> rc
  local A="$1" O="$2"; shift 2
  ( cd "$W" && env PATH="$W/bin:$PATH" PROJECT_ROOT="$W" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
      FAKE_COUNT="$A.count" "$@" bash "$SRC" --agent logic-reviewer --prompt-file "$W/prompt.md" --artifact "$A" --mode capture ) > "$O" 2>&1
}
# Start a helper in its OWN session (as the Bash tool's shell would be), let it run $2 seconds, then
# kill it BOTH ways a harness might: the whole process group, and a PPID-tree walk.
kill_after(){ # <artifact> <seconds> <outfile> -> helper rc
  local A="$1" T="$2" O="$3" H
  ( cd "$W" && env PATH="$W/bin:$PATH" PROJECT_ROOT="$W" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" FAKE_COUNT="$A.count" \
      FAKE_SLEEP="${FAKE_SLEEP:-6}" perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- bash "$SRC" --agent logic-reviewer --prompt-file "$W/prompt.md" --artifact "$A" --mode capture ) > "$O" 2>&1 &
  H=$!
  # Deterministic under load: wait until the child exists AND the started row landed, then a short
  # grace ($T) so the helper is in its poll loop — never a fixed sleep racing against startup.
  # State-driven, not grace-driven: wait (≤90 s, load-tolerant) for the child AND this helper's own
  # row (started for a fresh helper, reattached for a re-attaching one), then a short grace, then
  # confirm the child is STILL alive before killing — otherwise the case is a fixture failure.
  local _i=0 _want="${KILL_WAIT_ROW:-started}"; while [ $_i -lt 360 ]; do [ -s "$A.dispatch-lock/child.pid" ] && grep -q "status=${_want}" "$PROV" 2>/dev/null && break; sleep 0.25; _i=$((_i+1)); done
  sleep "$T"
  kill -0 "$(tr -dc '0-9' < "$A.dispatch-lock/child.pid" 2>/dev/null)" 2>/dev/null || echo "  --  kill_after: child already gone before the kill (fixture timing under load)" >&2
  pkill -TERM -P "$H" 2>/dev/null; kill -TERM -- "-$H" 2>/dev/null; kill -TERM "$H" 2>/dev/null
  wait "$H" 2>/dev/null; echo $?
}
statuses(){ grep -oE 'status=[a-z_]+' "$PROV" 2>/dev/null | sed 's/status=//' | tr '\n' ' '; }

echo "== W-REATTACH :: killed helper → detached child → re-attach =="
A1="$W/.v/artifacts/AGENT_REVIEW_${SID}.md"; : > "$PROV"
rc1=$(kill_after "$A1" 1 "$W/out1")
L="$A1.dispatch-lock"
[ "$rc1" = "143" ] && ok "1a helper #1 died from the TERM (rc=143)" || no "1a helper rc=$rc1" "$(tail -3 "$W/out1")"
grep -q 'status=detached' "$PROV" && ok "1b provenance records status=detached" || no "1b no detached row" "$(statuses)"
grep -q 'status=aborted' "$PROV" && no "1c an aborted row was ALSO written (trap ran the old branch)" "$(statuses)" || ok "1c no aborted row (detached branch ran first)"
[ -f "$L/lease" ] && grep -q '^HMAC=' "$L/lease" && ok "1d signed lease kept in the lock dir" || no "1d lease missing/unsigned" "$(ls "$L" 2>/dev/null | tr '\n' ' ')"
CP=$(tr -dc '0-9' < "$L/child.pid" 2>/dev/null); [ -n "$CP" ] && kill -0 "$CP" 2>/dev/null && ok "1e child (pid $CP) survived the process-group kill AND the PPID walk" || no "1e child dead or unknown" "pid=$CP"
[ ! -f "$L/rc" ] && ok "1f no rc yet (child still working)" || no "1f rc already present"
[ ! -s "$A1" ] && ok "1g artifact not yet written" || no "1g artifact present prematurely"
grep -q 'DISPATCH_STATUS=detached' "$W/out1" && ok "1h helper told the caller to re-issue the same command" || no "1h no detached notice on stdout" "$(grep DISPATCH_ "$W/out1" | head -2)"

run_fg "$A1" "$W/out2"; rc2=$?
[ "$rc2" = "0" ] && ok "2a helper #2 re-attached and completed (rc=0)" || no "2a rc=$rc2" "$(grep -E 'DISPATCH_STATUS|ERROR|REFUSED' "$W/out2" | head -3)"
grep -q 'status=reattached' "$PROV" && ok "2b provenance records status=reattached" || no "2b no reattached row" "$(statuses)"
[ "$(statuses)" = "started detached reattached ok " ] && ok "2c row order: started detached reattached ok" || no "2c unexpected row sequence" "$(statuses)"
grep -q 'Wrote correctly' "$A1" 2>/dev/null && ok "2d artifact carries the child's output" || no "2d artifact missing/empty"
[ "$(wc -l < "$A1.count" 2>/dev/null | tr -d ' ')" = "1" ] && ok "2e the fake claude ran exactly ONCE (no re-run)" || no "2e claude invocations: $(wc -l < "$A1.count" 2>/dev/null)"
[ ! -d "$L" ] && ok "2f lock dir released after the terminal ok" || no "2f lock dir left behind" "$(ls "$L" | tr '\n' ' ')"
grep -q 'DISPATCH_REATTACHED=1' "$W/out2" && ok "2g stdout flags DISPATCH_REATTACHED=1" || no "2g reattach flag missing"

echo "== 3 :: second-generation: helper #2 killed mid-poll, helper #3 attaches =="
A3="$W/.v/artifacts/AGENT_REVIEW_${SID}.3.md"; : > "$PROV"
rc3a=$(FAKE_SLEEP=20 kill_after "$A3" 1 "$W/out3a"); rc3b=$(FAKE_SLEEP=20 KILL_WAIT_ROW=reattached kill_after "$A3" 1 "$W/out3b")
[ "$(grep -c 'status=detached' "$PROV")" = "2" ] && ok "3a two detached rows (helper #1 and the re-attaching helper #2)" || no "3a detached rows: $(grep -c 'status=detached' "$PROV")" "$(statuses)"
run_fg "$A3" "$W/out3c"; rc3c=$?
[ "$rc3c" = "0" ] && [ "$(wc -l < "$A3.count" | tr -d ' ')" = "1" ] && ok "3b helper #3 completed; claude still ran only once" || no "3b rc=$rc3c count=$(wc -l < "$A3.count" 2>/dev/null)" "$(statuses)"

echo "== 4 :: forged lease (bad HMAC) → fresh launch, never adopted =="
A4="$W/.v/artifacts/AGENT_REVIEW_${SID}.4.md"; : > "$PROV"; L4="$A4.dispatch-lock"; mkdir -p "$L4"
printf '%s\n' 99999 > "$L4/pid"; printf 'V=1\nAGENT=logic-reviewer\nMODE=capture\nSID=%s\nARTIFACT=%s\nSTART_EPOCH=%s\nTIMEOUT=900\nHELPER_PID=99999\nHMAC=deadbeef\n' "$SID" "$(basename "$A4")" "$(date -u +%s)" > "$L4/lease"
printf '99999' > "$L4/child.pid"; printf '0' > "$L4/rc"; jq -n '{is_error:false,result:"Model: sonnet\nFORGED\n",duration_ms:1}' > "$L4/json"
run_fg "$A4" "$W/out4" FAKE_SLEEP=1; rc4=$?
grep -q 'FORGED' "$A4" 2>/dev/null && no "4a forged json was adopted as the result" || ok "4a forged lease rejected (result not adopted)"
grep -q 'status=reattached' "$PROV" && no "4b reattached row on a forged lease" || ok "4b no reattached row"
[ "$rc4" = "0" ] && grep -q 'Wrote correctly' "$A4" && ok "4c fresh launch ran the real child (rc=0)" || no "4c rc=$rc4" "$(grep -E 'DISPATCH_STATUS|REFUSED' "$W/out4" | head -2)"

echo "== 5 :: valid lease but child dead with no rc (SIGKILL class) → reclaim: stale artifact restored, fresh launch =="
A5="$W/.v/artifacts/AGENT_REVIEW_${SID}.5.md"; : > "$PROV"; L5="$A5.dispatch-lock"; mkdir -p "$L5"
. "$HOME/.claude/hooks/lib/gauntlet-witness.sh" 2>/dev/null
_st=$(date -u +%s); _h=$(_gw_compute_hmac "v-dispatch-lease|logic-reviewer|capture|$SID|$(basename "$A5")|$_st|900|99998")
printf 'V=1\nAGENT=logic-reviewer\nMODE=capture\nSID=%s\nARTIFACT=%s\nSTART_EPOCH=%s\nTIMEOUT=900\nHELPER_PID=99998\nHMAC=%s\n' "$SID" "$(basename "$A5")" "$_st" "$_h" > "$L5/lease"
printf '99998' > "$L5/pid"; printf '99998' > "$L5/child.pid"; printf 'ORIGINAL pre-dispatch content\n' > "$L5/stale"
run_fg "$A5" "$W/out5" FAKE_SLEEP=1; rc5=$?
grep -q 'status=reattached' "$PROV" && no "5a re-attached to a dead child" || ok "5a dead child without rc is NOT re-attached"
[ "$rc5" = "0" ] && grep -q 'Wrote correctly' "$A5" && ok "5b fresh launch completed" || no "5b rc=$rc5" "$(grep -E 'DISPATCH_STATUS|REFUSED' "$W/out5" | head -2)"
[ ! -e "$L5/stale" ] && ok "5c the orphaned stale sideline was consumed (restored, then superseded by the new artifact)" || no "5c stale sideline leaked"

echo "== 8 :: valid lease + dead child + PRE-STAGED rc/json but NO detach proof → never adopted (laundering) =="
A8="$W/.v/artifacts/AGENT_REVIEW_${SID}.8.md"; : > "$PROV"; L8="$A8.dispatch-lock"; mkdir -p "$L8"
_st8=$(date -u +%s); _h8=$(_gw_compute_hmac "v-dispatch-lease|logic-reviewer|capture|$SID|$(basename "$A8")|$_st8|900|99997")
printf 'V=1\nAGENT=logic-reviewer\nMODE=capture\nSID=%s\nARTIFACT=%s\nSTART_EPOCH=%s\nTIMEOUT=900\nHELPER_PID=99997\nHMAC=%s\n' "$SID" "$(basename "$A8")" "$_st8" "$_h8" > "$L8/lease"
printf '99997' > "$L8/pid"; printf '99997' > "$L8/child.pid"; sleep 1; printf '0' > "$L8/rc"; jq -n '{is_error:false,result:"Model: sonnet\nLAUNDERED\n",duration_ms:1,session_id:"dddddddd-4444-4444-8444-dddddddddddd"}' > "$L8/json"
run_fg "$A8" "$W/out8" FAKE_SLEEP=1; rc8=$?
grep -q 'LAUNDERED' "$A8" 2>/dev/null && no "8a pre-staged json was adopted WITHOUT a detach proof (laundering path open)" || ok "8a pre-staged rc/json without detach proof is NOT adopted"
grep -q 'status=reattached' "$PROV" && no "8b reattached row without proof" || ok "8b no reattached row"
[ "$rc8" = "0" ] && grep -q 'Wrote correctly' "$A8" && ok "8c the real child ran instead (rc=0)" || no "8c rc=$rc8"

echo "== 9 :: child FINISHES while detached (proof present) → harvested, no re-run =="
A9="$W/.v/artifacts/AGENT_REVIEW_${SID}.9.md"; : > "$PROV"
rc9a=$(FAKE_SLEEP=7 kill_after "$A9" 1 "$W/out9a"); sleep 9
L9="$A9.dispatch-lock"; [ -f "$L9/detached.sig" ] && ok "9a detached branch wrote the signed proof" || no "9a no detached.sig" "$(ls "$L9" 2>/dev/null | tr '\n' ' ')"
[ -f "$L9/rc" ] && ok "9b child finished on its own while no helper was attached" || no "9b rc missing after the child's sleep"
run_fg "$A9" "$W/out9b"; rc9b=$?
[ "$rc9b" = "0" ] && grep -q 'Wrote correctly' "$A9" && [ "$(wc -l < "$A9.count" | tr -d ' ')" = "1" ] && ok "9c result harvested by re-attach; claude ran once" || no "9c rc=$rc9b count=$(wc -l < "$A9.count" 2>/dev/null)" "$(statuses)"

echo "== 6 :: live child of a DIFFERENT dispatch → refused (LIVE-ONLY extended to the child) =="
A6="$W/.v/artifacts/AGENT_REVIEW_${SID}.6.md"; : > "$PROV"
rc6a=$(kill_after "$A6" 1 "$W/out6a")
( cd "$W" && env PATH="$W/bin:$PATH" PROJECT_ROOT="$W" CLAUDE_CODE_SESSION_ID="9f9f9f9f-9999-4999-8999-000000000009" CLAUDE_SESSION_ID="9f9f9f9f-9999-4999-8999-000000000009" FAKE_COUNT="$A6.count" bash "$SRC" --agent logic-reviewer --prompt-file "$W/prompt.md" --artifact "$A6" --mode capture ) > "$W/out6b" 2>&1; rc6b=$?
[ "$rc6b" = "10" ] && grep -q 'DIFFERENT dispatch' "$W/out6b" && ok "6a other session's dispatch refused with exit 10 while the child is alive" || no "6a rc=$rc6b" "$(grep -E 'REFUSED|DISPATCH_STATUS' "$W/out6b" | head -1 | cut -c1-120)"
run_fg "$A6" "$W/out6c"; rc6c=$?
[ "$rc6c" = "0" ] && [ "$(wc -l < "$A6.count" | tr -d ' ')" = "1" ] && ok "6b the owning session still re-attaches afterwards (count 1)" || no "6b rc=$rc6c" "$(statuses)"

echo "== 7 :: no perl → today's in-tree foreground run, no lease left behind =="
A7="$W/.v/artifacts/AGENT_REVIEW_${SID}.7.md"; : > "$PROV"
run_fg "$A7" "$W/out7" FAKE_SLEEP=1 V_REATTACH_PERL=/nonexistent/perl; rc7=$?
[ "$rc7" = "0" ] && grep -q 'Wrote correctly' "$A7" && ok "7a fallback run completed (rc=0)" || no "7a rc=$rc7"
[ "$(statuses)" = "started ok " ] && ok "7b provenance is the plain started/ok pair" || no "7b rows: $(statuses)"
[ ! -d "$A7.dispatch-lock" ] && ok "7c no lock dir / lease left behind" || no "7c lock dir remains"

echo "== 10 :: --detach wrapper killed (-9) → the helper writes its own DONE line; finished work is not re-run =="
A10="$W/.v/artifacts/AGENT_REVIEW_${SID}.10.md"; : > "$PROV"
( cd "$W" && env PATH="$W/bin:$PATH" PROJECT_ROOT="$W" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" FAKE_COUNT="$A10.count" FAKE_SLEEP=4 \
    bash "$SRC" --detach --agent logic-reviewer --prompt-file "$W/prompt.md" --artifact "$A10" --mode capture ) > "$W/out10a" 2>&1
WP=$(sed -n 's/^PID pid=\([0-9]*\)$/\1/p' "$A10.dispatch-status" | head -1); sleep 1.5
kill -9 "$WP" 2>/dev/null
for _i in $(seq 1 30); do grep -q '^DONE ' "$A10.dispatch-status" 2>/dev/null && break; sleep 0.5; done
grep -q '^DONE rc=0' "$A10.dispatch-status" && ok "10a wrapper SIGKILLed, yet DONE rc=0 landed (written by the helper itself)" || no "10a no DONE line after the wrapper died" "$(tail -2 "$A10.dispatch-status")"
grep -q 'Wrote correctly' "$A10" 2>/dev/null && ok "10b artifact written by the orphaned helper's child" || no "10b artifact missing"
[ "$(wc -l < "$A10.count" | tr -d ' ')" = "1" ] && ok "10c claude ran exactly once" || no "10c invocations=$(wc -l < "$A10.count")"
( cd "$W" && env PATH="$W/bin:$PATH" PROJECT_ROOT="$W" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" FAKE_COUNT="$A10.count" FAKE_SLEEP=4 \
    bash "$SRC" --detach --agent logic-reviewer --prompt-file "$W/prompt.md" --artifact "$A10" --mode capture ) > "$W/out10b" 2>&1
grep -q 'DISPATCH_DETACHED=already-running' "$W/out10b" && no "10d re-issue after DONE reported already-running (stale liveness)" || ok "10d re-issue after DONE is a NEW dispatch (contract unchanged: DONE means finished)"
pkill -f "$W/bin/claude" >/dev/null 2>&1; sleep 1

echo "== 11 :: lock dir under a path with ERE metacharacters → liveness still detected (fixed-string match) =="
M="$W/a+b(c)|d?e{1}"; mkdir -p "$M/.v/artifacts" "$M/.v/tmp"
A11="$M/.v/artifacts/AGENT_REVIEW_${SID}.11.md"; : > "$PROV"
( cd "$M" && env PATH="$W/bin:$PATH" PROJECT_ROOT="$M" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" FAKE_COUNT="$A11.count" FAKE_SLEEP=6 \
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- bash "$SRC" --agent logic-reviewer --prompt-file "$W/prompt.md" --artifact "$A11" --mode capture ) > "$W/out11a" 2>&1 &
H11=$!; _i=0; while [ $_i -lt 60 ]; do [ -s "$A11.dispatch-lock/child.pid" ] && grep -q 'status=started' "$M/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log" 2>/dev/null && break; sleep 0.25; _i=$((_i+1)); done; sleep 1
pkill -TERM -P "$H11" 2>/dev/null; kill -TERM "$H11" 2>/dev/null; wait "$H11" 2>/dev/null
grep -q 'status=detached' "$M/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log" && ok "11a metachar path: killed helper still recognised its live child (detached, not aborted)" || no "11a metachar path: liveness missed" "$(grep -o 'status=[a-z]*' "$M/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log" | tr '\n' ' ')"
( cd "$M" && env PATH="$W/bin:$PATH" PROJECT_ROOT="$M" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" FAKE_COUNT="$A11.count" bash "$SRC" --agent logic-reviewer --prompt-file "$W/prompt.md" --artifact "$A11" --mode capture ) > "$W/out11b" 2>&1; rc11=$?
[ "$rc11" = "0" ] && [ "$(wc -l < "$A11.count" | tr -d ' ')" = "1" ] && ok "11b metachar path: re-attached, claude ran once" || no "11b rc=$rc11 count=$(wc -l < "$A11.count" 2>/dev/null)"

echo "== 12 :: rc+json planted while the child is ALIVE → not harvested; the real result wins =="
A12="$W/.v/artifacts/AGENT_REVIEW_${SID}.12.md"; : > "$PROV"
( run_fg "$A12" "$W/out12" FAKE_SLEEP=5 ) & RF=$!
_i=0; while [ $_i -lt 60 ]; do [ -s "$A12.dispatch-lock/child.pid" ] && break; sleep 0.25; _i=$((_i+1)); done; sleep 1
jq -n '{is_error:false,result:"Model: sonnet\nPLANTED\n",duration_ms:1,session_id:"dddddddd-4444-4444-8444-dddddddddddd"}' > "$A12.dispatch-lock/json"; printf '0' > "$A12.dispatch-lock/rc"
wait $RF; rc12=$?
grep -q 'PLANTED' "$A12" 2>/dev/null && no "12a planted rc/json harvested while the child was alive (laundering)" || ok "12a planted rc/json ignored while the child lived"
[ "$rc12" = "0" ] && grep -q 'Wrote correctly' "$A12" && ok "12b the real child's output was harvested after it exited (rc=0)" || no "12b rc=$rc12" "$(grep -E 'DISPATCH_STATUS|ERROR' "$W/out12" | head -2 | cut -c1-120)"

echo "== 13 :: json rewritten AFTER rc (child finished while detached, proof present) → harvest refused =="
A13="$W/.v/artifacts/AGENT_REVIEW_${SID}.13.md"; : > "$PROV"
rc13a=$(FAKE_SLEEP=7 kill_after "$A13" 1 "$W/out13a"); sleep 9
[ -f "$A13.dispatch-lock/rc" ] && [ -f "$A13.dispatch-lock/detached.sig" ] && ok "13a child finished alone; rc + proof present" || no "13a fixture: rc/proof missing" "$(ls "$A13.dispatch-lock" 2>/dev/null | tr '\n' ' ')"
sleep 1.2; jq -n '{is_error:false,result:"Model: sonnet\nREWRITTEN\n",duration_ms:1,session_id:"dddddddd-4444-4444-8444-dddddddddddd"}' > "$A13.dispatch-lock/json"
run_fg "$A13" "$W/out13b"; rc13b=$?
grep -q 'REWRITTEN' "$A13" 2>/dev/null && no "13b post-rc json rewrite was adopted" || ok "13b json newer than rc is refused (not adopted)"
[ "$rc13b" != "0" ] && grep -q 'result signature does not verify' "$W/out13b" && ok "13c helper reports the refusal and fails the dispatch (caller's fallback)" || no "13c rc=$rc13b" "$(grep -E 'ERROR|DISPATCH_STATUS' "$W/out13b" | head -2 | cut -c1-120)"

echo "== 14 :: json SWAPPED via mv while the child runs (rename attack) → refused, never signed =="
A14="$W/.v/artifacts/AGENT_REVIEW_${SID}.14.md"; : > "$PROV"
( run_fg "$A14" "$W/out14" FAKE_SLEEP=5 ) & RF=$!
_i=0; while [ $_i -lt 60 ]; do [ -s "$A14.dispatch-lock/child.pid" ] && break; sleep 0.25; _i=$((_i+1)); done; sleep 1
jq -n '{is_error:false,result:"Model: sonnet\nSWAPPED\n",duration_ms:1,session_id:"dddddddd-4444-4444-8444-dddddddddddd"}' > "$W/forged.json"; mv -f "$W/forged.json" "$A14.dispatch-lock/json.w"; cp "$W/forged.json" "$A14.dispatch-lock/json" 2>/dev/null; jq -n '{result:"Model: sonnet\nSWAPPED\n"}' > "$A14.dispatch-lock/json.w.$(_wr_cp=$(cat "$A14.dispatch-lock/child.pid"); echo $_wr_cp)" 2>/dev/null
wait $RF; rc14=$?
grep -q 'SWAPPED' "$A14" 2>/dev/null && no "14a mv-swapped json was harvested and signed (laundering)" || ok "14a mv-swapped json is NOT adopted"
[ "$rc14" = "0" ] && grep -q 'Wrote correctly' "$A14" && ok "14b the real (unlinked-inode) output was harvested; swap of the path is inert" || no "14b rc=$rc14" "$(grep -E 'ERROR|DISPATCH_STATUS' "$W/out14" | head -2 | cut -c1-120)"

echo "== 15 :: json rewritten in place after completion AND backdated with touch -t → refused =="
A15="$W/.v/artifacts/AGENT_REVIEW_${SID}.15.md"; : > "$PROV"
rc15a=$(FAKE_SLEEP=7 kill_after "$A15" 1 "$W/out15a"); sleep 9
jq -n '{is_error:false,result:"Model: sonnet\nBACKDATED\n",duration_ms:1,session_id:"dddddddd-4444-4444-8444-dddddddddddd"}' > "$A15.dispatch-lock/json"; touch -t 202601010000 "$A15.dispatch-lock/json"
run_fg "$A15" "$W/out15b"; rc15b=$?
grep -q 'BACKDATED' "$A15" 2>/dev/null && no "15a backdated rewrite was adopted" || ok "15a backdated in-place rewrite is refused (content-bound, not mtime-bound)"

echo "== 16 :: same-path IN-PLACE hammer on json.w during the run (round-3 attack) → real result wins =="
A16="$W/.v/artifacts/AGENT_REVIEW_${SID}.16.md"; : > "$PROV"
( run_fg "$A16" "$W/out16" FAKE_SLEEP=4 ) & RF=$!
_i=0; while [ $_i -lt 60 ]; do [ -s "$A16.dispatch-lock/child.pid" ] && break; sleep 0.25; _i=$((_i+1)); done
FORGED='{"is_error":false,"result":"Model: sonnet\nHAMMERED\n","total_cost_usd":0.0,"duration_ms":1,"modelUsage":{"x":{}},"session_id":"dddddddd-4444-4444-8444-dddddddddddd"}'
( while [ ! -s "$A16.dispatch-lock/rc" ] && [ -d "$A16.dispatch-lock" ]; do for f in "$A16.dispatch-lock"/json.w*; do printf '%s' "$FORGED" > "$f" 2>/dev/null; done; printf '%s' "$FORGED" > "$A16.dispatch-lock/json.w" 2>/dev/null; done ) & HM=$!
wait $RF; rc16=$?; kill $HM 2>/dev/null; wait $HM 2>/dev/null
grep -q 'HAMMERED' "$A16" 2>/dev/null && no "16a in-place hammered content was signed and adopted (laundering)" || ok "16a in-place hammer never reaches the unlinked output inode"
[ "$rc16" = "0" ] && grep -q 'Wrote correctly' "$A16" && ok "16b real output harvested (rc=0)" || no "16b rc=$rc16" "$(grep -E 'ERROR|DISPATCH_STATUS' "$W/out16" | head -2 | cut -c1-120)"

echo "== 17 :: json with TWO top-level documents under a VALID signature → single-document rule refuses =="
A17="$W/.v/artifacts/AGENT_REVIEW_${SID}.17.md"; : > "$PROV"
rc17a=$(FAKE_SLEEP=7 kill_after "$A17" 1 "$W/out17a"); sleep 9
L17="$A17.dispatch-lock"; [ -f "$L17/rc" ] && ok "17a child finished while detached" || no "17a fixture: no rc" "$(ls "$L17" 2>/dev/null | tr '\n' ' ')"
printf '\n{"is_error":false,"result":"Model: sonnet\\nAPPENDED-DOC\\n","duration_ms":1,"session_id":"dddddddd-4444-4444-8444-dddddddddddd"}\n' >> "$L17/json"
_s17=$(shasum -a 256 "$L17/json" | awk '{print $1}'); _r17=$(sed -n 's/^rc=//p' "$L17/rc"); _h17=$(_gw_compute_hmac "v-dispatch-result|${_s17}|${_r17}")
printf 'rc=%s\nsha=%s\nhmac=%s\n' "$_r17" "$_s17" "$_h17" > "$L17/rc"   # attacker WITH the secret re-signs the polluted bytes
run_fg "$A17" "$W/out17b"; rc17b=$?
grep -q 'APPENDED-DOC' "$A17" 2>/dev/null && no "17b appended second document reached the artifact" || ok "17b appended document never reaches the artifact"
[ "$rc17b" != "0" ] && grep -q 'top-level JSON values' "$W/out17b" && ok "17c dispatch fails closed with the single-document error" || no "17c rc=$rc17b" "$(grep -E 'ERROR|DISPATCH_STATUS' "$W/out17b" | head -2 | cut -c1-120)"

echo "== 18 :: shared json path hammered from child.pid until helper exit (post-verify TOCTOU) → forged text never adopted =="
A18="$W/.v/artifacts/AGENT_REVIEW_${SID}.18.md"; : > "$PROV"
( run_fg "$A18" "$W/out18" FAKE_SLEEP=3 ) & RF=$!
_i=0; while [ $_i -lt 60 ]; do [ -s "$A18.dispatch-lock/child.pid" ] && break; sleep 0.25; _i=$((_i+1)); done
FORGED18='{"is_error":false,"result":"Model: sonnet\nTOCTOU-FORGED\n","total_cost_usd":0.0,"duration_ms":1,"modelUsage":{"x":{}},"session_id":"dddddddd-4444-4444-8444-dddddddddddd"}'
( while kill -0 $RF 2>/dev/null; do printf '%s' "$FORGED18" > "$A18.dispatch-lock/json" 2>/dev/null; done ) & HM=$!
wait $RF; rc18=$?; kill $HM 2>/dev/null; wait $HM 2>/dev/null
grep -q 'TOCTOU-FORGED' "$A18" 2>/dev/null && no "18a forged content adopted through the shared json path (read-side TOCTOU)" || ok "18a forged content never reaches the artifact (rc=$rc18: $(grep -o 'DISPATCH_STATUS=[a-z_]*' "$W/out18" | head -1))"
grep -q 'status=ok.*sha256=[0-9a-f]' "$PROV" && grep -q 'TOCTOU-FORGED' "$A18" 2>/dev/null && no "18b an ok row was signed over forged content" || ok "18b no ok row over forged content"

if [ -f "$BAK" ]; then
  echo "== RED oracle (pre-fix dispatcher) =="
  AR="$W/.v/artifacts/AGENT_REVIEW_${SID}.red.md"; : > "$PROV"
  rcr=$(FAKE_SLEEP=40 DISPATCH_UNDER_TEST="$BAK" SRC="$BAK" kill_after "$AR" 1 "$W/outr1")   # bak never writes child.pid: the wait loop times out (15 s) and the kill lands mid-run
  grep -q 'status=aborted' "$PROV" && ok "RED: pre-fix helper writes status=aborted on the kill (the waste class reproduced)" || no "RED: pre-fix did not write aborted" "$(statuses)"
  SRC="$BAK" run_fg "$AR" "$W/outr2"; n=$(grep -c 'status=started' "$PROV")
  [ "${n:-0}" -ge 2 ] && ok "RED: pre-fix re-dispatch STARTED the work over (started rows=$n; the killed child's work was lost)" || no "RED: pre-fix did not restart (started rows=$n) — bite not isolating" "$(statuses)"
else
  echo "  --  RED oracle skipped ($BAK missing)"
fi
echo; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1
