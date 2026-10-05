#!/usr/bin/env bash
# witness-session-scoped-ttl-test.sh
# Version: 1.0.0 (W-WITNESS-TTL, 2026-08-05)
#
# Covers the gauntlet-attestation witness staleness CEILING only.
#
# WHY: a forensic sweep (2026-08-05) of the sessions that ran after the /v opt-in inversion
# found the witness is implicated in a majority of Stop blocks, a sizeable share of which were
# "witness is STALE: age=NNNNs exceeds V_GAUNTLET_ATTESTATION_MAX_AGE_SEC=7200s". The 2h
# ceiling is shorter than a full gauntlet cycle on a real diff: a session attests once the
# core trio (PRE_FLIGHT/AGENT_REVIEW/VERIFY_DONE) exists, then spends hours on QA_REPORT and
# IMPACT_MAP remediation, and the witness ages out by WALL TIME alone — with the artifacts
# completely unchanged. The forced re-attest is pure ceremony. (This is the same failure the
# W-perf4 note at check-review-artifact.sh already raised 1800s->7200s for; 7200s is still
# short. One production session burned hours and dozens of identical blocks partly on this limb.)
#
# THE FIX UNDER TEST: when no explicit override is set, the ceiling becomes SESSION-SCOPED —
# session age + 1h slack — with a hard FLOOR at the current 7200s. Monotonic relaxation only:
# the ceiling can never become STRICTER than today, so the change cannot introduce a block
# that does not already occur.
#
# WHAT MUST NOT CHANGE (the actual anti-replay guards, all asserted below):
#   - SID binding      : a witness for another session is rejected regardless of age
#   - future-ts guard  : a forged future timestamp is rejected
#   - explicit override: V_GAUNTLET_ATTESTATION_MAX_AGE_SEC still wins, including when it
#                        TIGHTENS the ceiling
#   - no start marker  : falls back to exactly 7200s (fail-safe, unchanged behaviour)
# The content-hash / nonce / HMAC bindings live further down the hook and are untouched by
# this change; bug6-phase2-test.sh and the v-gauntlet-attest-*-test.sh harnesses cover them.
#
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail
HOOK="${HOOK_UNDER_TEST:-$HOME/.claude/hooks/check-review-artifact.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------------------------
# Extract the TTL-resolution block from the hook and evaluate it in isolation. We deliberately
# re-implement NOTHING: the block is lifted verbatim from the file under test, so a drift
# between this harness and the hook shows up as a parse/behaviour failure rather than a silent
# false pass. Sentinels bracket the block in the hook.
# ---------------------------------------------------------------------------------------------
extract_block() {
  awk '/# === W-WITNESS-TTL BEGIN/,/# === W-WITNESS-TTL END/' "$HOOK"
}

# Harness stub for the hook helper the block calls.
_stub_prelude() {
  cat <<'STUB'
_cra_session_start_epoch() { printf '%s' "${STUB_SESSION_START:-}"; }
STUB
}

# Resolve the ceiling under a given environment. Echoes the resolved _GAUNTLET_MAX_AGE.
resolve_ceiling() {
  local blk="$TMP/blk.sh"
  { _stub_prelude; extract_block; echo 'printf "%s" "$_GAUNTLET_MAX_AGE"'; } > "$blk"
  ( set +u; SESSION_ID="${SESSION_ID:-11112222-3333-4444-8555-999900001111}"; bash "$blk" 2>/dev/null )
}

echo "== W-WITNESS-TTL :: ceiling resolution =="

if ! extract_block | grep -q '_GAUNTLET_MAX_AGE'; then
  no "T0 sentinel block present in hook" "W-WITNESS-TTL BEGIN/END block defining _GAUNTLET_MAX_AGE" "not found (change not applied yet)"
else
  ok "T0 sentinel block present in hook"
fi

NOW=$(date -u +%s)

# T1 — RED->GREEN. Long session, witness older than 7200s but well inside the session.
#      Session started 10000s ago => ceiling should be 10000+3600 = ~13600, not 7200.
out=$(STUB_SESSION_START=$((NOW-10000)) V_GAUNTLET_ATTESTATION_MAX_AGE_SEC= resolve_ceiling)
if [ -n "$out" ] && [ "$out" -ge 13000 ] 2>/dev/null; then
  ok "T1 long session -> ceiling scales with session age (got ${out}s)"
else
  no "T1 long session -> ceiling scales with session age" ">=13000s" "${out:-<empty>}"
fi

# T2 — FLOOR. Brand-new session must NOT get a ceiling tighter than today's 7200s.
out=$(STUB_SESSION_START=$((NOW-30)) V_GAUNTLET_ATTESTATION_MAX_AGE_SEC= resolve_ceiling)
if [ "${out:-0}" -eq 7200 ] 2>/dev/null; then
  ok "T2 fresh session -> floor holds at 7200s (never stricter than today)"
else
  no "T2 fresh session -> floor holds at 7200s" "7200" "${out:-<empty>}"
fi

