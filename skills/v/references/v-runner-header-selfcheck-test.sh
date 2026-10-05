#!/usr/bin/env bash
# v-runner-header-selfcheck-test.sh — H4-11 (PLAN_2026-07-02_orchestrator-hardening-4)
#
# Ground truth: one production session burned several verify-done dispatches on missing Mode:/Changed:/
# verdict headers; another session's runner omitted ## Summary. Both runner agents now carry an explicit
# "MANDATORY SELF-CHECK BEFORE RETURNING" instruction block naming the literal required headers, so
# haiku self-corrects a malformed draft BEFORE returning it instead of the orchestrator catching the
# gap in a re-dispatch cycle. This is a prompt-side fix (no hook change); this harness pins the
# instruction block's presence + its required-header coverage.
set -uo pipefail
ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENTS="$ROOT/agents"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }

echo "== H4-11 :: runner agents carry a mandatory pre-return header self-check =="

VD="$AGENTS/v-verify-done-runner.md"
PF="$AGENTS/v-pre-flight-runner.md"
[ -f "$VD" ] && [ -f "$PF" ] || { echo "FATAL: runner agent file(s) missing"; exit 2; }

grep -qE '^## MANDATORY SELF-CHECK BEFORE RETURNING' "$VD" \
  && ok "v-verify-done-runner.md carries the mandatory self-check block" \
  || no "v-verify-done-runner.md missing the self-check block"
for req in 'Model: haiku' 'Mode:' 'Changed:' '## Checks' '## Summary' 'Overall Verdict:'; do
  grep -qF "$req" "$VD" && ok "verify-done self-check names required item: $req" \
    || no "verify-done self-check does not mention required item" "$req"
done

grep -qE '^## MANDATORY SELF-CHECK BEFORE RETURNING' "$PF" \
  && ok "v-pre-flight-runner.md carries the mandatory self-check block" \
  || no "v-pre-flight-runner.md missing the self-check block"
for req in 'Mode:' '## Gates' 'Overall Status:'; do
  grep -qF "$req" "$PF" && ok "pre-flight self-check names required item: $req" \
    || no "pre-flight self-check does not mention required item" "$req"
done

# Both blocks must instruct FIXING the draft before returning, not just describing the format.
grep -qiE 'FIX THE DRAFT before returning' "$VD" && ok "verify-done: instructs fixing before returning (not just describing)" \
  || no "verify-done self-check does not mandate fixing before return"
grep -qiE 'FIX THE DRAFT before returning' "$PF" && ok "pre-flight: instructs fixing before returning (not just describing)" \
  || no "pre-flight self-check does not mandate fixing before return"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
