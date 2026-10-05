#!/usr/bin/env bash
# run-v-packs-exit-code-test.sh — the AUTONOMY INVARIANT guard (NO-HUMAN, 2026-07-04).
#
# WHY: "no human in the middle" rests on ONE property — the runner must NEVER exit 0 while any work is
# outstanding. A cron/CI wrapper gates on the exit code; a false exit-0 means it reads success and walks
# away from queued/broken/off-main work. The 2026-07-04 autonomy audit (3 independent reviewers) found the
# exit-code derivation in _finish_report omitted three whole classes: packs still QUEUED after a stalled
# wave, a FAILED VERIFY (99-*) pack (invisible to count_left, which excludes wave 9999), and attested
# branches left DEFERRED/LIVE off main. In all three the runner exited 0 and the SELF-AUDIT said
# "attention needed: NONE" — a lie at the worst moment. This suite drives the REAL _finish_report (+ the
# real _run_verify_pack flag path) through each scenario and pins: (1) the correct exit code, and
# (2) the invariant that the SELF-AUDIT never prints "NONE" while the exit code is non-zero.
# These are RED-ORACLE cases: every NEW assertion below fails against the pre-fix runner.
# Portable bash 3.2/macOS: no arrays-of-arrays, no mapfile, no GNU-only tools.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

# Source the runner to get the real _finish_report / _run_verify_pack (main is sourcing-guarded).
# shellcheck disable=SC1090
source "$RUNNER" >/dev/null 2>&1
[ "$(type -t _finish_report)" = function ] || { echo "FATAL: sourcing did not expose _finish_report"; exit 1; }

# ── Stubs: _finish_report computes left/needs/_stranded internally from these. Override them per-scenario
#    via env vars the stubs read, so we can drive every branch deterministically. ─────────────────────────
count_left(){ printf '%s' "${STUB_LEFT:-0}"; }
count_needs(){ printf '%s' "${STUB_NEEDS:-0}"; }         # ACTIONABLE parked (excludes acknowledged)
count_needs_ack(){ printf '%s' "${STUB_NEEDS_ACK:-0}"; } # operator-acknowledged quarantine
count_done(){ printf '%s' "${STUB_DONE:-1}"; }
list_all_packs(){ [ -n "${STUB_LEFT_LIST:-}" ] && printf '%s\n' "$STUB_LEFT_LIST"; }
# _unlanded_branches emits TAB-separated: <verdict> <branch> <ncommits>. _finish_report formats each into a
# report line whose text (NEEDS MANUAL / deferred / …) both the human reads and _rc keys off.
_unlanded_branches(){ [ -n "${STUB_UNLANDED:-}" ] && printf '%b' "$STUB_UNLANDED"; }
PACK_ABS="${PACK_ABS:-/tmp/xp}"; LOG_DIR="${LOG_DIR:-/tmp/xp/.runlogs}"; REPO="${REPO:-/tmp/xp}"; DONE_DIR="/tmp/xp/.done"

# run _finish_report in a subshell (it ends with `exit`), capturing output + code. Args = env assignments.
run_fr(){ # usage: run_fr "VAR=val VAR2=val2 …"
  local out rc
  out="$(env $1 bash -c '
    source "'"$RUNNER"'" >/dev/null 2>&1
    count_left(){ printf "%s" "${STUB_LEFT:-0}"; }
    count_needs(){ printf "%s" "${STUB_NEEDS:-0}"; }
    count_needs_ack(){ printf "%s" "${STUB_NEEDS_ACK:-0}"; }
    count_done(){ printf "%s" "${STUB_DONE:-1}"; }
    list_all_packs(){ [ -n "${STUB_LEFT_LIST:-}" ] && printf "%s\n" "$STUB_LEFT_LIST"; }
    _unlanded_branches(){ [ -n "${STUB_UNLANDED:-}" ] && printf "%b" "$STUB_UNLANDED"; }
    PACK_ABS=/tmp/xp; LOG_DIR=/tmp/xp/.runlogs; REPO=/tmp/xp; DONE_DIR=/tmp/xp/.done
    _finish_report
  ' 2>&1)"; rc=$?
  LAST_OUT="$out"; LAST_RC="$rc"
}
# assert exit code + the NONE/NOT-NONE invariant together
assert_rc(){ # $1=label $2=expected_rc
  [ "$LAST_RC" = "$2" ] && ok "$1 → exit $2" || no "$1 exit code" "expected $2, got $LAST_RC"
  if [ "$LAST_RC" != 0 ]; then
    printf '%s' "$LAST_OUT" | grep -q 'attention needed: NONE' \
      && no "$1 INVARIANT" "SELF-AUDIT said NONE while exit=$LAST_RC (silent-success lie)" \
      || ok "$1 invariant: no false NONE while exit≠0"
  else
    printf '%s' "$LAST_OUT" | grep -q 'attention needed: NONE' \
      && ok "$1 clean run says NONE" \
      || no "$1 clean-run summary" "exit 0 but SELF-AUDIT did not say NONE"
  fi
}

echo "── A. fully clean: nothing queued, nothing parked, nothing off main → exit 0 ──"
run_fr "STUB_LEFT=0 STUB_NEEDS=0 STUB_UNLANDED= WAVE_BLOCKED=0 VERIFY_FAILED=0 ONCE=0"
assert_rc "A clean" 0

