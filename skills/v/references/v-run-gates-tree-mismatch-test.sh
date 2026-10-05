#!/usr/bin/env bash
# v-run-gates-tree-mismatch-test.sh — W71-F10 (forensic 2026-07-02).
#
# CLASS UNDER TEST: a pre-flight gate run executing in a tree that does NOT contain the
# session's commits, then attesting PASS for base code. Evidence: a production session's later
# pre-flight dispatch ran in the MAIN root ("Files changed since base: none", escalated scoped→full),
# PASSed a base-tree suite containing NONE of the session's branch commits, and OVERWROTE
# the earlier real report — GAUNTLET_ATTESTED then pointed at an attestation of the wrong tree.
#
# W71-F9 fixed the dispatch path (deterministic RUN_ROOT); this pins the deterministic belt
# INSIDE v-run-gates.sh: if the SID's commit witness (.v/tmp/commits-<SID>.txt) is non-empty and
# NONE of its SHAs is an ancestor of HEAD, TREE_MISMATCH=1 → ALL_PASS forced 0 + INCONCLUSIVE row.
#
# Functional cases run the extracted guard fragment against a real fixture git repo (v-run-gates.sh
# executes real build/test suites end-to-end, which is not a fast test vehicle — same design choice
# as v-postmerge-reverify-test.sh). RED against the pre-fix backup (fragment absent = old behavior).
#
# Run: bash v-run-gates-tree-mismatch-test.sh [/path/to/v-run-gates.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RG="${1:-${V_RUNGATES_OVERRIDE:-$HERE/v-run-gates.sh}}"
RG_BAK="$HERE/v-run-gates.sh.pre-w71f10-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }

