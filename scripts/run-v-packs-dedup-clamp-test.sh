#!/usr/bin/env bash
# run-v-packs-dedup-clamp-test.sh — BEHAVIORAL bite-test for FND-DUP (duplicate-dispatch guard) and
# FND-CLAMP (live-session concurrency clamp), both forensic 2026-07-03; retry case per adversarial
# review F2-1/#1 (a KEPT pack's own retry must NEVER be parked as its own duplicate).
#
# WHY: a Jul-3 fleet run dispatched ONE task to ≥6 concurrent sessions
# (redundant gauntlets, 0 landings) and bootstrap saw 13 parallel /v sessions — the runner had no
# queue de-dup and only a warn-level concurrency advisory.
#
# Drives run_pass_wave() DIRECTLY (the unit under test — main() needs a full repo/drain env and its
# end-of-run phases are not under test here); the clamp is asserted via main --dry-run (read-only).
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
BAK="${RUNNER}.pre-dedup-clamp-bak"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fakebin"
# fake claude: instant NON-attested result → verdict stays non-terminal → pack is KEPT for retry
printf '#!/usr/bin/env bash\nprintf "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"num_turns\\":1}\\n"\n' > "$TMP/fakebin/claude"
chmod +x "$TMP/fakebin/claude"; export PATH="$TMP/fakebin:$PATH"
export _REAP_POLL=1

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

# Drive run_pass_wave in a fresh subshell with minimal runner globals. $1=runner $2=packdir $3=passes
drive_wave(){
  local RB="$1" P="$2" N="${3:-1}"
  bash -c '
    set -uo pipefail
    source "'"$RB"'" >/dev/null 2>&1 || true
    REPO="'"$TMP"'/repo"; PACK_DIR="'"$P"'"; PACK_ABS="'"$P"'"
    LOG_DIR="'"$P"'/.runlogs"; DONE_DIR="'"$P"'/.done"; NEEDS_DIR="'"$P"'/.needs-review"
    mkdir -p "$LOG_DIR" "$DONE_DIR" "$NEEDS_DIR" "$REPO"
    JOBS=3; ARCHIVE=1; PACK_TIMEOUT=60
    for _n in $(seq 1 '"$N"'); do echo "=== PASS $_n ==="; run_pass_wave 0; done
  ' 2>&1
}

echo "── (1) FND-DUP: identical-body pack under a DIFFERENT name is PARKED; distinct pack runs ──"
P1="$TMP/p1"; mkdir -p "$P1"
printf '/v extract the example poc into an adapter\n' > "$P1/taskA.txt"
printf '/v extract the example poc into an adapter\n' > "$P1/taskA-duplicate.txt"
printf '/v add the queue heartbeat monitor\n'     > "$P1/taskB.txt"
o="$(drive_wave "$RUNNER" "$P1" 1)"
[ "$(printf '%s\n' "$o" | grep -c 'DUPLICATE-DISPATCH')" -eq 1 ] && ok "exactly one DUPLICATE-DISPATCH park" || no "expected 1 dup park" "$(printf '%s\n' "$o" | grep -m2 'DUPLICATE\|launch')"
[ "$(printf '%s\n' "$o" | grep -c 'launch taskA')" -eq 1 ] && ok "only the first identical-body copy launched" || no "wrong taskA launch count" "$(printf '%s\n' "$o" | grep -c 'launch taskA')"
printf '%s\n' "$o" | grep -q 'launch taskB' && ok "distinct pack still launched" || no "taskB did not launch"
ls "$P1/.needs-review/" | grep -q taskA && ok "duplicate parked in .needs-review/ (recoverable)" || no "duplicate not in .needs-review/"

echo "── (2) F2-1 retry: a KEPT pack relaunches on the next pass — never parked as its own duplicate ──"
P2="$TMP/p2"; mkdir -p "$P2"
printf '/v lonely task that will be kept\n' > "$P2/taskC.txt"
o="$(drive_wave "$RUNNER" "$P2" 2)"
lc="$(printf '%s\n' "$o" | grep -c 'launch taskC')"
[ "$lc" -eq 2 ] && ok "KEPT pack relaunched on pass 2 (launches=$lc)" || no "retry broken: launches=$lc (expected 2)" "$(printf '%s\n' "$o" | grep -m2 'DUPLICATE\|kept')"
printf '%s\n' "$o" | grep -q 'DUPLICATE-DISPATCH' && no "retry falsely flagged as duplicate" || ok "no false DUPLICATE on self-retry"

