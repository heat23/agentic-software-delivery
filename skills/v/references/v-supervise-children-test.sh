#!/usr/bin/env bash
# Regression tests for v-supervise-children.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SUPERVISOR="$SCRIPT_DIR/v-supervise-children.sh"

PASS=0
FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

BASE="$(mktemp -d /tmp/v-supervise.XXXXXX)"
trap 'rm -rf "$BASE" 2>/dev/null' EXIT

write_cmd() {
  local path="$1" body="$2"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    printf '%s\n' "$body"
  } > "$path"
}

echo "=== S1: one failed child does not erase sibling artifact ==="
SUCCESS_CMD="$BASE/success.sh"
FAIL_CMD="$BASE/fail.sh"
SUCCESS_ART="$BASE/PRE_FLIGHT_REPORT_success.md"
FAIL_ART="$BASE/PRE_FLIGHT_REPORT_fail.md"
SUMMARY="$BASE/s1.summary"
write_cmd "$SUCCESS_CMD" "printf 'Model: haiku\n\n## Gates\n\nOverall Status: PASS\n' > '$SUCCESS_ART'"
write_cmd "$FAIL_CMD" "echo 'permanent failure' >&2; exit 42"

bash "$SUPERVISOR" \
  --summary "$SUMMARY" \
  --retry-transient none \
  --fallback-artifacts enabled \
  --child "success::30::$SUCCESS_ART::$SUCCESS_CMD" \
  --child "fail::30::$FAIL_ART::$FAIL_CMD" >/tmp/v-supervise-s1.out 2>&1
RC=$?

[ "$RC" -ne 0 ] && ok "supervisor returns non-zero when a child fails" || no "S1: supervisor returned zero despite failed child"
grep -q 'Overall Status: PASS' "$SUCCESS_ART" && ok "successful sibling artifact preserved" || no "S1: successful artifact missing"
grep -q 'Overall Status: FAIL' "$FAIL_ART" && grep -q 'supervised child exited 42' "$FAIL_ART" \
  && ok "failed child receives loud fallback pre-flight artifact" || no "S1: fallback pre-flight artifact missing/weak"
grep -q 'CHILD|name=success' "$SUMMARY" && grep -q 'CHILD|name=fail' "$SUMMARY" \
  && ok "summary records both children" || no "S1: summary missing child records"

echo "=== S2: transient failure retries once and passes ==="
RETRY_CMD="$BASE/retry.sh"
RETRY_ART="$BASE/AGENT_REVIEW_retry.md"
RETRY_SUMMARY="$BASE/s2.summary"
COUNTER="$BASE/retry.count"
write_cmd "$RETRY_CMD" "n=\$(cat '$COUNTER' 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > '$COUNTER'; if [ \"\$n\" -eq 1 ]; then echo 'temporary timeout' >&2; exit 124; fi; printf 'Model: haiku\n\n## Agent Review\n- Status: pass\n' > '$RETRY_ART'"

bash "$SUPERVISOR" \
  --summary "$RETRY_SUMMARY" \
  --retry-transient once \
  --fallback-artifacts enabled \
  --child "review::30::$RETRY_ART::$RETRY_CMD" >/tmp/v-supervise-s2.out 2>&1
RC=$?

[ "$RC" -eq 0 ] && ok "transient retry recovers to success" || no "S2: transient retry did not recover"
grep -q 'CHILD_RETRY|name=review|first_exit=124|second_exit=0' "$RETRY_SUMMARY" \
  && ok "retry is recorded in summary" || no "S2: retry record missing"
grep -q 'Status: pass' "$RETRY_ART" && ok "retry-produced artifact retained" || no "S2: retry artifact missing"

echo "=== S3: malformed timeout is rejected instead of silently disabling timeout ==="
BAD_TIMEOUT_CMD="$BASE/bad-timeout.sh"
BAD_TIMEOUT_ART="$BASE/PRE_FLIGHT_REPORT_bad_timeout.md"
BAD_TIMEOUT_SUMMARY="$BASE/s3.summary"
write_cmd "$BAD_TIMEOUT_CMD" "printf 'Model: haiku\n\n## Gates\n\nOverall Status: PASS\n' > '$BAD_TIMEOUT_ART'"

bash "$SUPERVISOR" \
  --summary "$BAD_TIMEOUT_SUMMARY" \
  --retry-transient none \
  --fallback-artifacts enabled \
  --child "bad::not-a-number::$BAD_TIMEOUT_ART::$BAD_TIMEOUT_CMD" >/tmp/v-supervise-s3.out 2>&1
RC=$?

[ "$RC" -ne 0 ] && ok "invalid timeout makes supervisor fail closed" || no "S3: invalid timeout did not fail closed"
grep -q 'status=invalid_timeout' "$BAD_TIMEOUT_SUMMARY" \
  && ok "invalid timeout is explicit in summary" || no "S3: invalid timeout summary missing"

