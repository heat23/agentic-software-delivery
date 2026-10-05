#!/usr/bin/env bash
# v-telemetry-aggregate.sh — aggregate per-dispatch cost + wall-clock from DISPATCH_PROVENANCE logs.
#
# WHY (telemetry-for-optimization, 2026-06-20): per-dispatch cost_usd + duration_ms are ALREADY
# captured in DISPATCH_PROVENANCE (subprocess dispatches), but nothing consumes them — so the
# review/gate overhead that dominates many sessions (e.g. one session spent most of its wall-clock on
# review dispatches incl. codex 3x for a 7-file markdown task) is invisible. This is the missing
# consumer: it sums cost+duration by agent, per session and across the corpus, and flags death-march
# waste (a review agent dispatched more than once). Read-only; independent of the (broken) session-log.
#
# Usage: v-telemetry-aggregate.sh [--repo DIR] [--session SID]
set -u
REPO="."; ONLY=""
while [ $# -gt 0 ]; do case "$1" in --repo) shift; REPO="${1:-.}";; --session) shift; ONLY="${1:-}";; -h|--help) sed -n '2,15p' "$0"; exit 0;; esac; shift; done

LOGS=$(ls "$REPO"/.v/artifacts/DISPATCH_PROVENANCE_*.log "$REPO"/DISPATCH_PROVENANCE_*.log 2>/dev/null | sort -u || true)
[ -n "$LOGS" ] || { echo "no DISPATCH_PROVENANCE logs under $REPO"; exit 0; }

# Aggregate a stream of DISPATCH lines (stdin) for one session.
_agg_session(){ # $1 = sid
  awk -F'|' -v sid="$1" '
    /^DISPATCH/ {
      cost=0; dur=0; agent="";
      for(i=1;i<=NF;i++){
        if($i ~ /^cost_usd=/){split($i,kv,"="); cost=kv[2]+0}
        else if($i ~ /^duration_ms=/){split($i,kv,"="); dur=kv[2]+0}
        else if($i ~ /^agent=/){split($i,kv,"="); agent=kv[2]}
      }
      tcost+=cost; tdur+=dur; n++; acost[agent]+=cost; adur[agent]+=dur; acount[agent]++;
      if(agent ~ /codex/) codex++;
      if(acount[agent]>maxrep){maxrep=acount[agent]; maxag=agent}
    }
    END{
      if(n==0) exit 0;
      printf "session %s — $%.2f, %ds wall, %d dispatches", sid, tcost, int(tdur/1000+0.5), n;
      if(codex>1) printf "  \342\232\240 DEATH-MARCH: codex dispatched %d\303\227", codex;
      else if(maxrep>1) printf "  \342\232\240 %s re-dispatched %d\303\227", maxag, maxrep;
      printf "\n";
      for(g in acount) printf "    %-30s $%6.2f  %5ds  (%d\303\227)\n", g, acost[g], int(adur[g]/1000+0.5), acount[g];
    }'
}

# Unique SIDs (a session may have a provenance log in BOTH .v/artifacts and the repo root).
SIDS=$(for f in $LOGS; do basename "$f" | sed -E 's/^DISPATCH_PROVENANCE_//; s/\.log$//'; done | sort -u)

echo "== /v dispatch telemetry — $REPO =="
for sid in $SIDS; do
  [ -n "$ONLY" ] && [ "$sid" != "$ONLY" ] && continue
  # All logs for this sid, exact-duplicate lines removed (same dispatch can appear in both locations).
  sidlogs=$(printf '%s\n' $LOGS | grep -F "DISPATCH_PROVENANCE_${sid}.log" || true)
  # shellcheck disable=SC2086
  cat $sidlogs 2>/dev/null | sort -u | _agg_session "$sid"
done

if [ -z "$ONLY" ]; then
  echo "-- corpus --"
  # SREV-003 (review 2026-06-20): emit TOTAL and the AGENT| lines to one stream, then print TOTAL
  # FIRST, then the header, then the cost-sorted agents — the old single-sort interleaved the header
  # above TOTAL (ASCII 'b' > 'T' > '0').
  # shellcheck disable=SC2086
  _corpus=$(cat $LOGS 2>/dev/null | sort -u | awk -F'|' '
    /^DISPATCH/ {
      cost=0; dur=0; agent="";
      for(i=1;i<=NF;i++){
        if($i ~ /^cost_usd=/){split($i,kv,"="); cost=kv[2]+0}
        else if($i ~ /^duration_ms=/){split($i,kv,"="); dur=kv[2]+0}
        else if($i ~ /^agent=/){split($i,kv,"="); agent=kv[2]}
      }
      tcost+=cost; tdur+=dur; n++; acost[agent]+=cost; acount[agent]++;
    }
    END{
      printf "TOTAL: $%.2f, %ds wall, %d dispatches\n", tcost, int(tdur/1000+0.5), n;
      for(g in acost) printf "AGENT|%012.4f|%s|%d\n", acost[g], g, acount[g];
    }')
  printf '%s\n' "$_corpus" | grep '^TOTAL'
  echo "by agent (cost desc):"
  printf '%s\n' "$_corpus" | grep '^AGENT' | sort -t'|' -k2 -rn \
    | awk -F'|' '{printf "    %-30s $%6.2f  (%d\303\227)\n", $3, $2+0, $4}'
fi
