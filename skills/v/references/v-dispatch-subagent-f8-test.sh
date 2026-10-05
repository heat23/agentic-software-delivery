#!/usr/bin/env bash
# v-dispatch-subagent-f8-test.sh — F8 regression (SID leakage, forensic 2026-07-05):
# v-dispatch-subagent.sh (`claude -p --agent <name>` subprocess dispatcher) never propagated the
# PARENT session's SID into the subprocess, never verified a self-write agent didn't leave a
# stray sibling artifact under the WRONG session id, and could let a runner subprocess's own
# forked sub-session get falsely flagged as "owing a gauntlet" it structurally can never run.
#
# Three fixes verified here end-to-end against a FAKE `claude` CLI (no real API calls):
#   F8-1: the parent SID is exported into the subprocess env as CLAUDE_SESSION_ID (verified
#         empirically 2026-07-05 that `claude -p` overwrites CLAUDE_CODE_SESSION_ID with its OWN
#         freshly-minted child id but leaves CLAUDE_SESSION_ID untouched — see the comment at the
#         export site). The fake `claude` binary reports what it saw in ITS OWN environment.
#   F8-2: a self-write agent that leaves a STRAY sibling artifact under a MISMATCHED session id
#         (in addition to correctly writing the requested $ARTIFACT) is treated as a FAILED
#         dispatch (exit 9, DISPATCH_STATUS=sid_leak), never silently accepted.
#   F8-3: a GAUNTLET_OWED_<child-sid>.md marker for the DISPATCHED SUBPROCESS's own (distinct)
#         session id — as would be created by hooks/track-session-writes.sh if that subprocess
#         wrote a non-report file — is cleaned up after a dispatch we KNOW produced that child sid,
#         and ONLY that sid (never a sibling's, never the parent's own marker).
#
# Red-before evidence: v-dispatch-subagent.sh.pre-fullsid0704-bak is the real shipped file
# immediately before this hardening pass (confirmed to contain none of the F8 markers) — used to
# prove each behavior is genuinely NEW, not just re-describing something already there.
set -u
REF_DIR="$HOME/.claude/skills/v/references"
SRC="$REF_DIR/v-dispatch-subagent.sh"
SRC_BAK="$REF_DIR/v-dispatch-subagent.sh.pre-fullsid0704-bak"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

[ -f "$SRC" ] || { echo "FAIL v-dispatch-subagent.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
for _dep in jq claude; do :; done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"

# ── fake `claude` CLI ──────────────────────────────────────────────────────────────────────────
# Entirely controlled via env vars set per-scenario below. Drains stdin (the prompt), then emits a
# `claude -p --output-format json`-shaped blob. FAKE_CLAUDE_MODE selects the behavior:
#   report-sid    — capture mode: embeds this process's own $CLAUDE_SESSION_ID into the result text
#   selfwrite     — self-write mode: writes ONLY the correct $FAKE_CLAUDE_ARTIFACT
#   selfwrite-leak— self-write mode: writes the correct artifact AND a stray sibling under a
#                   different session id ($FAKE_CLAUDE_LEAK_PATH)
cat > "$FAKEBIN/claude" <<'FAKECLAUDE'
#!/usr/bin/env bash
cat > /dev/null   # drain the prompt (fed on stdin by the real dispatcher)
_seen_sid="${CLAUDE_SESSION_ID:-<unset>}"
case "${FAKE_CLAUDE_MODE:-report-sid}" in
  report-sid)
    RESULT="Model: haiku
SID: seen-parent-sid=${_seen_sid}
## Gates
Overall Status: PASS"
    ;;
  selfwrite)
    printf 'Model: sonnet\nWrote correctly. seen-parent-sid=%s\n' "$_seen_sid" > "$FAKE_CLAUDE_ARTIFACT"
    RESULT="wrote artifact"
    ;;
  selfwrite-leak)
    printf 'Model: sonnet\nWrote correctly. seen-parent-sid=%s\n' "$_seen_sid" > "$FAKE_CLAUDE_ARTIFACT"
    printf 'Model: sonnet\nSTRAY leaked artifact under the wrong sid\n' > "$FAKE_CLAUDE_LEAK_PATH"
    RESULT="wrote artifact + stray leak"
    ;;
esac
jq -n --arg result "$RESULT" --arg sid "${FAKE_CLAUDE_CHILD_SID:-child-sid-unset}" \
  '{is_error:false, result:$result, total_cost_usd:0.001, duration_ms:10, modelUsage:{"claude-haiku-x":{}}, session_id:$sid}'
