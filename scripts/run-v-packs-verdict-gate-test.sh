#!/usr/bin/env bash
# run-v-packs-verdict-gate-test.sh — NO-HUMAN-4 independent verdict backstop (2026-07-04 autonomy audit).
#
# WHY: verdict()==done rests on a whole-log GAUNTLET_ATTESTED substring + delegation to the Stop hook; the
# runner never independently re-read whether the gate artifacts PASSED. If the Stop hook fails open, a session
# whose PRE_FLIGHT/VERIFY_DONE/QA says FAIL could archive as production-ready. _gauntlet_verdicts_not_failed is
# the runner's OWN check. This suite pins BOTH directions: it must BLOCK a provable-FAIL (else broken code
# ships autonomously) and must NEVER block a PASS / absent / escalated / unparseable artifact (else it
# false-rejects good work on every run). Also pins the integration: a `done` log whose artifact says FAIL is
# parked to .needs-review/, not archived to .done/. Portable bash 3.2/macOS.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "── result: 0 passed, 0 failed (skipped) ──"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq";  echo "── result: 0 passed, 0 failed (skipped) ──"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }
# The pre-fix backups these RED cases compare against are not shipped in the public snapshot, so an
# absent backup is a visible skip (not counted as a pass), never a failure.
skip(){ printf '  skip %s — %s\n' "$1" "${2:-}"; }
# shellcheck disable=SC1090
source "$RUNNER" >/dev/null 2>&1
[ "$(type -t _gauntlet_verdicts_not_failed)" = function ] || { echo "FATAL: predicate not exposed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; mkdir -p "$REPO/.v/artifacts"; ( cd "$REPO" && git init -q . )
SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

mk_pf(){ printf 'Mode: full\n\n## Gates\n- tests: %s\n\nOverall Status: %s\n' "$2" "$1" > "$REPO/PRE_FLIGHT_REPORT_${SID}.md"; }
mk_vd(){ printf 'Mode: scoped(writes-log)\nChanged: 1\nSummary: x\n\n## Summary\ny\n\nOverall Verdict: %s\n' "$1" > "$REPO/VERIFY_DONE_REPORT_${SID}.md"; }
mk_qa(){ printf 'Model: sonnet\n\n## QA Acceptance\n\nverdict: %s\n' "$1" > "$REPO/QA_REPORT_${SID}.md"; }
clear_arts(){ rm -f "$REPO"/PRE_FLIGHT_REPORT_*.md "$REPO"/VERIFY_DONE_REPORT_*.md "$REPO"/QA_REPORT_*.md "$REPO/.v/artifacts"/*.md 2>/dev/null; }

# helper: run predicate against current $REPO/SID, capture rc + reason
runp(){ REASON="$(REPO="$REPO" _gauntlet_verdicts_not_failed "$SID")"; PRC=$?; }

echo "── 1. all PASS → NOT blocked (must never false-reject a good run) ──"
clear_arts; mk_pf PASS ok; mk_vd PASS; mk_qa pass
runp; [ "$PRC" = 0 ] && ok "all-PASS returns 0 (archives)" || no "all-PASS blocked" "rc=$PRC reason=$REASON"

echo "── 2. PRE_FLIGHT FAIL → BLOCKED ──"
clear_arts; mk_pf FAIL fail; mk_vd PASS; mk_qa pass
runp; { [ "$PRC" = 1 ] && printf '%s' "$REASON" | grep -q 'PRE_FLIGHT'; } && ok "PRE_FLIGHT FAIL blocks" || no "PRE_FLIGHT FAIL not blocked" "rc=$PRC reason=$REASON"

echo "── 3. VERIFY_DONE FAIL → BLOCKED ──"
clear_arts; mk_pf PASS ok; mk_vd FAIL; mk_qa pass
runp; { [ "$PRC" = 1 ] && printf '%s' "$REASON" | grep -q 'VERIFY_DONE'; } && ok "VERIFY_DONE FAIL blocks" || no "VERIFY_DONE FAIL not blocked" "rc=$PRC reason=$REASON"

echo "── 4. QA verdict: fail (and wrapped) → BLOCKED ──"
clear_arts; mk_pf PASS ok; mk_vd PASS; mk_qa fail
runp; { [ "$PRC" = 1 ] && printf '%s' "$REASON" | grep -q 'QA_REPORT'; } && ok "QA fail blocks" || no "QA fail not blocked" "rc=$PRC reason=$REASON"
clear_arts; mk_pf PASS ok; mk_vd PASS; printf 'Model: sonnet\n\n## QA Acceptance\n\nverdict: **FAIL**\n' > "$REPO/QA_REPORT_${SID}.md"
runp; [ "$PRC" = 1 ] && ok "QA wrapped **FAIL** blocks" || no "wrapped FAIL leaked through" "rc=$PRC"

echo "── 5. QA verdict: escalated / pass → NOT blocked (conservative; only explicit fail blocks) ──"
clear_arts; mk_pf PASS ok; mk_vd PASS; mk_qa escalated
runp; [ "$PRC" = 0 ] && ok "escalated not blocked" || no "escalated wrongly blocked" "rc=$PRC reason=$REASON"

echo "── 6. absent artifacts → NOT blocked (absence is not proof of failure) ──"
clear_arts
runp; [ "$PRC" = 0 ] && ok "absent artifacts return 0" || no "absence blocked" "rc=$PRC reason=$REASON"

echo "── 7. malformed artifact (no recognizable verdict line) → NOT blocked ──"
clear_arts; printf 'Mode: full\nsome notes, the word fail appears in prose here\n' > "$REPO/PRE_FLIGHT_REPORT_${SID}.md"
runp; [ "$PRC" = 0 ] && ok "prose 'fail' (not the Overall Status line) does NOT block" || no "false-matched prose fail" "rc=$PRC reason=$REASON"

echo "── 8. V_PACK_VERDICT_GATE=0 opt-out → never blocks even on FAIL ──"
clear_arts; mk_pf FAIL fail
REASON="$(REPO="$REPO" V_PACK_VERDICT_GATE=0 _gauntlet_verdicts_not_failed "$SID")"; PRC=$?
[ "$PRC" = 0 ] && ok "opt-out disables the gate" || no "opt-out ignored" "rc=$PRC"

echo "── 9. INTEGRATION: a done-verdict log + a FAIL artifact → parked to .needs-review/, NOT .done/ ──"
clear_arts; mk_pf FAIL fail; mk_vd PASS; mk_qa pass
LOG_DIR="$TMP/logs"; DONE_DIR="$TMP/done"; NEEDS_DIR="$TMP/needs"; mkdir -p "$LOG_DIR" "$DONE_DIR" "$NEEDS_DIR"
# a log that verdict() classifies `done`: success result, num_turns>0, GAUNTLET_ATTESTED, pinned sid
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":8,"session_id":"%s","result":"work complete — GAUNTLET_ATTESTED: yes"}\n' "$SID" > "$LOG_DIR/p1.log"
PACKF="$TMP/p1.txt"; printf '/v do a thing\n' > "$PACKF"
( REPO="$REPO" LOG_DIR="$LOG_DIR" DONE_DIR="$DONE_DIR" NEEDS_DIR="$NEEDS_DIR" ARCHIVE=1 PACK_ABS="$TMP" \
  bash -c 'source "'"$RUNNER"'" >/dev/null 2>&1; _archive_finished_pack p1 "'"$PACKF"'"' ) > "$TMP/arch.out" 2>&1
if [ -f "$NEEDS_DIR/p1.txt" ] && [ ! -f "$DONE_DIR/p1.txt" ]; then ok "FALSE-DONE parked to .needs-review/ (not .done/)"; else no "false-done was archived as done" "$(cat "$TMP/arch.out")"; fi
grep -q 'FALSE-DONE BLOCKED' "$TMP/arch.out" && ok "emits the FALSE-DONE BLOCKED explanation" || no "no block explanation" "$(cat "$TMP/arch.out")"

echo "── 10. INTEGRATION: a done-verdict log + all-PASS artifacts → archived to .done/ (no false-reject) ──"
clear_arts; mk_pf PASS ok; mk_vd PASS; mk_qa pass
rm -f "$NEEDS_DIR/p1.txt" "$DONE_DIR/p1.txt"; printf '/v do a thing\n' > "$PACKF"
( REPO="$REPO" LOG_DIR="$LOG_DIR" DONE_DIR="$DONE_DIR" NEEDS_DIR="$NEEDS_DIR" ARCHIVE=1 PACK_ABS="$TMP" \
  bash -c 'source "'"$RUNNER"'" >/dev/null 2>&1; _archive_finished_pack p1 "'"$PACKF"'"' ) > "$TMP/arch2.out" 2>&1
if [ -f "$DONE_DIR/p1.txt" ] && [ ! -f "$NEEDS_DIR/p1.txt" ]; then ok "all-PASS done archives to .done/"; else no "PASS run was NOT archived (false-reject!)" "$(cat "$TMP/arch2.out")"; fi

echo "── 11. HR-1 freshest-wins: stale .v/artifacts FAIL + FRESHER root PASS → NOT blocked (no false-reject) ──"
clear_arts
printf 'Mode: full\n\n## Gates\n\nOverall Status: FAIL\n' > "$REPO/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"; touch -t 202601010000 "$REPO/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
printf 'Mode: full\n\n## Gates\n\nOverall Status: PASS\n' > "$REPO/PRE_FLIGHT_REPORT_${SID}.md";               touch -t 202606010000 "$REPO/PRE_FLIGHT_REPORT_${SID}.md"
runp; [ "$PRC" = 0 ] && ok "fresher root PASS wins over stale mirror FAIL" || no "stale FAIL false-rejected a fresh PASS" "rc=$PRC reason=$REASON"

echo "── 12. HR-1 reverse: stale root PASS + FRESHER .v/artifacts FAIL → BLOCKED (fresher verdict wins) ──"
clear_arts
printf 'Mode: full\n\n## Gates\n\nOverall Status: PASS\n' > "$REPO/PRE_FLIGHT_REPORT_${SID}.md";               touch -t 202601010000 "$REPO/PRE_FLIGHT_REPORT_${SID}.md"
printf 'Mode: full\n\n## Gates\n\nOverall Status: FAIL\n' > "$REPO/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"; touch -t 202606010000 "$REPO/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
runp; [ "$PRC" = 1 ] && ok "fresher FAIL wins over stale PASS (blocks)" || no "fresher FAIL was missed" "rc=$PRC reason=$REASON"

echo "── 13. HR-2 space-in-REPO-path: a FAIL artifact under a spaced path still BLOCKS (backstop not no-op'd) ──"
SREPO="$TMP/repo with space"; mkdir -p "$SREPO/.v/artifacts"; ( cd "$SREPO" && git init -q . )
printf 'Mode: full\n\n## Gates\n\nOverall Status: FAIL\n' > "$SREPO/PRE_FLIGHT_REPORT_${SID}.md"
R2="$(REPO="$SREPO" _gauntlet_verdicts_not_failed "$SID")"; P2=$?
[ "$P2" = 1 ] && ok "spaced REPO path: FAIL correctly blocks (no word-split no-op)" || no "space in \$REPO silently no-op'd the backstop" "rc=$P2"
# and the inverse: a PASS under a spaced path must NOT block
printf 'Mode: full\n\n## Gates\n\nOverall Status: PASS\n' > "$SREPO/PRE_FLIGHT_REPORT_${SID}.md"
R2="$(REPO="$SREPO" _gauntlet_verdicts_not_failed "$SID")"; P2=$?
[ "$P2" = 0 ] && ok "spaced REPO path: PASS not false-rejected" || no "spaced-path PASS blocked" "rc=$P2"

echo "── 14. AUTH-DROP class (2026-07-07): a transient 'Not logged in' 0-turn success must be RETRIED (ratelimit), not PARKED (inconclusive) ──"
# verdict() reads $LOG_DIR/<name>.log; a genuine-inconclusive control (same success/0-turn shape, benign text)
# must still park — the fix must flip ONLY on the auth-failure signature, never widen the inconclusive escape.
VLD="$TMP/vlogs"; mkdir -p "$VLD"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"Not logged in · Please run /login","session_id":"b2b2b2b2-1111-4222-8333-444455556666"}' > "$VLD/AUTHDROP.log"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"Reviewed the tree; nothing obvious to change.","session_id":"c0ffee00-0000-0000-0000-000000000000"}' > "$VLD/INCONCL.log"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"Your session has expired, please sign in again.","session_id":"c0ffee00-0000-0000-0000-000000000001"}' > "$VLD/EXPIRED.log"
_av="$(LOG_DIR="$VLD" verdict AUTHDROP)"; [ "$_av" = ratelimit ] && ok "auth-drop 'Not logged in' → ratelimit (retried, not parked)" || no "auth-drop misclassified" "got '$_av' (want ratelimit)"
_ev="$(LOG_DIR="$VLD" verdict EXPIRED)";  [ "$_ev" = ratelimit ] && ok "session-expired → ratelimit"                       || no "session-expired misclassified" "got '$_ev' (want ratelimit)"
_iv="$(LOG_DIR="$VLD" verdict INCONCL)";  [ "$_iv" = inconclusive ] && ok "genuine 0-turn no-op still → inconclusive (park; escape not widened)" || no "inconclusive path regressed" "got '$_iv' (want inconclusive)"

echo "── 15. READ-ONLY lane (2026-07-07): a runner-tagged read-only pack that self-attests V-COMPLETION-SELFCHECK:PASS → readonly-done (archived); no attestation OR no tag → parks (never falsely archived). Gated on the runner's own \$logf.readonly tag so it can never fire for a code pack. ──"
RLD="$TMP/rlogs"; mkdir -p "$RLD"
_ro_result='Ran all gates. V-COMPLETION-SELFCHECK: PASS — read-only verification (no product code changed)'
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":%s,"session_id":"c0ffee00-0000-0000-0000-0000000000a0"}\n' "$(printf '%s' "$_ro_result" | jq -Rs .)" > "$RLD/ROPASS.log"
: > "$RLD/ROPASS.log.readonly"                                        # runner tagged this pack read-only
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"Ran some checks; session ended with no completion self-check.","session_id":"c0ffee00-0000-0000-0000-0000000000a1"}\n' > "$RLD/RONONE.log"
: > "$RLD/RONONE.log.readonly"                                        # tagged read-only, but NO attestation
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":%s,"session_id":"c0ffee00-0000-0000-0000-0000000000a2"}\n' "$(printf '%s' "$_ro_result" | jq -Rs .)" > "$RLD/CODEPASS.log"   # PASS token but NO .readonly tag (a code pack)
_r1="$(LOG_DIR="$RLD" verdict ROPASS)";   [ "$_r1" = readonly-done ]  && ok "read-only tagged + self-attested PASS → readonly-done (archives; wave can proceed)" || no "read-only completion not archived" "got '$_r1' (want readonly-done)"
_r2="$(LOG_DIR="$RLD" verdict RONONE)";   [ "$_r2" != readonly-done ] && ok "read-only tagged but NO attestation → parks ($_r2), never falsely archived" || no "read-only no-attestation falsely archived" "got '$_r2'"
_r3="$(LOG_DIR="$RLD" verdict CODEPASS)"; [ "$_r3" != readonly-done ] && ok "UNtagged pack (no \$logf.readonly) never gets readonly-done ($_r3) — code packs unaffected" || no "untagged pack falsely archived read-only" "got '$_r3'"
_VBAK="$HOME/.local/bin/run-v-packs-lib/30-verdict.sh.pre-readonly-bak"
if [ -f "$_VBAK" ]; then
  _rb="$( source "$_VBAK" >/dev/null 2>&1; LOG_DIR="$RLD" verdict ROPASS )"
  [ "$_rb" != readonly-done ] && ok "RED: pre-readonly-bak verdict() parks the SAME tagged+attested log ($_rb) — the lane is new" || no "RED oracle also archived read-only" "bak got '$_rb'; fix not new"
else skip "RED oracle absent" "$_VBAK"; fi

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