[ -f "$RG" ] || { echo "FATAL: script-under-test not found ($RG)"; exit 2; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== W71-F10 :: wrong-tree gate runs must come out INCONCLUSIVE, never a clean PASS =="

bash -n "$RG" && ok "v-run-gates.sh parses (bash -n)" || no "v-run-gates.sh syntax error"

# ── structural pins ───────────────────────────────────────────────────────────
grep -qE '^TREE_MISMATCH=0$' "$RG" \
  && ok "guard block present (TREE_MISMATCH=0 init)" \
  || no "guard block missing (TREE_MISMATCH=0 init not found)"
grep -qE '\[ "\$\{TREE_MISMATCH:-0\}" -eq 1 \] && ALL_PASS=0' "$RG" \
  && ok "ALL_PASS forced 0 on TREE_MISMATCH" \
  || no "ALL_PASS not forced 0 on TREE_MISMATCH"
grep -qE 'echo "TREE_MISMATCH=\$\{TREE_MISMATCH:-0\}"' "$RG" \
  && ok "gate-summary carries TREE_MISMATCH key" \
  || no "gate-summary TREE_MISMATCH key missing"
grep -qE '\| INCONCLUSIVE \| Tree \|' "$RG" \
  && ok "report skeleton emits INCONCLUSIVE Tree row" \
  || no "INCONCLUSIVE Tree row missing from skeleton"
grep -qE 'POSTMERGE_REVERIFY:-0\}" != "1" \] && \[ -s "\$_COMMITS_WITNESS" \]' "$RG" \
  && ok "guard skipped under POSTMERGE_REVERIFY=1 (rebase-safe)" \
  || no "POSTMERGE_REVERIFY skip condition missing"
grep -qE 'git rev-parse --git-common-dir' "$RG" \
  && ok "witness lookup falls back to the git-common-dir root (review F1)" \
  || no "common-dir witness fallback missing (guard inert when V_TMP_DIR diverges from the witness root)"

# ── fragment extraction (guard block start → the Phase-1 section header, exclusive) ──
_extract_guard(){ awk '/^TREE_MISMATCH=0$/{f=1} f&&/^# ── 4\. Phase 1/{exit} f' "$1"; }
_extract_guard "$RG" > "$TMP/guard.sh"
[ -s "$TMP/guard.sh" ] && ok "guard fragment extracted ($(wc -l < "$TMP/guard.sh" | tr -d ' ') lines)" \
  || no "guard fragment extraction empty"

# ── fixture repo: main with commit A; branch with commit B (session work) ─────
FIX="$TMP/repo"; mkdir -p "$FIX"
git -C "$FIX" init -q -b main
git -C "$FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$FIX" checkout -q -b fix/some-task-w71f10
git -C "$FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "session work"
B_SHA=$(git -C "$FIX" rev-parse HEAD)
git -C "$FIX" checkout -q main
mkdir -p "$FIX/.v/tmp"

# run the extracted guard in a subshell inside a given checkout, echoing TREE_MISMATCH
_run_guard(){ # $1=cwd $2=witness-content $3=postmerge-flag → prints resulting TREE_MISMATCH
  local _cwd="$1" _wit="$2" _pm="${3:-0}"
  printf '%s\n' "$_wit" > "$FIX/.v/tmp/commits-TESTSID.txt"
  [ -z "$_wit" ] && rm -f "$FIX/.v/tmp/commits-TESTSID.txt"
  ( cd "$_cwd" || exit 9
    SESSION_ID="TESTSID"; V_TMP_DIR="$FIX/.v/tmp"; POSTMERGE_REVERIFY="$_pm"
    # shellcheck source=/dev/null
    source "$TMP/guard.sh" 2>/dev/null
    echo "${TREE_MISMATCH:-<unset>}"
  )
}

# 1. FIRES: witness holds the branch commit, HEAD is main (the wrong-tree shape)
[ "$(_run_guard "$FIX" "$B_SHA")" = "1" ] \
  && ok "FIRES: session commit absent from tested HEAD → TREE_MISMATCH=1" \
  || no "did not fire on the wrong-tree shape"

# 2. PASSES: run inside the branch checkout (session commit IS ancestor)
git -C "$FIX" checkout -q fix/some-task-w71f10
[ "$(_run_guard "$FIX" "$B_SHA")" = "0" ] \
  && ok "passes: session commit is ancestor of tested HEAD → TREE_MISMATCH=0" \
  || no "false-fired inside the correct worktree"

# 3. AMEND-SAFE: witness holds one orphaned sha + one live sha → passes
[ "$(_run_guard "$FIX" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
$B_SHA")" = "0" ] \
  && ok "amend/rebase-safe: ANY surviving witness commit in ancestry → 0" \
  || no "false-fired on a witness with one orphaned (amended-away) sha"
git -C "$FIX" checkout -q main

# 4. POSTMERGE skip: same wrong-tree shape but POSTMERGE_REVERIFY=1 → 0
[ "$(_run_guard "$FIX" "$B_SHA" 1)" = "0" ] \
  && ok "POSTMERGE_REVERIFY=1 skips the guard (merge-back rebases SHAs)" \
  || no "fired under POSTMERGE_REVERIFY=1 (would false-block every post-merge re-verify)"

# 5. NO witness (fresh session, pre-commit pre-flight) → 0
[ "$(_run_guard "$FIX" "")" = "0" ] \
  && ok "no/empty witness → guard inert (no false block on pre-commit runs)" \
  || no "fired with no witness present"

# 6. garbage-only witness lines → 0 (checked-count stays 0)
[ "$(_run_guard "$FIX" "# comment
not-a-sha at all")" = "0" ] \
  && ok "non-sha witness lines ignored → guard inert" \
  || no "fired on a witness containing no valid shas"

# 7. review F1: witness lives ONLY at the main root while V_TMP_DIR points elsewhere → still FIRES
printf '%s\n' "$B_SHA" > "$FIX/.v/tmp/commits-TESTSID.txt"
mkdir -p "$TMP/elsewhere"
_r7=$( cd "$FIX" || exit 9
  SESSION_ID="TESTSID"; V_TMP_DIR="$TMP/elsewhere"; POSTMERGE_REVERIFY=0
  # shellcheck source=/dev/null
  source "$TMP/guard.sh" 2>/dev/null
  echo "${TREE_MISMATCH:-<unset>}" )
[ "$_r7" = "1" ] \
  && ok "common-dir fallback: witness found at the main root despite divergent V_TMP_DIR → fires" \
  || no "fallback failed: divergent V_TMP_DIR made the guard inert (got $_r7)"
rm -f "$FIX/.v/tmp/commits-TESTSID.txt"

# ── RED: pre-fix backup must lack the guard entirely ─────────────────────────
echo "-- RED: pre-fix backup --"
if [ -f "$RG_BAK" ]; then
  if grep -qE '^TREE_MISMATCH=0$' "$RG_BAK"; then
    no "backup unexpectedly already contains the guard (fix should be new)"
  else
    ok "backup lacks the guard (confirms the fix is new)"
  fi
  _extract_guard "$RG_BAK" > "$TMP/guard-old.sh"
  if [ -s "$TMP/guard-old.sh" ]; then
    no "backup fragment unexpectedly non-empty"
  else
    ok "backup: wrong-tree run produced NO mismatch signal (the false-attestation shape)"
  fi
else
  echo "  SKIP: no backup at $RG_BAK"
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