# T3 — FAIL-SAFE. No start marker (helper returns empty) -> exactly today's behaviour.
out=$(STUB_SESSION_START= V_GAUNTLET_ATTESTATION_MAX_AGE_SEC= resolve_ceiling)
if [ "${out:-0}" -eq 7200 ] 2>/dev/null; then
  ok "T3 no start marker -> falls back to 7200s unchanged"
else
  no "T3 no start marker -> falls back to 7200s" "7200" "${out:-<empty>}"
fi

# T4 — OVERRIDE WINS, including when it TIGHTENS. An operator pinning 1800s must still get
#      1800s even on a long session; otherwise the escape hatch is a lie.
out=$(STUB_SESSION_START=$((NOW-10000)) V_GAUNTLET_ATTESTATION_MAX_AGE_SEC=1800 resolve_ceiling)
if [ "${out:-0}" -eq 1800 ] 2>/dev/null; then
  ok "T4 explicit override wins and may TIGHTEN (1800s on a 10000s session)"
else
  no "T4 explicit override wins and may tighten" "1800" "${out:-<empty>}"
fi

# T5 — MONOTONICITY. For any session age, resolved ceiling >= 7200. Property check.
mono_ok=1
for age in 0 1 60 3599 7199 7200 20000 200000; do
  out=$(STUB_SESSION_START=$((NOW-age)) V_GAUNTLET_ATTESTATION_MAX_AGE_SEC= resolve_ceiling)
  [ "${out:-0}" -ge 7200 ] 2>/dev/null || { mono_ok=0; break; }
done
[ "$mono_ok" -eq 1 ] && ok "T5 ceiling >= 7200s for every session age (monotonic relaxation)" \
                     || no "T5 ceiling >= 7200s for every session age" ">=7200 always" "violated at age=${age}s -> ${out:-<empty>}"

# T7 — FAIL-SAFE ON A MALFORMED MARKER. Regression guard for a real defect found 2026-08-05:
#      bash arithmetic treats a bare non-numeric token as a VARIABLE NAME, so an unvalidated
#      'abc' evaluated to 0 and the span became `now - 0 + 3600` ~= 56 YEARS — silently
#      DISABLING the staleness ceiling (fail-OPEN). Every malformed shape must fall back to the
#      7200s floor, and none may emit noise on stderr.
bad_ok=1; bad_why=""
for bad in "abc" "not-a-date" "12x34" "-5" "1785961423abc" " " "1e9"; do
  out=$(STUB_SESSION_START="$bad" V_GAUNTLET_ATTESTATION_MAX_AGE_SEC= resolve_ceiling 2>/dev/null)
  if [ "${out:-0}" -ne 7200 ] 2>/dev/null; then bad_ok=0; bad_why="marker='$bad' -> ${out:-<empty>}"; break; fi
done
[ "$bad_ok" -eq 1 ] && ok "T7 malformed marker -> fail-SAFE to 7200s floor (no fail-open)" \
                    || no "T7 malformed marker -> fail-SAFE to 7200s floor" "7200 for every malformed shape" "$bad_why"

# T8 — UPPER CAP. A numerically valid but absurd past marker (epoch 0 / 1970) must not yield a
#      decades-wide ceiling. Capped at 48h; longest real session observed was well under that.
out=$(STUB_SESSION_START=0 V_GAUNTLET_ATTESTATION_MAX_AGE_SEC= resolve_ceiling)
if [ "${out:-0}" -le 172800 ] 2>/dev/null && [ "${out:-0}" -ge 7200 ] 2>/dev/null; then
  ok "T8 epoch-0 marker is capped at 48h (got ${out}s)"
else
  no "T8 epoch-0 marker is capped at 48h" "7200..172800" "${out:-<empty>}"
fi

# T9 — NO STDERR NOISE. A malformed marker must not print bash arithmetic errors into the
#      hook's output stream (it would land in the user-visible Stop feedback).
err=$(STUB_SESSION_START="12x34" V_GAUNTLET_ATTESTATION_MAX_AGE_SEC= resolve_ceiling 2>&1 >/dev/null)
if [ -z "$err" ]; then ok "T9 malformed marker emits no stderr noise"
else no "T9 malformed marker emits no stderr noise" "(empty)" "$err"; fi

# T6 — FUTURE START MARKER cannot shrink the ceiling below the floor (clock skew / tamper).
out=$(STUB_SESSION_START=$((NOW+50000)) V_GAUNTLET_ATTESTATION_MAX_AGE_SEC= resolve_ceiling)
if [ "${out:-0}" -ge 7200 ] 2>/dev/null; then
  ok "T6 future start marker cannot shrink ceiling below floor (got ${out}s)"
else
  no "T6 future start marker cannot shrink ceiling below floor" ">=7200" "${out:-<empty>}"
fi

echo
echo "== untouched anti-replay guards still present in the hook =="
for pat in "witness SID mismatch" "timestamp is in the FUTURE" "nonce missing or too short" "check' field is"; do
  if grep -q "$pat" "$HOOK"; then ok "guard intact: $pat"; else no "guard intact: $pat" "present" "MISSING"; fi
done

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
