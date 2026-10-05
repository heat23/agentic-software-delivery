#!/usr/bin/env bash
# p2-sid-collision-test.sh — P2 SID-collision refusal (2026-07-03, forensic N5).
#
# One terminal ran TWO /v tasks under one SID → every per-SID artifact became a 2-task hybrid →
# false-PASS log claimed a sibling task done. v-bootstrap.sh now refuses a second /v invocation
# under a SID whose previous task COMPLETED (prior invocation marker + VERIFY_DONE/QA/TRIVIAL_PASS).
#
# Executes the P2-SID-COLLISION block EXTRACTED VERBATIM from v-bootstrap.sh. Cases:
#   collision (marker + completed artifact)      → SID_COLLISION=detected + directive + durable marker
#   first invocation (no prior marker)           → silent
#   re-invocation mid-task (marker, no completion artifact) → silent (remediation re-runs are legit)
#   dial off (V_SID_COLLISION_GUARD=0)           → silent even on collision
# RED ORACLE: V_BOOTSTRAP_OVERRIDE=<pre-p2sid bak> → awk range empty → first case fails.
set -u
BOOT="${V_BOOTSTRAP_OVERRIDE:-$HOME/.claude/skills/v/references/v-bootstrap.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

BLK="$(awk '/=== P2-SID-COLLISION/,/=== end P2-SID-COLLISION/' "$BOOT")"
echo "== P2 :: SID-collision refusal at bootstrap =="
if [ -z "$BLK" ]; then
  no "P2-SID-COLLISION block present in v-bootstrap.sh" "awk range empty (pre-P2 = RED)"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "P2-SID-COLLISION block present"

SID="cccc1111-2222-3333-4444-555566667777"
run_blk() { # $1=make-marker $2=make-completion $3=guard-dial $4=case-id → echoes stdout; cwd = $WORK/$4
  local d="$WORK/$4"; mkdir -p "$d/.v/tmp"
  [ "$1" = "1" ] && date -u +%s > "$d/.v/tmp/v-invocation-start-${SID}.txt"
  [ "$2" = "1" ] && printf 'Model: haiku\nMode: scoped\nOverall Verdict: PASS\n' > "$d/VERIFY_DONE_REPORT_${SID}.md"
  (
    set +eu
    cd "$d" || exit 1
    SESSION_ID="$SID"; _SID_LC="$SID"; V_TMP_DIR="$d/.v/tmp"; V_SID_COLLISION_GUARD="$3"
    eval "$BLK"
  ) 2>/dev/null
}

out=$(run_blk 1 1 1 case1)
{ printf '%s' "$out" | grep -q '^SID_COLLISION=detected' && printf '%s' "$out" | grep -q 'CHECK BEFORE PROCEEDING'; } \
  && ok "invocation under completed SID ⇒ SID_COLLISION=detected + discriminating directive (follow-up proceeds, new task refuses)" \
  || no "collision not detected/refused" "$(printf '%s' "$out" | head -2)"
[ -f "$WORK/case1/SID_COLLISION_${SID}.md" ] \
  && ok "durable SID_COLLISION marker written (survives orchestrator ignoring stdout)" \
  || no "durable marker missing" ""

out=$(run_blk 0 1 1 case2)
[ -z "$out" ] && ok "first invocation (no prior marker) ⇒ silent" || no "false positive on first invocation" "$out"

out=$(run_blk 1 0 1 case3)
[ -z "$out" ] && ok "re-invocation mid-task (no completion artifact) ⇒ silent (remediation re-runs legit)" || no "false positive on mid-task re-run" "$out"

out=$(run_blk 1 1 0 case4)
[ -z "$out" ] && ok "V_SID_COLLISION_GUARD=0 ⇒ guard off" || no "dial did not disable" "$out"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
