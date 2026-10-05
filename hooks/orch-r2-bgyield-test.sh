#!/usr/bin/env bash
# orch-r2-bgyield-test.sh — BITE for W-perf9b (2026-06-30).
# A raw test runner + run_in_background:true inside an ACTIVE /v session (fresh bootstrap marker) must be DENIED.
# Foreground (no bg) → allow. Gate-dispatch + bg → still denied (W-perf9 no-regression). RED vs the pre-r2 .bak.
set -uo pipefail
HOOK="${V_BVPOLL_HOOK:-$HOME/.claude/hooks/block-v-polling.sh}"
[ -f "$HOOK" ] || { echo "FAIL: hook missing"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: no jq"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q 2>/dev/null || { echo "SKIP: no git"; exit 0; }
mkdir -p "$TMP/.v/tmp"; touch "$TMP/.v/tmp/bootstrap-test.env"   # fresh /v-active marker
_dec(){ (cd "$TMP" && printf '%s' "$1" | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null); }

RAW='{"tool_name":"Bash","tool_input":{"command":"php artisan test --parallel","run_in_background":true}}'
FG='{"tool_name":"Bash","tool_input":{"command":"php artisan test --parallel"}}'
GATE='{"tool_name":"Bash","tool_input":{"command":"bash ~/.claude/skills/v/references/v-dispatch-subagent.sh --agent v-pre-flight-runner","run_in_background":true}}'

[ "$(_dec "$RAW")" = "deny" ]  || { echo "FAIL: raw runner + bg in /v session NOT denied (pre-W-perf9b)"; exit 1; }
[ "$(_dec "$FG")"  != "deny" ] || { echo "FAIL: foreground raw runner wrongly denied"; exit 1; }
[ "$(_dec "$GATE")" = "deny" ] || { echo "FAIL: W-perf9 gate-dispatch+bg regressed (must still deny)"; exit 1; }
# ── W-perf9c (2026-09-01): foreground gate dispatch needs a >=300000 ms Bash timeout ──
_decj(){ (cd "$TMP" && printf '%s' "$1" | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null); }
D_CMD='bash ~/.claude/skills/v/references/v-dispatch-subagent.sh --agent v-pre-flight-runner --mode capture --prompt-file p.md --artifact a.md'
J_NOTO="$(jq -nc --arg c "$D_CMD" '{tool_name:"Bash",tool_input:{command:$c}}')"
J_600="$(jq -nc --arg c "$D_CMD" '{tool_name:"Bash",tool_input:{command:$c,timeout:600000}}')"
J_300="$(jq -nc --arg c "$D_CMD" '{tool_name:"Bash",tool_input:{command:$c,timeout:300000}}')"
J_120="$(jq -nc --arg c "$D_CMD" '{tool_name:"Bash",tool_input:{command:$c,timeout:120000}}')"
J_DET="$(jq -nc --arg c "$D_CMD --detach" '{tool_name:"Bash",tool_input:{command:$c}}')"
J_GREP="$(jq -nc --arg c 'grep -n -- "--agent" ~/.claude/skills/v/references/v-dispatch-subagent.sh | head' '{tool_name:"Bash",tool_input:{command:$c}}')"
J_PIPE="$(jq -nc --arg c 'sed -n 1,40p ~/.claude/skills/v/references/v-dispatch-subagent.sh | grep -- --agent v-qa-reviewer' '{tool_name:"Bash",tool_input:{command:$c}}')"
J_PM="$(jq -nc --arg c 'bash ~/.claude/skills/v/references/v-dispatch-subagent.sh --agent v-qa-reviewer --print-resolved-model' '{tool_name:"Bash",tool_input:{command:$c}}')"
J_MCP="$(jq -nc --arg c "$D_CMD" '{tool_name:"mcp__workspace__bash",tool_input:{command:$c}}')"
[ "$(_decj "$J_NOTO")" = "deny" ]  || { echo "FAIL (W-perf9c): foreground gate dispatch with NO timeout not denied (pre-fix: killed at 2m)"; exit 1; }
[ "$(_decj "$J_120")"  = "deny" ]  || { echo "FAIL (W-perf9c): 120000 ms timeout not denied"; exit 1; }
[ "$(_decj "$J_600")"  != "deny" ] || { echo "FAIL (W-perf9c): 600000 ms timeout wrongly denied"; exit 1; }
[ "$(_decj "$J_300")"  != "deny" ] || { echo "FAIL (W-perf9c): 300000 ms (the floor) wrongly denied"; exit 1; }
[ "$(_decj "$J_DET")"  != "deny" ] || { echo "FAIL (W-perf9c): --detach dispatch wrongly denied"; exit 1; }
[ "$(_decj "$J_GREP")" != "deny" ] || { echo "FAIL (W-perf9c): grep of the dispatcher source wrongly denied"; exit 1; }
[ "$(_decj "$J_PIPE")" != "deny" ] || { echo "FAIL (W-perf9c): piped read of the dispatcher source wrongly denied"; exit 1; }
[ "$(_decj "$J_PM")"   != "deny" ] || { echo "FAIL (W-perf9c): --print-resolved-model probe wrongly denied"; exit 1; }
[ "$(_decj "$J_MCP")"  = "deny" ]  || { echo "FAIL (W-perf9c): mcp__workspace__bash gate dispatch with NO timeout not denied"; exit 1; }
# review 2026-09-01 (correctness lens): quoted agent name, decoy exemption substring, continuation lines.
J_QUOTED="$(jq -nc --arg c 'bash ~/.claude/skills/v/references/v-dispatch-subagent.sh --agent "v-pre-flight-runner" --mode capture' '{tool_name:"Bash",tool_input:{command:$c}}')"
J_SQUOTED="$(jq -nc --arg c "bash ~/.claude/skills/v/references/v-dispatch-subagent.sh --agent 'v-qa-reviewer' --mode self-write" '{tool_name:"Bash",tool_input:{command:$c}}')"
J_DECOY="$(jq -nc --arg c 'echo "note: not using --detach here" && bash ~/.claude/skills/v/references/v-dispatch-subagent.sh --agent v-pre-flight-runner --mode capture' '{tool_name:"Bash",tool_input:{command:$c}}')"
J_CONT="$(jq -nc --arg c $'export SESSION_ID=x\nbash ~/.claude/skills/v/references/v-dispatch-subagent.sh \\\n  --agent v-pre-flight-runner \\\n  --mode capture --prompt-file p.md' '{tool_name:"Bash",tool_input:{command:$c}}')"
J_CONT_OK="$(jq -nc --arg c $'export SESSION_ID=x\nbash ~/.claude/skills/v/references/v-dispatch-subagent.sh \\\n  --agent v-pre-flight-runner \\\n  --mode capture --prompt-file p.md' '{tool_name:"Bash",tool_input:{command:$c,timeout:600000}}')"
J_DET2="$(jq -nc --arg c 'bash ~/.claude/skills/v/references/v-dispatch-subagent.sh --agent v-qa-reviewer --mode self-write --detach' '{tool_name:"Bash",tool_input:{command:$c}}')"
[ "$(_decj "$J_QUOTED")"  = "deny" ]  || { echo "FAIL (W-perf9c): double-quoted --agent name slipped the guard"; exit 1; }
[ "$(_decj "$J_SQUOTED")" = "deny" ]  || { echo "FAIL (W-perf9c): single-quoted --agent name slipped the guard"; exit 1; }
[ "$(_decj "$J_DECOY")"   = "deny" ]  || { echo "FAIL (W-perf9c): decoy '--detach' text elsewhere in the command exempted a real dispatch"; exit 1; }
[ "$(_decj "$J_CONT")"    = "deny" ]  || { echo "FAIL (W-perf9c): backslash-continuation dispatch with no timeout slipped the guard"; exit 1; }
[ "$(_decj "$J_CONT_OK")" != "deny" ] || { echo "FAIL (W-perf9c): continuation dispatch WITH timeout wrongly denied"; exit 1; }
[ "$(_decj "$J_DET2")"    != "deny" ] || { echo "FAIL (W-perf9c): real trailing --detach wrongly denied"; exit 1; }
echo "PASS (W-perf9c-r2): quoted names + decoy + continuation lines denied; real --detach allowed"
echo "PASS (W-perf9c): no/short timeout denied; >=300000, --detach, --print-resolved-model, source reads allowed"
echo "PASS (W-perf9b): raw+bg in /v denied; foreground allowed; gate-dispatch still denied"
exit 0
