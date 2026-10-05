#!/usr/bin/env bash
# v-cache-burn-test.sh — bite for v-cache-burn.py (the cache_read telemetry consumer, efficiency 2026-06-24).
# Correctness invariant: it sums usage.cache_read_input_tokens (the burn) + counts turns from a transcript
# dir. RED on v-cache-burn.py.mut-bak (a field-mutant that sums cache_CREATION instead of cache_read).
set -uo pipefail
VCB="${V_VCB_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-cache-burn.py}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

TD=$(mktemp -d)
# one fixture transcript: 2 turns, cache_read 600000+400000=1_000_000, output 30000+20000=50000, cache_create 0
cat > "$TD/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl" <<'JSONL'
{"type":"assistant","message":{"usage":{"cache_read_input_tokens":600000,"cache_creation_input_tokens":0,"output_tokens":30000,"input_tokens":10}}}
{"type":"assistant","message":{"usage":{"cache_read_input_tokens":400000,"cache_creation_input_tokens":0,"output_tokens":20000,"input_tokens":10}}}
JSONL
OUT=$(python3 "$VCB" "$TD" 2>&1)

# the cache_READ line must report 1M (rounds to "1M"); turns=2
echo "$OUT" | grep -qE 'cache_READ[[:space:]]*:[[:space:]]*1M' \
  && ok "v-cache-burn sums cache_read correctly (600K+400K = 1.0M reported)" \
  || no "wrong cache_read total" "$(echo "$OUT" | grep -i cache_READ | head -1)"
echo "$OUT" | grep -qE 'turns=2' \
  && ok "turn count correct (2 turns)" || no "wrong turn count" "$(echo "$OUT" | grep -i 'per session' | head -1)"
# cache_read must be reported as 97-100% of tokens (it dominates; create=0, output=50K)
echo "$OUT" | grep -qE 'cache_READ.*9[0-9]%|cache_READ.*100%' \
  && ok "cache_read share computed (dominant)" || no "share not computed" "$(echo "$OUT" | grep -i cache_READ | head -1)"

rm -rf "$TD"

echo "== RC-5 :: fork burn under <sid>/subagents/ is accumulated (was undercounted ~14x / dropped) =="
TD2=$(mktemp -d)
SID="11110000-1111-4222-8333-444455556666"
# parent transcript: ZERO usage turns — the normal /v FORK shape (the orchestrator's work is in subagents/)
printf '{"type":"user","message":{"content":"/v verify ..."}}\n' > "$TD2/$SID.jsonl"
mkdir -p "$TD2/$SID/subagents/workflows/wf-test"
# subagent transcripts at TWO depths: flat subagents/agent-x.jsonl (5M) + nested subagents/workflows/wf/.. (2M).
# The nested shape is the workflow-agent case; the recursive glob must reach BOTH (logic-review depth coverage).
printf '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":5000000,"cache_creation_input_tokens":0,"output_tokens":100000,"input_tokens":10}}}\n' > "$TD2/$SID/subagents/agent-x.jsonl"
printf '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":2000000,"cache_creation_input_tokens":0,"output_tokens":50000,"input_tokens":10}}}\n' > "$TD2/$SID/subagents/workflows/wf-test/nested-agent.jsonl"
OUT2=$(python3 "$VCB" "$TD2" 2>&1)
echo "$OUT2" | grep -qE '1 sessions' \
  && ok "RC-5: a 0-parent-turn FORK still surfaces (was dropped by 'if not turns: return None')" \
  || no "fork session not surfaced" "$(echo "$OUT2" | head -1)"
echo "$OUT2" | grep -qE 'cache_READ[[:space:]]*:[[:space:]]*7M' \
  && ok "RC-5: BOTH flat (5M) + nested workflows/ (2M) subagent burn accumulated = 7M (recursive depth)" \
  || no "subagent burn under-counted (depth/undercount)" "$(echo "$OUT2" | grep -i cache_READ | head -1)"
rm -rf "$TD2"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
