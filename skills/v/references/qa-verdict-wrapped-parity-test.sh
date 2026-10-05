#!/usr/bin/env bash
# qa-verdict-wrapped-parity-test.sh — BITE for the F2-upstream fix (round-3, 2026-07-02).
#
# CLASS (cycle-1 adversarial review, F2): a QA verdict whose VALUE is quote/backtick/bold-wrapped
# (`verdict: "fail"`) evades the bare-token extraction — the drain's C-1 gate had this and LANDED a
# QA-failed branch in the PoC; the reviewer verified the SAME blind spot in v-merge-back.sh's
# _qa_report_fail() AND (by shared pipeline) hooks/lib/validation.sh's validate_qa_report_structure().
# merge-back is the LAST gate before the irreversible merge; the validator is what the Stop hook and
# the self-check read. Both must see through value-wrappers, and both must stay IDENTICAL — their
# parity is a documented contract ("IDENTICAL extraction ... so merge-back and the Stop hook read the
# SAME verdict") that until now was enforced only by a comment.
set -uo pipefail
VALIDATION="${V_TEST_VALIDATION:-$HOME/.claude/hooks/lib/validation.sh}"
MERGEBACK="${V_TEST_MERGEBACK:-$HOME/.claude/skills/v/references/v-merge-back.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
[ -f "$VALIDATION" ] && [ -f "$MERGEBACK" ] || { echo "FATAL: sources missing"; exit 2; }

T="$(mktemp -d)"; trap 'rm -rf "$T" 2>/dev/null' EXIT
_PAD=$(head -c 240 /dev/zero | tr '\0' x)
mk(){ printf 'Model: sonnet\n## QA Acceptance\n%s\n%s\n' "$1" "$_PAD" > "$T/qa.md"; }
vd(){ ( . "$VALIDATION" && validate_qa_report_structure "$T/qa.md" 2>/dev/null ); }

echo "== validator: wrapped verdict VALUES extract to the bare token =="
mk 'verdict: pass';        [ "$(vd)" = pass ] && ok "bare pass (control)" || no "bare pass broke" "$(vd)"
mk 'VERDICT: PASS';        [ "$(vd)" = pass ] && ok "all-caps pass (F1e control)" || no "all-caps regressed" "$(vd)"
mk 'verdict: "fail"';      [ "$(vd)" = fail ] && ok "double-quoted fail extracted (the F2 evasion)" || no "quoted fail NOT extracted — F2 evasion live" "got '$(vd)'"
mk "verdict: 'fail'";      [ "$(vd)" = fail ] && ok "single-quoted fail extracted" || no "single-quoted fail missed" "got '$(vd)'"
mk 'verdict: `fail`';      [ "$(vd)" = fail ] && ok "backtick-wrapped fail extracted" || no "backtick fail missed" "got '$(vd)'"
mk 'verdict: **fail**';    [ "$(vd)" = fail ] && ok "bold-value fail extracted" || no "bold-value fail missed" "got '$(vd)'"
mk 'verdict: "pass"  acceptance: accept'; [ "$(vd)" = pass ] && ok "quoted pass with trailing fields" || no "trailing fields broke extraction" "got '$(vd)'"

echo "== parity pin: merge-back and the validator carry the IDENTICAL extraction pipeline =="
# The contract used to live in a comment; pin it structurally. Extract each side's grep pattern for the
# verdict line and its strip stage; they must be byte-identical (a fix landing on one side only = drift).
_vpat="$(grep -oE "grep -iE '\^verdict:[^']*'" "$VALIDATION" | head -1)"
_mpat="$(grep -oE "grep -iE '\^verdict:[^']*'" "$MERGEBACK"  | head -1)"
[ -n "$_vpat" ] && [ "$_vpat" = "$_mpat" ] && ok "verdict-line grep pattern identical in both files" || no "extraction GREP drifted between validator and merge-back" "validator: $_vpat / merge-back: $_mpat"
# The strip stage's unique fingerprint is the portable octal pair \140\047 (backtick + single-quote);
# a plain first-tr-d grab would match validation.sh's unrelated size-check `tr -d ' \n'`.
_vstrip="$(grep -cF '\140\047' "$VALIDATION" 2>/dev/null)" || true
_mstrip="$(grep -cF '\140\047' "$MERGEBACK"  2>/dev/null)" || true
[ "${_vstrip:-0}" -ge 1 ] && [ "${_mstrip:-0}" -ge 1 ] && ok "wrapper-strip stage present in both files (\\140\\047 fingerprint)" || no "wrapper-strip stage drifted (or absent on one side)" "validator: ${_vstrip:-0} / merge-back: ${_mstrip:-0}"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
