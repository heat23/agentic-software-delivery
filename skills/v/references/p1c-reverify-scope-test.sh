#!/usr/bin/env bash
# p1c-reverify-scope-test.sh — P1-C iteration-2+ auto-scoping (2026-07-03).
#
# Forensic: a remediation loop dispatched 6× FULL pre-flight (+6 verify-done)
# because nothing downgraded iteration-2+ re-verifies to the already-guarded scoped lane.
# P1C-REVERIFY-SCOPE in v-run-gates.sh: PFM=full + a COMPLETED prior gate-summary for this SID
# ⇒ PFM=scoped. Exemptions that must hold: first run (no summary / incomplete summary),
# POSTMERGE_REVERIFY=1, V_REVERIFY_FULL=1.
#
# Executes the block EXTRACTED VERBATIM from the production script (same idiom as
# sessionlog-warn-gate-test.sh). RED ORACLE: V_RUN_GATES_OVERRIDE=v-run-gates.sh.pre-p1c-bak
# → awk range empty → test 1 fails (proven at ship time; see BITE_LEDGER).
set -u
SCRIPT="${V_RUN_GATES_OVERRIDE:-$HOME/.claude/skills/v/references/v-run-gates.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$SCRIPT" ] || { echo "NO v-run-gates.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

P1C="$(awk '/=== P1C-REVERIFY-SCOPE/,/=== end P1C-REVERIFY-SCOPE/' "$SCRIPT")"

echo "== P1-C :: iteration-2+ re-verify auto-scopes to the guarded scoped lane =="
if [ -z "$P1C" ]; then
  no "P1C-REVERIFY-SCOPE block present in v-run-gates.sh" "awk range empty (pre-P1C = RED)"
  echo ""; echo "TOTAL: $PASS passed, $((FAIL)) failed"; exit 1
fi
ok "P1C-REVERIFY-SCOPE block present in v-run-gates.sh"

run_p1c() { # $1=PFM $2=summary-state(none|incomplete|complete) $3=POSTMERGE $4=FORCE_FULL → echoes resulting PFM
  local d="$WORK/r$RANDOM"; mkdir -p "$d"
  case "$2" in
    complete)   printf 'TSC_RC=0\nDONE_AT=2026-07-03T00:00:00Z\n' > "$d/gate-summary-p1c-sid.txt" ;;
    incomplete) printf 'TSC_RC=0\n' > "$d/gate-summary-p1c-sid.txt" ;;
    blind)      printf 'TSC_RC=SKIP\nPREFLIGHT_BLIND=1\nDONE_AT=2026-07-03T00:00:00Z\n' > "$d/gate-summary-p1c-sid.txt" ;;
    mismatch)   printf 'TSC_RC=0\nTREE_MISMATCH=1\nDONE_AT=2026-07-03T00:00:00Z\n' > "$d/gate-summary-p1c-sid.txt" ;;
    timeout)    printf 'DETECTION_ERROR=gate_timeout_900s\nDONE_AT=2026-07-03T00:00:00Z\n' > "$d/gate-summary-p1c-sid.txt" ;;
  esac
  (
    set +eu
    PFM="$1"; V_TMP_DIR="$d"; SESSION_ID="p1c-sid"
    POSTMERGE_REVERIFY="$3"; V_REVERIFY_FULL="$4"
    eval "$P1C" 2>/dev/null
    printf '%s' "$PFM"
  )
}

[ "$(run_p1c full complete 0 0)" = "scoped" ] \
  && ok "iteration 2 (completed prior summary) + PFM=full ⇒ auto-downgraded to scoped (the repeated-full-run cost fix)" \
  || no "iteration-2 full dispatch was NOT downgraded" "PFM=$(run_p1c full complete 0 0)"

[ "$(run_p1c full none 0 0)" = "full" ] \
  && ok "first run (no prior summary) stays FULL — iteration 1 unchanged" \
  || no "first run wrongly downgraded" ""

[ "$(run_p1c full incomplete 0 0)" = "full" ] \
  && ok "crashed prior run (summary without DONE_AT) stays FULL — incomplete iteration 1 does not count" \
  || no "incomplete summary wrongly counted as iteration 1" ""

[ "$(run_p1c full complete 1 0)" = "full" ] \
  && ok "POSTMERGE_REVERIFY=1 stays FULL — combined-state verify is never scoped away" \
  || no "postmerge re-verify wrongly downgraded" ""

[ "$(run_p1c full complete 0 1)" = "full" ] \
  && ok "V_REVERIFY_FULL=1 escape hatch stays FULL" \
  || no "forced-full escape hatch broken" ""

[ "$(run_p1c scoped complete 0 0)" = "scoped" ] \
  && ok "already-scoped dispatch unchanged (no double-handling)" \
  || no "scoped dispatch mangled" ""

# Review L#2 CRITICAL + CDX-2: a prior summary that never actually evaluated the diff must NOT
# count as iteration 1 — blind (0-file scope), wrong-tree, and watchdog-timeout summaries all
# carry DONE_AT and all must stay FULL.
[ "$(run_p1c full blind 0 0)" = "full" ] \
  && ok "PREFLIGHT_BLIND=1 prior summary stays FULL (L#2: blind run is not iteration 1)" \
  || no "blind prior summary wrongly downgraded (L#2 regression)" ""
[ "$(run_p1c full mismatch 0 0)" = "full" ] \
  && ok "TREE_MISMATCH=1 prior summary stays FULL (W71-F10 class)" \
  || no "wrong-tree prior summary wrongly downgraded" ""
[ "$(run_p1c full timeout 0 0)" = "full" ] \
  && ok "DETECTION_ERROR (watchdog timeout) prior summary stays FULL (CDX-2)" \
  || no "timed-out prior summary wrongly downgraded (CDX-2 regression)" ""

# 2026-09-01 (cohort forensic): the P1C downgrade message used to END with "Force full with
# V_REVERIFY_FULL=1." — a worker read exactly that line in its pre-flight output and then set the
# flag on 3 more remediation re-dispatches (4 full suites for a small diff).
# The flag is v-merge-back's final-verify lever, not a remediation knob, and the stderr must say so
# instead of advertising it. Text-level bite: RED against the pre-fix .bak, GREEN after.
if printf '%s' "$P1C" | grep -qF 'Force full with V_REVERIFY_FULL=1'; then
  no "P1C stderr still ADVERTISES 'Force full with V_REVERIFY_FULL=1' (the nudge that produced 4 full suites in one session)" ""
else
  ok "P1C stderr no longer advertises V_REVERIFY_FULL=1 as a force-full knob"
fi
if printf '%s' "$P1C" | grep -qF 'Do NOT set V_REVERIFY_FULL=1 on a remediation-loop re-dispatch'; then
  ok "P1C stderr states the flag is reserved for v-merge-back's final verify"
else
  no "P1C stderr lacks the merge-back reservation sentence" ""
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
