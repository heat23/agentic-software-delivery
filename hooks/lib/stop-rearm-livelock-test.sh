#!/usr/bin/env bash
# stop-rearm-livelock-test.sh — F8 harness (2026-08-29).
#
# DEFECT: rearm_gate's escape path does `rm -f "$_sf"` (chain state), so the NEXT Stop starts a
# fresh chain with _same=0 and the IDENTICAL violation consumes its full block budget again —
# indefinitely. The only cross-chain counter, `_esc_n`, feeds the escape marker's NARRATION and
# no decision. Measured: an executor session, 13 escapes on ONE
# identical block message over more than two hours; every row same=3 vs
# _REARM_MAX_SAME=2, i.e. 39 blocks on the same message.
#
# FIX: on the Nth escape of the same fingerprint within one session (default N=3), write a durable
# STOP_LIVELOCK_<sid>.md and emit a DISTINCT stderr line. Counted from escapes.log — append-only,
# per-SID, carries fp=, and survives the chain reset that hides the loop.
#
# THE CONTRACT THIS MUST NOT BREAK: rearm_gate returns 1 on escape ("caller allows the stop").
# F8 adds a marker and stderr and NOTHING else. Returning 0 would convert a livelock into an
# INFINITE BLOCK — strictly worse than the bug. Every case below re-asserts rc 1.
#
# RED oracle: hooks/lib/stop-rearm.sh.pre-fix20260829-bak (no marker, no distinct stderr).
set -uo pipefail
PASS=0; FAIL=0; SKIP=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }
skip(){ SKIP=$((SKIP+1)); echo "  SKIP $1"; }   # input not shipped in this snapshot: neither pass nor fail

LIB="${STOP_REARM_UNDER_TEST:-$HOME/.claude/hooks/lib/stop-rearm.sh}"
BAK="$HOME/.claude/hooks/lib/stop-rearm.sh.pre-fix20260829-bak"
REAL_LOG="$HOME/.claude/runtime/stop-rearm/escapes.log"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT

