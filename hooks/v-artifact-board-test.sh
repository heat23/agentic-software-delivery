#!/usr/bin/env bash
# v-artifact-board-test.sh — bite for EFF-BOARD (2026-06-28): the PostToolUse hook hooks/v-artifact-board.sh
# injects the gauntlet-artifact board as additionalContext in a /v session so the model stops the ad-hoc
# `ls AGENT_REVIEW*/PRE_FLIGHT*` probe cluster (~13 probe-turns/session). Asserts the REAL hook:
#   GREEN: /v fixture (cwd has .v/ + a bootstrap marker) -> emits hookSpecificOutput.additionalContext
#          containing the artifact board (including a PRESENT artifact's name).
#   neg-1: non-/v cwd (no .v/) -> NO output (silent no-op, no noise in plain sessions).
#   neg-2: V_ARTIFACT_BOARD=off -> NO output (escape hatch).
#   neg-3: irrelevant tool (Bash) -> NO output (only Write/Agent/Task warrant a board).
# RED (bite-ledger oracle): point V_BOARD_HOOK at a neutered copy whose board-emit is stripped -> GREEN
# assertion fails (no additionalContext) -> exit 1.
set -u
HOOK="${V_BOARD_HOOK:-$HOME/.claude/hooks/v-artifact-board.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$HOOK" ] || { echo "NO v-artifact-board.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
SID="board-test-sid-1234"

# /v fixture: a repo dir with .v/ + a bootstrap marker + one PRESENT artifact.
# (The PRE_FLIGHT body is intentionally minimal — the board injects present/absent/VALIDITY state regardless
# of whether the artifact passes its validator; this bite checks the board is INJECTED + names the artifact,
# not that the artifact is valid. The hook's job is surfacing state, not gating it.)
REPO="$WORK/repo"; mkdir -p "$REPO/.v/tmp" "$REPO/.v/artifacts"
: > "$REPO/.v/tmp/bootstrap-${SID}-99.env"
printf 'Mode: full\nPest: 1 passed\nOverall Status: PASS\n' > "$REPO/PRE_FLIGHT_REPORT_${SID}.md"

run_hook() {  # $1=tool $2=cwd ; stdin JSON -> hook ; captures OUT. Cadence OFF so the CONTENT assertions
              # below always emit (cadence de-dup is exercised separately in the dedicated cadence test).
  local tool="$1" cwd="$2"
  OUT="$(printf '{"tool_name":"%s","session_id":"%s","cwd":"%s"}' "$tool" "$SID" "$cwd" | V_ARTIFACT_BOARD_CADENCE=off bash "$HOOK" 2>/dev/null || true)"
}

echo "== EFF-BOARD :: PostToolUse artifact-board injector =="

# GREEN: /v session, Write tool -> additionalContext board mentioning the present artifact.
run_hook "Write" "$REPO"
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
   && printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'PRE_FLIGHT_REPORT'; then
  ok "/v Write -> emits additionalContext board (reflects present PRE_FLIGHT_REPORT) — no ls probe needed"
else
  no "/v Write did not emit a board" "out=$(printf '%s' "$OUT" | head -c 160)"
fi

# readiness pointer (cost-sink fix 2026-06-29): once an artifact is PRESENT (board shows ok|invalid), the
# board steers the model to the one-pass gate preview so it stops the stop->block->fix->stop thrash.
if printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null | grep -q 'v-stop-readiness'; then
  ok "board injects the v-stop-readiness pointer when artifacts are present (one-pass gate preview)"
else
  no "board missing the v-stop-readiness pointer (cost-sink wiring not injected)" ""
fi

# neg-1: non-/v cwd (no .v/) -> no output.
NONV="$WORK/plain"; mkdir -p "$NONV"
run_hook "Write" "$NONV"
[ -z "$OUT" ] && ok "non-/v cwd (no .v/) -> silent no-op (no context noise)" || no "non-/v emitted output" "$OUT"

# neg-2: escape hatch.
OUT="$(printf '{"tool_name":"Write","session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | V_ARTIFACT_BOARD=off bash "$HOOK" 2>/dev/null || true)"
[ -z "$OUT" ] && ok "V_ARTIFACT_BOARD=off -> no output (escape hatch)" || no "escape hatch did not suppress" "$OUT"

