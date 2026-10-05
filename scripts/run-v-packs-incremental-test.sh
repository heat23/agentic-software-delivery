#!/usr/bin/env bash
# run-v-packs-incremental-test.sh — BEHAVIORAL harness for run_pass_wave's INCREMENTAL archiving.
#
# WHY: the runner used to archive every finisher at PASS-END (after the whole wave drained), so `.done/` showed
# 0 for hours even when packs were completing, and a fast pack was held hostage by the slowest/wedged sibling.
# run_pass_wave now reaps + archives each pack THE MOMENT its run_pack job exits. This harness proves that with a
# real run_pass_wave + a fake `claude`: fast packs land in .done WHILE a hang is still running (the load-bearing
# property), each pack is disposed EXACTLY once, a partial is KEPT for re-run, and a wedged pack is parked.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

TMP="$(mktemp -d)"; trap 'pkill -f "$TMP/fakebin/claude" 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fakebin" "$TMP/repo/packs" "$TMP/repo/.runlogs" "$TMP/repo/.done" "$TMP/repo/.needs-review"
git -C "$TMP/repo" init -q 2>/dev/null || { echo "SKIP: git unavailable"; exit 0; }

# fake claude: behavior chosen from its args (the pack body is passed as an arg). hang = never returns (→ watchdog
# timeout); partial = result WITHOUT GAUNTLET_ATTESTED (→ kept); else = a clean attested result (→ done).
cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
a="$*"
case "$a" in
  *FAKE:hang*)    sleep 300 ;;
  *FAKE:partial*) printf '{"type":"result","subtype":"success","is_error":false,"num_turns":5}\nimplemented, tests started\n' ;;
  *)              printf '{"type":"result","subtype":"success","is_error":false,"num_turns":5}\nGAUNTLET_ATTESTED: yes\n' ;;
esac
EOF
chmod +x "$TMP/fakebin/claude"; export PATH="$TMP/fakebin:$PATH"

# shellcheck disable=SC1090
source "$RUNNER"
[ "$(type -t run_pass_wave)" = function ] || { echo "FATAL: sourcing $RUNNER did not expose run_pass_wave"; exit 1; }

REPO="$TMP/repo"; PACK_ABS="$REPO/packs"; LOG_DIR="$REPO/.runlogs"; DONE_DIR="$REPO/.done"; NEEDS_DIR="$REPO/.needs-review"
JOBS=3; ARCHIVE=1; CLAUDE_ARGS=( -p ); PACK_TIMEOUT=3
# V_PACK_ACTIVE_RETRY=0 (2026-07-04): with this fixture's tiny PACK_TIMEOUT and the default 300s
# V_WEDGE_IDLE_SEC, the watchdog's "active vs wedged" heuristic reads a log's mtime as "fresh" (hence
# ACTIVE) for the first few seconds after ANY launch — including a truly-silent `sleep 300` hang — simply
# because not enough wall-clock has passed for the log to look stale relative to a 300s window. That
# quirk is orthogonal to what THIS test proves (a wedged pack parks); the new active-timeout auto-retry
# grace has its own dedicated fixture (run-v-packs-active-retry-test.sh) with a V_WEDGE_IDLE_SEC scaled to
# match its short PACK_TIMEOUT, so it can actually distinguish active from wedged. Disable the grace here.
export V_PACK_TELEMETRY=0 _REAP_POLL=1 V_PACK_ACTIVE_RETRY=0   # skip telemetry side-effects; poll fast so the test is quick
printf '/v FAKE:fast a\n\nx\n'    > "$PACK_ABS/a.txt"
printf '/v FAKE:fast b\n\nx\n'    > "$PACK_ABS/b.txt"
printf '/v FAKE:hang h\n\nx\n'    > "$PACK_ABS/h.txt"
printf '/v FAKE:partial p\n\nx\n' > "$PACK_ABS/p.txt"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

run_pass_wave 0 >/dev/null 2>&1 & RPW=$!
echo "── INCREMENTAL: fast packs banked in .done WHILE the hang is still running (not held to pass-end) ──"
# Poll (don't fix-sleep) for a,b to land in .done, and capture whether the wave was STILL running at that moment
# (the hang h keeps run_pass_wave alive until PACK_TIMEOUT). Robust to scheduling jitter under a loaded sweep.
_seen=0; _midwave=0; _t=0
while [ "$_t" -lt 40 ]; do
  if [ -f "$DONE_DIR/a.txt" ] && [ -f "$DONE_DIR/b.txt" ]; then
    _seen=1; kill -0 "$RPW" 2>/dev/null && _midwave=1; break
  fi
  kill -0 "$RPW" 2>/dev/null || break   # wave ended without archiving a,b — a real failure
  sleep 0.25; _t=$((_t+1))
done
[ "$_seen" = 1 ] && ok "a,b archived during the run" || no "a,b never landed in .done" "incremental broke"
[ "$_midwave" = 1 ] && ok "…and run_pass_wave was STILL running when they did (hang keeps it alive) → mid-wave, not pass-end" || no "a,b only archived after the wave ended" "looks like pass-end archiving, not incremental"
wait "$RPW" 2>/dev/null

echo "── final outcomes ──"
{ [ -f "$DONE_DIR/a.txt" ] && [ -f "$DONE_DIR/b.txt" ]; } && ok "a,b in .done (attested)" || no "a,b final missing"
[ -f "$NEEDS_DIR/h.txt" ] && ok "wedged h → parked to .needs-review (timeout)" || no "h not parked" "needs=$(ls "$NEEDS_DIR" 2>/dev/null)"
[ -f "$PACK_ABS/p.txt" ] && ok "partial p KEPT in packs dir (re-runs next drain pass)" || no "p not kept"
{ [ ! -f "$PACK_ABS/a.txt" ] && [ ! -f "$PACK_ABS/h.txt" ]; } && ok "disposed packs moved out of the packs dir" || no "dispose incomplete"
[ "$(find "$DONE_DIR" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')" = 2 ] && ok "exactly 2 in .done (each disposed once, no double-archive)" || no "wrong .done count" "$(ls "$DONE_DIR" 2>/dev/null)"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