echo "=== S4: timeout kills the whole subtree — no orphaned grandchild (Blocker 1) ==="
ORPHAN_CMD="$BASE/orphan.sh"
ORPHAN_ART="$BASE/PRE_FLIGHT_REPORT_orphan.md"
ORPHAN_SUMMARY="$BASE/s4.summary"
ORPHAN_TAG="V_SUP_TEST_ORPHAN_$$"
# Child spawns a long-lived grandchild (the shape of `claude -p` / pest under the
# dispatch helper) and waits on it. A bare `kill $pid` on the wrapper would orphan it.
write_cmd "$ORPHAN_CMD" "( exec -a $ORPHAN_TAG sleep 45 ) & wait"
bash "$SUPERVISOR" \
  --summary "$ORPHAN_SUMMARY" \
  --retry-transient none \
  --fallback-artifacts enabled \
  --child "orphan::2::$ORPHAN_ART::$ORPHAN_CMD" >/tmp/v-supervise-s4.out 2>&1
RC=$?
sleep 1
LEAK="$(ps -A -o pid,command 2>/dev/null | grep "$ORPHAN_TAG" | grep -v grep)"
if [ -n "$LEAK" ]; then
  no "S4: timeout LEAKED an orphan grandchild: $LEAK"
  echo "$LEAK" | awk '{print $1}' | while read -r p; do kill -9 "$p" 2>/dev/null; done
else
  ok "timeout reaps the whole subtree (no orphaned grandchild)"
fi
grep -q 'SUPERVISOR_TIMEOUT after 2s' "${ORPHAN_SUMMARY}.orphan.log" && ok "timeout recorded in child log" || no "S4: timeout not recorded"
[ "$RC" -ne 0 ] && ok "supervisor fails closed on a timed-out child" || no "S4: supervisor returned zero on timeout"

echo "=== S5: deterministic FAIL mentioning 503/connection-reset is NOT retried (Blocker 2) ==="
DET_CMD="$BASE/det-fail.sh"
DET_ART="$BASE/PRE_FLIGHT_REPORT_det.md"
DET_SUMMARY="$BASE/s5.summary"
DET_COUNT="$BASE/det.count"
# Exits 1 (deterministic) and prints transient-sounding words in WORKLOAD output.
# The old log-grep heuristic retried this; the sentinel-only logic must not.
write_cmd "$DET_CMD" "n=\$(cat '$DET_COUNT' 2>/dev/null || echo 0); echo \$((n+1)) > '$DET_COUNT'; echo \"FAIL it('handles connection reset') expected 200 got 503 timeout\"; exit 1"
bash "$SUPERVISOR" \
  --summary "$DET_SUMMARY" \
  --retry-transient once \
  --fallback-artifacts enabled \
  --child "preflight::30::$DET_ART::$DET_CMD" >/tmp/v-supervise-s5.out 2>&1
[ "$(cat "$DET_COUNT")" = "1" ] && ok "deterministic fail ran exactly once (no spurious retry)" || no "S5: deterministic fail was retried ($(cat "$DET_COUNT") runs)"
! grep -q 'CHILD_RETRY' "$DET_SUMMARY" && ok "no CHILD_RETRY recorded for deterministic fail" || no "S5: CHILD_RETRY fired on deterministic fail"

echo "=== S6: EX_TEMPFAIL (rc=75) transient DOES retry ==="
SENT_CMD="$BASE/sentinel.sh"
SENT_ART="$BASE/PRE_FLIGHT_REPORT_sent.md"
SENT_SUMMARY="$BASE/s6.summary"
SENT_COUNT="$BASE/sent.count"
# First run exits 75 (the dispatch helper's unforgeable transient code); second succeeds.
write_cmd "$SENT_CMD" "n=\$(cat '$SENT_COUNT' 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > '$SENT_COUNT'; if [ \"\$n\" -eq 1 ]; then echo 'DISPATCH_TRANSIENT=1'; exit 75; fi; printf 'Model: haiku\n\n## Gates\n\nOverall Status: PASS\n' > '$SENT_ART'"
bash "$SUPERVISOR" \
  --summary "$SENT_SUMMARY" \
  --retry-transient once \
  --fallback-artifacts enabled \
  --child "preflight::30::$SENT_ART::$SENT_CMD" >/tmp/v-supervise-s6.out 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "rc=75 transient recovers on retry" || no "S6: rc=75 transient did not recover"
[ "$(cat "$SENT_COUNT")" = "2" ] && ok "rc=75 transient retried exactly once" || no "S6: rc=75 retry count = $(cat "$SENT_COUNT")"

