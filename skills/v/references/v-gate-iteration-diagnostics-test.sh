#!/usr/bin/env bash
# v-gate-iteration-diagnostics-test.sh — Change 5 (partial): make a degenerate gate lap DIAGNOSABLE.
#
# THE OPEN BUG (not fixed here, deliberately). A forensic session ran a dozen gate laps, several of which
# were `PFM_REQUESTED=full -> PFM=scoped ALL_PASS=0` completing in 1-6s — impossibly fast for a
# real pre-flight (tsc alone is 2-7s, a full test run far longer). Those laps did nothing and reported failure, and
# the orchestrator then re-dispatched, which is where the waste came from.
#
# WHY IT IS NOT FIXED HERE. To fix the downgrade correctly you must know WHY those laps were
# degenerate — empty scope? blind? tree mismatch? That evidence is GONE: gate-summary is a single
# per-SID file that section 7 TRUNCATE-OVERWRITES (`{ ... } > "$SUMMARY_FILE"`, v-run-gates.sh:1666)
# on every invocation, a property v-run-gates.sh's own Item-18 comment documents. Only the LAST
# run's summary survives, and in that session it was the healthy full run. Changing gate-mode
# selection on a guess is exactly the class of "fix" this ecosystem has had to revert before
# (fix at the SOURCE, and only with evidence).
#
# WHAT THIS DOES INSTEAD. The per-iteration ledger already survives (append-only, unlike the
# summary). It records PFM + ALL_PASS but not the fields that would explain a degenerate lap. This
# pins four additional diagnostic fields onto that line — additive and verdict-neutral: nothing
# parses individual fields of gate-iterations (verified: the only consumer is `wc -l` in
# p1c-durable-fallback-test.sh). Cost: zero. Payoff: the next occurrence is attributable instead
# of unfalsifiable, which is the precondition for fixing it properly.
#
# RED ORACLE: V_RUN_GATES=<pre-change bak> lacks the fields.
set -u
RG="${V_RUN_GATES:-$HOME/.claude/skills/v/references/v-run-gates.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$RG" ] || { echo "  NO  v-run-gates.sh not found at $RG"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

echo "== Change 5 :: the per-iteration ledger must explain a degenerate lap =="
LINE=$(grep -n '_P1C_ITER_LINE=' "$RG" | head -1)
[ -n "$LINE" ] && ok "iteration-line template found" || no "iteration-line template missing" ""
TPL=$(grep '_P1C_ITER_LINE="' "$RG" | head -1)

# The pre-existing fields must survive (this is additive, not a rewrite).
for f in 'PFM=' 'ALL_PASS=' 'DONE_AT_SOURCE='; do
  printf '%s' "$TPL" | grep -q "$f" \
    && ok "existing field preserved: ${f%=}" \
    || no "existing field DROPPED: ${f%=}" "$TPL"
done

# The four diagnostic fields that make a degenerate lap attributable.
#   PFM_REQUESTED — a silent full->scoped downgrade is currently only visible by correlating two
#                   SEPARATE ledger lines; on one line it is self-evident.
#   BLIND         — PREFLIGHT_BLIND=1 means a 0-file scope: the leading hypothesis for a 1-6s lap.
#   TREE_MISMATCH — graded the wrong tree.
#   SCOPE_N       — how many files the lap actually looked at. 0 explains everything.
for f in PFM_REQUESTED BLIND TREE_MISMATCH SCOPE_N; do
  printf '%s' "$TPL" | grep -q "${f}=" \
    && ok "diagnostic field present: $f" \
    || no "diagnostic field missing: $f (a degenerate lap stays unattributable)" ""
done

# Verdict-neutrality: the ledger line must not participate in deciding PASS/FAIL.
printf '%s' "$TPL" | grep -qE 'ALL_PASS=\$\{ALL_PASS' \
  && ok "ALL_PASS is still REPORTED, not recomputed, on the ledger line" \
  || no "ledger line appears to derive ALL_PASS rather than report it" "$TPL"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