# one_escape <lib> <statedir> <repo> <sid> <msg> [env assignments...]
# Drives rearm_gate until it escapes (with _REARM_MAX_SAME=2 the 3rd identical active call does),
# and echoes the FINAL rc. stderr of the whole cycle lands in $TD/err.txt (appended).
one_escape() {
  local lib="$1" sdir="$2" repo="$3" sid="$4" msg="$5"; shift 5
  ( cd "$repo" 2>/dev/null || cd "$TD"
    env CLAUDE_STOP_REARM_DIR="$sdir" "$@" bash -c '
      . "'"$lib"'"
      rearm_gate check-review-artifact "'"$sid"'" true "'"$msg"'" >/dev/null 2>>"'"$TD"'/err.txt"
      rearm_gate check-review-artifact "'"$sid"'" true "'"$msg"'" >/dev/null 2>>"'"$TD"'/err.txt"
      rearm_gate check-review-artifact "'"$sid"'" true "'"$msg"'" >/dev/null 2>>"'"$TD"'/err.txt"
      echo $?
    ' )
}

mkrepo() { mkdir -p "$1" && ( cd "$1" && git init -q . && git config user.email t@t.local && git config user.name t && echo x > f && git add -A && git commit -qm i ) >/dev/null 2>&1; }

echo "== F8 :: cross-chain escape memory (STOP_LIVELOCK) =="

# ── 1. same fp escaping N times -> marker + distinct stderr, rc STILL 1 ─────────────────
SID1="88880000-1111-4111-8111-000000000001"
S1="$TD/state1"; R1="$TD/repo1"; mkrepo "$R1"; : > "$TD/err.txt"
MSG="PRE_FLIGHT_REPORT missing for this session"
rc1=""; rc2=""; rc3=""
rc1=$(one_escape "$LIB" "$S1" "$R1" "$SID1" "$MSG")
[ -f "$R1/.v/artifacts/STOP_LIVELOCK_${SID1}.md" ] && no "1a marker fired on escape #1 (too early)" || ok "1a escape #1: no marker"
rc2=$(one_escape "$LIB" "$S1" "$R1" "$SID1" "$MSG")
[ -f "$R1/.v/artifacts/STOP_LIVELOCK_${SID1}.md" ] && no "1b marker fired on escape #2 (N-1: false positive)" || ok "1b escape #2 (N-1): still NO marker"
rc3=$(one_escape "$LIB" "$S1" "$R1" "$SID1" "$MSG")
MK="$R1/.v/artifacts/STOP_LIVELOCK_${SID1}.md"
[ -f "$MK" ] && ok "1c escape #3 (N): STOP_LIVELOCK marker written" || no "1c escape #3: marker MISSING at $MK"
[ "$rc1" = "1" ] && [ "$rc2" = "1" ] && [ "$rc3" = "1" ] \
  && ok "1d rc is 1 on every escape INCLUDING the marker one (return-code contract intact)" \
  || no "1d rc contract broken: rc1=$rc1 rc2=$rc2 rc3=$rc3 (must all be 1)"
if [ -f "$MK" ]; then
  grep -q "$SID1" "$MK" && ok "1e marker names the session" || no "1e marker lacks the sid"
  grep -qE 'Fingerprint: [0-9a-f]{16,}|Fingerprint: [0-9]+-[0-9]+' "$MK" && ok "1f marker names the fingerprint" || no "1f marker lacks the fingerprint"
  grep -q 'Escapes on THIS fingerprint: 3' "$MK" && ok "1g marker states the escape count (3)" || no "1g marker lacks the escape count"
  grep -q 'check-review-artifact' "$MK" && ok "1h marker names the hook" || no "1h marker lacks the hook"
  grep -qE '^- When: [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$MK" && ok "1i marker carries a UTC timestamp" || no "1i marker lacks a UTC timestamp"
  grep -q "BLOCKED_${SID1}.md" "$MK" && ok "1j marker tells the reader to do something different or write BLOCKED_<sid>.md" || no "1j marker lacks the remediation instruction"
  grep -q "$MSG" "$MK" && ok "1k marker quotes the still-present violation" || no "1k marker lacks the violation message"
fi
grep -q 'STOP LIVELOCK' "$TD/err.txt" && ok "1l DISTINCT stderr line emitted (not the GATE DEADLOCK ESCAPE wording)" || no "1l no distinct STOP LIVELOCK stderr line"
n_dl=$(grep -c 'GATE DEADLOCK ESCAPE' "$TD/err.txt" || true)
[ "${n_dl:-0}" -ge 3 ] && ok "1m the ordinary escape line still fires on every escape ($n_dl) — F8 replaces nothing" || no "1m escape stderr count is $n_dl (expected >=3)"

# ── 1-RED. the pre-fix lib produces no marker at all, ever ──────────────────────────────
if [ -f "$BAK" ]; then
  SIDR="88880000-1111-4111-8111-00000000000r"
  SR="$TD/stateR"; RR="$TD/repoR"; mkrepo "$RR"; : > "$TD/err.txt"
  rr1=$(one_escape "$BAK" "$SR" "$RR" "$SIDR" "$MSG")
  rr2=$(one_escape "$BAK" "$SR" "$RR" "$SIDR" "$MSG")
  rr3=$(one_escape "$BAK" "$SR" "$RR" "$SIDR" "$MSG")
  rr4=$(one_escape "$BAK" "$SR" "$RR" "$SIDR" "$MSG")
  [ -f "$RR/.v/artifacts/STOP_LIVELOCK_${SIDR}.md" ] \
    && no "1-RED oracle: pre-fix lib unexpectedly wrote a livelock marker" \
    || ok "1-RED oracle: pre-fix lib escapes 4x on the same fp with NO marker (the defect bites)"
  grep -q 'STOP LIVELOCK' "$TD/err.txt" \
    && no "1-RED oracle: pre-fix lib emitted the distinct stderr line" \
    || ok "1-RED oracle: pre-fix lib emits no livelock stderr (nothing tells the orchestrator to change course)"
  [ "$rr4" = "1" ] && ok "1-RED oracle: pre-fix rc on escape is 1 (the contract F8 must preserve)" \
                   || no "1-RED oracle: pre-fix rc was '$rr4', expected 1"
else
  skip "1-RED oracle: pre-fix backup not shipped in this snapshot ($BAK)"
fi

# ── 2. N DIFFERENT fingerprints -> no marker (it is same-fp, not total) ─────────────────
SID2="88880000-1111-4111-8111-000000000002"
S2="$TD/state2"; R2="$TD/repo2"; mkrepo "$R2"; : > "$TD/err.txt"
r=""
for m in "violation alpha" "violation bravo" "violation charlie" "violation delta"; do
  r=$(one_escape "$LIB" "$S2" "$R2" "$SID2" "$m")
done
[ -f "$R2/.v/artifacts/STOP_LIVELOCK_${SID2}.md" ] \
  && no "2 four DIFFERENT fingerprints wrongly tripped the same-fp livelock marker" \
  || ok "2 four DIFFERENT fingerprints -> NO marker (same-fp, not total escapes)"
[ "$r" = "1" ] && ok "2b rc still 1 across changing fingerprints" || no "2b rc was '$r'"

# ── 3. threshold floor: 0 / 1 / garbage must clamp to >= 2 ──────────────────────────────
for bad in 0 1 "" "abc" "-5" "1e10"; do
  SIDT="88880000-1111-4111-8111-0000000003$(printf '%02d' $((RANDOM%100)))"
  ST="$TD/stateT$$$bad"; RT="$TD/repoT$$${bad:-empty}"; mkrepo "$RT"
  rcT=$(one_escape "$LIB" "$ST" "$RT" "$SIDT" "floor probe" STOP_REARM_MAX_ESCAPES_SAME_FP="$bad")
  if [ -f "$RT/.v/artifacts/STOP_LIVELOCK_${SIDT}.md" ]; then
    no "3 STOP_REARM_MAX_ESCAPES_SAME_FP='$bad' fired the marker on the FIRST escape (floor not applied)"
  else
    ok "3 STOP_REARM_MAX_ESCAPES_SAME_FP='$bad' clamps to >=2 (no marker on escape #1)"
  fi
  [ "$rcT" = "1" ] || no "3b rc was '$rcT' with threshold '$bad' (must stay 1)"
  rm -rf "$RT" "$ST"
done
ok "3c rc stayed 1 across every malformed threshold value"

# ── 4. missing / unreadable escapes.log -> no marker, no crash, rc unchanged ────────────
SID4="88880000-1111-4111-8111-000000000004"
S4="$TD/state4"; R4="$TD/repo4"; mkrepo "$R4"; mkdir -p "$S4"
# Make escapes.log unreadable so both the append and the count fail.
: > "$S4/escapes.log"; chmod 000 "$S4/escapes.log" 2>/dev/null
rc4a=$(one_escape "$LIB" "$S4" "$R4" "$SID4" "unreadable-log probe")
rc4b=$(one_escape "$LIB" "$S4" "$R4" "$SID4" "unreadable-log probe")
rc4c=$(one_escape "$LIB" "$S4" "$R4" "$SID4" "unreadable-log probe")
rc4d=$(one_escape "$LIB" "$S4" "$R4" "$SID4" "unreadable-log probe")
chmod 644 "$S4/escapes.log" 2>/dev/null
[ -f "$R4/.v/artifacts/STOP_LIVELOCK_${SID4}.md" ] \
  && no "4 unreadable escapes.log still produced a marker (count cannot be trusted)" \
  || ok "4 unreadable escapes.log -> NO marker (fail-safe)"
{ [ "$rc4a" = "1" ] && [ "$rc4b" = "1" ] && [ "$rc4c" = "1" ] && [ "$rc4d" = "1" ]; } \
  && ok "4b rc UNCHANGED (1) with an unreadable escapes.log — no crash" \
  || no "4b rc changed with unreadable log: $rc4a/$rc4b/$rc4c/$rc4d"

# ── 5. no git work tree (_sr_root empty) -> no crash, no marker ─────────────────────────
SID5="88880000-1111-4111-8111-000000000005"
S5="$TD/state5"; N5="$TD/nogit"; mkdir -p "$N5"
rc5=""
for i in 1 2 3 4; do rc5=$(one_escape "$LIB" "$S5" "$N5" "$SID5" "no-git probe"); done
[ "$rc5" = "1" ] && ok "5 outside a git work tree: rc still 1, no crash" || no "5 rc was '$rc5' outside a git tree"
find "$N5" -name 'STOP_LIVELOCK_*' 2>/dev/null | grep -q . \
  && no "5b a marker was written outside a git work tree" \
  || ok "5b no marker written when _sr_root cannot resolve (SREV-004 posture kept)"
find "$HOME/.claude" -maxdepth 2 -name "STOP_LIVELOCK_${SID5}.md" 2>/dev/null | grep -q . \
  && no "5c marker leaked into \$HOME/.claude when not in a work tree" \
  || ok "5c nothing leaked into \$HOME (never falls back to \$HOME)"

# ── 6. LIVE-FIRE REPLAY of the real escape-loop evidence ───────────────────────────────
# Seed the fixture with the session's REAL escape rows for that fingerprint (re-keyed to a test
# SID), leaving it one short of the threshold, then drive one more escape and require the marker.
SID6="88880000-1111-4111-8111-000000000006"
S6="$TD/state6"; R6="$TD/repo6"; mkrepo "$R6"; mkdir -p "$S6"; : > "$TD/err.txt"
if [ -f "$REAL_LOG" ]; then
  REAL_MSG="a replayed production block message"
  # Compute the fingerprint this lib assigns to REAL_MSG, then re-key 2 real rows onto it.
  FP6=$(bash -c '. "'"$LIB"'"; _rearm_fp "'"$REAL_MSG"'"')
  n_real=$(grep -c "fp=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$REAL_LOG" 2>/dev/null || true)
  case "$n_real" in (''|*[!0-9]*) n_real=0 ;; esac
  [ "$n_real" -ge 13 ] && ok "6a real evidence present: $n_real escapes on fp deadbeef… in the live escapes.log" \
                       || no "6a expected >=13 real rows for fp deadbeef…, found $n_real"
  grep "fp=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$REAL_LOG" 2>/dev/null \
    | head -2 \
    | sed -e "s/5e55a000-0000-4000-8000-000000000001/${SID6}/" \
          -e "s/fp=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/fp=${FP6}/" \
    > "$S6/escapes.log"
  seeded=$(grep -c . "$S6/escapes.log" || true)
  [ "${seeded:-0}" = "2" ] && ok "6b replayed 2 real escape rows into the fixture (one short of the threshold)" \
                           || no "6b seeded $seeded rows, expected 2"
  [ -f "$R6/.v/artifacts/STOP_LIVELOCK_${SID6}.md" ] && no "6c marker existed before the 3rd escape" \
                                                     || ok "6c no marker yet at 2 replayed escapes"
  rc6=$(one_escape "$LIB" "$S6" "$R6" "$SID6" "$REAL_MSG")
  [ -f "$R6/.v/artifacts/STOP_LIVELOCK_${SID6}.md" ] \
    && ok "6d REPLAY: the 3rd escape on the real repeating fingerprint FIRES the marker" \
    || no "6d REPLAY: marker did not fire on the 3rd escape of the real pattern"
  [ "$rc6" = "1" ] && ok "6e REPLAY: rc still 1 (stop still allowed — no infinite block)" || no "6e REPLAY rc was '$rc6'"
  grep -q 'Escapes on THIS fingerprint: 3' "$R6/.v/artifacts/STOP_LIVELOCK_${SID6}.md" 2>/dev/null \
    && ok "6f REPLAY: marker counts the seeded rows + the current escape (3)" \
    || no "6f REPLAY: escape count wrong in the marker"
else
  skip "6 live-fire replay needs the owner's runtime escapes.log, which is not shipped ($REAL_LOG)"
fi

echo "== 7 :: marker lands in the CHECKOUT root when the Stop cwd is a SUBDIRECTORY (F8-ROOT) =="
# `git rev-parse --git-common-dir` is RELATIVE TO CWD ("../../.git" from two levels down). The
# pre-fix code prefixed the TOPLEVEL instead, aiming the marker at the checkout's parent —
# production: STOP_REARM_ESCAPE files landed in the user-home and parent-directory .v/artifacts, and a cohort
# session (cwd a subdirectory of a project) escaped 4x with no marker at all.
SID7="88880000-1111-4111-8111-000000000007"
S7="$TD/state7"; R7="$TD/parent7/repo7"; mkrepo "$R7"; mkdir -p "$R7/sub/dir"
rc7a=$(one_escape "$LIB" "$S7" "$R7/sub/dir" "$SID7" "$MSG")
rc7b=$(one_escape "$LIB" "$S7" "$R7/sub/dir" "$SID7" "$MSG")
rc7c=$(one_escape "$LIB" "$S7" "$R7/sub/dir" "$SID7" "$MSG")
[ -f "$R7/.v/artifacts/STOP_LIVELOCK_${SID7}.md" ] \
  && ok "7a subdir cwd: STOP_LIVELOCK marker written at the CHECKOUT root" \
  || no "7a subdir cwd: marker missing at $R7/.v/artifacts (relative git-common-dir mis-joined)"
[ -f "$R7/.v/artifacts/STOP_REARM_ESCAPE_${SID7}.md" ] \
  && ok "7b subdir cwd: STOP_REARM_ESCAPE file written at the CHECKOUT root" \
  || no "7b subdir cwd: escape file missing at the checkout root"
[ -e "$TD/parent7/.v" ] || [ -e "$R7/sub/.v" ] || [ -e "$R7/sub/dir/.v" ] \
  && no "7c subdir cwd: a .v/ was created OUTSIDE the checkout root (parent or subdir)" \
  || ok "7c subdir cwd: no stray .v/ in the parent or the subdirectory"
[ "$rc7a" = "1" ] && [ "$rc7b" = "1" ] && [ "$rc7c" = "1" ] && ok "7d rc contract intact from a subdir cwd" || no "7d rc contract broken from a subdir cwd: $rc7a $rc7b $rc7c"

echo; echo "TOTAL: $PASS passed, $FAIL failed, ${SKIP:-0} skipped"
[ "$FAIL" -eq 0 ] || exit 1
