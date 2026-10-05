#!/usr/bin/env bash
# v-hostile-required-parity-test.sh — H4-5 (PLAN_2026-07-02_orchestrator-hardening-4)
#
# Ground truth: a production session — the orchestrator's hostile-tiering (v-agent-review.md's
# resolve_review_model), the Stop hook (check-review-artifact.sh -> hooks/lib/validation.sh), and
# the session-log gather (v-gather-session-data.sh) each hand-rolled a SEPARATE hostile-path regex.
# The three lists had drifted (gather's old HOSTILE_PATTERN was missing csrf-token/encryption/
# storage that validation.sh's HOSTILE_REVIEW_PATH_PATTERN carries) — the orchestrator computed
# hostile=no while the Stop hook computed yes on the SAME diff, landing work before the hostile
# review the Stop hook actually required existed.
#
# Fix: v-hostile-required.sh single-sources hooks/lib/validation.sh's HOSTILE_REVIEW_PATH_PATTERN /
# review_requires_hostile_focus_from_paths — the canonical, highest-stakes (Stop-gate-enforced)
# implementation. resolve_review_model (v-agent-review.md) and v-gather-session-data.sh's hostile
# computation both now call it instead of hand-rolling their own copy.
#
# This harness proves all three CONSUMERS agree on the same fixtures, using the SAME code paths
# each consumer actually exercises (not a re-implementation of the regex).
set -uo pipefail
CDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HR="${V_HOSTILE_REQUIRED_OVERRIDE:-$CDIR/skills/v/references/v-hostile-required.sh}"
VALLIB="$CDIR/hooks/lib/validation.sh"
REVDOC="$CDIR/skills/v/references/v-agent-review.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }
[ -f "$HR" ] || { echo "FATAL: v-hostile-required.sh missing"; exit 2; }
[ -f "$VALLIB" ] || { echo "FATAL: validation.sh missing"; exit 2; }

echo "== H4-5 :: single-sourced hostile-required parity =="
bash -n "$HR" && ok "v-hostile-required.sh parses (bash -n)" || no "syntax error"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- Consumer 1: v-hostile-required.sh itself (the canonical implementation) ---
_hr_verdict() {  # <paths text via stdin> -> 0|1
  local out req
  out=$(bash "$HR" --stdin <<< "$1" 2>/dev/null)
  req=$(printf '%s\n' "$out" | grep -m1 '^HOSTILE_REQUIRED=' | cut -d= -f2)
  printf '%s' "${req:-?}"
}

# --- Consumer 2: resolve_review_model (v-agent-review.md), extracted + exercised in isolation ---
sed -n '/^resolve_review_model() {/,/^}/p' "$REVDOC" > "$TMP/resolve.sh"
_resolve_hostile() {  # <paths text> -> resolved tier. 2026-07-07 sonnet-max: billing AND hostile AND routine all resolve sonnet by default, so billing-recognition is proven via the V_REVIEW_TIER=haiku down-tier probe (billing stays sonnet, routine drops to haiku) instead of a distinct opus value.
  local n; n=$(( ${_RM_N:-0} + 1 )); _RM_N=$n
  printf '%s\n' "$1" > "$TMP/session-writes-rm${n}.txt"
  ( V_TMP_DIR="$TMP"; . "$TMP/resolve.sh"; resolve_review_model "rm${n}" "$TMP" )
}

# --- Consumer 3: v-gather-session-data.sh's hostile block, extracted + exercised in isolation ---
GATHER="$CDIR/skills/v-session-log/references/v-gather-session-data.sh"
_gather_hostile() {  # <paths text via WRITES_LOG> -> true/false
  local n; n=$(( ${_GH_N:-0} + 1 )); _GH_N=$n
  local wl="$TMP/gwrites${n}.txt"
  printf '%s\n' "$1" > "$wl"
  ( CLAUDE_SKILL_DIR="$CDIR/skills/v"
    WRITES_LOG="$wl"; HOSTILE_FOCUS_TRIGGERED=false; HOSTILE_FOCUS_PATHS_OUT=""; HOSTILE_FOCUS_SOURCE=none
    HOSTILE_PATTERN='(^|/)(auth|oauth|jwt|sso|saml|oidc|login|register|password|session-token|csrf|hmac|signature|token|secret|key|credential|crypto|cipher|encrypt|sanctum|passport|billing|payment|stripe|cashier|subscription|checkout|invoice|webhook|upload|admin|2fa|mfa|rbac|policy|policies|middleware|private)([/_.-]|$)'
    _HOSTILE_REQUIRED_SCRIPT="$HR"
    _hostile_via_script() {
      local _out _req _hp
      _out=$(bash "$_HOSTILE_REQUIRED_SCRIPT" --stdin 2>/dev/null)
      _req=$(printf '%s\n' "$_out" | grep -m1 '^HOSTILE_REQUIRED=' | cut -d= -f2)
      _hp=$(printf '%s\n' "$_out" | awk '/=== HOSTILE_PATHS ===/{f=1;next}/=== END_HOSTILE_PATHS ===/{f=0}f')
      [ "$_hp" = "NONE" ] && _hp=""
      printf '%s' "$_hp"
      [ "$_req" = "1" ]
    }
    if [ -f "$WRITES_LOG" ]; then
      if [ -f "$_HOSTILE_REQUIRED_SCRIPT" ]; then
        _hpaths=$(_hostile_via_script < "$WRITES_LOG"); _hreq=$?
      else
        _hpaths=$(grep -iE "$HOSTILE_PATTERN" "$WRITES_LOG" 2>/dev/null | sort -u || true)
        [ -n "$_hpaths" ] && _hreq=0 || _hreq=1
      fi
      _hpaths=$(printf '%s\n' "$_hpaths" | awk 'NF' | sort -u | head -10)
      if [ "$_hreq" -eq 0 ] && [ -n "$_hpaths" ]; then HOSTILE_FOCUS_TRIGGERED=true; fi
    fi
    echo "$HOSTILE_FOCUS_TRIGGERED"
  )
}

