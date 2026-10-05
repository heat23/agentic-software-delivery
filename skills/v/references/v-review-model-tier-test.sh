#!/usr/bin/env bash
# v-review-model-tier-test.sh — Lever 1 (cost-tier, forensic 2026-06-17).
#
# THE cost leak: review-agent frontmatter defaulted to `model: opus`, so any dispatch that didn't pass the
# W13 $REVIEW_MODEL override (the codex-down fallback path — common per the flaky-codex finding) ran reviews
# on OPUS (~25x haiku, ~5x sonnet). One measured session had 3 opus review subagents (~627k tokens). The
# operator chose a SONNET floor + opus only for billing. This harness locks BOTH halves of that contract:
#   (a) the review-agent frontmatter default is sonnet (not opus) — the effective floor for un-overridden
#       dispatches; framework-pitfall stays the cheap specialist (haiku).
#   (b) W13 resolve_review_model is a sonnet FLOOR **and CAP** (2026-07-07 operator decision: reviews run
#       ONLY on sonnet/haiku): routine -> sonnet, hostile-non-billing -> sonnet, billing/payment CODE ->
#       sonnet (risk-gated to the TOP available tier; the opus escalation was retired with the cap).
set -u
ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENTS="$ROOT/agents"
REVDOC="$ROOT/skills/v/references/v-agent-review.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$REVDOC" ] || { echo "NO v-agent-review.md missing"; exit 1; }

echo "== review model tier :: sonnet floor + sonnet CAP (no opus; 2026-07-07) =="

# (a) frontmatter floor: the four general review agents default to sonnet (NOT opus); framework-pitfall haiku.
for a in security-reviewer logic-reviewer codebase-fit-reviewer codex-adversarial-reviewer; do
  m="$(grep -iE '^model:' "$AGENTS/$a.md" 2>/dev/null | head -1 | tr -d ' ' | cut -d: -f2)"
  [ "$m" = sonnet ] && ok "$a frontmatter model: sonnet (no opus default)" || no "$a frontmatter model='$m' (expected sonnet — opus default is the cost leak)"
done
# 2026-08-06 OPERATOR DECISION — framework-pitfall moved haiku -> sonnet. This REVERSES the
# 2026-06-20 "cheap specialist" drift-fix, deliberately and with the reason recorded, because the
# original framing was wrong on the merits: this agent is not a cheap mechanical check. Its whole
# remit is the subtlest classes in the suite — framework-silent-override, env-keyed half-guards,
# side-effect-BEFORE-verify (nonce consumed before signature checked), hand-rolled crypto/cache
# primitives. Owner decision (2026-08-06): haiku is not adequate for judging product code. Cost impact is small because
# CLAUDE.md dispatches this agent CONDITIONALLY (queue jobs, service-provider boot, HMAC/webhook
# verification, migrations), never on every diff.
#
# The sonnet CAP is untouched: this raises a floor, it does not open an opus path. The mechanical
# RUNNERS (v-pre-flight-runner, v-verify-done-runner) correctly stay haiku — they execute gates and
# report, they do not judge code — and enforce-haiku-dispatch.sh still pins those.
fp="$(grep -iE '^model:' "$AGENTS/framework-pitfall-reviewer.md" 2>/dev/null | head -1 | tr -d ' ' | cut -d: -f2)"
[ "$fp" = sonnet ] && ok "framework-pitfall-reviewer is sonnet (judges code; haiku retired 2026-08-06)" || no "framework-pitfall model='$fp' (expected sonnet — it reviews the subtlest bug classes)"

