#!/usr/bin/env bash
# item3-done-at-source-canonical-test.sh — DONE_AT_SOURCE canonical-path pinning (2026-07-05).
#
# Forensic class: DONE_AT_SOURCE (the per-iteration ledger's "which gate-summary produced this
# entry" field) recorded the raw, EPHEMERAL $SUMMARY_FILE path under $V_TMP_DIR — which resolves
# to a DIFFERENT physical directory per invocation for the SAME sid (worktree path, main root,
# dirty-tree cwd), so forensics comparing ledger entries across iterations saw the "source"
# scattered across as many as 6 directories even when every entry described the same logical
# gate-summary. Fix: DONE_AT_SOURCE now records the durable, worktree-invariant MAIN-root
# .v/artifacts copy path (_CANARY_ART) instead of the ephemeral $V_TMP_DIR one.
#
# Executes the block EXTRACTED VERBATIM from the production script. RED ORACLE: a pre-fix
# backup's block still references $SUMMARY_FILE directly (no _DONE_AT_SOURCE/_CANARY_ART
# indirection) -> the extracted text has no "_CANARY_ART" token -> test 1 fails.
set -u
SCRIPT="${V_RUN_GATES_OVERRIDE:-$HOME/.claude/skills/v/references/v-run-gates.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$SCRIPT" ] || { echo "NO v-run-gates.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

BLOCK="$(awk '/^# Item 3 \(2026-07-05\)/,/_P1C_ITER_LINE=/' "$SCRIPT")"

echo "== ITEM3 :: DONE_AT_SOURCE pinned to the canonical durable path, not the ephemeral one =="
if [ -z "$BLOCK" ] || ! printf '%s' "$BLOCK" | grep -q '_CANARY_ART'; then
  no "Item 3 DONE_AT_SOURCE canonicalization present in v-run-gates.sh" "awk range empty or no _CANARY_ART reference (pre-fix = RED)"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "Item 3 DONE_AT_SOURCE canonicalization present in v-run-gates.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

run_item3() { # $1=canary-art-set(yes|no) → echoes DONE_AT_SOURCE value
  local d="$WORK/r$RANDOM"; mkdir -p "$d/vtmp"
  (
    set +eu
    V_TMP_DIR="$d/vtmp"; SESSION_ID="item3-sid"; PFM=full; ALL_PASS=1; _GATE_SUFFIX=""
    SUMMARY_FILE="$d/vtmp/gate-summary-item3-sid.txt"
    if [ "$1" = "yes" ]; then
      _CANARY_ART="$d/durable/.v/artifacts"; mkdir -p "$_CANARY_ART"
    else
      _CANARY_ART=""
    fi
    eval "$BLOCK" 2>/dev/null
    printf '%s' "$_P1C_ITER_LINE" | sed -n 's/.*DONE_AT_SOURCE=//p'
  )
}

OUT="$(run_item3 yes)"
case "$OUT" in
  */durable/.v/artifacts/gate-summary-item3-sid.txt)
    ok "durable _CANARY_ART path used for DONE_AT_SOURCE when resolvable (worktree-invariant)" ;;
  *)
    no "DONE_AT_SOURCE did not use the durable canonical path" "$OUT" ;;
esac

OUT="$(run_item3 no)"
case "$OUT" in
  */vtmp/gate-summary-item3-sid.txt)
    ok "falls back to ephemeral SUMMARY_FILE only when no durable path is resolvable" ;;
  *)
    no "fallback path broken when _CANARY_ART unresolvable" "$OUT" ;;
esac

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
