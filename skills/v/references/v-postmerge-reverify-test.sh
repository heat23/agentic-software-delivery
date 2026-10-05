#!/usr/bin/env bash
# v-postmerge-reverify-test.sh — H4-4 (PLAN_2026-07-02_orchestrator-hardening-4)
#
# Evidence: a gate-summary-<sid> ran MODE=scoped with BASE_SHA_FOR_DIFF=<post-merge sha> (the POST-merge
# HEAD — a 0-diff base against itself), so every stack SKIPped and the run "passed" in 1 second
# having verified nothing, then OVERWROTE the earlier real gate-summary (aliasing a stale real
# PASS report with a bogus SKIP summary that coexisted with it).
#
# Fix, split three ways:
#   (a) v-merge-back.sh emits MERGE_BACK_REVERIFY_BASE_SHA=$FORK_BASE (the correct pre-session,
#       pre-sibling base) alongside its existing MERGE_BACK_REVERIFY_REQUIRED/REASON contract.
#   (b) v-run-gates.sh's blind-scope guard also fires when POSTMERGE_REVERIFY=1, even under
#       PFM=full (previously scoped/dirty-tree only) — a re-verify is scoped by definition.
#   (c) v-run-gates.sh writes the skeleton + summary to `-postmerge`-suffixed filenames when
#       POSTMERGE_REVERIFY=1, never overwriting the session's primary artifact.
#
# RED on the pre-edit backups (no BASE_SHA line, no POSTMERGE_REVERIFY branch, no suffix). GREEN
# on the fix. Structural (grep/extraction) rather than a full gate run — v-run-gates.sh executes
# real test/build/lint suites end-to-end, which is not a reliable or fast test vehicle (see
# v-run-gates-vendor-guard-test.sh for the same design choice).
set -u
RG="${V_RUNGATES_OVERRIDE:-$HOME/.claude/skills/v/references/v-run-gates.sh}"
RG_BAK="$HOME/.claude/skills/v/references/v-run-gates.sh.pre-h4-bak"
MB="${V_MERGEBACK_OVERRIDE:-$HOME/.claude/skills/v/references/v-merge-back.sh}"
MB_BAK="$HOME/.claude/skills/v/references/v-merge-back.sh.pre-h4-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }

echo "== H4-4 :: postmerge re-verify base-SHA + non-clobbering summary =="

bash -n "$RG" && ok "v-run-gates.sh parses (bash -n)" || no "v-run-gates.sh syntax error"
bash -n "$MB" && ok "v-merge-back.sh parses (bash -n)" || no "v-merge-back.sh syntax error"

# --- (a) v-merge-back.sh emits the pre-merge base SHA ---
echo "-- GREEN --"
grep -qE 'MERGE_BACK_REVERIFY_BASE_SHA=\$FORK_BASE' "$MB" \
  && ok "fixed: v-merge-back.sh emits MERGE_BACK_REVERIFY_BASE_SHA=\$FORK_BASE" \
  || no "fixed: MERGE_BACK_REVERIFY_BASE_SHA line missing"

# --- (b) blind-scope guard also fires under POSTMERGE_REVERIFY=1 regardless of PFM ---
grep -qE '\[ "\$PFM" = "scoped" \] \|\| \[ "\$PFM" = "dirty-tree" \] \|\| \[ "\$\{POSTMERGE_REVERIFY:-0\}" = "1" \]' "$RG" \
  && ok "fixed: blind-scope guard condition includes POSTMERGE_REVERIFY=1" \
  || no "fixed: blind-scope guard does not check POSTMERGE_REVERIFY"

# --- (c) -postmerge suffix computed and threaded into SKELETON_FILE / SUMMARY_FILE ---
grep -qE '_GATE_SUFFIX=""' "$RG" && grep -qE '\[ "\$\{POSTMERGE_REVERIFY:-0\}" = "1" \] && _GATE_SUFFIX="-postmerge"' "$RG" \
  && ok "fixed: _GATE_SUFFIX computed from POSTMERGE_REVERIFY" \
  || no "fixed: _GATE_SUFFIX computation missing"
grep -qE 'SKELETON_FILE="\$V_TMP_DIR/pre-flight-skeleton-\$\{SESSION_ID\}\$\{_GATE_SUFFIX\}\.md"' "$RG" \
  && ok "fixed: SKELETON_FILE threads _GATE_SUFFIX" \
  || no "fixed: SKELETON_FILE does not thread _GATE_SUFFIX"
grep -qE 'SUMMARY_FILE="\$V_TMP_DIR/gate-summary-\$\{SESSION_ID\}\$\{_GATE_SUFFIX\}\.txt"' "$RG" \
  && ok "fixed: SUMMARY_FILE threads _GATE_SUFFIX" \
  || no "fixed: SUMMARY_FILE does not thread _GATE_SUFFIX"

# --- functional: extract just the suffix + blind-guard-condition logic and exercise it in isolation ---
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
_exercise_suffix() {  # $1=script -> prints computed _GATE_SUFFIX for POSTMERGE_REVERIFY=1
  local script="$1" line
  line=$(grep -n '_GATE_SUFFIX=""' "$script" | head -1 | cut -d: -f1)
  [ -n "$line" ] || { echo "<no-suffix-logic>"; return; }
  ( POSTMERGE_REVERIFY=1
    sed -n "${line},$((line+2))p" "$script" > "$TMP/frag.sh"
    # shellcheck source=/dev/null
    source "$TMP/frag.sh" 2>/dev/null
    echo "${_GATE_SUFFIX:-<unset>}"
  )
}
[ "$(_exercise_suffix "$RG")" = "-postmerge" ] \
  && ok "functional: POSTMERGE_REVERIFY=1 -> _GATE_SUFFIX=-postmerge (fixed)" \
  || no "functional: _GATE_SUFFIX did not resolve to -postmerge under POSTMERGE_REVERIFY=1"

echo "-- RED: pre-edit backups must be missing all three of (a)/(b)/(c) --"
if [ -f "$MB_BAK" ]; then
  grep -qE 'MERGE_BACK_REVERIFY_BASE_SHA=\$FORK_BASE' "$MB_BAK" \
    && no "backup: unexpectedly already emits MERGE_BACK_REVERIFY_BASE_SHA (fix should be new)" \
    || ok "backup: no MERGE_BACK_REVERIFY_BASE_SHA line (confirms the fix is new)"
else
  echo "  SKIP: no backup at $MB_BAK"
fi
if [ -f "$RG_BAK" ]; then
  grep -qE 'POSTMERGE_REVERIFY' "$RG_BAK" \
    && no "backup: unexpectedly already references POSTMERGE_REVERIFY (fix should be new)" \
    || ok "backup: no POSTMERGE_REVERIFY handling at all (confirms the fix is new)"
else
  echo "  SKIP: no backup at $RG_BAK"
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
