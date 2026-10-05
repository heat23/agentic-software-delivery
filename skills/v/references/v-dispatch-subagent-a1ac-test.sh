#!/usr/bin/env bash
# v-dispatch-subagent-a1ac-test.sh — bite for A-1a/c (2026-07-02).
#
# A-1a: DISPATCH_PROVENANCE_<sid>.log must be written to the MAIN checkout's `.v/artifacts/`, never
# `dirname "$ARTIFACT"` (worktree-local whenever the caller's artifact path is inside a linked
# worktree — the "worktree split-brain" that made a real session's dispatches invisible to a
# forensic grep of the main repo tree even though they were faithfully recorded, just in the wrong
# place). Extracts the REAL PROV_LOG-resolution logic from the shipped script (via the shared
# git-main-root.sh helper) so this can't drift from what actually runs.
#
# A-1c: on a TIMEOUT (rc 124) specifically, if `gate-summary-<sid>.txt` shows `DONE_AT` within the
# dispatch window, the provenance status must be `ok_late`, not a flat `error` — the underlying gate
# work legitimately completed; only the wrapper's own JSON-formatting/teardown overran the ceiling.
# A genuine non-timeout failure (rc=5, no gate-summary, or a stale/out-of-window gate-summary) must
# still record `status=error` — ok_late must never mask a real failure.
set -u
SRC="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
GMR="$HOME/.claude/hooks/lib/git-main-root.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$SRC" ] || { echo "NO v-dispatch-subagent.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }

echo "== A-1a :: DISPATCH_PROVENANCE resolves to the MAIN checkout, not a worktree-local dir =="

# Extract the REAL _check_ok_late() function so it can't drift from what ships.
FN=$(mktemp)
awk '/^_check_ok_late\(\) \{/{inf=1} inf{print} inf&&/^\}/{exit}' "$SRC" > "$FN"
if ! grep -q '_check_ok_late()' "$FN"; then
  no "could not extract _check_ok_late from $SRC"
else
  ok "extracted _check_ok_late() from the shipped script"
fi
# shellcheck source=/dev/null
source "$FN"

# A-1a: verify PROV_LOG resolution logic by extracting the actual block and running it against a
# synthetic worktree + main checkout, mirroring the external-worktree convention.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
MAIN="$WORK/main"; mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@example.com; git -C "$MAIN" config user.name t
: > "$MAIN/.gitkeep"; git -C "$MAIN" add -A; git -C "$MAIN" commit -qm init
WT="$WORK/wt-external/fix-slug-a1atest"
mkdir -p "$WORK/wt-external"
git -C "$MAIN" worktree add -q -b fix/slug-a1atest "$WT" >/dev/null 2>&1

# Simulate the script's resolution block directly (same helper, same call shape as the source).
ART_DIR="$WT"
if [ -f "$GMR" ]; then
  # shellcheck source=/dev/null
  source "$GMR"
  PROV_MAIN_ROOT="$(resolve_main_root "$ART_DIR" 2>/dev/null || true)"
fi
MAIN_CANON="$(cd "$MAIN" && pwd -P)"
if [ "$PROV_MAIN_ROOT" = "$MAIN_CANON" ]; then
  ok "resolve_main_root(worktree) == the true MAIN checkout (not the worktree itself)"
else
  no "PROV_MAIN_ROOT resolution wrong" "got=$PROV_MAIN_ROOT want=$MAIN_CANON"
fi

# Wiring check: the script itself must actually CALL resolve_main_root and source git-main-root.sh
# (not just have it available) — pins that the fix is wired, not just possible.
if grep -q 'source "\$_GMR_LIB"' "$SRC" && grep -q 'resolve_main_root "\$ART_DIR"' "$SRC"; then
  ok "v-dispatch-subagent.sh actually sources git-main-root.sh and calls resolve_main_root (wired, not just possible)"
else
  no "v-dispatch-subagent.sh does not call resolve_main_root on ART_DIR — PROV_LOG fix not wired"
fi

echo
echo "== A-1c :: ok_late honesty on a timeout-race, never on a genuine failure =="

SID="a1ctest1-a1c1-a1c1-a1c1-a1c1a1c1a1c1"
VT="$WORK/vtmp"; mkdir -p "$VT"

# GREEN-1: DONE_AT within the dispatch window -> ok_late (true positive).
DISPATCH_START=$(date -u +%s)
sleep 1
printf 'DONE_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$VT/gate-summary-${SID}.txt"
if _check_ok_late "$DISPATCH_START" "$SID" "$VT"; then
  ok "DONE_AT within the dispatch window -> ok_late fires (true positive)"
else
  no "DONE_AT within window did NOT fire ok_late"
fi

# GREEN-2: no gate-summary file at all -> NOT ok_late (a genuine failure, no evidence of completion).
SID2="a1ctest2-a1c2-a1c2-a1c2-a1c2a1c2a1c2"
if _check_ok_late "$DISPATCH_START" "$SID2" "$VT"; then
  no "missing gate-summary wrongly triggered ok_late (would mask a real failure)"
else
  ok "no gate-summary file -> ok_late does NOT fire (real failures stay 'error')"
fi

# GREEN-3: STALE gate-summary (DONE_AT BEFORE this dispatch started, e.g. left over from a prior
# retry attempt) -> NOT ok_late (must not credit an earlier attempt's completion to this dispatch).
SID3="a1ctest3-a1c3-a1c3-a1c3-a1c3a1c3a1c3"
STALE_START=$(date -u +%s)
sleep 1
printf 'DONE_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$VT/gate-summary-${SID3}.txt"
sleep 1
LATER_START=$(date -u +%s)
if _check_ok_late "$LATER_START" "$SID3" "$VT"; then
  no "stale (pre-dispatch) gate-summary wrongly triggered ok_late"
else
  ok "stale gate-summary (DONE_AT before dispatch start) -> ok_late does NOT fire"
fi

# GREEN-4 (codex CDX-1 2026-07-02): a gate-summary carrying DETECTION_ERROR= (v-run-gates.sh writes
# DONE_AT even on its OWN internal gate_timeout_* summary, and on pest_worker_crash_or_oom) is a
# NON-completed / non-authoritative run — it must NEVER be salvaged as ok_late, even with a fresh
# in-window DONE_AT.
SID4="a1ctest4-a1c4-a1c4-a1c4-a1c4a1c4a1c4"
{
  printf 'DETECTION_ERROR=gate_timeout_900s\n'
  printf 'REMEDIATION=gates exceeded budget\n'
  printf 'DONE_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$VT/gate-summary-${SID4}.txt"
if _check_ok_late "$DISPATCH_START" "$SID4" "$VT"; then
  no "DETECTION_ERROR summary (internal gate timeout) wrongly salvaged as ok_late"
else
  ok "DETECTION_ERROR summary with fresh DONE_AT -> ok_late does NOT fire (non-completed run stays 'error')"
fi

# Wiring check: the error-handling branch must gate ok_late on rc==124 specifically (never on a
# generic non-zero rc, which would risk masking a genuine deterministic failure as ok_late).
if grep -q '\[ "\$RC" -eq 124 \] && _check_ok_late' "$SRC"; then
  ok "ok_late check is gated on rc==124 (timeout only), not any non-zero rc"
else
  no "ok_late check is not properly scoped to rc==124 — could mask non-timeout failures"
fi

# Wiring check: emit_marker must actually be called with the literal 'ok_late' status string.
if grep -q 'emit_marker ok_late' "$SRC"; then
  ok "emit_marker ok_late is wired into the error-handling branch"
else
  no "emit_marker ok_late not found — provenance status fix not wired"
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
