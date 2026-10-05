#!/usr/bin/env bash
# v-preflight-mark-test.sh — behavioral + negative coverage for the no-diff marker writer
# (audit 2026-06-18, P4). BEFORE this, v-preflight-mark.sh had ZERO coverage: a regression in the
# Step-6.1 short-circuit baseline (HEAD + writes-hash markers) was invisible. These cases run the
# REAL helper against a throwaway repo and assert the markers are written, reflect the live HEAD,
# refresh on a moved HEAD, and — the negative — that a missing SID writes NO marker (so Step 6.1
# re-dispatches defensively rather than short-circuiting on a stale baseline). In a sweep dir → auto-run.
set -u
HELPER="$HOME/.claude/skills/v/references/v-preflight-mark.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s — %s\n' "$1" "$2"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git absent"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }
[ -f "$HELPER" ] || { echo "FAIL v-preflight-mark: helper missing ($HELPER)"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

R=$(mktemp -d "${TMPDIR:-/tmp}/pfm.XXXXXX")
git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
git -C "$R" commit -q --allow-empty -m c1
VT="$R/.v/tmp"
SID="11111111-2222-3333-4444-555555555555"
run(){ env -u CLAUDE_CODE_SESSION_ID "$@" PROJECT_ROOT="$R" V_TMP_DIR="$VT" bash "$HELPER" >/dev/null 2>&1; }

# T1 (behavioral): with a SID, both markers are written and HEAD marker == live HEAD.
run CLAUDE_SESSION_ID="$SID"; rc=$?
[ "$rc" -eq 0 ] && ok "T1 helper exits 0" || no "T1 helper exit" "helper exited rc=$rc (expected 0)"
HEAD_NOW=$(git -C "$R" rev-parse HEAD)
HF="$VT/step4-head-$SID.txt"; WF="$VT/step4-writes-hash-$SID.txt"
[ -f "$HF" ] && [ -f "$WF" ] && ok "T1 writes both step4-head + step4-writes-hash markers" || no "T1 markers written" "missing $HF or $WF"
[ "$(cat "$HF" 2>/dev/null)" = "$HEAD_NOW" ] && ok "T1 HEAD marker matches live HEAD" || no "T1 HEAD marker fidelity" "marker=[$(cat "$HF" 2>/dev/null)] live=[$HEAD_NOW]"

# T2 (behavioral — freshness): after HEAD moves, re-running refreshes the HEAD marker.
git -C "$R" commit -q --allow-empty -m c2
HEAD2=$(git -C "$R" rev-parse HEAD)
run CLAUDE_SESSION_ID="$SID"
[ "$(cat "$HF" 2>/dev/null)" = "$HEAD2" ] && ok "T2 marker refreshes on a moved HEAD (no stale baseline)" || no "T2 freshness" "marker=[$(cat "$HF" 2>/dev/null)] expected=[$HEAD2]"

# T3 (NEGATIVE — no SID): with NO session id, the helper writes NO marker (Step 6.1 must re-dispatch
# defensively rather than short-circuit on a baseline it never owned). Exit must still be 0.
VT2="$R/.v/tmp2"
( cd "$R"; env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID PROJECT_ROOT="$R" V_TMP_DIR="$VT2" bash "$HELPER" >/dev/null 2>&1 )
rc=$?
nmarks=$(find "$VT2" -name 'step4-*' 2>/dev/null | wc -l | tr -d ' ')
[ "$rc" -eq 0 ] && ok "T3 exits 0 with no SID (never breaks the gate)" || no "T3 exit code" "rc=$rc (must be 0)"
[ "$nmarks" -eq 0 ] && ok "T3 NEGATIVE: no SID writes no markers (defensive re-dispatch preserved)" || no "T3 no-marker on no-SID" "wrote $nmarks marker(s) without a SID"

# T4-T7 (2026-07-01): --check mode — the folded Step-6.1 no-diff short-circuit. Word-on-stdout
# contract (PREFLIGHT_REUSE=0|1), always exit 0. Bit red against the pre-fold helper (no --check
# mode -> no PREFLIGHT_REUSE line) — see BITE_LEDGER 2026-07-01.
( cd "$R"; CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$R" V_TMP_DIR="$VT" bash "$HELPER" >/dev/null 2>&1 )  # refresh markers
touch "$R/PRE_FLIGHT_REPORT_${SID}.md"
res=$( cd "$R"; CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$R" V_TMP_DIR="$VT" bash "$HELPER" --check 2>/dev/null ); rc=$?
{ [ "$rc" -eq 0 ] && [ "$res" = "PREFLIGHT_REUSE=1" ]; } && ok "T4 --check: REUSE=1 when markers fresh + report present" || no "T4 --check reuse" "rc=$rc out=[$res]"

git -C "$R" commit -q --allow-empty -m c-moves-head
res=$( cd "$R"; CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$R" V_TMP_DIR="$VT" bash "$HELPER" --check 2>/dev/null )
[ "$res" = "PREFLIGHT_REUSE=0" ] && ok "T5 --check: REUSE=0 after HEAD moved (stale baseline caught)" || no "T5 --check moved-head" "out=[$res]"

( cd "$R"; CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$R" V_TMP_DIR="$VT" bash "$HELPER" >/dev/null 2>&1 )  # refresh to current HEAD
rm -f "$R/PRE_FLIGHT_REPORT_${SID}.md"
res=$( cd "$R"; CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$R" V_TMP_DIR="$VT" bash "$HELPER" --check 2>/dev/null )
[ "$res" = "PREFLIGHT_REUSE=0" ] && ok "T6 --check: REUSE=0 when the report itself is missing" || no "T6 --check missing-report" "out=[$res]"

res=$( cd "$R"; env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID PROJECT_ROOT="$R" V_TMP_DIR="$VT" bash "$HELPER" --check 2>/dev/null ); rc=$?
{ [ "$rc" -eq 0 ] && [ "$res" = "PREFLIGHT_REUSE=0" ]; } && ok "T7 --check: no SID prints REUSE=0 (word contract holds even SID-less; CDX-1)" || no "T7 --check no-SID" "rc=$rc out=[$res] (must be exactly PREFLIGHT_REUSE=0)"

rm -rf "$R"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