# (b) W13 resolve_review_model tiers — extract the function from the doc and exercise the 3 tiers.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sed -n '/^resolve_review_model() {/,/^}/p' "$REVDOC" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { no "could not extract resolve_review_model from v-agent-review.md"; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
tier() { # <writes-file-content> -> resolved model
  _TIER_N=$(( ${_TIER_N:-0} + 1 )); local sid="t_${_TIER_N}"; printf '%s\n' "$1" > "$TMP/session-writes-${sid}.txt"  # deterministic counter (determinism-net); global is safe — standalone-only harness, never sourced (SREV-004)
  ( V_TMP_DIR="$TMP"; . "$TMP/fn.sh"; resolve_review_model "$sid" "$TMP" )
}
# billing/payment CODE -> sonnet (Tier 1 is risk-GATED, capped at sonnet — 2026-07-07 sonnet-max decision)
for p in "config/cashier.php" "app/billing/Charge.php" "app/Services/payment/Gateway.php" "routes/webhook.php"; do
  r="$(tier "$p")"; [ "$r" = sonnet ] && ok "billing '$p' -> sonnet (Tier-1 cap, no opus)" || no "billing '$p' -> '$r' (expected sonnet — opus tier retired 2026-07-07)"
done
# hostile non-billing (auth/secret) -> sonnet (floor, not opus)
r="$(tier "app/Auth/TokenGuard.php")"; [ "$r" = sonnet ] && ok "auth (hostile non-billing) -> sonnet" || no "auth -> '$r' (expected sonnet)"
# routine -> sonnet (THE floor; was haiku before the cost-tier decision)
r="$(tier "app/Models/Post.php")"; [ "$r" = sonnet ] && ok "routine -> sonnet (the sonnet floor, was haiku)" || no "routine -> '$r' (expected sonnet floor)"
# routine must NOT be opus (no accidental blanket-opus regression)
[ "$(tier "app/Models/Post.php")" != opus ] && ok "routine is NOT opus (no blanket-opus regression)" || no "routine resolved to opus (cost regression)"

# D3 (MR-3, 2026-06-21): $V_REVIEW_TIER overrides the ROUTINE floor ONLY — RISK-GATED so it can never
# down-tier a security/payment review (Tier 1/2 return before the override).
tier_t() { # <V_REVIEW_TIER> <writes-content> -> resolved model
  _TIER_N=$(( ${_TIER_N:-0} + 1 )); local sid="o_${_TIER_N}"; printf '%s\n' "$2" > "$TMP/session-writes-${sid}.txt"
  ( V_TMP_DIR="$TMP"; V_REVIEW_TIER="$1"; . "$TMP/fn.sh"; resolve_review_model "$sid" "$TMP" )
}
# D3 RETIRED 2026-08-06 — owner decision: remove haiku from code reviews.
# `haiku` is no longer an accepted V_REVIEW_TIER value. The dial previously down-tiered ROUTINE
# (non-hostile) diffs to haiku for a ~3x saving; the operator has priced review quality above that
# saving, so the resolver now returns the sonnet floor for EVERY tier. Tier 1/2 were already
# non-overridable, so this closes the last path by which a code review could run on haiku.
#
# Retired at the RESOLVER rather than relying only on the dispatch floor
# (enforce-haiku-dispatch.sh Layer 3): two mechanisms disagreeing about the same value is the
# condition that produced this whole class — a declaration saying one thing and the decision doing
# another. Layer 3 remains as defence in depth for callers that hard-code a model.
[ "$(tier_t haiku 'app/Models/Post.php')" = sonnet ] && ok "D3: V_REVIEW_TIER=haiku is REJECTED — routine stays at the sonnet floor (haiku retired from reviews 2026-08-06)" || no "D3: V_REVIEW_TIER=haiku still yields haiku — the dial was not retired"
[ "$(tier_t haiku 'config/cashier.php')" = sonnet ]  && ok "D3: V_REVIEW_TIER=haiku does NOT down-tier BILLING (stays sonnet — risk-gated)" || no "D3: billing wrongly down-tiered under V_REVIEW_TIER=haiku (security exposure!)"
[ "$(tier_t haiku 'app/Auth/TokenGuard.php')" = sonnet ] && ok "D3: V_REVIEW_TIER=haiku does NOT down-tier HOSTILE auth (stays sonnet — risk-gated)" || no "D3: hostile auth wrongly down-tiered under V_REVIEW_TIER=haiku (security exposure!)"
[ "$(tier_t opus 'app/Models/Post.php')" = sonnet ] && ok "D3: V_REVIEW_TIER=opus is REJECTED (sonnet cap — only haiku|sonnet are valid dial values)" || no "D3: V_REVIEW_TIER=opus was honored (violates 2026-07-07 sonnet-max decision)"
[ "$(tier_t garbage 'app/Models/Post.php')" = sonnet ] && ok "D3: invalid V_REVIEW_TIER falls back to the sonnet floor" || no "D3: invalid V_REVIEW_TIER did not fall back to sonnet"
# The resolver must not be able to emit haiku on ANY input — the property, not one dial value.
_anyhaiku=0
for _t in haiku HAIKU claude-haiku-4-5 opus fable '' garbage; do
  for _p in 'app/Models/Post.php' 'resources/js/Pages/Home.tsx' 'app/Auth/TokenGuard.php' 'config/cashier.php'; do
    [ "$(tier_t "$_t" "$_p")" = haiku ] && { _anyhaiku=1; break 2; }
  done
