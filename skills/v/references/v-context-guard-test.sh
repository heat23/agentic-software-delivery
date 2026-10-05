#!/usr/bin/env bash
# v-context-guard-test.sh — W-ctx threshold guard harness (2026-07-08).
#
# CLASS: unbounded context growth (forensic: 81k->421k, no compaction,
# avoidable cost). The guard must (a) measure from the transcript's LAST usage record,
# (b) be fork-aware (max across parent + subagent files — the parent stays tiny while
# the real orchestrator context lives in subagents/agent-*.jsonl), (c) map thresholds
# exactly, (d) fail CLOSED to 'unknown' (exit 3), never to 'ok', when nothing is found.
# RED oracle: V_GUARD_PATH=/nonexistent bash <this>  -> every case fails.
set -u
ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
GUARD="${V_GUARD_PATH:-$ROOT/skills/v/references/v-context-guard.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_usage(){ # <file> <ctx-tokens...> — one usage record per value, last wins
  local f="$1"; shift
  : > "$f"
  local i=0
  for v in "$@"; do
    i=$((i+1))
    printf '{"message":{"id":"m%s","usage":{"input_tokens":10,"cache_creation_input_tokens":90,"cache_read_input_tokens":%s}}}\n' "$i" "$((v-100))" >> "$f"
  done
}
run(){ # <sid> -> stdout line; rc in $RC
  OUT=$(V_PROJECTS_DIR="$T/projects" bash "$GUARD" "$1" 2>/dev/null); RC=$?
}

echo "== W-ctx :: v-context-guard thresholds + fork-awareness =="
[ -f "$GUARD" ] || { no "guard script exists" "missing: $GUARD"; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1; }

SLUG="$T/projects/-home-x-repo"; mkdir -p "$SLUG"

# T1-T4: threshold mapping on a main-only transcript (LAST record governs, not max-history)
mk_usage "$SLUG/s1.jsonl" 400000 100000            # history spiked, last=100k -> ok
run s1; echo "$OUT" | grep -q 'CONTEXT_STATE=ok'      && ok "T1: last-record 100k -> ok (last wins, not history max)" || no "T1" "$OUT"
mk_usage "$SLUG/s2.jsonl" 160000
run s2; echo "$OUT" | grep -q 'CONTEXT_STATE=note'    && ok "T2: 160k -> note" || no "T2" "$OUT"
mk_usage "$SLUG/s3.jsonl" 230000
run s3; echo "$OUT" | grep -q 'CONTEXT_STATE=lean'    && ok "T3: 230k -> lean" || no "T3" "$OUT"
mk_usage "$SLUG/s4.jsonl" 310000
run s4; echo "$OUT" | grep -q 'CONTEXT_STATE=handoff' && ok "T4: 310k -> handoff" || no "T4" "$OUT"

# T5: fork layout — tiny parent, big subagent: the subagent's context must govern
mk_usage "$SLUG/s5.jsonl" 5000
mkdir -p "$SLUG/s5/subagents"
mk_usage "$SLUG/s5/subagents/agent-abc.jsonl" 90000 305000
run s5; echo "$OUT" | grep -q 'CONTEXT_STATE=handoff' && ok "T5: fork-aware (parent 5k, subagent 305k -> handoff)" || no "T5: fork-blind (observed class)" "$OUT"
echo "$OUT" | grep -q 'agent-abc' && ok "T5b: source attributes the subagent file" || no "T5b" "$OUT"

# T6: unknown SID → fail CLOSED (exit 3 + unknown), never 'ok'
run nosuchsid
[ "$RC" = 3 ] && echo "$OUT" | grep -q 'CONTEXT_STATE=unknown' && ok "T6: missing transcript -> unknown + exit 3 (fail-closed)" || no "T6: absent transcript did not fail closed" "rc=$RC $OUT"

# T7: exact boundary values (149,999 ok / 150,000 note / 280,000 handoff)
mk_usage "$SLUG/s7.jsonl" 149999; run s7; echo "$OUT" | grep -q 'CONTEXT_STATE=ok' && ok "T7a: 149,999 -> ok" || no "T7a" "$OUT"
mk_usage "$SLUG/s8.jsonl" 150000; run s8; echo "$OUT" | grep -q 'CONTEXT_STATE=note' && ok "T7b: 150,000 -> note" || no "T7b" "$OUT"
mk_usage "$SLUG/s9.jsonl" 280000; run s9; echo "$OUT" | grep -q 'CONTEXT_STATE=handoff' && ok "T7c: 280,000 -> handoff" || no "T7c" "$OUT"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
