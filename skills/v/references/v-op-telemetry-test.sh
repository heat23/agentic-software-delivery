#!/usr/bin/env bash
# v-op-telemetry-test.sh — bite for v-op-telemetry.py (per-operation telemetry, efficiency 2026-06-29).
# Invariants:
#   (a) per-TOOL wall-clock = tool_result-line ts - tool_use-line ts, paired by the toolu_ id;
#   (b) per-TURN token classes summed with message.id DEDUP (streaming partials collapse to the final;
#       matches v-extract-tokens — proven equal on a real session to the token);
#   (c) subagent burn under <sid>/subagents/** is recursed in;
#   (d) coarse by_phase splits main_loop (parent) vs dispatch (subagents).
# RED on v-op-telemetry.py.mut-bak (the wall-clock pairing dropped to None). Re-run: bash <thisfile>
set -uo pipefail
OPT="${V_OPT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-op-telemetry.py}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

# Hermetic fixture under a temp HOME (the extractor resolves cfg = $HOME/.claude). Faithful transcript
# JSONL: parent with a STREAMED-twice assistant message (dedup must keep the final usage) + a Bash
# tool_use/result 2000ms apart, plus one subagent transcript with 5M cache_read.
TD=$(mktemp -d)
SID="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
PROJ="$TD/.claude/projects/proj"
mkdir -p "$PROJ/$SID/subagents"
cat > "$PROJ/$SID.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-06-29T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-4","usage":{"cache_read_input_tokens":1,"output_tokens":1,"input_tokens":1},"content":[{"type":"text","text":"streamed partial"}]}}
{"type":"assistant","timestamp":"2026-06-29T10:00:00.500Z","message":{"id":"m1","model":"claude-opus-4","usage":{"cache_read_input_tokens":600000,"output_tokens":30000,"input_tokens":10},"content":[{"type":"tool_use","id":"toolu_t1","name":"Bash"}]}}
{"type":"user","timestamp":"2026-06-29T10:00:02.500Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_t1","content":"out"}]}}
JSONL
cat > "$PROJ/$SID/subagents/agent-x.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-06-29T10:00:05.000Z","message":{"id":"s1","model":"claude-sonnet-4","usage":{"cache_read_input_tokens":5000000,"output_tokens":100000,"input_tokens":10},"content":[{"type":"text","text":"hi"}]}}
JSONL

