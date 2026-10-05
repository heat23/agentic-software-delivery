#!/usr/bin/env bash
# v-batch-health.sh — read-only one-glance health for a WINDOW of /v sessions (telemetry-plan 2026-06-26: T-C,
# folding in T-B block-churn, T-D lifecycle, T-E overclaim-trend). Replaces the by-hand reconstruction of
# "N sessions | logged/INVALID/deferred/silent | burn | turns" done after every batch.
#
# Composes existing signals — discovers /v sessions from the /v-SCOPED bootstrap-<sid>.env (NOT the every-session
# session-start, per RC-1/SREV-001), windows on LAST-ACTIVITY (transcript mtime, so a long session started before
# the window still counts), then for each SID reads: the SESSION_LOG_* markers (log-status + lifecycle),
# v-extract-tokens.py (fork-aware turns + cache_read), a transcript grep (Stop-block churn), and the INVALID
# marker reason (dispatch_path/independence over-claim trend). Read-only; never writes.
#
# Usage: v-batch-health.sh [--repo DIR] [--since-hours H] [--active-min M]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VEXT="$HERE/../../v-session-log/references/v-extract-tokens.py"
REPO="$HOME/dev/project-a"; SINCE=24; ACTIVE_MIN=5
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        REPO="$2"; shift 2 ;;
    --since-hours) SINCE="$2"; shift 2 ;;
    --active-min)  ACTIVE_MIN="$2"; shift 2 ;;
    *) shift ;;
  esac
done
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TD="$CFG/projects/$(printf '%s' "$REPO" | sed 's#/#-#g')"
_UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
_mtime(){ stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
_int(){ local v; v=$(printf '%s' "${1:-0}" | grep -oE '^[0-9]+' | head -1); printf '%s' "${v:-0}"; }  # SREV-004: leading digits only (a float "3.0" must not become "30")
# logic-review LOW: sanitize the CLI numerics so a non-numeric --since-hours/--active-min can't crash the
# arithmetic under set -u (fall back to the defaults).
SINCE=$(_int "$SINCE"); [ "$SINCE" -gt 0 ] 2>/dev/null || SINCE=24
ACTIVE_MIN=$(_int "$ACTIVE_MIN"); [ "$ACTIVE_MIN" -gt 0 ] 2>/dev/null || ACTIVE_MIN=5
now=$(date +%s); cutoff=$(( now - SINCE*3600 ))
have_py=0; command -v python3 >/dev/null 2>&1 && have_py=1

echo "════════════ /v BATCH HEALTH — repo=$(basename "$REPO") · last ${SINCE}h ════════════"
[ -d "$REPO/.v" ] || { echo "  (no .v/ in $REPO — wrong repo?)"; exit 0; }

# discover the window's SIDs from the /v-scoped bootstrap witnesses; window on LAST-ACTIVITY (transcript mtime),
# falling back to the bootstrap mtime when the transcript is gone. Dedup by full UUID.
_seen=""; SIDS=""
for bf in "$REPO"/.v/tmp/bootstrap-*.env "$REPO"/.v/artifacts/bootstrap-*.env; do
  [ -f "$bf" ] || continue
  sid="$(basename "$bf" | sed -e 's/^bootstrap-//' | grep -oiE "^${_UUID_RE}" | head -1)"
  [ -n "$sid" ] || continue
  case " $_seen " in *" $sid "*) continue ;; esac
  tf="$(ls "$TD/$sid".jsonl 2>/dev/null | head -1)"
  if [ -n "$tf" ]; then act=$(_mtime "$tf"); else act=$(_mtime "$bf"); fi
  [ "$act" -ge "$cutoff" ] || continue
  _seen="$_seen $sid"; SIDS="$SIDS $sid"
done
[ -n "$SIDS" ] || { echo "  no /v sessions (bootstrap.env, active in window) found"; exit 0; }

