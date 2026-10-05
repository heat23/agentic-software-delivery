#!/usr/bin/env bash
# run-v-packs-watchdog-test.sh — BEHAVIORAL harness for the per-pack timeout watchdog (run_pack + _watchdog).
#
# WHY (not just the contract test's sidecar-read bites): the real failure this guards is a WEDGED headless /v
# session (failed subagent dispatch it keeps polling, rate-limit stall, interactive wait that never fires under
# -p) holding its parallel -jN slot FOREVER and starving the whole run (observed live: packs at 0 turns for ~1h).
# The contract test only proves verdict() READS the .timedout sidecar; THIS harness drives the REAL run_pack with
# a fake `claude` and asserts the end-to-end behavior: a stuck session is killed + parked, a HEALTHY one (incl.
# one finishing at the ceiling boundary) is NOT — the grace re-check must not false-park a slow-but-finishing pack.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

TMP="$(mktemp -d)"; trap 'pkill -f "$TMP/fakebin/claude" 2>/dev/null; [ -f "$TMP/childpid" ] && kill -KILL "$(cat "$TMP/childpid" 2>/dev/null)" 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fakebin" "$TMP/repo/packs" "$TMP/repo/.runlogs"
git -C "$TMP/repo" init -q 2>/dev/null || { echo "SKIP: git unavailable"; exit 0; }

# fake claude: optional pre-sleep (to land near/over a ceiling), then fast (write a clean result) or hang. In
# hang mode it spawns a child "subagent" and records its PID to FAKE_CHILD_PIDFILE so the orphan check is HERMETIC
# (verifies THIS child by pid, never a system-wide `pgrep sleep` that could hit another concurrent harness).
cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_CLAUDE_SLEEP:-}" ] && sleep "$FAKE_CLAUDE_SLEEP"
if [ "${FAKE_CLAUDE_MODE:-fast}" = hang ]; then
  sleep 300 & _c=$!; [ -n "${FAKE_CHILD_PIDFILE:-}" ] && echo "$_c" > "$FAKE_CHILD_PIDFILE"; wait "$_c"
else
  printf '{"type":"result","subtype":"success","is_error":false,"num_turns":5}\nGAUNTLET_ATTESTED: yes\n'
fi
EOF
chmod +x "$TMP/fakebin/claude"
export PATH="$TMP/fakebin:$PATH" FAKE_CHILD_PIDFILE="$TMP/childpid"

# shellcheck disable=SC1090
source "$RUNNER"
[ "$(type -t run_pack)" = function ] && [ "$(type -t _watchdog)" = function ] || { echo "FATAL: sourcing $RUNNER did not expose run_pack/_watchdog"; exit 1; }

REPO="$TMP/repo"; PACK_ABS="$REPO/packs"; LOG_DIR="$REPO/.runlogs"; CLAUDE_ARGS=( -p )
printf '/v do a thing\n\nbody\n' > "$PACK_ABS/a.txt"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

echo "── (1) HEALTHY fast pack → verdict=done, NO sidecar (watchdog never fires) ──"
FAKE_CLAUDE_MODE=fast PACK_TIMEOUT=60 run_pack "$PACK_ABS/a.txt"
[ ! -f "$LOG_DIR/a.log.timedout" ] && ok "no .timedout sidecar on a healthy pack" || no "healthy pack got a false sidecar"
[ "$(verdict a)" = done ] && ok "healthy verdict=done" || no "healthy verdict wrong" "$(verdict a)"

echo "── (2) WEDGED pack (hangs) past ceiling → killed + sidecar → verdict=timeout, no orphan ──"
rm -f "$TMP/childpid"
FAKE_CLAUDE_MODE=hang PACK_TIMEOUT=1 run_pack "$PACK_ABS/a.txt"
[ -f "$LOG_DIR/a.log.timedout" ] && ok "wedged pack got the .timedout sidecar" || no "no sidecar on a wedged pack"
[ "$(verdict a)" = timeout ] && ok "wedged verdict=timeout" || no "wedged verdict wrong" "$(verdict a)"
# HERMETIC orphan check: the recorded "subagent" pid must be dead (watchdog's pkill -P reaped the subtree).
_child="$(cat "$TMP/childpid" 2>/dev/null || true)"
if [ -n "$_child" ] && kill -0 "$_child" 2>/dev/null; then
  no "the subagent (pid $_child) survived the timeout-kill" "pkill -P did not reap the subtree"; kill -KILL "$_child" 2>/dev/null
else ok "no orphaned subagent after the timeout-kill (pkill -P reaped the recorded child pid)"; fi

echo "── (3) BOUNDARY: pack finishes ~just after the ceiling → cancelled at finish, NO false timeout ──"
# ceiling 1s, claude finishes at 1.3s: run_pack's wait reaps it → its kill of the watchdog + the grace re-check
# both prevent a false sidecar. This is the CRITICAL race the reviewer flagged.
FAKE_CLAUDE_SLEEP=1.3 FAKE_CLAUDE_MODE=fast PACK_TIMEOUT=1 run_pack "$PACK_ABS/a.txt"
[ ! -f "$LOG_DIR/a.log.timedout" ] && ok "ceiling-adjacent finish → NO false timeout sidecar" || no "boundary finish false-parked" "grace re-check failed"
[ "$(verdict a)" = done ] && ok "ceiling-adjacent finish verdict=done (real verdict stands)" || no "boundary verdict wrong" "$(verdict a)"

echo "── (4) re-run a previously-timed-out pack → launch clears the stale sidecar (recovers) ──"
: > "$LOG_DIR/a.log.timedout"   # simulate a leftover from a prior timed-out pass
FAKE_CLAUDE_MODE=fast PACK_TIMEOUT=60 run_pack "$PACK_ABS/a.txt"
[ ! -f "$LOG_DIR/a.log.timedout" ] && ok "run_pack cleared the stale sidecar at launch" || no "stale sidecar not cleared → false timeout on re-run"
[ "$(verdict a)" = done ] && ok "re-run verdict=done (recovered)" || no "re-run verdict wrong" "$(verdict a)"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