FAKECLAUDE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"

PROMPT_FILE="$WORK/prompt.txt"
printf 'Dummy dispatch prompt for F8 tests.\n' > "$PROMPT_FILE"

dispatch() {  # <script> <agent> <mode> <artifact>
  local script="$1" agent="$2" mode="$3" artifact="$4"
  ( cd "$WORK" && PROJECT_ROOT="$WORK" bash "$script" \
      --agent "$agent" --prompt-file "$PROMPT_FILE" --artifact "$artifact" --mode "$mode" )
}

echo "== F8-1 :: parent SID is exported into the subprocess (CLAUDE_SESSION_ID survives; CLAUDE_CODE_SESSION_ID would not) =="

PARENT_SID="aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
# Real-world shape: the orchestrator's OWN Bash-tool env carries CLAUDE_CODE_SESSION_ID (platform-set)
# but NOT necessarily CLAUDE_SESSION_ID (only some v-*.sh scripts bridge that alias). Simulate exactly
# that gap: only CLAUDE_CODE_SESSION_ID is present going in.
export CLAUDE_CODE_SESSION_ID="$PARENT_SID"
unset CLAUDE_SESSION_ID 2>/dev/null || true
export FAKE_CLAUDE_MODE=report-sid
ART1="$WORK/CUSTOM_CAPTURE_TEST_${PARENT_SID}.md"
OUT1="$(dispatch "$SRC" v-pre-flight-runner capture "$ART1" 2>"$WORK/f81.err")"
RC1=$?
if [ "$RC1" -eq 0 ] && [ -f "$ART1" ]; then
  ok "GREEN dispatch succeeded (rc=0, artifact present)"
else
  no "GREEN dispatch did not succeed as expected" "rc=$RC1 stderr=$(tail -5 "$WORK/f81.err")"
fi
if grep -q "seen-parent-sid=${PARENT_SID}" "$ART1" 2>/dev/null; then
  ok "FIXED: subprocess's own env saw CLAUDE_SESSION_ID=<parent sid> (F8-1 export reached the child)"
else
  no "FIXED: subprocess did not see the parent's SID via CLAUDE_SESSION_ID" "$(cat "$ART1" 2>/dev/null)"
fi

if [ -f "$SRC_BAK" ]; then
  unset CLAUDE_SESSION_ID 2>/dev/null || true
  ART1B="$WORK/CUSTOM_CAPTURE_TEST_BAK_${PARENT_SID}.md"
  dispatch "$SRC_BAK" v-pre-flight-runner capture "$ART1B" >/dev/null 2>"$WORK/f81b.err"
  if grep -q "seen-parent-sid=<unset>" "$ART1B" 2>/dev/null; then
    ok "RED confirmed: pre-fix backup never exported CLAUDE_SESSION_ID — the child subprocess saw '<unset>'"
  else
    no "RED fixture vacuous — backup already propagated the SID" "$(cat "$ART1B" 2>/dev/null)"
  fi
else
  ok "RED skipped: no pre-fullsid0704 backup on disk"
fi

echo
echo "== F8-2 :: a self-write agent leaving a stray sibling artifact under the WRONG sid is a FAILED dispatch =="

QA_SID="bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
WRONG_SID="cccccccc-3333-4333-8333-cccccccccccc"
mkdir -p "$WORK/.v/artifacts"
ART2="$WORK/.v/artifacts/QA_REPORT_${QA_SID}.md"
LEAK2="$WORK/.v/artifacts/QA_REPORT_${WRONG_SID}.md"
# This dispatch must itself run AS the QA_SID session (matching the artifact it's writing) so the
# pre-dispatch 17c same-session check passes and execution reaches the POST-dispatch F8-2 sid-leak
# scan under test — a mismatched CLAUDE_CODE_SESSION_ID here would be refused by 17c first (rc=7),
# never exercising the new check at all.
export CLAUDE_CODE_SESSION_ID="$QA_SID"
export CLAUDE_SESSION_ID="$QA_SID"
export FAKE_CLAUDE_MODE=selfwrite-leak
export FAKE_CLAUDE_ARTIFACT="$ART2"
export FAKE_CLAUDE_LEAK_PATH="$LEAK2"
export FAKE_CLAUDE_CHILD_SID="dddddddd-4444-4444-8444-dddddddddddd"
OUT2="$(dispatch "$SRC" v-qa-reviewer self-write "$ART2" 2>"$WORK/f82.err")"
RC2=$?
if [ "$RC2" -eq 9 ]; then
  ok "GREEN: leaked-sibling dispatch is treated as FAILED (rc=9), not silently accepted"
