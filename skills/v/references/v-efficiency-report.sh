#!/usr/bin/env bash
# v-efficiency-report.sh — ONE-STOP /v efficiency snapshot for measuring runs.
#
# Combines the telemetry signals that matter, read-only:
#   1. cache_read burn (the ~97% cost)        — via v-cache-burn.py over the session transcripts
#   2. per-dispatch subprocess cost + waste    — via v-telemetry-aggregate.sh over DISPATCH_PROVENANCE
#
# Run it AFTER a batch of /v sessions to see the burn + the dispatch overhead. Use --since-hours to isolate a
# fresh baseline (no need to delete old transcripts — the time window does it).
#
# Usage: v-efficiency-report.sh [--repo DIR] [--since-hours H] [--packs-per-day P]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HOME/dev/project-a"; SINCE=48; PACKS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)          REPO="$2"; shift 2 ;;
    --since-hours)   SINCE="$2"; shift 2 ;;
    --packs-per-day) PACKS="$2"; shift 2 ;;
    *) shift ;;
  esac
done
# transcript dir Claude Code derives from the repo path (/a/b/c -> -a-b-c)
TD="$HOME/.claude/projects/$(printf '%s' "$REPO" | sed 's#/#-#g')"
PFLAG=""; [ "$PACKS" != 0 ] && PFLAG="--packs-per-day $PACKS"

echo "════════════ /v EFFICIENCY REPORT — last ${SINCE}h ════════════"
echo "repo: $REPO"
echo
echo "─── 1. cache_read burn (the dominant cost) ───────────────────"
# shellcheck disable=SC2086
python3 "$HERE/v-cache-burn.py" "$TD" --since-hours "$SINCE" $PFLAG --top 8 2>/dev/null | sed 's/^/  /' \
  || echo "  (no transcripts in window)"
echo
echo "─── 2. per-dispatch subprocess cost + re-dispatch waste ──────"
bash "$HERE/v-telemetry-aggregate.sh" --repo "$REPO" 2>/dev/null | sed -n '/^-- corpus --/,$p' | sed 's/^/  /' \
  || echo "  (no DISPATCH_PROVENANCE — fresh repo)"
[ -z "$(bash "$HERE/v-telemetry-aggregate.sh" --repo "$REPO" 2>/dev/null | sed -n '/^-- corpus --/,$p')" ] \
  && echo "  (no DISPATCH_PROVENANCE yet — run some /v sessions)"
echo
echo "Tip: re-run after each batch; compare cache_read/session + turns/session to the prior batch."