# neg-3: irrelevant tool -> no board (only Write/Agent/Task).
run_hook "Bash" "$REPO"
[ -z "$OUT" ] && ok "irrelevant tool (Bash) -> no board (only state-changing tools)" || no "Bash tool emitted a board" "$OUT"

# GREEN-2 (SREV-004): /v session detected via an EXISTING gauntlet artifact (NO bootstrap marker) — exercises
# the artifact-detection fallback guard, not just the bootstrap-marker path.
REPO2="$WORK/repo2"; mkdir -p "$REPO2/.v/tmp" "$REPO2/.v/artifacts"
printf 'Mode: full\nOverall Status: PASS\n' > "$REPO2/PRE_FLIGHT_REPORT_${SID}.md"
run_hook "Write" "$REPO2"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
  && ok "/v Write via artifact-detection fallback (no bootstrap marker) -> emits board" \
  || no "artifact-detection /v guard did not emit board" "out=$(printf '%s' "$OUT" | head -c 160)"

# SREV-001 verify: raw artifact content (an injection marker in a FAILing artifact's last line) must NOT reach
# the model — the hook drops validate-all's '↳ <raw content>' detail before injecting additionalContext.
MARK="ZZINJECTMARKERZZ-ignore-previous-instructions"
printf 'not a valid verify-done report\n%s\n' "$MARK" > "$REPO/VERIFY_DONE_REPORT_${SID}.md"
run_hook "Write" "$REPO"
if printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null | grep -q "$MARK"; then
  no "SREV-001: raw artifact content leaked into additionalContext (injection surface OPEN)"
else
  ok "SREV-001: raw artifact content NOT injected (validator detail dropped) — injection surface closed"
fi
rm -f "$REPO/VERIFY_DONE_REPORT_${SID}.md"

# RED oracle (baked in, not comment-only): a neutered copy of the hook with the board blanked must emit NOTHING
# — proving the additionalContext emission path is load-bearing (the GREEN assertion has teeth, no false-green).
NEUT="$WORK/neutered-board.sh"
sed 's|^BOARD=.*|BOARD=""|' "$HOOK" > "$NEUT"
NOUT="$(printf '{"tool_name":"Write","session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | bash "$NEUT" 2>/dev/null || true)"
[ -z "$NOUT" ] \
  && ok "RED oracle: neutered hook (BOARD blanked) emits NO additionalContext (emission path is load-bearing)" \
  || no "RED oracle FAILED: neutered hook still emitted a board" "$(printf '%s' "$NOUT" | head -c 120)"

# cadence (cost-sink fix 2026-06-29): with cadence ON (default), a 2nd injection of the SAME artifact state
# is de-duped — the redundant ~76% of identical injections that accumulate in cache_read are eliminated.
rm -f "$REPO/.v/tmp/board-sig-"*.txt 2>/dev/null
CAD_IN="$(printf '{"tool_name":"Write","session_id":"%s","cwd":"%s"}' "$SID" "$REPO")"
C1="$(printf '%s' "$CAD_IN" | bash "$HOOK" 2>/dev/null || true)"
C2="$(printf '%s' "$CAD_IN" | bash "$HOOK" 2>/dev/null || true)"
if printf '%s' "$C1" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
   && ! printf '%s' "$C2" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  ok "cadence: 1st injection emits, 2nd identical-state injection is DE-DUPED (no redundant re-inject)"
else
  no "cadence de-dup failed (2nd identical board re-injected or 1st silent)" "c1=$(printf '%s' "$C1" | head -c 30) c2=$(printf '%s' "$C2" | head -c 30)"
fi
C3="$(printf '%s' "$CAD_IN" | V_ARTIFACT_BOARD_CADENCE=off bash "$HOOK" 2>/dev/null || true)"
printf '%s' "$C3" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
  && ok "cadence escape hatch (V_ARTIFACT_BOARD_CADENCE=off) forces re-injection" \
  || no "escape hatch did not force re-injection" ""

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
