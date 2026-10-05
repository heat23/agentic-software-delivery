#!/usr/bin/env bash
# ui-gate-own-scope-test.sh — W49-SCOPE bite (forensic 2026-06-28).
#
# The UX_CRITIQUE + WORKFLOW_VERIFICATION UI gates (check-review-artifact.sh) share one trigger,
# any_user_facing_ui "$W49_UI_SCOPE_PATHS". Before the fix the trigger used ALL_CHANGED_PATHS, whose source #2
# (START_HEAD..CURRENT_HEAD over a frozen base) captures a SIBLING's committed UI file under concurrent sessions
# on shared main → both gates fired on a session that touched no UI. The W49-SCOPE block subtracts files
# provably attributable to another session (sibling writes-log, not mine) via files_attributable_to_other_sessions.
#
# This EXTRACTS the W49-SCOPE block VERBATIM from the production hook (real coverage, not a re-impl) and runs it
# against three fixtures, asserting the SAFE-DIRECTION invariants:
#   1. contamination filtered: a sibling's .tsx (in sibling log, not mine) is REMOVED → gate would NOT fire
#   2. own UI preserved: a .tsx in MY writes-log is KEPT → gate fires (NO under-trigger / quality gap)
#   3. fail-open: empty own writes-log → nothing subtracted → sibling .tsx stays → gate fires (safe over-trigger)
# RED oracle: a neutered block (no subtraction) leaves the sibling .tsx → gate fires on a foreign file (the bug).
set -u
HOOK="${V_CRA_OVERRIDE:-$HOME/.claude/hooks/check-review-artifact.sh}"
LIBDIR="${V_HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$HOOK" ] || { echo "NO hook missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
. "$LIBDIR/session-writes.sh" 2>/dev/null || { echo "NO cannot source session-writes.sh"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
. "$LIBDIR/ui-path-pattern.sh" 2>/dev/null || { echo "NO cannot source ui-path-pattern.sh"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

SCOPE_BLK="$(awk '/# >>> W49-SCOPE/{f=1} f{print} /# <<< W49-SCOPE/{f=0}' "$HOOK")"
[ -n "$SCOPE_BLK" ] || { echo "NO W49-SCOPE block not found (sentinels removed?)"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
R="$WORK/repo"; mkdir -p "$R"; git -C "$R" init -q >/dev/null 2>&1
cd "$R" || { echo "NO cannot cd repo"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
MY="11111111-aaaa-4000-8000-000000000000"
SIB="22222222-bbbb-4000-8000-000000000000"
UI="resources/js/Pages/Foo.tsx"
PHP="app/Services/Svc.php"
log_for(){ printf '%s/claude-session-writes-%s.txt' "$(git rev-parse --git-common-dir)" "$1"; }
reset_logs(){ rm -f "$(git rev-parse --git-common-dir)"/claude-session-writes-*.txt 2>/dev/null; }

# Run the EXTRACTED W49-SCOPE block; sets global W49_UI_SCOPE_PATHS.
run_scope(){ SESSION_ID="$1"; ALL_CHANGED_PATHS="$2"; W49_UI_SCOPE_PATHS=""; eval "$SCOPE_BLK"; }
has(){ printf '%s\n' "$1" | grep -qxF "$2"; }

echo "== W49-SCOPE :: UI-gate trigger scoped to this session's own paths =="

# 1. Contamination filtered — sibling authored the .tsx, I authored only the .php.
reset_logs
printf '%s\n' "$PHP" > "$(log_for "$MY")"
printf '%s\n' "$UI"  > "$(log_for "$SIB")"
run_scope "$MY" "$(printf '%s\n%s\n' "$PHP" "$UI")"
if ! has "$W49_UI_SCOPE_PATHS" "$UI" && has "$W49_UI_SCOPE_PATHS" "$PHP" && ! any_user_facing_ui "$W49_UI_SCOPE_PATHS"; then
  ok "contamination: sibling's .tsx removed from scope; own .php kept; UI gate would NOT fire"
else
  no "contamination not filtered" "scope=[$(printf '%s' "$W49_UI_SCOPE_PATHS" | tr '\n' ',')]"
fi
# control: the UNFILTERED set DOES look like UI (proves the scenario is real)
any_user_facing_ui "$(printf '%s\n%s\n' "$PHP" "$UI")" \
  && ok "control: unfiltered ALL_CHANGED_PATHS DOES contain UI (the contamination is real)" \
  || no "control: unfiltered set unexpectedly has no UI (fixture wrong)"

# 2. Own UI preserved — I authored the .tsx → must NOT be subtracted (no under-trigger / quality gap).
reset_logs
printf '%s\n' "$UI" > "$(log_for "$MY")"
run_scope "$MY" "$(printf '%s\n' "$UI")"
{ has "$W49_UI_SCOPE_PATHS" "$UI" && any_user_facing_ui "$W49_UI_SCOPE_PATHS"; } \
  && ok "own UI: my own .tsx is KEPT → gate fires (no under-trigger / no quality gap)" \
  || no "own UI wrongly dropped — quality gap" "scope=[$(printf '%s' "$W49_UI_SCOPE_PATHS" | tr '\n' ',')]"

# 3. Fail-open — empty own writes-log → nothing subtracted → sibling .tsx stays → gate fires (safe over-trigger).
reset_logs
printf '%s\n' "$UI" > "$(log_for "$SIB")"   # only the sibling has a log; mine is absent
run_scope "$MY" "$(printf '%s\n' "$UI")"
{ has "$W49_UI_SCOPE_PATHS" "$UI" && any_user_facing_ui "$W49_UI_SCOPE_PATHS"; } \
  && ok "fail-open: empty own log → no subtraction → gate still fires (safe over-trigger, never silent)" \
  || no "fail-open broke (under-triggered)" "scope=[$(printf '%s' "$W49_UI_SCOPE_PATHS" | tr '\n' ',')]"

# 4. ALL-FOREIGN (logic-review HIGH / codex SREV-001): every path in scope is the sibling's; my log is non-empty
# but non-UI. The scope must empty out → gate must NOT fire. The pre-fix `grep -vxF || printf ALL` fallback
# RESTORED the foreign set here (exit 1 on zero survivors) → gate over-fired on pure-foreign. awk fixes it.
reset_logs
printf '%s\n' "$PHP" > "$(log_for "$MY")"     # I authored a non-UI file (own log non-empty, so not fail-open)
printf '%s\n' "$UI"  > "$(log_for "$SIB")"
run_scope "$MY" "$(printf '%s\n' "$UI")"        # ALL_CHANGED_PATHS = ONLY the sibling's .tsx
{ [ -z "$(printf '%s' "$W49_UI_SCOPE_PATHS" | tr -d '[:space:]')" ] && ! any_user_facing_ui "$W49_UI_SCOPE_PATHS"; } \
  && ok "all-foreign: scope empties out → gate does NOT fire (the grep-vxF fallback-restore bug is fixed)" \
  || no "all-foreign: scope did not empty → gate would over-fire on pure-foreign" "scope=[$(printf '%s' "$W49_UI_SCOPE_PATHS" | tr '\n' ',')]"

# RED oracle — a neutered block (passthrough, no subtraction) leaves the sibling .tsx → gate fires on a foreign file.
reset_logs
printf '%s\n' "$PHP" > "$(log_for "$MY")"
printf '%s\n' "$UI"  > "$(log_for "$SIB")"
SESSION_ID="$MY"; ALL_CHANGED_PATHS="$(printf '%s\n%s\n' "$PHP" "$UI")"; W49_UI_SCOPE_PATHS=""
eval 'W49_UI_SCOPE_PATHS="$ALL_CHANGED_PATHS"'   # neutered: the subtraction removed
{ has "$W49_UI_SCOPE_PATHS" "$UI" && any_user_facing_ui "$W49_UI_SCOPE_PATHS"; } \
  && ok "RED oracle: WITHOUT the subtraction the sibling .tsx survives → gate fires on foreign (the bug) — fix is load-bearing" \
  || no "RED oracle inconclusive (neutered block did not reproduce the contamination)"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