n=0; logged=0; invalid=0; failed=0; deferred=0; missing=0; active=0; nolog=0; overclaim=0
tot_cr=0; tot_turns=0; tot_blocks=0; tot_active=0
printf '  %-8s  %-9s  %5s  %6s  %4s  %8s  %6s  %s\n' "SID" "STATUS" "wall" "turns" "blk" "cache_rd" "cr/trn" "note"
printf '  %-8s  %-9s  %5s  %6s  %4s  %8s  %6s  %s\n' "--------" "---------" "-----" "-----" "----" "--------" "------" "----"
for sid in $SIDS; do
  n=$((n+1)); s8="${sid:0:8}"; note=""
  # --- log-status + lifecycle (T-D) ---
  # SREV-003: these are OR conditions — `ls A B` exits 0 only if BOTH exist (AND), which misclassified a
  # session carrying just one of the pair. Use explicit [ -f ]||[ -f ] (exact paths) / [ -n "$(ls ...)" ] (globs).
  if   [ -f "$REPO/SESSION_LOG_${sid}.yaml" ]; then status="LOGGED"; logged=$((logged+1))
  elif [ -f "$REPO/SESSION_LOG_${sid}.yaml.invalid" ] || [ -f "$REPO/SESSION_LOG_INVALID_${sid}.md" ]; then
       status="INVALID"; invalid=$((invalid+1))
       if grep -qiE "over-claim|dispatch_path|independen|W22-CC1" "$REPO"/SESSION_LOG_INVALID_"$sid".md 2>/dev/null; then
         overclaim=$((overclaim+1)); note="over-claim"; fi   # T-E
  elif [ -f "$REPO/SESSION_LOG_FAILED_${sid}.md" ]; then status="FAILED"; failed=$((failed+1))
  elif [ -n "$(ls "$REPO"/HANDOFF_"$sid"*.md "$REPO"/MERGE_DEFERRED_"$sid"*.md "$REPO"/WORKTREE_HANDOFF*"$sid"*.md 2>/dev/null)" ]; then
       status="DEFERRED"; deferred=$((deferred+1)); note="owes-log"
  elif [ -f "$REPO/SESSION_LOG_MISSING_${sid}.md" ]; then status="MISSING"; missing=$((missing+1))
  else
    tf="$(ls "$TD/$sid".jsonl 2>/dev/null | head -1)"
    if [ -n "$tf" ] && [ "$(( now - $(_mtime "$tf") ))" -lt "$(( ACTIVE_MIN*60 ))" ]; then
      status="ACTIVE"; active=$((active+1))            # transcript just written -> still in flight
    else status="NO-LOG"; nolog=$((nolog+1)); note="silent?"; fi   # idle, no terminal marker -> owes a log (T3 backstops at 6h)
  fi
  # --- burn + turns (fork-aware, T-A's source) ---
  cr=0; turns=0
  if [ "$have_py" = 1 ] && [ -f "$VEXT" ]; then
    to="$(python3 "$VEXT" "$sid" "$CFG" 2>/dev/null || true)"
    cr=$(printf '%s\n' "$to"    | sed -nE 's/^SET token_cost\.cache_read_tokens:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    turns=$(printf '%s\n' "$to" | sed -nE 's/^SET token_cost\.turns:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  fi
  cr=$(_int "$cr"); turns=$(_int "$turns")
  # --- Stop-block churn (T-B): COMPLETION BLOCKED feedback events in the transcript ---
  blocks=0; tf="$(ls "$TD/$sid".jsonl 2>/dev/null | head -1)"
  [ -n "$tf" ] && blocks=$(_int "$(grep -c "COMPLETION BLOCKED" "$tf" 2>/dev/null)")
  # --- ACTIVE wall-clock (the felt "this took N min"): summed inter-turn gaps over the session tree (parent +
  #     subagents), idle gaps (>120s = stepped away) dropped. Wall-clock ~= turns x model+tool latency, so the
  #     real lever is TURN count (block->remediate churn + work), NOT a per-turn speedup.
  wall=0
  if [ "$have_py" = 1 ]; then
    wall=$(python3 - "$TD" "$sid" <<'PY' 2>/dev/null || echo 0
import sys,json,glob,os,datetime
td,sid=sys.argv[1],sys.argv[2]
full=None
for p in sorted(glob.glob(os.path.join(td, sid+"*.jsonl"))):
    full=os.path.basename(p)[:-6]; break
if not full: print(0); raise SystemExit
files=[os.path.join(td,full+".jsonl")]+glob.glob(os.path.join(td,full,"subagents","**","*.jsonl"),recursive=True)
def ep(ts):
    try: return datetime.datetime.fromisoformat(str(ts).replace("Z","+00:00")).timestamp()
    except: return None
tss=[]
for fp in files:
    if not os.path.exists(fp): continue
    for line in open(fp,errors="replace"):
        try: o=json.loads(line)
        except: continue
        t=ep(o.get("timestamp")) if o.get("timestamp") else None
        if t is not None: tss.append(t)
tss.sort(); a=0.0
for i in range(1,len(tss)):
    g=tss[i]-tss[i-1]
    if 0<g<=120: a+=g
print(int(a/60))
PY
)
  fi
  wall=$(_int "$wall")
  tot_cr=$(( tot_cr + cr )); tot_turns=$(( tot_turns + turns )); tot_blocks=$(( tot_blocks + blocks )); tot_active=$(( tot_active + wall ))
  crpt=0; [ "$turns" -gt 0 ] && crpt=$(( cr / turns ))
  crM=$(awk -v x="$cr" 'BEGIN{printf "%.1f", x/1000000}')
  printf '  %-8s  %-9s  %4dm  %6d  %4d  %7sM  %5dK  %s\n' "$s8" "$status" "$wall" "$turns" "$blocks" "$crM" "$(( crpt/1000 ))" "$note"
done

echo "  ----------------------------------------------------------------------"
echo "  SESSIONS: $n  |  LOGGED $logged · INVALID $invalid · FAILED $failed · DEFERRED $deferred · MISSING $missing · ACTIVE $active · NO-LOG $nolog"
[ "$nolog"     -gt 0 ] && echo "  ⚠ SILENT-HOLE CANDIDATES (NO-LOG, idle): $nolog — run /v-session-log or wait for the 6h T3 sweep"
[ "$overclaim" -gt 0 ] && echo "  ⚠ DISPATCH_PATH OVER-CLAIMS (T-E): $overclaim of $invalid INVALID — review-independence honesty drift"
avg_turns=0; [ "$n" -gt 0 ] && avg_turns=$(( tot_turns / n ))
avg_crpt=0; [ "$tot_turns" -gt 0 ] && avg_crpt=$(( tot_cr / tot_turns ))
avg_wall=0; [ "$n" -gt 0 ] && avg_wall=$(( tot_active / n ))
totM=$(awk -v x="$tot_cr" 'BEGIN{printf "%.0f", x/1000000}')
printf '  WALL: %dm active total · avg %dm/session · avg %d turns/session · %d Stop-blocks (the churn lever)\n' \
  "$tot_active" "$avg_wall" "$avg_turns" "$tot_blocks"
printf '  BURN: %sM cache_read total · avg %dK cache_read/turn\n' "$totM" "$(( avg_crpt/1000 ))"
echo "  (wall = active minutes, idle gaps dropped; wall ≈ turns × latency → the lever is FEWER TURNS: churn fixes + the already-scoped gauntlet. fork-aware via v-extract-tokens.)"