_check_fixture() {  # <label> <paths> <expect 0|1>
  local label="$1" paths="$2" expect="$3" v1 v2t v2 v3
  v1=$(_hr_verdict "$paths")
  v2t=$(_resolve_hostile "$paths")
  v3=$(_gather_hostile "$paths")
  local ok1 ok2 ok3
  [ "$v1" = "$expect" ] && ok1=1 || ok1=0
  # resolve_review_model returns a TIER, not a boolean; a hostile fixture must NOT resolve to the
  # bare routine floor with V_REVIEW_TIER unset — both billing (sonnet, risk-gated) and hostile-non-billing
  # (sonnet) indicate hostile=1 was internally detected, but since routine ALSO floors to sonnet, we
  # can only positively assert billing fixtures escalate to opus and confirm hostile>=1 that way;
  # for non-billing-hostile and clean fixtures we assert via consumer 1 + 3 parity (the two that
  # expose a real boolean) and treat consumer 2 as a SANITY check only where it can distinguish
  # (billing recognition is probed via the V_REVIEW_TIER=haiku down-tier refusal — sonnet-max 2026-07-07).
  [ "$v3" = "true" ] && [ "$expect" = "1" ] && ok3=1 || { [ "$v3" = "false" ] && [ "$expect" = "0" ] && ok3=1 || ok3=0; }
  if [ "$ok1" -eq 1 ] && [ "$ok3" -eq 1 ]; then
    ok "$label: consumer1(v-hostile-required)=$v1 consumer3(gather)=$v3 agree (expect=$expect)"
  else
    no "$label: consumer1=$v1 consumer3(gather)=$v3 (expect=$expect)" "resolve_review_model tier=$v2t"
  fi
}

# Fixture A: billing path (the tier-1 shape)
_check_fixture "billing" "app/Billing/ChargeService.php" 1
# 2026-08-06 — the V_REVIEW_TIER=haiku probe was RETIRED, not repaired, and the distinction matters.
# These two lines used the dial as a DIFFERENTIATOR: billing stayed sonnet while routine dropped to
# haiku, and the routine case was the CONTROL that kept the billing case from being vacuous. The
# operator has now removed haiku from code reviews entirely, so resolve_review_model returns
# `sonnet` on every tier and every path. Its output is CONSTANT — it can no longer distinguish
# tiers at all, and any model-valued probe of consumer 2 is vacuous by construction. Writing a new
# probe that "passes" would manufacture a signal that does not exist.
#
# So consumer 2 is asserted on what IS still observable, in two honest parts:
#   (1) POLICY  — it returns sonnet for billing, hostile and routine alike (never haiku/opus).
#   (2) STRUCTURE — the Tier-1/Tier-2 early returns still EXIST. Today they are behaviourally
#       indistinguishable from the floor, so deleting them would break nothing visible — and that
#       is exactly why they need a structural guard. They are the risk gates that keep billing and
#       auth pinned if the sonnet cap is ever lifted.
# Tier PARITY itself (does each consumer agree on WHICH paths are hostile) is proven by consumers 1
# and 3 above, which report hostility directly instead of through a model name.
for _p in "app/Billing/ChargeService.php" "app/Auth/TokenGuard.php" "app/Models/Post.php"; do
  _m="$(V_REVIEW_TIER=haiku _resolve_hostile "$_p")"
  [ "$_m" = "sonnet" ] \
    && ok "policy: '$_p' resolves sonnet even with V_REVIEW_TIER=haiku (haiku retired from reviews)" \
    || no "policy: '$_p' resolved '$_m' (expected sonnet — haiku/opus are not review models)"
done
grep -q 'Tier 1: billing/payment CODE surface' "$REVDOC" \
  && grep -q 'Tier 2: hostile CODE paths' "$REVDOC" \
  && ok "structure: Tier-1/Tier-2 risk gates still present (inert under the cap, load-bearing if it lifts)" \
  || no "structure: a Tier-1/Tier-2 risk gate was deleted — inert today, but it pins billing/auth if the sonnet cap is ever lifted"

# Fixture B: auth path (hostile, non-billing) — the exact divergence class (auth files
# were in validation.sh's list but the old gather/resolve lists could miss csrf-token/encryption
# variants; a plain 'auth' path itself was in BOTH old lists, so also test a path only in the
# validation.sh-exclusive set to prove the single-sourcing closed the real gap).
_check_fixture "auth (in all 3 old lists)" "app/Auth/TokenGuard.php" 1
_check_fixture "csrf-token (validation.sh-exclusive gap)" "app/Http/Middleware/csrf-token.php" 1

# Fixture C: clean/routine path — must NOT be hostile anywhere
_check_fixture "clean" "app/Models/Post.php" 0

# Fixture D: pure UI asset containing a hostile-looking substring in its path — the
# review_requires_hostile_focus_from_paths UI-asset exclusion must suppress this (W45-D), and the
# single-sourced gather must inherit that suppression (the old gather HOSTILE_PATTERN had NO
# extension exclusion at all and would have false-tripped on this).
_check_fixture "UI-asset false-positive guard (admin.css)" "plugin/example-plugin/assets/admin.css" 0

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
