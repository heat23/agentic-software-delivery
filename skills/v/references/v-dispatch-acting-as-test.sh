#!/usr/bin/env bash
# v-dispatch-acting-as-test.sh — 17c (R4 HIGH-2 downgraded, forensic 2026-07-03): witness
# SID-match / acting_as. Extracts the REAL "17c" block verbatim from v-dispatch-subagent.sh
# (between the `=== 17c ===` / `=== end 17c ===` marker comments) and executes it in isolation
# against synthetic PROV_SID/ART_BASE fixtures, proving:
#   - same-session dispatch (artifact SID == this session's SID)            -> no refusal, no marker
#   - cross-session dispatch WITHOUT V_DISPATCH_ACTING_AS acknowledgment    -> refused (exit 7)
#   - cross-session dispatch WITH V_DISPATCH_ACTING_AS=<this-sid>          -> allowed, ACTING_AS_*.json written
set -u
SRC="${V_DISPATCH_SUBAGENT_SCRIPT:-$HOME/.claude/skills/v/references/v-dispatch-subagent.sh}"
[ -f "$SRC" ] || { echo "SKIP: missing $SRC"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

BLOCK=$(sed -n '/# === 17c (R4 HIGH-2/,/# === end 17c ===/p' "$SRC")
if [ -z "$BLOCK" ]; then
  no "17c block present in $SRC (RED — extraction found nothing)"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "17c block extracted from the real v-dispatch-subagent.sh"

T1=$(mktemp -d); trap 'rm -rf "$T1"' EXIT

# --- T1: same session (short-8 prefix matches) -> no refusal, no marker ---
( set -e
  ART_BASE="VERIFY_DONE_REPORT_aaaa1111-1111-4111-8111-111111111111.md"
  PROV_SID="aaaa1111-1111-4111-8111-111111111111"
  PROV_DIR="$T1"
  AGENT="v-verify-done-runner"
  _ORIG_ARGS=()
  eval "$BLOCK"
  exit 0
)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$(find "$T1" -name 'ACTING_AS_*.json' 2>/dev/null)" ]; then
  ok "T1 same-session dispatch: rc=0, no ACTING_AS marker written"
else
  no "T1 same-session dispatch behaved unexpectedly" "rc=$RC"
fi

# --- T2: cross-session, NO acknowledgment -> refused (exit 7), no marker ---
( set -e
  ART_BASE="VERIFY_DONE_REPORT_0a0a0a0a-1111-4111-8111-00000000c002.md"
  PROV_SID="e0e0e0e0-0000-4000-8000-000000000000"
  PROV_DIR="$T1"
  AGENT="v-verify-done-runner"
  _ORIG_ARGS=(--agent v-verify-done-runner --artifact "$ART_BASE" --prompt-file x --mode capture)
  eval "$BLOCK"
  exit 0
)
RC=$?
if [ "$RC" -eq 7 ] && [ -z "$(find "$T1" -name 'ACTING_AS_0a0a0a0a*.json' 2>/dev/null)" ]; then
  ok "T2 cross-session WITHOUT acknowledgment: refused rc=7, no marker (silent mismatch never proceeds)"
else
  no "T2 cross-session without ack not refused as expected" "rc=$RC"
fi

# --- T3: cross-session, explicit V_DISPATCH_ACTING_AS ack -> allowed, marker written ---
( set -e
  ART_BASE="VERIFY_DONE_REPORT_0a0a0a0a-1111-4111-8111-00000000c002.md"
  PROV_SID="e0e0e0e0-0000-4000-8000-000000000000"
  PROV_DIR="$T1"
  AGENT="v-verify-done-runner"
  _ORIG_ARGS=(--agent v-verify-done-runner --artifact "$ART_BASE" --prompt-file x --mode capture)
  export V_DISPATCH_ACTING_AS="e0e0e0e0-0000-4000-8000-000000000000"
  eval "$BLOCK"
  exit 0
)
RC=$?
MARKER="$T1/ACTING_AS_0a0a0a0a-1111-4111-8111-00000000c002.json"
if [ "$RC" -eq 0 ] && [ -f "$MARKER" ]; then
  ok "T3 cross-session WITH explicit acting_as: allowed rc=0, marker written"
  grep -q '"acting_as":"e0e0e0e0-0000-4000-8000-000000000000"' "$MARKER" \
    && ok "T3 marker records the correct acting_as sid" \
    || no "T3 marker missing/incorrect acting_as field" "$(cat "$MARKER" 2>/dev/null)"
  grep -q '"target_sid":"0a0a0a0a-1111-4111-8111-00000000c002"' "$MARKER" \
    && ok "T3 marker records the correct target_sid" \
    || no "T3 marker missing/incorrect target_sid field" "$(cat "$MARKER" 2>/dev/null)"
else
  no "T3 acknowledged cross-session dispatch not allowed" "rc=$RC marker_exists=$([ -f "$MARKER" ] && echo yes || echo no)"
fi

# --- T4 (FULL-SID-MATCH, forensic 2026-07-04): a mis-transcribed artifact SID that shares
#     the 8-char PREFIX but differs in a LATER UUID segment must be REFUSED (the old prefix-only
#     check let this bogus-SID artifact through). env SID is the REAL one; artifact path has the typo.
( set -e
  ART_BASE="PRE_FLIGHT_REPORT_5e55a000-0000-4000-8000-000000000005.md"   # bogus last segment
  PROV_SID="0a0a0a0a-1111-4111-8111-00000000c007"                        # real
  export CLAUDE_SESSION_ID="0a0a0a0a-1111-4111-8111-00000000c007"
  PROV_DIR="$T1"; AGENT="v-pre-flight-runner"
  _ORIG_ARGS=(--agent v-pre-flight-runner --artifact "$ART_BASE" --prompt-file x --mode capture)
  eval "$BLOCK"
  exit 0
)
RC=$?
if [ "$RC" -eq 7 ]; then
  ok "T4 mis-transcribed later-segment SID (shared 8-char prefix) → REFUSED rc=7 (full-UUID compare)"
else
  no "T4 transcription-error SID slipped through (prefix-only compare regression)" "rc=$RC"
fi
unset CLAUDE_SESSION_ID

# --- T4b (no false-block): the EXACT full SID still passes (env == artifact, full match) ---
( set -e
  ART_BASE="PRE_FLIGHT_REPORT_0a0a0a0a-1111-4111-8111-00000000c007.md"
  PROV_SID="0a0a0a0a-1111-4111-8111-00000000c007"
  PROV_DIR="$T1"; AGENT="v-pre-flight-runner"; _ORIG_ARGS=()
  eval "$BLOCK"
  exit 0
)
RC=$?
[ "$RC" -eq 0 ] && ok "T4b exact full-SID match still passes (no false-block on the legit case)" || no "T4b false-blocked an exact match" "rc=$RC"

# --- T4c (red fixture): the pre-fix block ACCEPTS the T4 transcription error (prefix-only) ---
BAK_SRC="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh.pre-fullsid0704-bak"
if [ -f "$BAK_SRC" ]; then
  BAK_BLOCK=$(sed -n '/# === 17c (R4 HIGH-2/,/# === end 17c ===/p' "$BAK_SRC")
  RC=$( ( set -e
    ART_BASE="PRE_FLIGHT_REPORT_5e55a000-0000-4000-8000-000000000005.md"
    PROV_SID="0a0a0a0a-1111-4111-8111-00000000c007"
    export CLAUDE_SESSION_ID="0a0a0a0a-1111-4111-8111-00000000c007"
    PROV_DIR="$T1"; AGENT="v-pre-flight-runner"; _ORIG_ARGS=()
    eval "$BAK_BLOCK"; exit 0 ); echo $? )
  [ "$RC" -eq 0 ] && ok "T4c red-fixture: pre-fix prefix-only block ACCEPTED the transcription error (the bug)" || no "T4c red-fixture vacuous" "pre-fix rc=$RC (expected 0)"
  unset CLAUDE_SESSION_ID
else
  ok "T4c skipped: no pre-fix bak on disk"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
