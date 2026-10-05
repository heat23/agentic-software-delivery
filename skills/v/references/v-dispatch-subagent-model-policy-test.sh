#!/usr/bin/env bash
# v-dispatch-subagent-model-policy-test.sh — ND-0716 sonnet-max allowlist at the dispatch chokepoint.
#
# Ground truth: the 2026-07-07 sonnet-max policy sweep (CLAUDE.md Model Policy) fixed frontmatter
# and review tiering, but v-dispatch-subagent.sh forwarded ANY --model string verbatim to
# `claude -p --model <value>` — the structural gap that made in-body `--model opus` prose in
# v-audit-seo/sales-pricing/bug-hunt/anti-template-gauntlet/legal-docs executable (the
# opus-leak class, round 2), and let typos ("oups") reach the CLI silently.
#
# Contract under test (extracted verbatim from the real script between the
# `# === ND-MODEL-POLICY` / `# === end ND-MODEL-POLICY ===` markers, same convention as
# v-dispatch-subagent-sanity-gate-test.sh):
#   enforce_model_policy <value> <origin> ->
#     0  for empty, sonnet, haiku, full sonnet/haiku ids (no [1m])
#     2  for opus/fable/[1m]/unknown aliases (fail-closed, loud)
#     0  + stderr NOTICE when V_MODEL_POLICY_OVERRIDE=1 (operator-explicit lane)
# Plus call-site wiring: a full-script `--model opus` invocation exits 2 BEFORE any dispatch,
# and the AGENT_PINNED_MODEL path is guarded too.
set -u
SRC="${V_DISPATCH_SUBAGENT_SCRIPT:-$HOME/.claude/skills/v/references/v-dispatch-subagent.sh}"
[ -f "$SRC" ] || { echo "SKIP: missing $SRC"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

BLOCK=$(sed -n '/# === ND-MODEL-POLICY/,/# === end ND-MODEL-POLICY ===/p' "$SRC")
if [ -z "$BLOCK" ]; then
  no "ND-MODEL-POLICY block present in $SRC (RED — extraction found nothing)"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "ND-MODEL-POLICY block extracted from the real v-dispatch-subagent.sh"

eval "$BLOCK"
if ! type enforce_model_policy >/dev/null 2>&1; then
  no "enforce_model_policy defined by the extracted block"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi

chk(){  # <expected-rc> <label> <model> [override]
  local want="$1" lbl="$2" m="$3" ovr="${4:-}"
  local rc=0
  ( [ -n "$ovr" ] && export V_MODEL_POLICY_OVERRIDE="$ovr"
    unset V_MODEL_POLICY_OVERRIDE_dummy 2>/dev/null
    enforce_model_policy "$m" "test" ) 2>/dev/null; rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$lbl (rc=$rc)"; else no "$lbl" "want rc=$want got rc=$rc"; fi
}

# ── allowed lane ──
chk 0 "empty model value is a no-op (agent-pin absent case)" ""
chk 0 "alias 'sonnet' allowed" sonnet
chk 0 "alias 'haiku' allowed" haiku
chk 0 "full sonnet id allowed" claude-sonnet-5
chk 0 "full haiku id allowed" claude-haiku-4-5-20251001

# ── banned lane (fail-closed) ──
chk 2 "alias 'opus' REJECTED (sonnet-max)" opus
chk 2 "alias 'fable' REJECTED" fable
chk 2 "full opus id REJECTED" claude-opus-4-8
chk 2 "fable [1m] variant REJECTED" 'claude-fable-5[1m]'
chk 2 "sonnet [1m] variant REJECTED (no 1m lane in /v dispatch)" 'claude-sonnet-5[1m]'
chk 2 "typo 'oups' REJECTED (unknown alias = typo, not silent pass-through)" oups

# ── operator-explicit override lane ──
chk 0 "V_MODEL_POLICY_OVERRIDE=1 lets 'opus' through (operator-explicit per CLAUDE.md)" opus 1
_ovr_err=$( ( export V_MODEL_POLICY_OVERRIDE=1; enforce_model_policy opus "test" ) 2>&1 >/dev/null )
if printf '%s' "$_ovr_err" | grep -qi "override"; then
  ok "override path is LOUD (stderr notice mentions the override)"
else
  no "override path is silent — must announce itself on stderr" "got: $_ovr_err"
fi

# ── call-site wiring: full-script --model opus exits 2 before any dispatch ──
T1=$(mktemp -d); trap 'rm -rf "$T1"' EXIT
printf 'noop prompt\n' > "$T1/p.md"
OUT=$(bash "$SRC" --model opus --mode capture --prompt-file "$T1/p.md" --artifact "$T1/a.md" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "sonnet-max"; then
  ok "full-script --model opus -> exit 2 with sonnet-max message (no dispatch attempted)"
else
  no "full-script --model opus was not rejected at the chokepoint" "rc=$RC out=$(printf '%s' "$OUT" | head -3)"
fi

# ── call-site wiring: the AGENT_PINNED_MODEL path is guarded (static assertion) ──
if grep -q 'enforce_model_policy "\$AGENT_PINNED_MODEL"' "$SRC"; then
  ok "AGENT_PINNED_MODEL call site guarded (a future opus-pinned agent file is caught too)"
else
  no "AGENT_PINNED_MODEL is not passed through enforce_model_policy" "grep found no call site"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
