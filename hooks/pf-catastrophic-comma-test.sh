#!/usr/bin/env bash
# pf-catastrophic-comma-test.sh
# Version: 1.0.0 (W-PF-COMMA, 2026-08-09)
#
# Guards the I2-PF "CATASTROPHIC test-failure count" detector in check-review-artifact.sh against
# the field-separator swallow that made it wrong in BOTH directions.
#
# THE BUG. The count class was `[0-9][0-9,]{0,8}` — which accepts a TRAILING comma, so a match
# could straddle two different fields of a summary line. Against PHPUnit's standard output:
#
#   Tests: 1200, Assertions: 9486, Failures: 1
#     old => 9486. FALSE POSITIVE. Blocked a production session on 2026-08-09
#     with "reports a CATASTROPHIC test-failure count (9486 failed)" for a run with ONE failure.
#     The number before "Failures" in that line is the ASSERTION count, always.
#
#   Tests: 1200, Assertions: 0, Failures: 1200
#     old => 0. FALSE NEGATIVE, and this is the worse half. `grep -o` returns non-overlapping
#     matches left-to-right, so the bogus "0, Failures" match CONSUMES the "Failures" token and
#     the real 1200 is never seen. The unprovisioned-worktree case this detector was built for
#     (forensic: thousands of failures labelled "BASELINE" and nearly shipped) sails straight through
#     whenever the report quotes PHPUnit's summary line rather than prose.
#
# THE FIX. `[0-9]([0-9]|,[0-9]){0,8}` — a comma is only valid BETWEEN digits, i.e. as a thousands
# separator, never as a trailing field separator. Thousands-separated counts still parse.
#
# WHY THIS SHAPE KEEPS RECURRING HERE: the detector read the token that PRECEDES the word
# "Failures" as a proxy for the failure count. The count is DECIDED by the `Failures: N` field.
# Fourth instance of that class in this ecosystem.
#
# NOTE ON SCOPE: this asserts the extraction arithmetic against the live regexes read out of the
# hook, not a copy. If someone edits the class in check-review-artifact.sh, these cases re-run
# against the NEW class and this harness bites.
#
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail
HOOK="${HOOK_UNDER_TEST:-$HOME/.claude/hooks/check-review-artifact.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }

[ -r "$HOOK" ] || { echo "FAIL: hook not readable at $HOOK"; exit 1; }

echo "== W-PF-COMMA :: catastrophic-failure count extraction =="

# Pull the LIVE arm-(b) regex out of the hook so this tests the shipped code, not a transcription.
# The first single-quoted segment on the `_pf_fail_only=` line IS the arm-(b) regex.
ARM_B=$(grep -m1 '_pf_fail_only=\$(grep -oiE' "$HOOK" 2>/dev/null | sed -E "s/^[^']*'([^']*)'.*/\1/")
if [ -z "$ARM_B" ]; then
  echo "  FAIL could not extract arm-(b) regex from $HOOK (anchor moved?)"; exit 1
fi
ok "extracted live arm-(b) regex from the hook ($(printf '%s' "$ARM_B" | wc -c | tr -d ' ') bytes)"

# The swallow is what we are guarding against: a trailing comma must not be part of a count.
if printf '%s' "$ARM_B" | grep -q '\[0-9\]\[0-9,\]'; then
  no "arm (b) uses the swallowing class" "[0-9]([0-9]|,[0-9])" "[0-9][0-9,] — REGRESSED"
else
  ok "arm (b) no longer uses the swallowing [0-9][0-9,] class"
fi

extract(){ printf '%s\n' "$1" | grep -oiE "$ARM_B" 2>/dev/null | grep -oE '[0-9,]+' | tr -d ',' | sort -rn | head -1; }

check(){ # $1=label $2=input $3=expected
  local got; got=$(extract "$2"); got=${got:-0}
  if [ "$got" = "$3" ]; then ok "$1 -> $got"; else no "$1" "$3" "$got"; fi
}

# --- the two regressions that motivated this harness -------------------------------------------
check "PHPUnit summary, 1 real failure (was FP: 9486)" 'Tests: 1200, Assertions: 9486, Failures: 1' 1
check "PHPUnit summary, broken env (was FN: 0)"         'Tests: 1200, Assertions: 0, Failures: 1200' 1200
# --- the true positives this detector exists for, which must still fire -------------------------
check "standalone prose count"                          '3120 failures in the suite' 3120
check "labelled count"                                  'failures: 3120' 3120
check "labelled with equals"                            'failed=3120' 3120
check "N tests failed"                                  '512 tests failed' 512
# --- formatting that must not be mangled --------------------------------------------------------
check "thousands separator preserved"                   '1,234 failed' 1234
check "multi-group thousands separator"                 '1,234,567 failed' 1234567
check "assertions with separator, small failure count"  'Assertions: 18,428, Failures: 2' 2
check "clean run"                                       'Tests: 40, Assertions: 120, Failures: 0' 0

# --- arm (a) carries the same class; assert it was fixed too ------------------------------------
if grep -q "_pf_counts=\$(grep -oiE '\[0-9\]\[0-9,\]" "$HOOK" 2>/dev/null; then
  no "arm (a) class" "[0-9]([0-9]|,[0-9])" "[0-9][0-9,] — REGRESSED"
else
  ok "arm (a) also uses the non-swallowing class"
fi

# --- mutation check: the assertions must actually bite -----------------------------------------
# Re-run the FP case against the OLD class. If it does NOT reproduce 9486, these cases are
# vacuous and this harness is not proving anything.
OLD_CLASS='[0-9][0-9,]{0,8}[[:space:]]+(tests?[[:space:]]+)?(failed|failures?)|(failed|failures?)[[:space:]:=]+[0-9][0-9,]{0,8}'
mut=$(printf '%s\n' 'Tests: 1200, Assertions: 9486, Failures: 1' | grep -oiE "$OLD_CLASS" 2>/dev/null | grep -oE '[0-9,]+' | tr -d ',' | sort -rn | head -1)
if [ "$mut" = "9486" ]; then
  ok "mutation check: old class reproduces the false positive (assertions are live)"
else
  no "mutation check" "old class yields 9486" "$mut — assertions may be vacuous"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
