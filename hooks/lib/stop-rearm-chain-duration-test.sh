#!/usr/bin/env bash
# stop-rearm-chain-duration-test.sh
# Version: 1.0.0 (W-CHAIN-S, 2026-08-10)
#
# Guards the chain-duration field added to rearm_gate's escape record.
#
# WHY THIS EXISTS. The 2026-08-09 attest-enumeration fix predicted escapes would fall. They did
# not (the daily rate rose, dominated by one pathological session). Measured from escapes.log:
# every post-change escape fired on same>MAX_SAME and most were exactly same=3,total=3 — the
# entire chain was three identical blocks. What is NOT recorded is
# how long that chain took, which is the difference between "stuck" and "waiting on in-flight
# dispatches". chain_s records it. It is OBSERVATIONAL — nothing gates on it.
#
# WHAT MAKES THIS HARNESS NECESSARY RATHER THAN NICE. A four-reviewer panel found that the naive
# implementation SILENTLY OPENS THE STOP GATE:
#   * an invalid token in $(( )) is FATAL to bash (verified on system bash 3.2.57), and
#     `2>/dev/null || true` does NOT rescue it — it is not a `set -e` effect;
#   * inside this sourced function that abort makes rearm_gate return 1;
#   * rc=1 is the CALLER'S CONTRACT for "DEADLOCK ESCAPE, ALLOW THE STOP"
#     (check-review-artifact.sh:162-167 does `return $?`);
#   * so a malformed epoch allows the stop with NO escapes.log line, NO artifact, NO stderr —
#     strictly worse than an escape and the exact silent-bypass shape W5G-1 exists to prevent.
# T4 is the regression guard for precisely that. Treat any T4 failure as a security regression.
#
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail
LIB="${LIB_UNDER_TEST:-$HOME/.claude/hooks/lib/stop-rearm.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skip(){ printf '  skip %s — %s\n' "$1" "${2:-}"; }   # pre-fix backups are not shipped in the public snapshot
[ -r "$LIB" ] || { echo "FAIL: lib missing at $LIB"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
export CLAUDE_STOP_REARM_DIR="$WORK/state"
mkdir -p "$CLAUDE_STOP_REARM_DIR"
# shellcheck disable=SC1090
. "$LIB"

echo "== W-CHAIN-S :: chain duration recorded at the escape site =="

esc_line(){ tail -1 "$CLAUDE_STOP_REARM_DIR/escapes.log" 2>/dev/null; }
chain_of(){ printf '%s' "$1" | grep -oE 'chain_s=[^|]*' | cut -d= -f2; }
reset(){ rm -rf "$CLAUDE_STOP_REARM_DIR"; mkdir -p "$CLAUDE_STOP_REARM_DIR"; }

# Drive a chain to escape. $1=hook $2=sid $3=sleep-before-final-block
drive(){ local h="$1" s="$2" nap="${3:-0}"
  rearm_init "$h" "$s" "false"
  rearm_gate "$h" "$s" "false" "same violation" >/dev/null 2>&1
  rearm_gate "$h" "$s" "true"  "same violation" >/dev/null 2>&1
  [ "$nap" -gt 0 ] 2>/dev/null && sleep "$nap"
  rearm_gate "$h" "$s" "true"  "same violation" >/dev/null 2>&1
  rearm_gate "$h" "$s" "true"  "same violation" >/dev/null 2>&1
}

# --- T1: chain_s present AND in a plausible range (a chain_s=0-always mutant must fail) --------
reset; drive chainA 11111111-aaaa-4aaa-8aaa-111111111111 2
L="$(esc_line)"; C="$(chain_of "$L")"
if printf '%s' "$C" | grep -qE '^[0-9]+$' && [ "${C:-0}" -ge 1 ] && [ "${C:-0}" -le 30 ]; then
  ok "T1 chain_s present and in range (=$C s after a 2s chain)"
else
  no "T1 chain_s absent or implausible" "got chain_s='$C' from: $L"
fi

# --- T2: duration tracks REAL time, not the block counters ------------------------------------
# Two chains with IDENTICAL same/total; one has a 5s pause. A mutant deriving chain_s from
# same/total gives both the same value — T1 alone would not catch that.
reset; drive fastC 22222222-bbbb-4bbb-8bbb-222222222222 0
A="$(chain_of "$(esc_line)")"
reset; drive slowC 33333333-cccc-4ccc-8ccc-333333333333 5
B="$(chain_of "$(esc_line)")"
if printf '%s%s' "$A" "$B" | grep -qE '^[0-9]+$' && [ $(( B - A )) -ge 4 ]; then
  ok "T2 duration tracks wall-clock, not counters (fast=${A}s slow=${B}s, delta=$(( B - A ))s)"
else
  no "T2 duration did not track wall-clock" "fast='$A' slow='$B' — a counter-derived mutant would tie"
fi

# --- T3: LEGACY 3-line state file => n/a, NOT a small number -----------------------------------
# Real 3-line files existed in runtime/stop-rearm/ when this shipped. Stamping `now` for them
# would report ~0s for a chain that may have been running for minutes.
reset
SID=44444444-dddd-4ddd-8ddd-444444444444
SF="$(rearm_state_file legacyC "$SID")"
FP="$(printf '%s' "same violation" | shasum -a 256 | awk '{print $1}')"
printf '%s\n%s\n%s\n' "$FP" 2 2 > "$SF"          # exact pre-upgrade production format
sleep 1
rearm_gate legacyC "$SID" "true" "same violation" >/dev/null 2>&1
C3="$(chain_of "$(esc_line)")"
if [ "$C3" = "n/a" ]; then
  ok "T3 legacy 3-line state => chain_s=n/a (did not fabricate a start)"
else
  no "T3 legacy file fabricated a duration" "expected n/a, got '$C3'"
fi

# --- T4: garbage 4th line must NOT abort arithmetic or perturb the return code -----------------
# This is the security-critical case: an abort here returns rc=1, which the caller reads as
# "deadlock escape -> allow the stop".
# NOTE ON THIS TEST'S OWN FIRST VERSION (kept as a warning): it called rearm_gate bare under
# `set -e` and asserted a sentinel printed afterwards. That cannot work — `set -e` kills the
# script on a LEGITIMATE rc=1 escape too, so the sentinel is absent whether or not an abort
# happened, and every case "failed". Capture rc with `|| rc=$?` (which set -e does not trap) and
# detect an abort by its bash DIAGNOSTIC on stderr, which a clean escape never emits.
for GARBAGE in 'not-a-number' '1e10' '99999999999999999999999999' '' '-5'; do
  reset
  SID=55555555-eeee-4eee-8eee-555555555555
  SF="$(rearm_state_file garbC "$SID")"
  printf '%s\n%s\n%s\n%s\n' "$FP" 2 2 "$GARBAGE" > "$SF"
  ERR="$WORK/err.$$"
  OUT=$(/bin/bash -c '
    set -euo pipefail
    export CLAUDE_STOP_REARM_DIR="'"$CLAUDE_STOP_REARM_DIR"'"
    . "'"$LIB"'"
    rc=0
    rearm_gate garbC "'"$SID"'" "true" "same violation" >/dev/null 2>"'"$ERR"'" || rc=$?
    echo "SENTINEL_rc=$rc"
  ' 2>&1)
  # `grep -c` already prints 0 and exits 1 on no-match; `|| echo 0` would append a SECOND line,
  # producing "0\n0" and an "integer expected" error in the test below. Use `|| true`.
  ARITH_ERR=$(grep -cE 'value too great|syntax error|error token' "$ERR" 2>/dev/null || true)
  ARITH_ERR=${ARITH_ERR:-0}
  if printf '%s' "$OUT" | grep -q 'SENTINEL_rc=' && [ "${ARITH_ERR:-0}" -eq 0 ]; then
    ok "T4 garbage 4th line [${GARBAGE:-<empty>}] — no arithmetic abort ($(printf '%s' "$OUT" | grep -o 'SENTINEL_rc=[0-9]*'))"
  else
    no "T4 garbage 4th line [${GARBAGE:-<empty>}] ABORTED" "SILENT GATE BYPASS. arith_err=$ARITH_ERR out=$OUT stderr=$(head -2 "$ERR" 2>/dev/null)"
  fi
  rm -f "$ERR"
done

# --- T5: write field order pinned (an epoch in the total slot falsely trips the escape) --------
reset; drive orderC 66666666-ffff-4fff-8fff-666666666666 0
SF="$(rearm_state_file orderC 66666666-ffff-4fff-8fff-666666666666)"
if [ -f "$SF" ]; then
  L3=$(sed -n '3p' "$SF"); L4=$(sed -n '4p' "$SF")
  # line 3 = a small block counter; line 4 = a unix epoch (>= 2024-01-01).
  if printf '%s' "$L3" | grep -qE '^[0-9]{1,3}$' && printf '%s' "$L4" | grep -qE '^[0-9]{10,}$' && [ "$L4" -ge 1704067200 ]; then
    ok "T5 field order pinned (line3=$L3 counter, line4=$L4 epoch)"
  else
    no "T5 field order looks TRANSPOSED" "line3='$L3' line4='$L4' — an epoch in the total slot trips a false escape"
  fi
else
  # escape path unlinks the state file; re-derive from a non-escaping chain instead
  reset
  rearm_init orderD 77777777-1111-4111-8111-777777777777 "false"
  rearm_gate orderD 77777777-1111-4111-8111-777777777777 "false" "v" >/dev/null 2>&1
  SF="$(rearm_state_file orderD 77777777-1111-4111-8111-777777777777)"
  L3=$(sed -n '3p' "$SF"); L4=$(sed -n '4p' "$SF")
  if printf '%s' "$L3" | grep -qE '^[0-9]{1,3}$' && printf '%s' "$L4" | grep -qE '^[0-9]{10,}$'; then
    ok "T5 field order pinned (line3=$L3 counter, line4=$L4 epoch)"
  else
    no "T5 field order looks TRANSPOSED" "line3='$L3' line4='$L4'"
  fi
fi

# --- T6: the escape DECISION is byte-identical to the PRE-CHANGE library -----------------------
# Do NOT hand-assert an expected rc sequence — the first version of this test asserted 0,0,0,1
# from my own reasoning and was simply wrong (the real sequence is 0,0,1,0: escape fires on the
# THIRD call, and the escape unlinks the state file so the fourth starts a fresh chain). An
# expectation I derive by reading the code proves nothing about whether I CHANGED it. Diff the
# live library against the pre-change sidecar instead: that is the actual regression question.
OLD_LIB="$HOME/.claude/hooks/lib/stop-rearm.sh.pre-chains-bak"
seq_for(){ # $1 = library path -> comma-joined rc sequence over a 6-block chain
  /bin/bash -c '
    export CLAUDE_STOP_REARM_DIR=$(mktemp -d)
    . "'"$1"'"
    S=88888888-2222-4222-8222-888888888888
    rearm_init sanC "$S" false
    for i in 1 2 3 4 5 6; do
      a=false; [ $i -gt 1 ] && a=true
      r=0; rearm_gate sanC "$S" "$a" "v" >/dev/null 2>&1 || r=$?
      printf "%s," "$r"
    done' 2>/dev/null
}
if [ -r "$OLD_LIB" ]; then
  NEWSEQ="$(seq_for "$LIB")"; OLDSEQ="$(seq_for "$OLD_LIB")"
  if [ -n "$OLDSEQ" ] && [ "$NEWSEQ" = "$OLDSEQ" ]; then
    ok "T6 escape timing IDENTICAL to pre-change lib (rc sequence $NEWSEQ)"
  else
    no "T6 ESCAPE TIMING CHANGED" "new=[$NEWSEQ] old=[$OLDSEQ]"
  fi
  # Mutation check: the comparison must be capable of failing. A lib with MAX_SAME raised
  # must produce a DIFFERENT sequence; if it does not, T6 is vacuous.
  MUT="$WORK/mutant.sh"; sed 's/^_REARM_MAX_SAME=.*/_REARM_MAX_SAME=5/' "$LIB" > "$MUT"
  MUTSEQ="$(STOP_REARM_MAX_SAME=5 seq_for "$MUT")"
  if [ "$MUTSEQ" != "$NEWSEQ" ]; then
    ok "T6 mutation check: a changed escape threshold DOES alter the sequence ($MUTSEQ)"
  else
    no "T6 mutation check FAILED — comparison is vacuous" "mutant produced the same sequence $MUTSEQ"
  fi
else
  skip "T6 RED comparison" "pre-change sidecar not shipped ($OLD_LIB)"
fi

# --- T7: W-ESCAPE-COUNT — the artifact must state its own lossiness --------------------------
# STOP_REARM_ESCAPE_<sid>.md is written with a truncating `>`: ONE file per SID, overwritten every
# escape. That is deliberate (marker-reconcile.sh ages these files; v-drain-deferred-merges.sh does
# a per-SID `[ -f ]` check — both want exactly one). But it makes the file a LOSSY frequency signal:
# one production session had many escapes.log lines and 1 file on disk, and the 2026-08-10 audit
# itself reported far fewer escapes than the log showed — a ~10x undercount. The artifact must therefore carry
# its true ordinal and name the authoritative source.
reset
W7="$WORK/repo7"; mkdir -p "$W7"
( cd "$W7" && git init -q . && git config user.email t@t && git config user.name t \
  && echo seed > README.md && git add -A && git commit -qm seed ) >/dev/null 2>&1
SID7=aaaabbbb-cccc-4ddd-8eee-ffff11112222
for round in 1 2 3; do
  ( cd "$W7" && rearm_init t7 "$SID7" false \
    && rearm_gate t7 "$SID7" false "violation $round" \
    && rearm_gate t7 "$SID7" true  "violation $round" \
    && rearm_gate t7 "$SID7" true  "violation $round" ) >/dev/null 2>&1
done
ART="$W7/.v/artifacts/STOP_REARM_ESCAPE_${SID7}.md"
LOGN=$(grep -c "|$SID7|" "$CLAUDE_STOP_REARM_DIR/escapes.log" 2>/dev/null || true)
NFILES=$(find "$W7/.v/artifacts" -name "STOP_REARM_ESCAPE_${SID7}.md" 2>/dev/null | wc -l | tr -d ' ')
if [ -f "$ART" ]; then
  ORD=$(grep -aoE 'Escape #[0-9]+' "$ART" | grep -oE '[0-9]+' | head -1)
  # The ordinal must equal the LOG count, not the FILE count — that is the whole point.
  if [ "${ORD:-0}" = "${LOGN:-x}" ] && [ "$NFILES" = "1" ] && [ "$LOGN" -gt 1 ]; then
    ok "T7 artifact states its true ordinal (#$ORD) while only $NFILES file exists for $LOGN escapes"
  else
    no "T7 ordinal wrong or lossiness not represented" "ordinal='$ORD' log_lines='$LOGN' files='$NFILES'"
  fi
  if grep -aq 'do NOT count these files' "$ART" && grep -aq 'escapes.log' "$ART"; then
    ok "T7 artifact warns against file-counting and names the authoritative source"
  else
    no "T7 artifact does not warn about its own lossiness" "$(grep -a 'Escape #' "$ART" | head -1)"
  fi
else
  no "T7 no escape artifact written" "expected $ART"
fi
# Mutation check: an ordinal hardcoded to 1 (or derived from the file count) must FAIL the
# equality above. Prove the assertion can distinguish log-count from file-count.
if [ "${LOGN:-0}" -gt 1 ] && [ "${ORD:-0}" != "1" ]; then
  ok "T7 mutation check: ordinal tracks the LOG ($LOGN), not the file count (1)"
else
  no "T7 mutation check FAILED — ordinal is indistinguishable from a file count" "ordinal='$ORD' log='$LOGN'"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
