#!/usr/bin/env bash
# sessionlog-warn-gate-test.sh — EFF-SLGATE (2026-06-28).
#
# The LAYER-4 session-log TELEMETRY gate (check-review-artifact.sh) blocked a /v session that shipped commits
# but wrote no session-log. The session-log apparatus is TEMPORARY hardening scaffolding the operator is
# retiring, so this gate now defaults to WARN (no block→remediate churn) while STILL writing the durable
# GAUNTLET_SKIPPED marker + a stderr warning, so the telemetry signal survives for the 6h sweep.
# `V_SESSION_LOG_GATE=block` restores hard enforcement (opt-in). Scope is the session-log gate ONLY — the
# AGENT_REVIEW / PRE_FLIGHT / data-safety gates are untouched (output quality preserved).
#
# COVERAGE: this EXECUTES the LAYER-4 block EXTRACTED VERBATIM from the production hook (real coverage, not a
# re-impl, mirroring v-agent-review-autoforce-test.sh) against a witness+no-telemetry scenario, stubbing only
# the two helper fns (_cra_block_gate / _cra_write_skipped_marker). Asserts:
#   default (unset)          -> NO block (exit 0) + durable marker + stderr WARNING  (the churn-killing change)
#   V_SESSION_LOG_GATE=warn   -> same as default
#   V_SESSION_LOG_GATE=block  -> blocks (exit 2)                                     (opt-in enforcement preserved)
# The stderr assertion (SREV-002) makes a regression that drops the warn printf turn RED; the structural
# assertion pins the EXACT `= "block" && _cra_block_gate` construct (SREV-003/F1: no comment-only tautology).
# RED on the pre-fix hook: default still blocked (exit 2) + no dial in the construct.
set -u
HOOK="${V_CRA_OVERRIDE:-$HOME/.claude/hooks/check-review-artifact.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$HOOK" ] || { echo "NO check-review-artifact.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

L4="$(awk '/=== LAYER-4: SESSION-LOG TELEMETRY/,/=== end LAYER-4 session-log telemetry/' "$HOOK")"
[ -n "$L4" ] || { echo "NO LAYER-4 block not found"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
LAST_RC=0; MKR=""; ERRF=""

# Execute the extracted LAYER-4 block with a commit-witness + NO telemetry, stubbing the 2 helper fns.
# $1 = value for V_SESSION_LOG_GATE ("" = unset/default). Captures exit code (LAST_RC), marker (MKR), stderr (ERRF).
run_l4() {
  local gate="$1" sid="sl-test-sid" root
  root="$WORK/r$$-$RANDOM"; mkdir -p "$root/.v/tmp"
  MKR="$root/marker.flag"; rm -f "$MKR"
  ERRF="$root/err.txt"; rm -f "$ERRF"
  echo "deadbeefcommitsha" > "$root/.v/tmp/commits-${sid}.txt"   # witness => session shipped commits
  (
    set +eu
    SESSION_ID="$sid"; MAIN_ROOT="$root"; REPO_ROOT="$root"; V_TMP_DIR_RESOLVED="$root/.v/tmp"; IS_V_SESSION=1
    IS_V_INVOCATION_VIA_HISTORY=0
    V_SL_AUTOGEN=0   # P1E seam: this harness pins the WARN/BLOCK dial in isolation; the P1E autogen/marker branches are covered by hooks/p1e-free-telemetry-test.sh
    if [ -n "$gate" ]; then V_SESSION_LOG_GATE="$gate"; else unset V_SESSION_LOG_GATE; fi
    _cra_block_gate(){ return 0; }                      # re-arm says "block now" — proves the DIAL gates, not the re-arm
    _cra_write_skipped_marker(){ : > "$MKR"; }          # durable telemetry marker
    eval "$L4"
  ) >/dev/null 2>"$ERRF"
  LAST_RC=$?
}

echo "== EFF-SLGATE :: LAYER-4 session-log telemetry gate is WARN by default, block on opt-in =="

run_l4 ""
{ [ "$LAST_RC" -eq 0 ] && [ -f "$MKR" ] && grep -qi 'session-log telemetry gap' "$ERRF"; } \
  && ok "default (unset) -> WARN: no block (exit 0) + durable marker + stderr warning (churn killed, signal kept)" \
  || no "default did NOT warn-pass" "rc=$LAST_RC marker=$([ -f "$MKR" ] && echo yes || echo NO) warned=$(grep -qi 'telemetry gap' "$ERRF" 2>/dev/null && echo yes || echo NO)"

run_l4 "warn"
{ [ "$LAST_RC" -eq 0 ] && [ -f "$MKR" ] && grep -qi 'session-log telemetry gap' "$ERRF"; } \
  && ok "explicit warn -> no block (exit 0) + marker + stderr warning" \
  || no "explicit warn did not pass" "rc=$LAST_RC warned=$(grep -qi 'telemetry gap' "$ERRF" 2>/dev/null && echo yes || echo NO)"

run_l4 "block"
[ "$LAST_RC" -eq 2 ] \
  && ok "V_SESSION_LOG_GATE=block -> hard enforcement preserved (exit 2)" \
  || no "block opt-in did NOT block" "rc=$LAST_RC"

# Unexpected value -> fail-safe to WARN (anything != 'block' is warn), not block.
run_l4 "off"
[ "$LAST_RC" -eq 0 ] \
  && ok "unexpected value ('off') -> fail-safe WARN (exit 0), not block" \
  || no "unexpected value did not fail-safe to warn" "rc=$LAST_RC"

# Structural guard (SREV-003/F1): pin the EXACT `= "block" && _cra_block_gate` construct — NOT a bare mention
# of V_SESSION_LOG_GATE (which appears in comments). `&& _cra_block_gate` occurs ONLY on the real code line.
printf '%s\n' "$L4" | grep -qE 'V_SESSION_LOG_GATE.*=.*"block".*&&.*_cra_block_gate' \
  && ok "LAYER-4 exit-2 path is guarded by the '= \"block\" && _cra_block_gate' construct (not a comment tautology)" \
  || no "no V_SESSION_LOG_GATE dial guarding the exit-2 construct (pre-fix / regressed) — default would block (RED)"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
