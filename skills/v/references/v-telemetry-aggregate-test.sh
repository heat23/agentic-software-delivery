#!/usr/bin/env bash
# v-telemetry-aggregate-test.sh — the aggregator must sum per-dispatch cost and FLAG death-march waste
# (a review agent dispatched more than once). Synthetic DISPATCH_PROVENANCE: 3 codex + 1 pre-flight.
# Re-run: bash <thisfile>
set -u
TOOL="$HOME/.claude/skills/v/references/v-telemetry-aggregate.sh"
[ -f "$TOOL" ] || { echo "SKIP: missing $TOOL"; exit 0; }
command -v awk >/dev/null 2>&1 || { echo "SKIP: awk unavailable"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

BASE="$(mktemp -d)"; trap 'rm -rf "$BASE" 2>/dev/null' EXIT
R="$BASE/repo"; mkdir -p "$R/.v/artifacts"
SID="cccccccc-0000-0000-0000-00000000cccc"
LOG="$R/DISPATCH_PROVENANCE_${SID}.log"
{
  for k in 1 2 3; do
    printf 'DISPATCH|ts=2026-06-20T0%s:00:00Z|agent=codex-adversarial-reviewer|mode=capture|status=ok|submodel=sonnet|cost_usd=0.50|duration_ms=100000|artifact=A.md|sha256=x\n' "$k"
  done
  printf 'DISPATCH|ts=2026-06-20T05:00:00Z|agent=v-pre-flight-runner|mode=capture|status=ok|submodel=haiku|cost_usd=0.10|duration_ms=50000|artifact=P.md|sha256=y\n'
} > "$LOG"

OUT="$(bash "$TOOL" --repo "$R" --session "$SID" 2>&1)"
# Cost total = 3*0.50 + 0.10 = 1.60 ; wall = (3*100000+50000)/1000 = 350s ; 4 dispatches.
printf '%s' "$OUT" | grep -q '\$1\.60' && ok "per-dispatch cost summed to \$1.60" || no "cost total wrong" "$OUT"
printf '%s' "$OUT" | grep -q '350s'    && ok "wall-clock summed to 350s"          || no "wall total wrong" "$OUT"
printf '%s' "$OUT" | grep -q 'DEATH-MARCH: codex dispatched 3' && ok "death-march flagged (codex 3x)" || no "death-march NOT flagged" "$OUT"
printf '%s' "$OUT" | grep -qE 'codex-adversarial-reviewer +\$ +1\.50 .*\(3' && ok "per-agent breakdown (codex \$1.50, 3x)" || no "per-agent breakdown wrong" "$OUT"

# Control: a single-dispatch session must NOT be flagged as death-march.
SID2="dddddddd-0000-0000-0000-00000000dddd"
printf 'DISPATCH|ts=2026-06-20T05:00:00Z|agent=v-pre-flight-runner|mode=capture|status=ok|submodel=haiku|cost_usd=0.10|duration_ms=50000|artifact=P.md|sha256=z\n' > "$R/DISPATCH_PROVENANCE_${SID2}.log"
OUT2="$(bash "$TOOL" --repo "$R" --session "$SID2" 2>&1)"
printf '%s' "$OUT2" | grep -q 'DEATH-MARCH' && no "single dispatch false-flagged as death-march" "$OUT2" || ok "single-dispatch session NOT flagged (no false positive)"

# SREV-003: corpus output must print the TOTAL line BEFORE the "by agent" header.
CORPUS="$(bash "$TOOL" --repo "$R" 2>&1)"
TOT_LN=$(printf '%s\n' "$CORPUS" | grep -n '^TOTAL' | head -1 | cut -d: -f1)
AGT_LN=$(printf '%s\n' "$CORPUS" | grep -n 'by agent' | head -1 | cut -d: -f1)
if [ -n "$TOT_LN" ] && [ -n "$AGT_LN" ] && [ "$TOT_LN" -lt "$AGT_LN" ]; then
  ok "corpus: TOTAL printed before 'by agent' header (SREV-003)"
else
  no "corpus ordering wrong (TOTAL must precede by-agent)" "$CORPUS"
fi

# Edge: MALFORMED/partial DISPATCH lines (missing fields, reordered, plus a non-dispatch line) must not
# crash; dispatches still count, a missing cost defaults to 0, the garbage line is ignored.
SID3="eeeeeeee-0000-0000-0000-00000000eeee"
{
  printf 'DISPATCH|ts=t|agent=logic-reviewer|mode=capture|status=ok\n'        # no cost_usd / duration_ms
  printf 'garbage line that is not a dispatch at all\n'
  printf 'DISPATCH|agent=v-qa-reviewer|cost_usd=0.20|duration_ms=5000\n'      # reordered, no ts
} > "$R/DISPATCH_PROVENANCE_${SID3}.log"
OUT3="$(bash "$TOOL" --repo "$R" --session "$SID3" 2>&1)"
printf '%s' "$OUT3" | grep -q '2 dispatches' && ok "malformed/partial DISPATCH lines counted (2); garbage ignored; no crash" || no "malformed line handling wrong" "$OUT3"
printf '%s' "$OUT3" | grep -q '\$0.20'        && ok "partial line: present cost summed, missing cost defaults to 0" || no "partial-cost handling wrong" "$OUT3"

# Edge: an EMPTY provenance log must not crash and must report nothing for that session.
SID4="ffffffff-0000-0000-0000-00000000ffff"
: > "$R/DISPATCH_PROVENANCE_${SID4}.log"
if OUT4="$(bash "$TOOL" --repo "$R" --session "$SID4" 2>&1)"; then
  printf '%s' "$OUT4" | grep -q "session ${SID4}" && no "empty log emitted a phantom session line" "$OUT4" || ok "empty provenance log handled gracefully (no crash, no phantom session)"
else no "empty provenance log crashed (nonzero exit)" "$OUT4"; fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