SUM=$(HOME="$TD" python3 "$OPT" --sid "$SID" --summary-json 2>/dev/null)
RES=$(printf '%s' "$SUM" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('ERR ERR ERR ERR'); sys.exit()
cr=d['by_token_class']['cache_read']; turns=d['totals']['turns']
bt=[t for t in d['by_tool_wallclock'] if t['tool']=='Bash']
bmax=bt[0]['max_ms'] if bt else -1
ph={p['phase']:p['cache_read'] for p in d['by_phase']}
print(cr, turns, bmax, ph.get('dispatch',-1))
" 2>/dev/null)
CR=$(echo "$RES" | awk '{print $1}'); TURNS=$(echo "$RES" | awk '{print $2}')
BMAX=$(echo "$RES" | awk '{print $3}'); DISP_CR=$(echo "$RES" | awk '{print $4}')

[ "$CR" = "5600000" ] \
  && ok "cache_read deduped + recursed: 600000 (final, not the 1+600000 streamed sum) + 5000000 subagent = 5,600,000" \
  || no "cache_read wrong (dedup or subagent recursion)" "got $CR"
[ "$TURNS" = "2" ] \
  && ok "turns deduped by message.id (m1 streamed twice -> 1) + subagent s1 = 2" \
  || no "turn count wrong (dedup)" "got $TURNS"
[ "$BMAX" = "2000" ] \
  && ok "per-tool wall-clock = tool_result ts - tool_use ts = 2000ms (Bash)" \
  || no "Bash wall-clock wrong (tool_use/result pairing)" "got $BMAX (mutant drops this -> 0)"
[ "$DISP_CR" = "5000000" ] \
  && ok "by_phase splits dispatch (subagent) cache_read = 5,000,000 from main_loop" \
  || no "by_phase dispatch split wrong" "got $DISP_CR"

rm -rf "$TD"

# SREV-001 / logic-MED: an out-of-order tool_result (ts BEFORE its tool_use — clock skew/NTP) must yield
# wall_ms None, NEVER a negative that corrupts sums / sort keys / quantiles.
TD2=$(mktemp -d); P2="$TD2/.claude/projects/p"; mkdir -p "$P2/$SID"
cat > "$P2/$SID.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-06-29T10:00:10.000Z","message":{"id":"r1","model":"claude-opus-4","usage":{"cache_read_input_tokens":1,"output_tokens":1,"input_tokens":1},"content":[{"type":"tool_use","id":"toolu_r","name":"Bash"}]}}
{"type":"user","timestamp":"2026-06-29T10:00:08.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_r","content":"out"}]}}
JSONL
NEG=$(HOME="$TD2" python3 "$OPT" --sid "$SID" --json 2>/dev/null | python3 -c "
import json,sys
try: s=json.load(sys.stdin)[0]
except Exception: print('ERR'); sys.exit()
print(sum(1 for t in s['tools'] if t['wall_ms'] is not None and t['wall_ms']<0))
" 2>/dev/null)
[ "$NEG" = "0" ] \
  && ok "out-of-order tool_result -> wall_ms None (zero negative walls leak into totals)" \
  || no "negative wall_ms leaked from out-of-order timestamps" "neg count=$NEG"
rm -rf "$TD2"

# TEL-1 gate-friction: a Stop-hook block is HARNESS-INJECTED (system / user-str, NEVER a tool_result); an
# auto-mode denial is an is_error tool_result. A tool_result or assistant line that merely CONTAINS the
# phrase (a grep output, a file read, the model's own prose) must NOT count (precision — the naive
# any-non-assistant rule over-counted on a real session). Fixture exercises all 5 shapes.
FRDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TD3=$(mktemp -d); P3="$TD3/.claude/projects/p"; mkdir -p "$P3/$SID"
cat > "$P3/$SID.jsonl" <<'JSONL'
{"type":"system","timestamp":"2026-06-29T10:00:00.000Z","content":"COMPLETION BLOCKED — artifact gates not satisfied"}
{"type":"assistant","timestamp":"2026-06-29T10:00:01.000Z","message":{"id":"f1","model":"claude-opus-4","usage":{"cache_read_input_tokens":100,"output_tokens":50,"input_tokens":1},"content":[{"type":"text","text":"my own prose quoting COMPLETION BLOCKED must NOT count"}]}}
{"type":"user","timestamp":"2026-06-29T10:00:02.000Z","message":{"content":"COMPLETION BLOCKED — second injected gate feedback (user string)"}}
{"type":"user","timestamp":"2026-06-29T10:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_z","content":"grep output: COMPLETION BLOCKED (a command output — must NOT count)"}]}}
{"type":"user","timestamp":"2026-06-29T10:00:04.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_d","is_error":true,"content":"Error: Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Logging/Audit Tampering]"}]}}
JSONL
_fr(){ HOME="$TD3" python3 "$1" --sid "$SID" --summary-json 2>/dev/null | python3 -c "
import json,sys
try: g=json.load(sys.stdin).get('gate_friction') or {}
except Exception: print('ERR ERR'); sys.exit()
print(g.get('stop_blocks','?'), g.get('automode_denials','?'))
" 2>/dev/null; }
FR=$(_fr "$OPT")
[ "$FR" = "2 1" ] \
  && ok "gate-friction: 2 Stop-blocks (system + user-str) + 1 is_error denial; tool_result output & assistant prose EXCLUDED" \
  || no "gate-friction miscounted (precision guard: tool_result/assistant must not count)" "got '$FR' (want '2 1')"
BAK_FR="$FRDIR/v-op-telemetry.py.pre-friction-bak"
if [ -f "$BAK_FR" ]; then
  FRB=$(_fr "$BAK_FR")
  [ "$FRB" != "2 1" ] \
    && ok "RED: pre-friction backup has no gate-friction accounting (the fixture's blocks are invisible -> got '$FRB')" \
    || no "RED: pre-friction backup already counts friction?!" "got '$FRB'"
else echo "  skip RED oracle — pre-fix backup not shipped in the public snapshot ($BAK_FR)"; fi
rm -rf "$TD3"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
