#!/usr/bin/env bash
# v-dispatch-subagent-timeout-test.sh
# Regression harness for the W-perf9b timeout CEILING in v-dispatch-subagent.sh.
#
# ROOT BUG (forensics: a production session, 2026-06-02): a FOREGROUND gate dispatch
# (`claude -p` QA review, run_in_background:false) overran the Bash tool's 10-min timeout,
# the runtime AUTO-BACKGROUNDED it, and the orchestrator went passive for over an hour.
# W-perf9 (block-v-polling.sh) only catches run_in_background:TRUE, so it could not see this.
# The fix: _run_bounded caps the child; an overrun self-terminates (rc 124) and the caller
# falls back instead of stranding.
#
# This harness EXTRACTS the real _run_bounded function from the shipped script (so it can't
# drift from what runs in production) and exercises it with `sleep` stand-ins for `claude`.

SRC="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
PASS=0; FAIL=0
_ok()   { printf '  ok  %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== v-dispatch-subagent :: W-perf9b timeout ceiling =="

# Extract the real _run_bounded() from the shipped script and source it.
FN=$(mktemp)
awk '/^_run_bounded\(\) \{/{inf=1} inf{print} inf&&/^\}/{exit}' "$SRC" > "$FN"
if ! grep -q '_run_bounded()' "$FN"; then
  _fail "could not extract _run_bounded from $SRC"
  echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
# shellcheck source=/dev/null
source "$FN"

_elapsed() { # run a command, echo "<rc> <elapsed_int_sec>"
  local start end rc
  start=$(date +%s)
  "$@"; rc=$?
  end=$(date +%s)
  echo "$rc $((end - start))"
}

# T1 — OVERRUN: a 20s child under a 2s ceiling must be KILLED ~promptly (not run 20s),
# and the rc normalized to 124 (timeout). This is the hour-long-stall class, in miniature.
read -r rc el < <(_elapsed _run_bounded 2 sleep 20)
if [ "$rc" = "124" ] && [ "$el" -lt 10 ]; then
  _ok "T1 overrun child killed at the ceiling (rc=$rc, ${el}s < 20s)"
else
  _fail "T1 overrun NOT bounded (rc=$rc, elapsed=${el}s — expected rc=124, <10s)"
fi

# T2 — HAPPY PATH: a fast child finishes naturally; rc + timing are unchanged by the wrapper.
read -r rc el < <(_elapsed _run_bounded 30 sleep 1)
if [ "$rc" = "0" ] && [ "$el" -lt 5 ]; then
  _ok "T2 fast child completes naturally (rc=$rc, ${el}s) — happy path unchanged"
else
  _fail "T2 fast child mishandled (rc=$rc, elapsed=${el}s — expected rc=0, <5s)"
fi

# T3 — EXIT CODE passthrough: a child that exits nonzero (not a timeout) keeps its own rc.
_run_bounded 30 bash -c 'exit 7'; rc=$?
[ "$rc" = "7" ] && _ok "T3 non-timeout exit code passes through (rc=7)" \
                || _fail "T3 exit code not preserved (rc=$rc — expected 7)"

# T4 — REDIRECT passthrough: caller-supplied stdout/stderr redirection reaches the child
# (the real call relies on this to capture claude's JSON on stdout and errors on stderr).
o=$(mktemp); e=$(mktemp)
_run_bounded 30 bash -c 'printf CAPTURED_OUT; printf CAPTURED_ERR >&2' > "$o" 2> "$e"; rc=$?
if [ "$rc" = "0" ] && grep -q CAPTURED_OUT "$o" && grep -q CAPTURED_ERR "$e"; then
  _ok "T4 stdout/stderr redirection passes through to the child"
else
  _fail "T4 redirection lost (rc=$rc out='$(cat "$o")' err='$(cat "$e")')"
fi

# T5 — NO LINGERING WATCHDOG: after a fast child, no orphan `sleep` watchdog should remain
# pinned to this shell (the kill+wait cleanup must cancel it). Best-effort, hermetic.
_run_bounded 45 sleep 1; rc=$?
sleep 1
if jobs -p 2>/dev/null | grep -q .; then
  _fail "T5 a background job lingered after _run_bounded returned"
else
  _ok "T5 no lingering watchdog/background job after completion"
fi

rm -f "$FN" "$o" "$e" 2>/dev/null || true
echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
