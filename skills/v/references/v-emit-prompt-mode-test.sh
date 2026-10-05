#!/usr/bin/env bash
# v-emit-prompt-mode-test.sh
# Regression harness for W-perf3b: the PRE_FLIGHT_MODE (W16) decision must size itself from
# THIS session's writes-log when DIRTY_COUNT is not passed — instead of the old blind 999
# default that forced `full` on every bare `v-emit-prompt.sh v-pre-flight` dispatch.
#
# ROOT BUG (forensics: a production session, 2026-06-02): the QA-loop re-verify pre-flights
# were dispatched as bare `v-emit-prompt.sh v-pre-flight` (no WORKFLOW, no DIRTY_COUNT), so
# DC defaulted to 999 -> `*) DC>40` -> PRE_FLIGHT_MODE=full on EVERY iteration (3 full suites),
# then W16-2 ran the full suite a 4th time at completion. The fix derives DC from the
# SID-attributed writes-log; the authoritative full suite still runs at completion (no
# coverage loss). This harness runs the REAL emitter end-to-end and asserts the emitted mode.

EMIT="$HOME/.claude/skills/v/references/v-emit-prompt.sh"
# F7 SCOPING (2026-08-29): this harness builds STACKLESS fixture repos (no package.json,
# composer.json, tsconfig, lockfile or vendor bin). v-emit-prompt.sh's F7 pre-dispatch stack gate
# correctly fires there and exits 10 with a DO-NOT-DISPATCH notice instead of a runner prompt —
# which is the intended production behavior, not a defect. This harness asserts MODE / RUN_ROOT
# SUBSTITUTION, a different concern that F7 short-circuits before reaching. Opt out via the gate's
# own documented switch so the assertions below keep testing exactly what they were written to test.
# F7's own behavior is covered by v-predispatch-stack-gate-test.sh (45 assertions).
export V_PREDISPATCH_STACK_GATE=0

TEST_UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
PASS=0; FAIL=0
_ok()   { printf '  ok  %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== v-emit-prompt :: W-perf3b PRE_FLIGHT_MODE from session writes-log =="

# _emit_mode <num_writes_files> <extra_export_string> -> echoes the resolved mode (scoped|full|dirty-tree|"")
_emit_mode() {
  local n="$1" extra="${2:-}"
  local repo gcd out i
  repo=$(mktemp -d)
  git init -q "$repo" >/dev/null 2>&1
  gcd=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)
  case "$gcd" in /*) ;; *) gcd="$repo/$gcd";; esac
  if [ "$n" -gt 0 ]; then
    : > "$gcd/claude-session-writes-$TEST_UUID.txt"
    mkdir -p "$repo/app/Svc"
    i=1; while [ "$i" -le "$n" ]; do
      printf 'app/Svc/File%s.php\n' "$i" >> "$gcd/claude-session-writes-$TEST_UUID.txt"
      # W5G-5/M-3 (v-emit-prompt.sh, 2026-06-07, added AFTER this harness): a scoped pre-flight over
      # session-written files that are ALL git-clean tests nothing, so v-emit-prompt escalates scoped->full.
      # The scoped-path cases must therefore make the session-written files actually DIRTY (untracked here,
      # which `git status --porcelain -- <file>` reports as `??`) — else they correctly resolve to 'full'.
      printf '<?php // wip %s\n' "$i" > "$repo/app/Svc/File$i.php"
      i=$((i+1));
    done
  fi
  mkdir -p "$repo/.v/tmp"
  out=$(
    cd "$repo" || exit 1
    unset DIRTY_COUNT MODE WORKFLOW V_W16_DC_FROM_WRITESLOG PARALLEL_SESSIONS_DETECTED
    export CLAUDE_SESSION_ID="$TEST_UUID" SESSION_ID="$TEST_UUID" PROJECT_ROOT="$repo" \
           CLAUDE_SKILL_DIR="$HOME/.claude/skills/v" V_TMP_DIR="$repo/.v/tmp"
    [ -n "$extra" ] && eval "$extra"
    bash "$EMIT" v-pre-flight 2>/dev/null
  )
  rm -rf "$repo" 2>/dev/null || true
  printf '%s\n' "$out" | grep -oE 'PRE_FLIGHT_MODE=[a-z-]+' | head -1 | cut -d= -f2
}

_check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then _ok "$1 -> $3"; else _fail "$1 (want '$2', got '${3:-<empty/emit-failed>}')"; fi
}

_check "C1 small footprint (3 files), no DIRTY_COUNT -> scoped"        scoped "$(_emit_mode 3)"
_check "C2 large footprint (60 files), no DIRTY_COUNT -> full"          full   "$(_emit_mode 60)"
_check "C3 no writes-log at all -> conservative full"                  full   "$(_emit_mode 0)"
_check "C4 explicit DIRTY_COUNT=2 wins over a 60-file log -> scoped"   scoped "$(_emit_mode 60 'export DIRTY_COUNT=2')"
_check "C5 explicit MODE=full short-circuits -> full"                  full   "$(_emit_mode 3 'export MODE=full')"
_check "C6 kill-switch V_W16_DC_FROM_WRITESLOG=0 + 3 files -> full"    full   "$(_emit_mode 3 'export V_W16_DC_FROM_WRITESLOG=0')"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
