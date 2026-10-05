#!/usr/bin/env bash
# v-dispatch-subagent-fleet-sibling-test.sh — FLEET-AWARE sid-leak scoping (2026-07-06 pack-runner
# forensics).
#
# THE CLASS: under -jN parallel /v sessions sharing one <repo>/.v/artifacts dir, the F8-2 post-dispatch
# sid-leak scan flagged a CONCURRENT SIBLING session's own legitimately-written same-type artifact as a
# leak, failing perfectly good dispatches (exit 9) and re-dispatching. Live incident: one session's
# pre-flight dispatches were failed TWICE (DISPATCH_PROVENANCE status=sid_leak) because a sibling
# session wrote its own PRE_FLIGHT_REPORT_<sibling-sid> during the window — the rejected
# re-dispatches fed a long full-gate retry storm and the session died at the runner's ceiling.
#
# THE FIX (_sid_is_fleet_sibling): a mismatched-SID sibling artifact is NOT a leak when its SID provably
# belongs to a real concurrent session — its own DISPATCH_PROVENANCE_<sid>.log in the same dir, or a
# registered worktree session lock naming it. The mis-transcribed-forked-sub-session class F8-2 exists
# for has neither, so it still flags (case 2 pins that).
#
# Bite (RED): strip _sid_is_fleet_sibling + its call site from a copy of v-dispatch-subagent.sh and run
# this file with V_DISPATCH_SRC_OVERRIDE=<copy> — case 1 fails (rc=9 sid_leak on the sibling's artifact).
# Re-run: env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID bash <thisfile>
set -u
REF_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${V_DISPATCH_SRC_OVERRIDE:-$REF_DIR/v-dispatch-subagent.sh}"
[ -f "$SRC" ] || { echo "SKIP: dispatch script missing: $SRC"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }

QA="aaaa1111-2222-4333-8444-555566667777"
SIB="bbbb1111-2222-4333-8444-555566667777"
ORPHAN="cccc1111-2222-4333-8444-555566667777"

mk_env(){ # fresh WORK dir + fake claude; echoes WORK path
  local W FB
  W="$(mktemp -d)"; mkdir -p "$W/.v/artifacts" "$W/.v/tmp"
  FB="$W/bin"; mkdir -p "$FB"
  cat > "$FB/claude" <<'FC'
#!/usr/bin/env bash
cat > /dev/null
printf 'Model: sonnet\nWrote correctly.\n' > "$FAKE_CLAUDE_ARTIFACT"
jq -n '{is_error:false, result:"wrote artifact", total_cost_usd:0.001, duration_ms:10, modelUsage:{"m":{}}, session_id:"dddd1111-2222-4333-8444-555566667777"}'
FC
  chmod +x "$FB/claude"
  printf 'p\n' > "$W/prompt.md"
  printf '%s' "$W"
}
run_dispatch(){ # <WORK> <artifact> -> rc (stdout/err captured to $WORK/out, $WORK/err)
  local W="$1" A="$2"
  ( cd "$W" && PATH="$W/bin:$PATH" PROJECT_ROOT="$W" \
      CLAUDE_CODE_SESSION_ID="$QA" CLAUDE_SESSION_ID="$QA" FAKE_CLAUDE_ARTIFACT="$A" \
      bash "$SRC" --agent v-qa-reviewer --prompt-file "$W/prompt.md" --artifact "$A" --mode self-write \
      >"$W/out" 2>"$W/err" )
}
future_touch(){ # pin a file's mtime firmly inside the dispatch window
  local _fut
  _fut="$(date -v+2M +%Y%m%d%H%M.%S 2>/dev/null || date -d '+2 minutes' +%Y%m%d%H%M.%S 2>/dev/null || echo '')"
  [ -n "$_fut" ] && touch -t "$_fut" "$1" 2>/dev/null
}

echo "== v-dispatch-subagent.sh :: fleet-aware sid-leak scoping =="

# Case 1 (THE FIX): sibling artifact whose SID has its OWN provenance ledger -> NOT a leak, dispatch ok.
W1="$(mk_env)"; A1="$W1/.v/artifacts/QA_REPORT_${QA}.md"
printf 'sibling own report\n' > "$W1/.v/artifacts/QA_REPORT_${SIB}.md"
printf 'DISPATCH|status=ok\n'  > "$W1/.v/artifacts/DISPATCH_PROVENANCE_${SIB}.log"
future_touch "$W1/.v/artifacts/QA_REPORT_${SIB}.md"
run_dispatch "$W1" "$A1"; RC1=$?
if [ "$RC1" -eq 0 ] && [ -s "$A1" ]; then
  ok "case1: provenance-backed sibling artifact -> dispatch ok (no false sid_leak)"
else
  no "case1: sibling's legit artifact false-positived (rc=$RC1)" "$(grep DISPATCH_STATUS "$W1/out" 2>/dev/null | head -1)"
fi
rm -rf "$W1"

# Case 2 (guard NOT weakened): orphan mismatched SID with NO provenance and NO worktree lock -> STILL a leak.
W2="$(mk_env)"; A2="$W2/.v/artifacts/QA_REPORT_${QA}.md"
printf 'stray orphan artifact\n' > "$W2/.v/artifacts/QA_REPORT_${ORPHAN}.md"
future_touch "$W2/.v/artifacts/QA_REPORT_${ORPHAN}.md"
run_dispatch "$W2" "$A2"; RC2=$?
if [ "$RC2" -eq 9 ] && grep -q '^DISPATCH_STATUS=sid_leak' "$W2/out" 2>/dev/null; then
  ok "case2: orphan wrong-SID artifact (no provenance/lock) still flags sid_leak (rc=9)"
else
  no "case2: F8-2 guard weakened — orphan leak not flagged (rc=$RC2)" "$(head -3 "$W2/out" 2>/dev/null | tr '\n' ' ')"
fi
rm -rf "$W2"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
