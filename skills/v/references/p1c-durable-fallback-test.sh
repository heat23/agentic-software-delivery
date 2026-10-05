#!/usr/bin/env bash
# p1c-durable-fallback-test.sh — Item 18 regression test (forensic 2026-07-03).
#
# Root-cause verified on disk: v-run-gates.sh's P1C-REVERIFY-SCOPE guard only ever consulted a
# SINGLE mutable per-SID file ($V_TMP_DIR/gate-summary-<sid>.txt) that is truncate-overwritten on
# every invocation — there is exactly ONE DONE_AT stamp alive at a time, not one per iteration.
# Worse, that file's path is derived from THIS invocation's own $V_TMP_DIR, which can resolve to a
# DIFFERENT directory across iterations of the same SID (worktree torn down/recreated between
# remediation-loop passes) — so a genuinely-completed iteration 1 was invisible to iteration 2's
# check, and the full-mode dispatch never downgraded (the "zero live firings" + storm-recurrence
# symptom). The fix adds a durable fallback (the resolved MAIN root's .v/artifacts copy — the SAME
# location CANARY-A already uses for the summary file itself) AND an append-only per-iteration
# ledger so "how many PRE_FLIGHT dispatches happened" is observable even when the mutable file
# disappears between iterations.
#
# This test extracts the P1C-REVERIFY-SCOPE block VERBATIM from the production script (same idiom
# as p1c-reverify-scope-test.sh) and drives it against a LOCAL dir with NO gate-summary (simulating
# the worktree-recreated-between-iterations case) but a durable copy present only at the resolved
# MAIN root — proving the fallback closes the gap, and that the ledger accumulates across calls.
set -u
SCRIPT="${V_RUN_GATES_OVERRIDE:-$HOME/.claude/skills/v/references/v-run-gates.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$SCRIPT" ] || { echo "NO v-run-gates.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

P1C="$(awk '/=== P1C-REVERIFY-SCOPE/,/=== end P1C-REVERIFY-SCOPE/' "$SCRIPT")"
if [ -z "$P1C" ]; then
  no "P1C-REVERIFY-SCOPE block present in v-run-gates.sh" "awk range empty"
  echo ""; echo "TOTAL: $PASS passed, $((FAIL)) failed"; exit 1
fi
ok "P1C-REVERIFY-SCOPE block present in v-run-gates.sh"

run_p1c() { # $1=local-summary-state(none|complete) $2=durable-summary-state(none|complete) → echoes resulting PFM
  local d="$WORK/r$RANDOM"; local main_d="$WORK/m$RANDOM"
  mkdir -p "$d" "$main_d/.v/artifacts"
  case "$1" in
    complete) printf 'TSC_RC=0\nDONE_AT=2026-07-03T00:00:00Z\n' > "$d/gate-summary-p1c-sid.txt" ;;
  esac
  case "$2" in
    complete) printf 'TSC_RC=0\nDONE_AT=2026-07-03T00:00:00Z\n' > "$main_d/.v/artifacts/gate-summary-p1c-sid.txt" ;;
    blind)    printf 'TSC_RC=0\nPREFLIGHT_BLIND=1\nDONE_AT=2026-07-03T00:00:00Z\n' > "$main_d/.v/artifacts/gate-summary-p1c-sid.txt" ;;
    mismatch) printf 'TSC_RC=0\nTREE_MISMATCH=1\nDONE_AT=2026-07-03T00:00:00Z\n' > "$main_d/.v/artifacts/gate-summary-p1c-sid.txt" ;;
  esac
  (
    cd "$d" 2>/dev/null || exit 1   # NOT a git repo (~/.claude has no .git) — git-worktree-list fails, forcing the PROJECT_ROOT fallback path
    set +eu
    PFM="full"; V_TMP_DIR="$d"; SESSION_ID="p1c-sid"
    PROJECT_ROOT="$main_d"
    POSTMERGE_REVERIFY="0"; V_REVERIFY_FULL="0"
    eval "$P1C" 2>/dev/null
    printf '%s' "$PFM"
  )
}

echo "== Item 18 :: durable-fallback consultation when the local per-SID file is absent =="

[ "$(run_p1c none complete)" = "scoped" ] \
  && ok "local gate-summary ABSENT (simulated worktree-recreated iteration-2) + durable MAIN-root copy present ⇒ still downgrades to scoped" \
  || no "durable fallback did not fire" "PFM=$(run_p1c none complete)"

[ "$(run_p1c none none)" = "full" ] \
  && ok "neither local nor durable summary present ⇒ stays full (genuine first run, no false downgrade)" \
  || no "wrongly downgraded with no evidence anywhere" ""

[ "$(run_p1c complete none)" = "scoped" ] \
  && ok "local gate-summary present (no worktree churn) ⇒ unchanged behavior, still downgrades" \
  || no "local-file path regressed" ""

# Cycle-3 audit P3 (2026-07-04): the exclusions must hold ON THE DURABLE BRANCH too — previously
# only proven by "the grep chain is shared code", now proven by execution.
[ "$(run_p1c none blind)" = "full" ] \
  && ok "durable copy carries PREFLIGHT_BLIND=1 ⇒ stays full even via the fallback branch" \
  || no "BLIND exclusion lost on the durable branch" "PFM=$(run_p1c none blind)"

[ "$(run_p1c none mismatch)" = "full" ] \
  && ok "durable copy carries TREE_MISMATCH=1 ⇒ stays full even via the fallback branch" \
  || no "TREE_MISMATCH exclusion lost on the durable branch" "PFM=$(run_p1c none mismatch)"

echo ""
echo "== Item 18 :: append-only per-iteration ledger (never overwritten) =="
LEDGER_DIR="$WORK/ledger-run"
mkdir -p "$LEDGER_DIR"
printf 'TSC_RC=0\nDONE_AT=2026-07-03T00:00:00Z\n' > "$LEDGER_DIR/gate-summary-p1c-sid.txt"
(
  cd "$LEDGER_DIR" 2>/dev/null || exit 1
  set +eu
  PFM="full"; V_TMP_DIR="$LEDGER_DIR"; SESSION_ID="p1c-sid"; PROJECT_ROOT="$LEDGER_DIR"
  POSTMERGE_REVERIFY="0"; V_REVERIFY_FULL="0"
  eval "$P1C" 2>/dev/null
  PFM="full"   # simulate iteration 2's dispatcher requesting full again
  eval "$P1C" 2>/dev/null
) >/dev/null 2>&1
_lines=$(wc -l < "$LEDGER_DIR/gate-iterations-p1c-sid.txt" 2>/dev/null | tr -d ' ')
[ "${_lines:-0}" -eq 2 ] \
  && ok "ledger accumulated 2 lines across 2 invocations (append, not overwrite)" \
  || no "ledger did not accumulate as expected" "got ${_lines:-0} line(s)"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