echo "── (3) FND-CLAMP via main --dry-run: 6 live sessions clamp JOBS; env kill-switch works ──"
# FB-24b (2026-07-11): the clamp de-dupes by OWNING PID (one session dual-registered under both worktree
# roots must count ONCE) — so each fake lock needs its own DISTINCT live pid, not a shared $$.
P3="$TMP/repo3/packs"; mkdir -p "$P3"; git -C "$TMP/repo3" init -q
printf '/v some task\n' > "$P3/taskD.txt"
SLEEPERS=""
for n in 1 2 3 4 5 6; do
  sleep 300 & _sp=$!
  SLEEPERS="$SLEEPERS $_sp"
  mkdir -p "$TMP/repo3/.worktrees/fake-$n"
  printf 'fakesid-%s %s 1751500000\n' "$n" "$_sp" > "$TMP/repo3/.worktrees/fake-$n/.claude-session-lock"
done
o="$(bash -c "source '$RUNNER' >/dev/null 2>&1 || true; main '$P3' --dry-run" 2>&1 || true)"
printf '%s\n' "$o" | grep -q 'CONCURRENCY CLAMP' && ok "clamp fired with 6 live sessions (dry-run)" || no "no clamp message" "$(printf '%s\n' "$o" | grep -im1 concurrency)"
o="$(V_CONCURRENCY_CLAMP=0 bash -c "source '$RUNNER' >/dev/null 2>&1 || true; main '$P3' --dry-run" 2>&1 || true)"
printf '%s\n' "$o" | grep -q 'CONCURRENCY CLAMP' && no "V_CONCURRENCY_CLAMP=0 did not disable clamp" || ok "V_CONCURRENCY_CLAMP=0 restores warn-only"

echo "── (3b) FB-24b: ONE session dual-registered under BOTH worktree roots counts ONCE (no clamp) ──"
P3B="$TMP/repo3b/packs"; mkdir -p "$P3B"; git -C "$TMP/repo3b" init -q
printf '/v some task\n' > "$P3B/taskE.txt"
_keep="${SLEEPERS## }"; _keep="${_keep%% *}"   # reuse the first sleeper as the single live session
mkdir -p "$TMP/repo3b/.worktrees/fake-dual" "$TMP/claudecfg/worktrees/repo3b/fake-dual"
printf 'fakesid-dual %s 1751500000\n' "$_keep" > "$TMP/repo3b/.worktrees/fake-dual/.claude-session-lock"
printf 'fakesid-dual %s 1751500000\n' "$_keep" > "$TMP/claudecfg/worktrees/repo3b/fake-dual/.claude-session-lock"
o="$(CLAUDE_CONFIG_DIR="$TMP/claudecfg" bash -c "source '$RUNNER' >/dev/null 2>&1 || true; main '$P3B' --dry-run" 2>&1 || true)"
printf '%s\n' "$o" | grep -q 'CONCURRENCY CLAMP' && no "dual-registered single session was double-counted (clamp fired at active=1)" || ok "dual-registered session counted once (no clamp at active=1)"
kill $SLEEPERS 2>/dev/null; wait 2>/dev/null

echo "── (4) RED oracle vs pre-fix snapshot ──"
if [ -f "$BAK" ]; then
  P4="$TMP/p4"; mkdir -p "$P4"
  printf '/v extract the example poc into an adapter\n' > "$P4/taskA.txt"
  printf '/v extract the example poc into an adapter\n' > "$P4/taskA-duplicate.txt"
  o="$(drive_wave "$BAK" "$P4" 1)"
  [ "$(printf '%s\n' "$o" | grep -c 'launch taskA')" -eq 2 ] && ok "red-oracle: pre-fix runner launched BOTH identical copies" || no "red-oracle: unexpected pre-fix behavior" "$(printf '%s\n' "$o" | grep -c 'launch taskA')"
else
  echo "  WARN red-oracle snapshot missing ($BAK)"
fi

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
