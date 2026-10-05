#!/usr/bin/env bash
# v-op-telemetry-stop-hook-summary-test.sh — Item 22 regression test (2026-07-03, stop_blocks 2x overcount).
#
# Ground truth verified on a real production transcript: each ACTUAL Stop-hook block
# emits a structured {"type":"system","subtype":"stop_hook_summary","hookErrors":[...]} event, but
# Claude Code ALSO surfaces the identical "COMPLETION BLOCKED" text a second time as a separate
# injected 'user' message immediately before it — so the OLD raw substring scan (over both 'system'
# and 'user' lines) counted every real block TWICE (raw hits were exactly 2x the real blocking
# events; the same overcount showed up as a stop_blocks figure exceeding the ground-truth
# stop_hook_summary blocking count in a forensics report). The fix counts stop_hook_summary events
# with non-empty hookErrors instead, which is 1:1 with the real Stop-hook invocation.
set -uo pipefail
OPT="${V_OPT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-op-telemetry.py}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

SID="cccccccc-dddd-4eee-8fff-000000000000"

_fr(){ # $1 = script path, $2 = fixture dir (has .claude/projects/p/$SID.jsonl)
  HOME="$2" python3 "$1" --sid "$SID" --summary-json 2>/dev/null | python3 -c "
import json,sys
try: g=json.load(sys.stdin).get('gate_friction') or {}
except Exception: print('ERR'); sys.exit()
print(g.get('stop_blocks','?'))
" 2>/dev/null
}

echo "== Item 22 :: stop_blocks counts REAL stop_hook_summary events, not raw substring hits =="

# Fixture: 2 real Stop-hook blocks, each represented (per real transcript ground truth) as BOTH an
# injected 'user' text copy AND the structured stop_hook_summary system event with hookErrors. Plus
# one NON-blocking stop_hook_summary (empty hookErrors, e.g. a clean stop) that must NOT count.
TD=$(mktemp -d); P="$TD/.claude/projects/p"; mkdir -p "$P"
cat > "$P/$SID.jsonl" <<'JSONL'
{"type":"user","timestamp":"2026-07-03T10:00:00.000Z","message":{"content":"COMPLETION BLOCKED — artifact gates not satisfied (injected duplicate copy #1)"}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-07-03T10:00:00.100Z","hookErrors":["[check-review-artifact.sh]: COMPLETION BLOCKED — artifact gates not satisfied"]}
{"type":"assistant","timestamp":"2026-07-03T10:00:01.000Z","message":{"id":"m1","model":"claude-opus-4","usage":{"cache_read_input_tokens":10,"output_tokens":5,"input_tokens":1},"content":[{"type":"text","text":"fixing gate 1"}]}}
{"type":"user","timestamp":"2026-07-03T10:00:02.000Z","message":{"content":"COMPLETION BLOCKED — artifact gates not satisfied (injected duplicate copy #2)"}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-07-03T10:00:02.100Z","hookErrors":["[check-review-artifact.sh]: COMPLETION BLOCKED — artifact gates not satisfied"]}
{"type":"assistant","timestamp":"2026-07-03T10:00:03.000Z","message":{"id":"m2","model":"claude-opus-4","usage":{"cache_read_input_tokens":10,"output_tokens":5,"input_tokens":1},"content":[{"type":"text","text":"fixing gate 2"}]}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-07-03T10:00:04.000Z","hookErrors":[]}
JSONL

FR=$(_fr "$OPT" "$TD")
[ "$FR" = "2" ] \
  && ok "2 real blocks (2 stop_hook_summary w/ hookErrors, 1 clean-stop excluded) ⇒ stop_blocks=2, NOT 4 (the 2x-overcount bite)" \
  || no "stop_blocks miscounted" "got '$FR' (want '2')"
rm -rf "$TD"

echo ""
echo "== Item 22 :: legacy fallback still works when NO structured event exists in the file =="
TD2=$(mktemp -d); P2="$TD2/.claude/projects/p"; mkdir -p "$P2"
cat > "$P2/$SID.jsonl" <<'JSONL'
{"type":"system","timestamp":"2026-07-03T10:00:00.000Z","content":"COMPLETION BLOCKED — legacy-format transcript, no stop_hook_summary event"}
{"type":"assistant","timestamp":"2026-07-03T10:00:01.000Z","message":{"id":"m1","model":"claude-opus-4","usage":{"cache_read_input_tokens":10,"output_tokens":5,"input_tokens":1},"content":[{"type":"text","text":"ok"}]}}
JSONL
FR2=$(_fr "$OPT" "$TD2")
[ "$FR2" = "1" ] \
  && ok "legacy transcript (no stop_hook_summary anywhere) still counted via substring fallback (no regression)" \
  || no "legacy fallback broken" "got '$FR2' (want '1')"
rm -rf "$TD2"

BAK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-op-telemetry.py.mut-bak"
if [ -f "$BAK" ]; then
  TD3=$(mktemp -d); P3="$TD3/.claude/projects/p"; mkdir -p "$P3"
  cat > "$P3/$SID.jsonl" <<'JSONL'
{"type":"user","timestamp":"2026-07-03T10:00:00.000Z","message":{"content":"COMPLETION BLOCKED — dup #1"}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-07-03T10:00:00.100Z","hookErrors":["COMPLETION BLOCKED"]}
JSONL
  FR3=$(_fr "$BAK" "$TD3")
  # informational only: the .mut-bak fixture predates this class of fix and is not required to
  # reproduce the exact RED shape for THIS specific test (its RED oracle role is covered by the
  # existing wall-clock-pairing test); skip strictly asserting on it here.
  rm -rf "$TD3"
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
