#!/usr/bin/env bash
# item2-p1c-freshness-test.sh — P1C-REVERIFY-SCOPE invocation-freshness guard (2026-07-05).
#
# Forensic class (PFM_REQUESTED=full silently downgraded to scoped): the P1C-REVERIFY-SCOPE
# mechanism in v-run-gates.sh downgrades PFM=full -> scoped whenever a COMPLETED, non-blind,
# tree-matched prior gate-summary exists for this SID — legitimate for a genuine iteration-2+
# re-verify WITHIN the current /v invocation's remediation loop. But SIDs get reused loosely in
# this environment (resumed handoffs, re-invoked sessions); without a freshness check, a STALE
# completed gate-summary left over from an EARLIER /v invocation of the same SID would ALSO
# satisfy the downgrade conditions, silently ignoring a genuinely fresh, explicit PFM=full
# request from the caller. The fix compares the prior summary's mtime against
# v-invocation-start-<sid>.txt (rewritten unconditionally at the start of every /v invocation) —
# a summary older than THIS invocation's start marker cannot be "iteration 1 of this loop".
#
# Executes the block EXTRACTED VERBATIM from the production script (same idiom as
# p1c-reverify-scope-test.sh). RED ORACLE: point SCRIPT at a pre-item2 backup (no ITEM2 marker
# text in the P1C block) → grep for the marker fails -> test 1 fails.
set -u
SCRIPT="${V_RUN_GATES_OVERRIDE:-$HOME/.claude/skills/v/references/v-run-gates.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$SCRIPT" ] || { echo "NO v-run-gates.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

P1C="$(awk '/=== P1C-REVERIFY-SCOPE/,/=== end P1C-REVERIFY-SCOPE/' "$SCRIPT")"

echo "== ITEM2 :: P1C downgrade requires the prior summary to be fresh for THIS /v invocation =="
if [ -z "$P1C" ] || ! printf '%s' "$P1C" | grep -q 'ITEM2'; then
  no "ITEM2 freshness guard present inside P1C-REVERIFY-SCOPE" "block missing or no ITEM2 marker (pre-fix = RED)"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "ITEM2 freshness guard present inside P1C-REVERIFY-SCOPE"

run_p1c() { # $1=PFM $2=marker-state(none|older|newer) → echoes resulting PFM
  local d="$WORK/r$RANDOM"; mkdir -p "$d"
  printf 'TSC_RC=0\nDONE_AT=2026-07-05T00:00:00Z\n' > "$d/gate-summary-item2-sid.txt"
  case "$2" in
    older)
      touch -t 202601010000 "$d/gate-summary-item2-sid.txt"
      touch -t 202607050000 "$d/v-invocation-start-item2-sid.txt"
      ;;
    newer)
      touch -t 202601010000 "$d/v-invocation-start-item2-sid.txt"
      touch -t 202607050000 "$d/gate-summary-item2-sid.txt"
      ;;
    none) : ;;
  esac
  (
    set +eu
    PFM="$1"; V_TMP_DIR="$d"; SESSION_ID="item2-sid"
    POSTMERGE_REVERIFY=0; V_REVERIFY_FULL=0
    eval "$P1C" 2>/dev/null
    printf '%s' "$PFM"
  )
}

[ "$(run_p1c full newer)" = "scoped" ] \
  && ok "prior summary newer than this invocation's start marker -> genuine iteration-2, downgrade to scoped" \
  || no "same-invocation iteration-2 was NOT downgraded (regression)" "PFM=$(run_p1c full newer)"

[ "$(run_p1c full older)" = "full" ] \
  && ok "prior summary OLDER than this invocation's start marker -> stale leftover, PFM=full honored (the fix)" \
  || no "stale cross-invocation summary wrongly downgraded PFM=full to scoped" "PFM=$(run_p1c full older)"

[ "$(run_p1c full none)" = "scoped" ] \
  && ok "no invocation-start marker at all -> can't prove staleness, preserves prior (pre-item2) behavior" \
  || no "absent-marker case regressed prior behavior" "PFM=$(run_p1c full none)"

[ "$(run_p1c scoped older)" = "scoped" ] \
  && ok "already-scoped dispatch unaffected by freshness check" \
  || no "already-scoped dispatch mangled by freshness check" "PFM=$(run_p1c scoped older)"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
