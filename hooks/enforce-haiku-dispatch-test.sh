#!/usr/bin/env bash
# enforce-haiku-dispatch-test.sh — ND-0716: VERIFY_DONE_MODEL_OVERRIDE must respect sonnet-max.
#
# Ground truth: HOOK-10 (v4.0, W13-2) whitelisted `haiku|sonnet|opus` for the v-verify-done
# override — written BEFORE the 2026-07-07 sonnet-max policy (CLAUDE.md Model Policy: ALL
# gate/review dispatches Sonnet 5 + Haiku ONLY) and never updated. An env var could therefore
# legitimately push a GATE dispatch to opus. Post-fix: opus is treated like any unrecognized
# value → falls through to the haiku default.
set -u
HOOK="${V_ENFORCE_HAIKU_HOOK:-$HOME/.claude/hooks/enforce-haiku-dispatch.sh}"
[ -f "$HOOK" ] || { echo "SKIP: missing $HOOK"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

agent_json(){  # <skill> <model>
  jq -n --arg p "You are $1 running as a dispatched subagent.\nDo the thing." --arg m "$2" \
    '{tool_name:"Agent", tool_input:{prompt:$p, model:$m}}'
}

effective_model(){  # <input-json> [override] -> prints resolved model ("" = allowed unchanged)
  local in="$1" ovr="${2:-}"
  local out
  if [ -n "$ovr" ]; then
    out=$(printf '%s' "$in" | VERIFY_DONE_MODEL_OVERRIDE="$ovr" bash "$HOOK" 2>/dev/null)
  else
    out=$(printf '%s' "$in" | bash "$HOOK" 2>/dev/null)
  fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.model // empty' 2>/dev/null
}

# ── baseline behavior preserved ──
M=$(effective_model "$(agent_json v-pre-flight sonnet)")
[ "$M" = "haiku" ] && ok "v-pre-flight at sonnet auto-corrected to haiku (Layer 2 baseline)" \
  || no "v-pre-flight not coerced to haiku" "got '$M'"

M=$(effective_model "$(agent_json v-verify-done haiku)")
[ -z "$M" ] && ok "v-verify-done already at haiku → passed through unchanged" \
  || no "haiku dispatch unexpectedly rewritten" "got '$M'"

M=$(effective_model "$(agent_json v-verify-done haiku)" sonnet)
[ "$M" = "sonnet" ] && ok "VERIFY_DONE_MODEL_OVERRIDE=sonnet still honored (W13-2 large-diff lane)" \
  || no "sonnet override broken" "got '$M'"

# ── ND-0716: opus override must NOT reach a gate dispatch ──
OUT=$(printf '%s' "$(agent_json v-verify-done haiku)" | VERIFY_DONE_MODEL_OVERRIDE=opus bash "$HOOK" 2>/dev/null)
M=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.model // empty' 2>/dev/null)
if [ "$M" = "opus" ]; then
  no "VERIFY_DONE_MODEL_OVERRIDE=opus produced an OPUS gate dispatch (sonnet-max violation)" "updatedInput.model=opus"
else
  ok "VERIFY_DONE_MODEL_OVERRIDE=opus does NOT yield opus (falls to haiku default; got '${M:-<unchanged=haiku>}')"
fi

M=$(effective_model "$(agent_json v-verify-done sonnet)" opus)
if [ "$M" = "haiku" ]; then
  ok "opus override + sonnet input → coerced to haiku default (unrecognized-value path)"
elif [ "$M" = "opus" ]; then
  no "opus override + sonnet input → OPUS dispatch (sonnet-max violation)" ""
else
  no "unexpected resolution for opus override + sonnet input" "got '$M'"
fi

# ── pre-flight/handoff must ignore the override entirely (mechanical work stays haiku) ──
M=$(effective_model "$(agent_json v-pre-flight sonnet)" sonnet)
[ "$M" = "haiku" ] && ok "override does not leak to v-pre-flight (stays haiku)" \
  || no "override leaked to v-pre-flight" "got '$M'"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
