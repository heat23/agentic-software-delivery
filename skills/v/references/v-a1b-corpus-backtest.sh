#!/usr/bin/env bash
# v-a1b-corpus-backtest.sh — A-1b corpus backtest (HANDOFF_orchestrator-hardening-3.md, Trap 2).
#
# WHY: A-1b proposes tightening `_agent_was_dispatched()` (hooks/lib/validation.sh:808) so a
# `status=ok` provenance row with an EMPTY/malformed sha256 no longer counts as proof of an
# independent dispatch (the exact fabrication vector observed in a past session: a hand-printf'd row with
# `mode=capture|status=ok|...|sha256=` — empty — currently satisfies the grep and is accepted as
# "dispatched"). Per the plan's own Trap 2 ("A-1 strict internal order... A-1b ships LAST with a
# grandfather cutoff... + a corpus backtest over every existing DISPATCH_PROVENANCE_*.log in
# a production repo + ~/.claude — else Stop false-blocks fleet-wide on historical degraded rows"), the
# tightening must NOT be shipped until this backtest shows 0 false positives on real history.
#
# WHAT THIS SCRIPT DOES: scans every DISPATCH_PROVENANCE_*.log file under the given root paths for
# `status=ok` rows and reports, PER MODE, how many have a valid 64-hex sha256 vs an empty/malformed
# one. This is the evidence gate — it does NOT modify validation.sh. A human/future-session decision
# to tighten should only proceed if `capture` mode rows are ~100% sha256-populated in real history
# (proving the tightening rule targets exactly the fabrication vector, not a legitimate edge case).
#
# Usage: bash v-a1b-corpus-backtest.sh [root1] [root2] ...
#   Defaults to ~/.claude and ~/dev if no roots given.
# Output: a per-mode table + a FALSE_POSITIVE_CANDIDATES section (status=ok, mode=capture, no sha256)
# with file:line so a human can inspect each one before deciding whether to ship the tightening.
set +e
set +o pipefail
set +u

ROOTS=("$@")
if [ "${#ROOTS[@]}" -eq 0 ]; then
  ROOTS=("$HOME/.claude" "$HOME/dev")
fi

TMP_ALL=$(mktemp)
TMP_FP=$(mktemp)
trap 'rm -f "$TMP_ALL" "$TMP_FP"' EXIT

TOTAL_LOGS=0
TOTAL_OK_ROWS=0

for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  while IFS= read -r log; do
    TOTAL_LOGS=$((TOTAL_LOGS+1))
    # status=ok rows only (the class this tightening targets — status=error/transient/ok_late rows
    # are irrelevant since they were never used as "proof of independence" in the first place).
    grep -nE '\|status=ok\|' "$log" 2>/dev/null | while IFS= read -r line; do
      _lineno="${line%%:*}"
      _rest="${line#*:}"
      _mode=$(printf '%s' "$_rest" | grep -oE '\|mode=[^|]*\|' | head -1 | sed 's/^|mode=//; s/|$//')
      _sha=$(printf '%s' "$_rest" | grep -oE 'sha256=[0-9a-fA-F]*$' | sed 's/^sha256=//')
      _valid="no"
      # NOTE: a hand-typed 64x[0-9a-fA-F] `case` glob is extremely error-prone to author correctly
      # (an off-by-one bracket-count is invisible on read-back) and bash's case/glob syntax has no
      # {n} interval quantifier — use `grep -qE '^...{64}$'` instead, which is both correct and
      # legible. Verified against a real 64-hex sha256 before trusting this in the full corpus scan.
      if printf '%s' "$_sha" | grep -qE '^[0-9a-fA-F]{64}$'; then
        _valid="yes"
      fi
      printf '%s\t%s\t%s\n' "${_mode:-none}" "$_valid" "$log:$_lineno" >> "$TMP_ALL"
      if [ "$_mode" = "capture" ] && [ "$_valid" = "no" ]; then
        printf '%s: %s\n' "$log:$_lineno" "$_rest" >> "$TMP_FP"
      fi
    done
  done < <(find "$root" -iname "DISPATCH_PROVENANCE_*.log" -not -path "*/node_modules/*" -not -path "*/vendor/*" 2>/dev/null)
done

TOTAL_OK_ROWS=$(wc -l < "$TMP_ALL" | tr -d ' ')

echo "=== A-1b corpus backtest ==="
echo "Roots scanned: ${ROOTS[*]}"
echo "DISPATCH_PROVENANCE_*.log files found: $TOTAL_LOGS"
echo "status=ok rows analyzed: $TOTAL_OK_ROWS"
echo ""
echo "--- per-mode sha256 validity ---"
if [ -s "$TMP_ALL" ]; then
  awk -F'\t' '{print $1"\t"$2}' "$TMP_ALL" | sort | uniq -c | sort -rn | \
    awk '{printf "  %-6s mode=%-20s sha256_valid=%s\n", $1, $2, $3}'
else
  echo "  (no status=ok rows found in corpus)"
fi
echo ""
FP_COUNT=$(wc -l < "$TMP_FP" 2>/dev/null | tr -d ' ')
FP_COUNT="${FP_COUNT:-0}"
echo "--- FALSE_POSITIVE_CANDIDATES: mode=capture status=ok with EMPTY/malformed sha256 ($FP_COUNT found) ---"
if [ "$FP_COUNT" -gt 0 ]; then
  cat "$TMP_FP"
  echo ""
  echo "VERDICT: NOT SAFE to ship the A-1b tightening as a hard block without a grandfather cutoff —"
  echo "  $FP_COUNT real historical mode=capture rows would newly fail. Inspect each: genuine crypto-tool-"
  echo "  unavailable edge case (legitimate, needs a carve-out) vs actual fabrication (the tightening is"
  echo "  correctly catching it, but must not retroactively fail sessions that already completed)."
else
  echo "VERDICT: SAFE — 0 false positives. Every real mode=capture status=ok row in the scanned corpus"
  echo "  carries a valid 64-hex sha256. Tightening _agent_was_dispatched() to require sha256 specifically"
  echo "  for mode=capture rows would not have broken any historical session in this corpus."
fi
echo ""
echo "NOTE: this is a STATIC backtest (grep over historical logs), not a live re-run of old gates."
echo "Ship the tightening ONLY with a grandfather cutoff (enforce only rows with ts= newer than this"
echo "backtest's run time) per the plan's Trap 2, regardless of this result — old rows outside the"
echo "cutoff are never re-evaluated by a live session."
