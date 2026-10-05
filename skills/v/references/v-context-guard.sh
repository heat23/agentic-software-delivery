#!/usr/bin/env bash
# v-context-guard.sh — measured, threshold-based context-size guard (W-ctx, 2026-07-08).
#
# WHY (forensic finding): the orchestrator's context grew 81k -> 421k with NO compaction
# because the model's 1M window never triggered the harness auto-compact — the old
# turn-count heuristic (25/40 turns) fired far too late/never. Reads scale with
# context x turns, so unbounded growth is the #1 cost driver.
# This helper reads the session's OWN transcript usage records (ground truth, not a
# guess) and reports a state the orchestrator must obey (SKILL.md § Context
# Degradation Safeguard).
#
# Usage: v-context-guard.sh [SID]     (default: $CLAUDE_SESSION_ID)
# Env:   V_PROJECTS_DIR (default ~/.claude/projects — test seam)
#
# Output (single line, machine-parseable):
#   CONTEXT_TOKENS=<n> CONTEXT_STATE=<ok|note|lean|handoff> CONTEXT_SOURCE=<file>
# States: <150k ok · 150-200k note (write PROGRESS_NOTE) · 200-280k lean (no
# full-file reads/re-reads; subprocess gates only) · >=280k handoff (HANDOFF_<sid>.md,
# essential gates only, complete).
# Exit: 0 = measured; 3 = no transcript/usage found (CONTEXT_STATE=unknown) — callers
# fall back to the turn-count heuristic, never treat unknown as ok.
#
# Fork-aware: a `context: fork` /v session's real work lives in
# <slug>/<sid>/subagents/agent-*.jsonl while <slug>/<sid>.jsonl stays tiny — the guard
# takes the MAX of each candidate file's LAST usage record.
set -uo pipefail

SID="${1:-${CLAUDE_SESSION_ID:-}}"
PROJ="${V_PROJECTS_DIR:-$HOME/.claude/projects}"

[ -n "$SID" ] || { echo "CONTEXT_TOKENS=0 CONTEXT_STATE=unknown CONTEXT_SOURCE=no-sid"; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "CONTEXT_TOKENS=0 CONTEXT_STATE=unknown CONTEXT_SOURCE=no-jq"; exit 3; }

BEST=0
BEST_SRC="none"
# nullglob-equivalent iteration without changing shell opts for callers
for f in "$PROJ"/*/"$SID".jsonl "$PROJ"/*/"$SID"/subagents/agent-*.jsonl; do
  [ -f "$f" ] || continue
  # Last usage record only — tail keeps this O(1) per file regardless of transcript size.
  n=$(tail -n 200 "$f" 2>/dev/null | jq -rs '
        [.[] | select(.message.usage) | .message.usage
         | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)]
        | if length > 0 then last else 0 end' 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -gt "$BEST" ]; then BEST="$n"; BEST_SRC="$f"; fi
done

if [ "$BEST" -eq 0 ]; then
  echo "CONTEXT_TOKENS=0 CONTEXT_STATE=unknown CONTEXT_SOURCE=none"
  exit 3
fi

if   [ "$BEST" -lt 150000 ]; then STATE=ok
elif [ "$BEST" -lt 200000 ]; then STATE=note
elif [ "$BEST" -lt 280000 ]; then STATE=lean
else STATE=handoff
fi

echo "CONTEXT_TOKENS=$BEST CONTEXT_STATE=$STATE CONTEXT_SOURCE=$BEST_SRC"
exit 0