echo "── B. packs still QUEUED after a stalled wave (NO-HUMAN-1) → exit 2 [red-oracle: old code = 0] ──"
run_fr "STUB_LEFT=2 STUB_LEFT_LIST=w1-x.txt STUB_NEEDS=0 WAVE_BLOCKED=0 VERIFY_FAILED=0 ONCE=0"
assert_rc "B queued-after-stall" 2
printf '%s' "$LAST_OUT" | grep -q 'still queued / not completed' && ok "B names the queued packs" || no "B message" "no queued-packs bullet"

echo "── C. --once deliberately left later waves → exit 0 (by design, not a failure) ──"
run_fr "STUB_LEFT=2 STUB_LEFT_LIST=w2-y.txt STUB_NEEDS=0 WAVE_BLOCKED=0 VERIFY_FAILED=0 ONCE=1"
assert_rc "C once-partial" 0

echo "── D. VERIFY (99-*) GO/NO-GO pack failed (NO-HUMAN-2) → exit 2 [red-oracle: old code = 0] ──"
run_fr "STUB_LEFT=0 STUB_NEEDS=0 WAVE_BLOCKED=0 VERIFY_FAILED=1 ONCE=0"
assert_rc "D verify-failed" 2
printf '%s' "$LAST_OUT" | grep -q 'GO/NO-GO gate failed' && ok "D names the failed verify gate" || no "D message" "no verify-fail bullet"

echo "── E. attested branch left DEFERRED off main (NO-HUMAN-3) → exit 2 [red-oracle: old code = 0] ──"
run_fr "STUB_LEFT=0 STUB_NEEDS=0 WAVE_BLOCKED=0 VERIFY_FAILED=0 ONCE=0 STUB_UNLANDED=deferred\tfix/aa\t3\n"
assert_rc "E deferred-off-main" 2
printf '%s' "$LAST_OUT" | grep -q 'not yet on main' && ok "E surfaces the deferred branch as outstanding" || no "E message" "no deferred bullet"

echo "── F. branch NEEDS-MANUAL (failed drain) → exit 2 + names it won't self-resolve ──"
run_fr "STUB_LEFT=0 STUB_NEEDS=0 WAVE_BLOCKED=0 VERIFY_FAILED=0 ONCE=0 STUB_UNLANDED=failed\tfix/bb\t2\n"
assert_rc "F needs-manual" 2
printf '%s' "$LAST_OUT" | grep -q 'NEEDS-MANUAL' && ok "F flags NEEDS-MANUAL branch" || no "F message" "no needs-manual bullet"

echo "── G. parked pack in .needs-review/ (existing behavior preserved) → exit 2 ──"
run_fr "STUB_LEFT=0 STUB_NEEDS=1 WAVE_BLOCKED=0 VERIFY_FAILED=0 ONCE=0"
assert_rc "G parked" 2

echo "── H. wave-landing barrier stopped the run (existing behavior preserved) → exit 2 ──"
run_fr "STUB_LEFT=0 STUB_NEEDS=0 WAVE_BLOCKED=1 VERIFY_FAILED=0 ONCE=0"
assert_rc "H wave-blocked" 2

echo "── J. ONLY acknowledged-quarantine packs parked (2026-07-13) → exit 0 (triaged, held for interactive completion) ──"
run_fr "STUB_LEFT=0 STUB_NEEDS=0 STUB_NEEDS_ACK=5 WAVE_BLOCKED=0 VERIFY_FAILED=0 ONCE=0"
assert_rc "J ack-quarantine-only" 0
printf '%s' "$LAST_OUT" | grep -qi 'quarantined(ack)' && ok "J self-audit surfaces the acknowledged quarantine" || no "J message" "no quarantined(ack) counter"

echo "── K. one ACTIONABLE strand ALONGSIDE acknowledged quarantine → exit 2 (a fresh un-acked park still nags) ──"
run_fr "STUB_LEFT=0 STUB_NEEDS=1 STUB_NEEDS_ACK=3 WAVE_BLOCKED=0 VERIFY_FAILED=0 ONCE=0"
assert_rc "K actionable-plus-ack" 2
printf '%s' "$LAST_OUT" | grep -q 'parked in .needs-review/' && ok "K still nags on the actionable strand" || no "K message" "no actionable-park bullet"

echo "── I. all-oversized pack dir (NO-HUMAN-5): real /v packs skipped as oversized → exit 2, not clean 0 ──"
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  _TD="$(mktemp -d)"; ( cd "$_TD" && git init -q . && git commit -q --allow-empty -m init ); mkdir -p "$_TD/packs"
  ~/.local/bin/run-v-packs "$_TD/packs" >/dev/null 2>&1; _erc=$?
  [ "$_erc" = 0 ] && ok "genuinely-empty pack dir → exit 0" || no "empty dir exit" "expected 0, got $_erc"
  { printf '/v do the thing\n'; head -c 30000 /dev/zero | tr '\0' 'x'; } > "$_TD/packs/w1-huge.txt"
  _o="$(~/.local/bin/run-v-packs "$_TD/packs" 2>&1)"; _erc=$?
  [ "$_erc" = 2 ] && ok "all-oversized dir → exit 2 (real packs skipped, not a clean success)" || no "oversized dir exit" "expected 2, got $_erc"
  printf '%s' "$_o" | grep -qi 'SKIPPED as oversized' && ok "oversized exit names the skipped work" || no "oversized message" "no oversized notice"
  rm -rf "$_TD"
else
  echo "  (skipped — git/jq unavailable)"
fi

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