echo "=== S8: workload that PRINTS DISPATCH_TRANSIENT=1 but exits non-75 is NOT retried (forge closed — codex MEDIUM-1) ==="
FORGE_CMD="$BASE/forge.sh"
FORGE_ART="$BASE/PRE_FLIGHT_REPORT_forge.md"
FORGE_SUMMARY="$BASE/s8.summary"
FORGE_COUNT="$BASE/forge.count"
# Hostile workload echoes the literal sentinel on its own stdout, then fails
# deterministically (exit 1). The old log-grep logic would have retried; the
# exit-code logic must not.
write_cmd "$FORGE_CMD" "n=\$(cat '$FORGE_COUNT' 2>/dev/null || echo 0); echo \$((n+1)) > '$FORGE_COUNT'; echo 'DISPATCH_TRANSIENT=1'; echo 'FAIL'; exit 1"
bash "$SUPERVISOR" \
  --summary "$FORGE_SUMMARY" \
  --retry-transient once \
  --fallback-artifacts enabled \
  --child "preflight::30::$FORGE_ART::$FORGE_CMD" >/tmp/v-supervise-s8.out 2>&1
[ "$(cat "$FORGE_COUNT")" = "1" ] && ok "forged stdout sentinel did NOT trigger a retry" || no "S8: forged sentinel was retried ($(cat "$FORGE_COUNT") runs)"
! grep -q 'CHILD_RETRY' "$FORGE_SUMMARY" && ok "no CHILD_RETRY for forged sentinel" || no "S8: CHILD_RETRY fired on forged sentinel"

echo "=== S7: --max-concurrency caps simultaneous children (race-free interval measure) ==="
# Each child writes its OWN start/end epoch to a private file (no shared-counter
# race). Peak concurrency = max number of [start,end] intervals covering any
# start point. A control run with NO cap proves the measure can actually SEE
# concurrency, so the capped run's low peak isn't a false pass from serialization.
peak_overlap() {  # args: dir of "*.iv" files each containing "START END"
  awk '
    FNR==1 { s[NR]=$1; e[NR]=$2; n=NR }
    END {
      max=0
      for (i=1;i<=n;i++) { c=0; for (j=1;j<=n;j++) if (s[j]<=s[i] && s[i]<e[j]) c++; if (c>max) max=c }
      print max
    }' "$1"/*.iv 2>/dev/null
}
mk_iv_cmd() {  # path, iv_file
  write_cmd "$1" "echo \"\$(date +%s) \$(( \$(date +%s) + 2 ))\" > '$2'; sleep 2"
}

# Control: no cap, 5 children → expect peak >= 3 (proves measurement sees concurrency).
CTRL_DIR="$BASE/ctrl.iv.d"; mkdir -p "$CTRL_DIR"
CTRL_ARGS=()
for i in 1 2 3 4 5; do
  c="$BASE/ctrl-$i.sh"; mk_iv_cmd "$c" "$CTRL_DIR/$i.iv"
  CTRL_ARGS+=(--child "c$i::30::$BASE/CTRL_$i.md::$c")
done
bash "$SUPERVISOR" --summary "$BASE/s7ctrl.summary" --retry-transient none --fallback-artifacts disabled \
  "${CTRL_ARGS[@]}" >/tmp/v-supervise-s7ctrl.out 2>&1
CTRL_PEAK="$(peak_overlap "$CTRL_DIR")"
[ "${CTRL_PEAK:-0}" -ge 3 ] 2>/dev/null && ok "control (no cap) reaches peak $CTRL_PEAK (measure detects concurrency)" || no "S7: control peak only ${CTRL_PEAK:-0} — measure can't see concurrency, cap test would be meaningless"

# Capped: --max-concurrency 2, 5 children → peak must be <= 2.
CAP_DIR="$BASE/cap.iv.d"; mkdir -p "$CAP_DIR"
CAP_ARGS=()
for i in 1 2 3 4 5; do
  c="$BASE/cap-$i.sh"; mk_iv_cmd "$c" "$CAP_DIR/$i.iv"
  CAP_ARGS+=(--child "c$i::30::$BASE/CAP_$i.md::$c")
done
bash "$SUPERVISOR" --summary "$BASE/s7cap.summary" --retry-transient none --fallback-artifacts disabled \
  --max-concurrency 2 "${CAP_ARGS[@]}" >/tmp/v-supervise-s7cap.out 2>&1
CAP_PEAK="$(peak_overlap "$CAP_DIR")"
{ [ "${CAP_PEAK:-9}" -le 2 ] 2>/dev/null && [ "${CAP_PEAK:-0}" -ge 1 ] 2>/dev/null; } \
  && ok "capped run peak $CAP_PEAK respects --max-concurrency 2 (vs uncapped $CTRL_PEAK)" \
  || no "S7: capped peak was ${CAP_PEAK:-?} (cap=2)"

echo
echo "═══════════ RESULT: $PASS passed, $FAIL failed ═══════════"
[ "$FAIL" -eq 0 ]
