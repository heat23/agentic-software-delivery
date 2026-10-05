#!/usr/bin/env bash
# run-v-packs-active-retry-test.sh — BEHAVIORAL harness for the near-completion (ACTIVE) watchdog-timeout
# auto-retry (2026-07-04 resilience pass).
#
# WHY: a session still ACTIVELY working when it blows the wall-clock ceiling (concurrent full-suite
# gauntlets routinely need more headroom than a single --timeout guess) is NOT wedged — but the pre-existing
# behavior parked it to .needs-review/ on the very first occurrence, same as a genuinely stuck/wedged
# session, forcing the operator to notice and manually re-run it. This harness proves: an ACTIVE timeout is
# now KEPT (retried) up to V_PACK_ACTIVE_RETRY times before parking; a WEDGED timeout NEVER gets the grace
# (it parks immediately, unchanged from before); V_PACK_ACTIVE_RETRY=0 restores the old strict behavior.
#
# _timeout_kind's active/wedged split reads the PACK LOG's mtime relative to V_WEDGE_IDLE_SEC at the moment
# the watchdog fires. To get a DETERMINISTIC active vs wedged distinction in a fast test, both env vars are
# scaled down together: PACK_TIMEOUT=2s, V_WEDGE_IDLE_SEC=1s. An "active" fake claude keeps re-touching its
# own log (heartbeat writes) so the log always looks fresh; a "wedged" fake claude sleeps silently so its
# log goes stale well past the 1s idle window by the time the watchdog checks (~3s after launch).
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

TMP="$(mktemp -d)"; trap 'pkill -f "$TMP/fakebin/claude" 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fakebin" "$TMP/repo/packs" "$TMP/repo/.runlogs" "$TMP/repo/.done" "$TMP/repo/.needs-review"
git -C "$TMP/repo" init -q 2>/dev/null || { echo "SKIP: git unavailable"; exit 0; }

# fake claude: FAKE_CLAUDE_MODE=active-hang keeps writing to stdout (keeps the log mtime fresh) while it
# hangs past the ceiling; FAKE_CLAUDE_MODE=wedge-hang hangs SILENTLY (no writes) so the log goes stale.
cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_CLAUDE_MODE:-fast}" in
  active-hang)
    for _i in 1 2 3 4 5 6 7 8 9 10; do echo "heartbeat $_i"; sleep 0.3; done
    sleep 300
    ;;
  wedge-hang)
    sleep 300
    ;;
  *)
    printf '{"type":"result","subtype":"success","is_error":false,"num_turns":5}\nGAUNTLET_ATTESTED: yes\n'
    ;;
esac
EOF
chmod +x "$TMP/fakebin/claude"; export PATH="$TMP/fakebin:$PATH"

# shellcheck disable=SC1090
source "$RUNNER"
[ "$(type -t run_pass_wave)" = function ] && [ "$(type -t _archive_finished_pack)" = function ] \
  || { echo "FATAL: sourcing $RUNNER did not expose run_pass_wave/_archive_finished_pack"; exit 1; }

REPO="$TMP/repo"; PACK_ABS="$REPO/packs"; LOG_DIR="$REPO/.runlogs"; DONE_DIR="$REPO/.done"; NEEDS_DIR="$REPO/.needs-review"
JOBS=1; ARCHIVE=1; CLAUDE_ARGS=( -p )
export V_PACK_TELEMETRY=0 _REAP_POLL=1 PACK_TIMEOUT=2 V_WEDGE_IDLE_SEC=1

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

echo "── (1) ACTIVE timeout is KEPT (not parked) on the first occurrence, with a retry counter ──"
printf '/v FAKE:active a\n\nx\n' > "$PACK_ABS/a.txt"
FAKE_CLAUDE_MODE=active-hang run_pass_wave 0 >/tmp/arwave1.out 2>&1
[ "$(_timeout_kind a)" = active ] && ok "fixture sanity: _timeout_kind reads 'active' for the heartbeat-writing hang" || no "fixture did not produce an ACTIVE timeout kind" "$(cat /tmp/arwave1.out)"
[ -f "$PACK_ABS/a.txt" ] && ok "pack KEPT in the queue (not parked) after first ACTIVE timeout" || no "pack was parked on first ACTIVE timeout (grace not applied)" "$(ls "$NEEDS_DIR" "$DONE_DIR" 2>&1)"
[ "$(cat "$LOG_DIR/a.log.activeretries" 2>/dev/null)" = 1 ] && ok "retry counter incremented to 1" || no "retry counter missing/wrong" "$(cat "$LOG_DIR/a.log.activeretries" 2>/dev/null)"
grep -q "Auto-retrying" /tmp/arwave1.out && ok "output announces the auto-retry" || no "no auto-retry announcement" "$(cat /tmp/arwave1.out)"

echo "── (2) a SECOND consecutive ACTIVE timeout (default V_PACK_ACTIVE_RETRY=1) exhausts the grace → parked ──"
FAKE_CLAUDE_MODE=active-hang run_pass_wave 0 >/tmp/arwave2.out 2>&1
[ -f "$NEEDS_DIR/a.txt" ] && ok "pack parked to .needs-review/ after retries exhausted" || no "pack not parked after exhausting grace" "$(ls "$PACK_ABS" "$DONE_DIR" "$NEEDS_DIR" 2>&1)"
[ ! -f "$LOG_DIR/a.log.activeretries" ] && ok "retry counter cleaned up on final park" || no "retry counter leaked" ""
grep -q "auto-retries exhausted" /tmp/arwave2.out && ok "output says retries were exhausted" || no "no exhaustion message" "$(cat /tmp/arwave2.out)"

echo "── (3) WEDGED timeout NEVER gets the grace — parks immediately, unchanged from before ──"
printf '/v FAKE:wedge w\n\nx\n' > "$PACK_ABS/w.txt"
FAKE_CLAUDE_MODE=wedge-hang run_pass_wave 0 >/tmp/wrwave1.out 2>&1
[ "$(_timeout_kind w)" = wedged ] && ok "fixture sanity: _timeout_kind reads 'wedged' for the silent hang" || no "fixture did not produce a WEDGED timeout kind" "$(cat /tmp/wrwave1.out)"
[ -f "$NEEDS_DIR/w.txt" ] && ok "WEDGED pack parked on the FIRST occurrence (no grace)" || no "wedged pack was kept/retried (should never happen)" "$(ls "$PACK_ABS" "$DONE_DIR" "$NEEDS_DIR" 2>&1)"
[ ! -f "$LOG_DIR/w.log.activeretries" ] && ok "no retry counter created for a wedged park" || no "retry counter wrongly created for wedged" ""

echo "── (4) V_PACK_ACTIVE_RETRY=0 restores strict (immediate park) behavior for an ACTIVE timeout ──"
printf '/v FAKE:active a2\n\nx\n' > "$PACK_ABS/a2.txt"
FAKE_CLAUDE_MODE=active-hang V_PACK_ACTIVE_RETRY=0 run_pass_wave 0 >/tmp/arwave3.out 2>&1
[ -f "$NEEDS_DIR/a2.txt" ] && ok "V_PACK_ACTIVE_RETRY=0 parks an ACTIVE timeout immediately" || no "grace still applied despite V_PACK_ACTIVE_RETRY=0" "$(ls "$PACK_ABS" "$DONE_DIR" "$NEEDS_DIR" 2>&1)"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
