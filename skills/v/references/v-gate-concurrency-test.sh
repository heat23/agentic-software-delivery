#!/usr/bin/env bash
# v-gate-concurrency-test.sh — RETIRED 2026-08-05.
#
# This harness used to assert the presence and calibration of W-GATECONC, a Stop-hook advisory that
# warned when N distinct gate agents' FIRST dispatch timestamps spread over >90s. The detector was
# retired because measurement showed it had NO discriminating power. This file is kept, and kept
# executable, as the guard against rebuilding it: it now FAILS if a timestamp-spread detector
# reappears in the Stop hook.
#
# ------------------------------------------------------------------------------------------------
# WHY IT WAS RETIRED (corpus: 105 dispatch rounds across 47 sessions, 2026-07-25 .. 2026-08-05)
#
#   * The canonical known-SERIALIZED forensic session, whose log reads "each awaited before the
#     next" — measured a 161s spread: the 15th PERCENTILE. The case the detector was BUILT FOR is
#     one of the TIGHTEST rounds in the entire corpus.
#   * The median round measured 726s. 85% of all rounds exceeded the 90s threshold, including
#     rounds verified BY HAND as correctly batched (one session, round 2: 5 distinct agents in 126s,
#     round 3: 3 agents in 35s).
#   * Net: it fired on 40 of 47 sessions. Any threshold that catches the motivating case fires on
#     ~85% of sessions; any threshold that spares verified-good batches misses it by ~10x.
#
# WHY THE PROXY IS STRUCTURALLY WRONG, not merely mis-tuned:
#   Provenance rows are written when a subprocess STARTS or COMPLETES, never when the orchestrator
#   EMITS the dispatch — and the recommended concurrent path (v-agent-review.md, "Concurrent
#   reviewer dispatch") writes `--mode capture` rows at COMPLETION. A perfectly batched round whose
#   slowest agent takes 20 minutes therefore "spreads" 20 minutes, indistinguishable from serial.
#
# WHY IT CANNOT BE REBUILT FROM ANOTHER SIGNAL:
#   * interval overlap — impossible: `agent-tool` provenance rows carry duration_ms=0 (0 of 235
#     usable in the corpus), i.e. missing for exactly the dispatches most likely to serialize.
#   * transcript batching — unavailable: 0 of 14,802 assistant records hold >=2 tool_use blocks.
#     The transcript writer splits every tool call into its own record, so "gate agents dispatched
#     per message" is not observable there. (Verified against Read/Grep pairs known to be batched.)
#
# Concurrent gate dispatch REMAINS the documented default (v-agent-review.md; owner
# guidance on parallel gate dispatch). It is simply not measurable from the Stop hook, and an
# advisory firing on 85% of sessions trains the reader to ignore the whole advisory channel.
#
# Anything reintroducing a spread-based detector must first defeat the evidence above.
# Live behavioural coverage of the retirement: hooks/stop-advisory-hardening-test.sh (T22/T23).
# ------------------------------------------------------------------------------------------------
set -uo pipefail
HOOK="${V_CRA_OVERRIDE:-$HOME/.claude/hooks/check-review-artifact.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }

echo "== W-GATECONC :: retired, guarding against rebuild =="

if grep -q 'GATE-SERIALIZATION' "$HOOK"; then
  no "no GATE-SERIALIZATION advisory in the Stop hook" \
     "it reappeared — read the retirement rationale in this file's header before restoring it"
else
  ok "no GATE-SERIALIZATION advisory in the Stop hook"
fi

if grep -q 'W-GATECONC RETIRED' "$HOOK"; then
  ok "retirement rationale retained in the hook (survives a future reader who greps for W-GATECONC)"
else
  no "retirement rationale retained in the hook" "the 'W-GATECONC RETIRED' note was removed"
fi

# The replacement guarantee: the advisory channel is now idempotent, so the class of complaint that
# made W-GATECONC intolerable (an unclearable advisory repeating on every Stop) is fixed generally
# rather than per-advisory.
if grep -q 'W-ADVISORY-IDEM BEGIN' "$HOOK"; then
  ok "advisory idempotence block present (the general fix for unclearable repeat advisories)"
else
  no "advisory idempotence block present" "W-ADVISORY-IDEM missing from the Stop hook"
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
