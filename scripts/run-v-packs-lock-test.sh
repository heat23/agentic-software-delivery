#!/usr/bin/env bash
# run-v-packs-lock-test.sh — BEHAVIORAL harness for the single-runner (per-dir) lock.
#
# WHY: two run-v-packs on the same dir is the contention that stranded a real run for hours — they double the API
# load (hit the usage limit ~2x faster) and race the same worktrees + merge-to-main lock. The lock refuses a 2nd
# concurrent runner and reclaims a stale one. This drives the REAL main() with a fake `claude` and asserts:
# --dry-run never locks; a normal run acquires + releases; a stale (dead-pid) lock is reclaimed; a LIVE holder is
# refused AND its lock is not deleted by the refused runner.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

TMP="$(mktemp -d)"; trap 'kill "${FAKE_HOLDER:-}" 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fakebin" "$TMP/repo/packs"
git -C "$TMP/repo" init -q 2>/dev/null || { echo "SKIP: git unavailable"; exit 0; }
printf '#!/usr/bin/env bash\nprintf "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"num_turns\\":0}\\nGAUNTLET_ATTESTED: yes\\n"\n' > "$TMP/fakebin/claude"
chmod +x "$TMP/fakebin/claude"; export PATH="$TMP/fakebin:$PATH"

# shellcheck disable=SC1090
source "$RUNNER"
[ "$(type -t main)" = function ] || { echo "FATAL: sourcing $RUNNER did not expose main()"; exit 1; }

P="$TMP/repo/packs"; L="$P/.runlogs/.runlock"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

echo "── (1) --dry-run is read-only → never takes a lock ──"
( main "$P" --dry-run ) >/dev/null 2>&1
[ ! -f "$L" ] && ok "no lock created under --dry-run" || no "dry-run created a lock"

echo "── (2) a normal run acquires the lock and RELEASES it on exit (EXIT trap) ──"
( main "$P" ) >/dev/null 2>&1
[ ! -f "$L" ] && ok "lock released after the run exits" || no "lock leaked after exit"

echo "── (3) a STALE lock (holder pid is dead) is reclaimed, and the run proceeds ──"
mkdir -p "$P/.runlogs"; echo 999999 > "$L"
o=$( ( main "$P" ) 2>&1 )
echo "$o" | grep -q "reclaiming a stale lock" && ok "stale (dead-pid) lock reclaimed" || no "did not reclaim stale lock" "$(printf '%s' "$o" | tail -1)"

echo "── (4) a LIVE run-v-packs holder → the 2nd runner is REFUSED and does NOT delete the holder's lock ──"
( exec -a "run-v-packs-locktest" sleep 60 ) & FAKE_HOLDER=$!
echo "$FAKE_HOLDER" > "$L"
o=$( ( main "$P" ) 2>&1 );
echo "$o" | grep -q "already running on" && ok "2nd concurrent runner refused" || no "did not refuse a live holder" "$(printf '%s' "$o" | tail -1)"
[ "$(cat "$L" 2>/dev/null)" = "$FAKE_HOLDER" ] && ok "refused runner left the holder's lock intact (die precedes the EXIT trap)" || no "holder lock was clobbered by the refused runner"
kill "$FAKE_HOLDER" 2>/dev/null; FAKE_HOLDER=""

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