done
[ "$_anyhaiku" -eq 0 ] && ok "resolver emits haiku for NO tier/path combination (28 combinations swept)" || no "resolver still emits haiku for V_REVIEW_TIER='$_t' on '$_p'"

# Every fallback STUB must declare the model its agent actually runs on. A stub that hard-codes
# `Model: haiku` for a sonnet agent makes the artifact LIE about its own reviewer — the same
# declaration-vs-decision split that let every reviewer run on haiku while its frontmatter said
# sonnet. (The old "Model: haiku is the validator magic constant" rationale is stale: validation.sh
# ALLOWED_REVIEW_MODELS is 'haiku|sonnet|opus', so sonnet validates fine.)
#
# Derived from each agent's frontmatter rather than hard-coded, so this assertion cannot rot the
# next time an agent's tier changes — the failure mode that produced this whole class.
# Correctly-haiku stubs (pre-flight, ux-critique, verify-done are mechanical/advisory) must STAY
# haiku; this checks agreement, not a blanket ban.
_sup="$ROOT/skills/v/references/v-supervise-children.sh"
if [ -f "$_sup" ]; then
  while IFS='|' read -r _branch _agent; do
    _want="$(grep -iE '^model:' "$AGENTS/$_agent.md" 2>/dev/null | head -1 | tr -d ' ' | cut -d: -f2)"
    [ -n "$_want" ] || continue
    _got="$(awk -v b="    $_branch" 'index($0,b)==1{f=1} f && /echo "Model: /{sub(/.*Model: /,""); sub(/".*/,""); print; exit}' "$_sup")"
    if [ "$_got" = "$_want" ]; then
      ok "stub $_branch declares '$_got' = $_agent frontmatter"
    else
      no "stub $_branch declares '$_got' but $_agent runs '$_want' (artifact would misdeclare its reviewer)"
    fi
  done <<'MAP'
PRE_FLIGHT_REPORT_*.md)|v-pre-flight-runner
UX_CRITIQUE_*.md)|v-ux-critique-reviewer
AGENT_REVIEW_*.md)|adversarial-panel-reviewer
VERIFY_DONE_REPORT_*.md)|v-verify-done-runner
QA_REPORT_*.md)|v-qa-reviewer
MAP
fi
# The AGENT_REVIEW skeleton emitter is a code-review artifact: never haiku.
_ers="$ROOT/skills/v/references/v-emit-agent-review-skeleton.sh"
if [ -f "$_ers" ]; then
  grep -qE '^[[:space:]]*Model: haiku[[:space:]]*$' "$_ers" \
    && no "v-emit-agent-review-skeleton.sh still emits 'Model: haiku' for a code review" \
    || ok "v-emit-agent-review-skeleton.sh does not declare haiku for a code review"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