else
  no "GREEN: expected rc=9 for a sid-leak, got different rc" "rc=$RC2 stdout=$OUT2 stderr=$(tail -10 "$WORK/f82.err")"
fi
if printf '%s' "$OUT2" | grep -q '^DISPATCH_STATUS=sid_leak'; then
  ok "GREEN: DISPATCH_STATUS=sid_leak reported on stdout"
else
  no "GREEN: DISPATCH_STATUS=sid_leak not found on stdout" "$OUT2"
fi
if [ ! -s "$ART2" ] && [ -n "$(find "$WORK/.v/tmp" -maxdepth 1 -name 'rejected-sidleak-*' 2>/dev/null)" ]; then
  ok "GREEN: the correctly-written artifact was sidelined to a rejected-* sidecar, never left in place as if accepted"
else
  no "GREEN: rejected artifact was not sidelined as expected" "$(ls -la "$WORK/.v/tmp" 2>/dev/null)"
fi

# Clean the leaked sibling from the PRIOR scenario before the no-leak control — otherwise it would
# still match the QA_REPORT_* prefix scan and produce a false rc=9 unrelated to this scenario's own
# behavior (a test-fixture hygiene requirement, not a product bug: real dispatches don't reuse the
# same artifacts directory across unrelated sessions the way this single-WORK-dir test harness does).
rm -f "$WORK/.v/artifacts"/QA_REPORT_*

# no-leak control: identical setup but the fake agent writes ONLY the correct artifact.
QA_SID2="eeeeeeee-5555-4555-8555-eeeeeeeeeeee"
ART2C="$WORK/.v/artifacts/QA_REPORT_${QA_SID2}.md"
export CLAUDE_CODE_SESSION_ID="$QA_SID2"
export CLAUDE_SESSION_ID="$QA_SID2"
export FAKE_CLAUDE_MODE=selfwrite
export FAKE_CLAUDE_ARTIFACT="$ART2C"
unset FAKE_CLAUDE_LEAK_PATH 2>/dev/null || true
dispatch "$SRC" v-qa-reviewer self-write "$ART2C" > "$WORK/f82c.out" 2> "$WORK/f82c.err"
RC2C=$?
if [ "$RC2C" -eq 0 ] && [ -s "$ART2C" ]; then
  ok "control: no stray sibling -> dispatch succeeds normally (rc=0) — the leak check has no false positives"
else
  no "control: no-leak dispatch unexpectedly failed" "rc=$RC2C $(tail -10 "$WORK/f82c.err")"
fi

rm -f "$WORK/.v/artifacts"/QA_REPORT_*

# FLEET-SIBLING false-positive class (2026-07-06 forensics) is covered by its OWN harness —
# v-dispatch-subagent-fleet-sibling-test.sh — because this file's multi-scenario WORK dir made the
# fixture non-deterministic (an in-here variant passed vacuously against the pre-fix script).

if [ -f "$SRC_BAK" ]; then
  QA_SID_BAK="ffffffff-6666-4666-8666-ffffffffffff"
  WRONG_SID_BAK="11111111-7777-4777-8777-111111111177"
  ART2B="$WORK/.v/artifacts/QA_REPORT_${QA_SID_BAK}.md"
  LEAK2B="$WORK/.v/artifacts/QA_REPORT_${WRONG_SID_BAK}.md"
  export CLAUDE_CODE_SESSION_ID="$QA_SID_BAK"
  export CLAUDE_SESSION_ID="$QA_SID_BAK"
  export FAKE_CLAUDE_MODE=selfwrite-leak
  export FAKE_CLAUDE_ARTIFACT="$ART2B"
  export FAKE_CLAUDE_LEAK_PATH="$LEAK2B"
  dispatch "$SRC_BAK" v-qa-reviewer self-write "$ART2B" >/dev/null 2>"$WORK/f82b.err"
  RC2B=$?
  if [ "$RC2B" -eq 0 ] && [ -s "$ART2B" ] && [ -s "$LEAK2B" ]; then
    ok "RED confirmed: pre-fix backup silently ACCEPTS the exact same leaked-sibling scenario (rc=0, stray file left behind)"
  else
    no "RED fixture vacuous — backup already rejected the leak" "rc=$RC2B"
  fi
else
  ok "RED skipped: no pre-fullsid0704 backup on disk"
fi

echo
echo "== F8-3 :: GAUNTLET_OWED marker for the dispatched subprocess's OWN child sid is cleaned up =="

