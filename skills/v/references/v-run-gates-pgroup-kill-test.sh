#!/usr/bin/env bash
# v-run-gates-pgroup-kill-test.sh — V-5 (2026-07-06 pack-runner forensics).
#
# THE CLASS: v-run-gates.sh's bash-native timeout killer TERM'd only the wrapper subshell pid.
# The inner `bash "$0"` helper and its gate children (pest/paratest workers, vitest, npm) were NOT
# in the blast radius — they outlived the "timeout" and kept writing gate-*.log (observed live: a
# pest child wrote its log long past DETECTION_ERROR=gate_timeout_480s, past the session's own
# runner-kill, leaving artifacts that contradicted the already-written PRE_FLIGHT_REPORT).
# THE FIX: spawn the helper as its own process-group leader (momentary `set -m`) and signal the
# NEGATIVE pgid, so every descendant dies with the timeout.
#
# Two layers here:
#   1. WIRING — the shipped script carries the pgroup spawn + negative-pgid kill (fails on pre-fix).
#   2. MECHANISM — a live simulation proving (a) a plain-pid TERM leaves a grandchild running (the
#      pre-fix failure mode, red-by-construction) and (b) the pgroup TERM kills the whole tree.
# Re-run: bash <thisfile>
set -u
REF_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${V_RUN_GATES_SRC_OVERRIDE:-$REF_DIR/v-run-gates.sh}"
[ -f "$SRC" ] || { echo "SKIP: v-run-gates.sh missing"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }

echo "== v-run-gates.sh :: V-5 timeout must kill the whole gate process GROUP =="

echo "── 1. wiring: shipped script spawns the helper as a pgroup leader and kills the negative pgid ──"
grep -q 'set -m' "$SRC" && ok "momentary job-control (set -m) spawn present" || no "set -m spawn missing (helper not a pgroup leader)"
grep -qE 'kill -TERM -- "-\$_gate_pid"' "$SRC" && ok "graceful kill targets the negative pgid" || no "TERM still targets only the wrapper pid"
grep -qE 'kill -KILL -- "-\$_gate_pid"' "$SRC" && ok "hard kill targets the negative pgid" || no "KILL still targets only the wrapper pid"

echo "── 2. mechanism: pgroup TERM reaps the grandchild a plain-pid TERM leaves running ──"
T="$(mktemp -d)"
_G1=""; _G2=""
cleanup(){ kill -KILL "$_G1" "$_G2" 2>/dev/null; rm -rf "$T" 2>/dev/null; }
trap cleanup EXIT
# tree: wrapper subshell -> child bash (exec'd into a long sleep; stands in for a pest worker).
# IMPORTANT: not spawned inside $() — a background job inheriting a command substitution's stdout
# holds the substitution open until the whole tree exits (the exact hang a first cut of this test hit).
spawn_tree(){ # $1=child-pid marker  $2=wrapper-pid marker
  set -m 2>/dev/null || true
  # trailing `:` stops bash exec-optimizing the single-command subshell (which would collapse the
  # wrapper and child into ONE pid and make the plain-pid-TERM control vacuously reap the "child")
  ( bash -c "echo \$\$ > \"$1\"; exec sleep 300"; : ) >/dev/null 2>&1 &
  echo $! > "$2"
  set +m 2>/dev/null || true
}
# (a) pre-fix failure mode: plain-pid TERM on the wrapper — the child must SURVIVE (proves the red)
spawn_tree "$T/g1.pid" "$T/w1.pid"
for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/g1.pid" ] && break; sleep 0.3; done
G1="$(cat "$T/g1.pid" 2>/dev/null)"; W1="$(cat "$T/w1.pid" 2>/dev/null)"; _G1="$G1"
kill -TERM "$W1" 2>/dev/null; sleep 1
if [ -n "$G1" ] && kill -0 "$G1" 2>/dev/null; then
  ok "plain-pid TERM leaves the child alive (the pre-fix orphan class is REAL)"
else
  no "plain-pid TERM unexpectedly reaped the child — mechanism fixture invalid" "g1=$G1"
fi
kill -KILL "$G1" 2>/dev/null || true
# (b) the fix: negative-pgid TERM — the child must DIE with the group
spawn_tree "$T/g2.pid" "$T/w2.pid"
for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/g2.pid" ] && break; sleep 0.3; done
G2="$(cat "$T/g2.pid" 2>/dev/null)"; W2="$(cat "$T/w2.pid" 2>/dev/null)"; _G2="$G2"
kill -TERM -- "-$W2" 2>/dev/null; sleep 1
if [ -n "$G2" ] && ! kill -0 "$G2" 2>/dev/null; then
  ok "negative-pgid TERM reaps the whole tree incl. the child"
else
  no "pgroup TERM did not reap the child" "g2=$G2 alive"
  kill -KILL "$G2" 2>/dev/null || true
fi

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
