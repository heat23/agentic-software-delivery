#!/usr/bin/env bash
# v-verify-done-noiso-parity-test.sh — F-3 no-isolation VERIFY_DONE surfacing (forensic 2026-07-04).
#
# A no-isolation VERIFY_DONE cannot gate a merge — v-merge-back's W-GATE hard-blocks it (load-bearing).
# The artifact BOARD now ALSO surfaces it at completion (advisory) via the shared
# validation.sh::verify_done_no_isolation helper, so the fix happens in one pass, not at merge.
# Proves: (1) the shared helper classifies correctly; (2) the board prints the advisory; (3) PARITY —
# merge-back's inline no-isolation regex and the shared helper are the same pattern (no drift).
set -u
VLIB="$HOME/.claude/hooks/lib/validation.sh"
BOARD="$HOME/.claude/skills/v/references/v-artifact-validate-all.sh"
MB="$HOME/.claude/skills/v/references/v-merge-back.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
[ -f "$VLIB" ] || { echo "SKIP: validation.sh missing"; exit 0; }

# shellcheck source=/dev/null
set +u; source "$VLIB" 2>/dev/null; set -u
type verify_done_no_isolation >/dev/null 2>&1 \
  && ok "verify_done_no_isolation resolves from validation.sh (single-source helper)" \
  || { no "helper missing"; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── T1: a no-isolation VERIFY_DONE → helper true ──
NOISO="$T/VERIFY_DONE_REPORT_a1.md"
printf 'Model: haiku\nMode: scoped(writes-log:no-isolation)\nChanged: 3\n\n## Summary\nok\n\nOverall Verdict: PASS\n' > "$NOISO"
verify_done_no_isolation "$NOISO" && ok "T1 no-isolation Mode → helper returns true" || no "T1 helper missed no-isolation"

# ── T2: a normal isolated VERIFY_DONE → helper false ──
ISO="$T/VERIFY_DONE_REPORT_a2.md"
printf 'Model: haiku\nMode: scoped(writes-log)\nChanged: 3\n\n## Summary\nok\n\nOverall Verdict: PASS\n' > "$ISO"
verify_done_no_isolation "$ISO" && no "T2 false-positive on an isolated report" || ok "T2 isolated Mode → helper returns false (no false-positive)"

# ── T3: the board prints the ADVISORY for a no-isolation report, but still counts it ok ──
if [ -f "$BOARD" ]; then
  SID="a1b2c3d4-1111-4111-8111-000000000001"
  BD="$T/board"; mkdir -p "$BD/.v/artifacts"
  # a full valid gauntlet set so the board reaches VERIFY_DONE as ok
  pad="$(printf 'x%.0s' $(seq 1 220))"
  printf 'Model: haiku\nMode: scoped\nStatus: PASS\n## Gates\n%s\nOverall Status: PASS\n' "$pad" > "$BD/PRE_FLIGHT_REPORT_${SID}.md"
  printf 'Model: haiku\nMode: scoped(writes-log:no-isolation)\nChanged: 1\n\n## Summary\nok\n\nOverall Verdict: PASS\n' > "$BD/VERIFY_DONE_REPORT_${SID}.md"
  OUT="$(cd "$BD" && bash "$BOARD" "$SID" "$BD/.v/artifacts" "$BD" 2>&1 || true)"
  if printf '%s' "$OUT" | grep -qi 'ADVISORY: ran no-isolation'; then
    ok "T3 board surfaces the no-isolation ADVISORY at completion"
  else
    no "T3 board did not surface the advisory" "$(printf '%s' "$OUT" | grep -i verify | head -2)"
  fi
  # the isolated one must NOT print the advisory
  printf 'Model: haiku\nMode: scoped(writes-log)\nChanged: 1\n\n## Summary\nok\n\nOverall Verdict: PASS\n' > "$BD/VERIFY_DONE_REPORT_${SID}.md"
  OUT2="$(cd "$BD" && bash "$BOARD" "$SID" "$BD/.v/artifacts" "$BD" 2>&1 || true)"
  printf '%s' "$OUT2" | grep -qi 'ADVISORY: ran no-isolation' \
    && no "T3b advisory printed for an ISOLATED report (false surfacing)" \
    || ok "T3b no advisory for an isolated report"
else
  ok "T3 skipped: board script absent"
fi

# ── T4 (PARITY): merge-back's inline no-isolation check uses the SAME regex as the helper ──
if [ -f "$MB" ]; then
  # both must key on: ^Mode:.*no-isolation (case-insensitive)
  _h="$(sed -n "s/.*grep -iqE '\(\^Mode:[^']*no-isolation\)'.*/\1/p" "$VLIB" | head -1)"
  _m="$(sed -n "s/.*grep -iqE '\(\^Mode:[^']*no-isolation\)'.*/\1/p" "$MB" | head -1)"
  if [ -n "$_h" ] && [ "$_h" = "$_m" ]; then
    ok "T4 parity: validation.sh helper and merge-back inline check share the regex '$_h'"
  else
    no "T4 no-isolation regex DRIFT between helper and merge-back" "helper='$_h' merge-back='$_m'"
  fi
else
  ok "T4 skipped: merge-back absent"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