CHILD_SID3="22222222-8888-4888-8888-222222222288"
SIBLING_SID3="33333333-9999-4999-8999-333333333399"
PARENT_SID3="aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
mkdir -p "$WORK/.v/artifacts"
printf '# GAUNTLET OWED\nsid: %s\n' "$CHILD_SID3" > "$WORK/.v/artifacts/GAUNTLET_OWED_${CHILD_SID3}.md"
printf '# GAUNTLET OWED\nsid: %s\n' "$SIBLING_SID3" > "$WORK/.v/artifacts/GAUNTLET_OWED_${SIBLING_SID3}.md"
printf '# GAUNTLET OWED\nsid: %s\n' "$PARENT_SID3" > "$WORK/.v/artifacts/GAUNTLET_OWED_${PARENT_SID3}.md"
export CLAUDE_CODE_SESSION_ID="$PARENT_SID3"
export CLAUDE_SESSION_ID="$PARENT_SID3"
export FAKE_CLAUDE_MODE=report-sid
export FAKE_CLAUDE_CHILD_SID="$CHILD_SID3"
ART3="$WORK/CUSTOM_CAPTURE_TEST3_${PARENT_SID3}.md"
dispatch "$SRC" v-pre-flight-runner capture "$ART3" > "$WORK/f83.out" 2> "$WORK/f83.err"
RC3=$?
if [ "$RC3" -eq 0 ]; then ok "dispatch completed (rc=0)"; else no "dispatch failed unexpectedly" "rc=$RC3 $(tail -10 "$WORK/f83.err")"; fi
if [ ! -f "$WORK/.v/artifacts/GAUNTLET_OWED_${CHILD_SID3}.md" ]; then
  ok "GREEN: this dispatch's OWN child-sid GAUNTLET_OWED marker was removed (known runner subprocess, not an independent session)"
else
  no "GREEN: child-sid GAUNTLET_OWED marker was NOT removed"
fi
if [ -f "$WORK/.v/artifacts/GAUNTLET_OWED_${SIBLING_SID3}.md" ]; then
  ok "GREEN: an UNRELATED sibling SID's marker is left untouched (scoped cleanup, not a blanket sweep)"
else
  no "GREEN: sibling SID's marker was wrongly removed too — cleanup is not properly scoped"
fi
if [ -f "$WORK/.v/artifacts/GAUNTLET_OWED_${PARENT_SID3}.md" ]; then
  ok "GREEN: the PARENT session's own marker is never touched by subprocess-cleanup"
else
  no "GREEN: the parent's own GAUNTLET_OWED marker was wrongly removed"
fi

if [ -f "$SRC_BAK" ]; then
  CHILD_SID3B="44444444-0000-4000-8000-444444444400"
  printf '# GAUNTLET OWED\nsid: %s\n' "$CHILD_SID3B" > "$WORK/.v/artifacts/GAUNTLET_OWED_${CHILD_SID3B}.md"
  export FAKE_CLAUDE_CHILD_SID="$CHILD_SID3B"
  ART3B="$WORK/CUSTOM_CAPTURE_TEST3B_${PARENT_SID3}.md"
  dispatch "$SRC_BAK" v-pre-flight-runner capture "$ART3B" >/dev/null 2>"$WORK/f83b.err"
  if [ -f "$WORK/.v/artifacts/GAUNTLET_OWED_${CHILD_SID3B}.md" ]; then
    ok "RED confirmed: pre-fix backup leaves the child-sid GAUNTLET_OWED marker stranded (no cleanup existed)"
  else
    no "RED fixture vacuous — backup already cleaned up the marker"
  fi
else
  ok "RED skipped: no pre-fullsid0704 backup on disk"
fi

echo
echo "== Wiring checks on the ACTUAL shipped script =="
grep -q 'export CLAUDE_SESSION_ID="\${PROV_SID:-\${CLAUDE_SESSION_ID:-}}"' "$SRC" \
  && ok "F8-1 export line present in the shipped script" \
  || no "F8-1 export line not found in the shipped script"
grep -q '_check_sid_leak' "$SRC" && grep -q 'exit 9' "$SRC" \
  && ok "F8-2 sid-leak check + exit 9 present in the shipped script" \
  || no "F8-2 wiring not found in the shipped script"
grep -q '_exempt_subprocess_gauntlet' "$SRC" \
  && ok "F8-3 gauntlet-exemption function present in the shipped script" \
  || no "F8-3 wiring not found in the shipped script"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
