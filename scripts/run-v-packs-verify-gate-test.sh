#!/usr/bin/env bash
# run-v-packs-verify-gate-test.sh — regression guard for the VERIFY-GATE BACKSTOP in _run_verify_pack.
#
# WHY (2026-07-07 forensic, a v-bug-hunt batch): the final 99-* verify pack's `/v` session runs
# headless under `claude -p`. When it dispatches its gates/bug-hunts as BACKGROUND subprocesses and then
# parks on a Monitor wait that never fires under `-p`, it closes at 0 turns without emitting the terminal
# V-COMPLETION-SELFCHECK token. The runner's verdict for that session is `inconclusive`, which fell to the
# `*)` branch → VERIFY_FAILED=1 → exit 2 — so a FULLY GREEN batch reported the GO/NO-GO as FAILED. The fix:
# when the verify session attests no verdict, if the verify pack declares a machine-readable gate directive
# `<!-- v-verify-gate: <cmd> -->`, the runner RE-RUNS that command synchronously (fork-proof) and keys the
# banner on its REAL exit code. This suite pins the four behaviors that make that sound:
#   A. fork-park (inconclusive) + GREEN gate  → verify PASSES, VERIFY_FAILED unset (→ exit 0), pack archived.
#   B. fork-park (inconclusive) + RED gate    → verify FAILS, VERIFY_FAILED set (→ exit 2). THE GUARD BITES:
#      a green banner requires the gates to POSITIVELY pass; a red batch is never false-greened.
#   C. fork-park (inconclusive) + NO directive → original FAIL behavior, unchanged (no silent auto-pass).
#   D. a real `done` attestation → untouched (the backstop only engages when the session gave no verdict).
# Portable bash 3.2/macOS: no `timeout` (override `sleep` to make the real heartbeat loop instant), no
# GNU-only tools. Sources the installed runner and drives the REAL inline _run_verify_pack.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }
# shellcheck disable=SC1090
source "$RUNNER" >/dev/null 2>&1

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; LOG_DIR="$TMP/logs"; DONE_DIR="$TMP/done"; ARCHIVE=1; WAVE_BLOCKED=0
VERIFY_FAILED=0; HAD_TIMEOUT=0
mkdir -p "$REPO" "$LOG_DIR" "$DONE_DIR"

# Stubs so _run_verify_pack exercises ONLY the verdict→gate decision (not a real claude dispatch):
count_left(){ echo 0; }             # all non-verify packs already landed
pack_name(){ basename "$1" .txt; }
run_pack(){ :; }                    # the "verify session" does nothing; VERDICT decides the verdict
_hb(){ :; }
sleep(){ :; }                       # make the real `while jobs -rp; sleep 60` heartbeat loop instant
_timeout_kind(){ echo active; }
VERDICT="inconclusive"              # the fork-park verdict (0-turn, no token)
verdict(){ echo "$VERDICT"; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }
O="$TMP/out"

echo "── A: fork-park (inconclusive) + GREEN gate → PASS, exit-clean ──"
PA="$TMP/99-verify-green.txt"; printf '/v verify\n<!-- v-verify-gate: true && true -->\n' > "$PA"
verify_pack(){ echo "$PA"; }; VERIFY_FAILED=0
_run_verify_pack > "$O" 2>&1 || true
grep -q '✓ verify passed (session did not attest' "$O" && ok "A green banner shown" || no "A no green banner"
[ "$VERIFY_FAILED" = 0 ] && ok "A VERIFY_FAILED unset (→ exit 0 done banner)" || no "A VERIFY_FAILED set"
[ -f "$DONE_DIR/99-verify-green.txt" ] && ok "A pack archived to .done/" || no "A pack not archived"

echo "── B: fork-park (inconclusive) + RED gate → FAIL (guard bites, no false-green) ──"
PB="$TMP/99-verify-red.txt"; printf '/v verify\n<!-- v-verify-gate: true && false -->\n' > "$PB"
verify_pack(){ echo "$PB"; }; VERIFY_FAILED=0
_run_verify_pack > "$O" 2>&1 || true
grep -q '✗ verify FAILED' "$O" && ok "B red banner shown" || no "B no red banner"
[ "$VERIFY_FAILED" = 1 ] && ok "B VERIFY_FAILED set (→ exit 2 — guard bites)" || no "B FALSE-GREEN on a red batch"

echo "── C: fork-park (inconclusive) + NO directive → original FAIL (unchanged) ──"
PC="$TMP/99-verify-none.txt"; printf '/v verify\n(no gate directive)\n' > "$PC"
verify_pack(){ echo "$PC"; }; VERIFY_FAILED=0
_run_verify_pack > "$O" 2>&1 || true
grep -q 'declares no' "$O" && ok "C 'no directive' message shown" || no "C wrong message"
[ "$VERIFY_FAILED" = 1 ] && ok "C VERIFY_FAILED set (behavior unchanged)" || no "C VERIFY_FAILED unset — silent auto-pass"

echo "── D: a real 'done' attestation is untouched by the backstop ──"
PD="$TMP/99-verify-done.txt"; printf '/v verify\n' > "$PD"
verify_pack(){ echo "$PD"; }; VERIFY_FAILED=0; VERDICT="done"
_run_verify_pack > "$O" 2>&1 || true; VERDICT="inconclusive"
grep -qx '  ✓ verify passed' "$O" && ok "D plain done banner intact" || no "D done banner changed"
[ "$VERIFY_FAILED" = 0 ] && ok "D done → no VERIFY_FAILED" || no "D done set VERIFY_FAILED"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
