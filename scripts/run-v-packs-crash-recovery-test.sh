#!/usr/bin/env bash
# run-v-packs-crash-recovery-test.sh — BEHAVIORAL harness for orphan adoption after a crashed runner
# (2026-07-04 resilience pass).
#
# WHY: if run-v-packs itself is killed mid-run (host restart, `kill -9`, OOM), its backgrounded `claude`
# child can OUTLIVE it — bash gives no guarantee a background job gets SIGHUP when a non-interactive
# script's process dies. The single-runner LOCK already refuses a SECOND concurrent runner, but once that
# lock is reclaimed as stale (the old runner is provably dead), nothing previously stopped a fresh
# invocation from RE-LAUNCHING the same pack while the dead runner's orphaned claude session for it was
# still alive — a duplicate concurrent session on the same pack/sid. run_pack() now drops a per-pack
# pidfile ($LOG_DIR/<name>.log.pid) at launch and removes it on every normal reap path; _adopt_orphans()
# (called once at startup, after the lock is confirmed held) is the recovery step.
#
# This harness drives _adopt_orphans directly (unit-level — the realistic way to exercise crash recovery
# without actually killing a real run-v-packs process) with REAL background processes standing in for
# "orphaned claude sessions" (renamed via `exec -a claude` so the `ps -o command=` check matches, the same
# technique run-v-packs-lock-test.sh already uses for its fake LIVE holder).
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

TMP="$(mktemp -d)"
trap 'jobs -p | xargs -I{} kill -KILL {} 2>/dev/null; rm -rf "$TMP" 2>/dev/null' EXIT
mkdir -p "$TMP/repo/packs" "$TMP/repo/.runlogs" "$TMP/repo/.done" "$TMP/repo/.needs-review"
git -C "$TMP/repo" init -q 2>/dev/null || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

# shellcheck disable=SC1090
source "$RUNNER"
[ "$(type -t _adopt_orphans)" = function ] || { echo "FATAL: sourcing $RUNNER did not expose _adopt_orphans"; exit 1; }

REPO="$TMP/repo"; PACK_ABS="$REPO/packs"; LOG_DIR="$REPO/.runlogs"; DONE_DIR="$REPO/.done"; NEEDS_DIR="$REPO/.needs-review"
ARCHIVE=1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

echo "── (1) a STALE pidfile (dead pid) is silently cleaned up, no false CRASH RECOVERY noise ──"
printf '999999\n' > "$LOG_DIR/dead.log.pid"   # beyond macOS pid_max — can never be live
out="$(_adopt_orphans 2>&1)"
[ ! -f "$LOG_DIR/dead.log.pid" ] && ok "stale pidfile removed" || no "stale pidfile left behind"
printf '%s' "$out" | grep -q "CRASH RECOVERY" && no "false CRASH RECOVERY message for a dead pid" "$out" || ok "no false alarm for a dead pid"

echo "── (2) a pidfile pointing at a live NON-claude process is ignored (recycled-pid guard) ──"
sleep 30 & OTHERPID=$!
printf '%s\n' "$OTHERPID" > "$LOG_DIR/notclaude.log.pid"
out="$(_adopt_orphans 2>&1)"
[ ! -f "$LOG_DIR/notclaude.log.pid" ] && ok "pidfile for a live non-claude process removed (not treated as an orphan)" || no "non-claude pidfile left behind"
printf '%s' "$out" | grep -q "CRASH RECOVERY" && no "false CRASH RECOVERY for a non-claude live pid" "$out" || ok "no false alarm for a non-claude process"
kill -KILL "$OTHERPID" 2>/dev/null

echo "── (3) a genuine orphan (renamed 'claude', still queued pack) that finishes DURING the grace window is adopted, not killed, and disposed via _archive_finished_pack ──"
printf '/v do the orphaned thing\n\nbody\n' > "$PACK_ABS/o1.txt"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":4}\nGAUNTLET_ATTESTED: yes\n' > "$LOG_DIR/o1.log"
( exec -a claude sleep 1 ) & OPID=$!
printf '%s\n' "$OPID" > "$LOG_DIR/o1.log.pid"
out="$(V_PACK_ORPHAN_GRACE_SEC=30 _adopt_orphans 2>&1)"
printf '%s' "$out" | grep -q "CRASH RECOVERY" && ok "orphan detected and reported" || no "orphan not detected" "$out"
printf '%s' "$out" | grep -q "finished on its own" && ok "orphan observed to finish naturally (not force-killed)" || no "orphan force-killed despite finishing quickly" "$out"
[ -f "$DONE_DIR/o1.txt" ] && ok "the crashed run's finished pack was disposed (archived to .done/) instead of left to be re-run from scratch" || no "adopted-and-finished pack not archived" "$(ls "$PACK_ABS" "$DONE_DIR" "$NEEDS_DIR" 2>&1)"
[ ! -f "$LOG_DIR/o1.log.pid" ] && ok "pidfile cleaned up after adoption" || no "pidfile leaked"

echo "── (4) a genuine orphan that OUTLIVES the grace window is reaped (subtree-safe) and left for a fresh relaunch ──"
printf '/v do the stubborn orphaned thing\n\nbody\n' > "$PACK_ABS/o2.txt"
: > "$LOG_DIR/o2.log"   # no result yet — the crashed run never got this far
( exec -a claude sleep 60 ) & OPID2=$!
printf '%s\n' "$OPID2" > "$LOG_DIR/o2.log.pid"
out="$(V_PACK_ORPHAN_GRACE_SEC=2 _adopt_orphans 2>&1)"
printf '%s' "$out" | grep -q "reaping it" && ok "overstaying orphan is reaped after its grace period" || no "orphan not reaped after overstaying grace" "$out"
sleep 1
kill -0 "$OPID2" 2>/dev/null && no "reaped orphan pid is still alive" "" || ok "reaped orphan process is actually dead"
[ "$(head -1 "$LOG_DIR/o2.log.timedout" 2>/dev/null)" = wedged ] && ok "reaped orphan gets a wedged .timedout sidecar" || no "no/wrong .timedout sidecar for the reaped orphan" "$(cat "$LOG_DIR/o2.log.timedout" 2>/dev/null)"
# The sidecar makes verdict()=timeout(wedged) — _adopt_orphans disposes it through the SAME
# _archive_finished_pack path a live watchdog-reaped wedge uses: parked to .needs-review/ immediately
# (never silently re-queued for another automatic attempt, and never double-dispatched by adoption itself).
[ -f "$NEEDS_DIR/o2.txt" ] && ok "reaped orphan's pack parked to .needs-review/ (same disposal a live wedge gets)" || no "pack not parked after reap" "$(ls "$PACK_ABS" "$DONE_DIR" "$NEEDS_DIR" 2>&1)"
[ ! -f "$LOG_DIR/o2.log.pid" ] && ok "pidfile cleaned up after the reap" || no "pidfile leaked after reap"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
