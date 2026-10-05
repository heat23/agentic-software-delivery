#!/usr/bin/env bash
# v-run-gates-staged-scope-test.sh — F9 regression (staged-blindness, forensic 2026-07-05):
# a real PRE_FLIGHT_REPORT_<sid>.md claimed "Files in scope: 0 dirty files (session changes
# already committed/merged)" while several files were actually STAGED (`git add`, not yet committed)
# at dispatch time. Root cause: v-run-gates.sh never exported an authoritative in-scope file
# count to gate-summary-<sid>.txt, so the haiku report-writer had to freehand its own git check
# for the "Files in scope" line — and a bare `git diff --name-only` (no ref) sees ONLY unstaged
# changes, missing anything already staged.
#
# Three fixes verified here:
#   F9-1: gate-summary now carries IN_SCOPE_FILE_COUNT=, computed from working-tree (git diff
#         --name-only HEAD) + staged (git diff --cached --name-only) + session-writes log +
#         committed-since-base diff — staged-only files MUST count as in-scope.
#   F9-2: a requested `full` that P1C-REVERIFY-SCOPE auto-downgrades to `scoped` must remain
#         VISIBLE: gate-summary carries both MODE= (effective) and PFM_REQUESTED= (as asked),
#         and the dispatch prompt must build its report's "Mode:" line from MODE=, never from
#         the raw $PRE_FLIGHT_MODE env var (which is always the ORIGINAL request).
#   F9-3: the scoped/dirty-tree diff base is PINNED to this session's durable
#         head-baseline-<sid>.txt (written once at bootstrap), not a merge-base recomputed fresh
#         on every dispatch (which drifts if $MAIN advances mid-session).
#
# Red-before evidence: v-run-gates.sh.pre-item1-bak / dispatch-v-pre-flight.md.pre-fabletrim0704-bak
# are the real pre-fix files (the actual shipped state immediately before this hardening pass) —
# neither has IN_SCOPE_FILE_COUNT/PFM_REQUESTED/the head-baseline pin, and the dispatch prompt's
# report template unconditionally echoed `Mode: $PRE_FLIGHT_MODE`.
set -u
REF_DIR="$HOME/.claude/skills/v/references"
SRC="$REF_DIR/v-run-gates.sh"
SRC_BAK="$REF_DIR/v-run-gates.sh.pre-item1-bak"
PROMPT="$REF_DIR/dispatch-v-pre-flight.md"
PROMPT_BAK="$REF_DIR/dispatch-v-pre-flight.md.pre-fabletrim0704-bak"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

[ -f "$SRC" ] || { echo "FAIL v-run-gates.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── fixture: a repo with (1) a durable session-start head-baseline, (2) ONE real session commit
#    made after bootstrap, and (3) additional files STAGED (git add) but never committed — the
#    exact "many staged files" shape from the real incident. ─────────────────────────────────────
make_fixture() {
  local repo="$1" sid="$2"
  rm -rf "$repo"; mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  printf '.v/\n' > "$repo/.gitignore"
  printf 'hello\n' > "$repo/README.md"
  git -C "$repo" add README.md .gitignore
  git -C "$repo" commit -qm init
  mkdir -p "$repo/.v/tmp"
  git -C "$repo" rev-parse HEAD > "$repo/.v/tmp/head-baseline-${sid}.txt"
  # session's own real commit (moves HEAD forward from the bootstrap baseline)
  printf 'committed change\n' > "$repo/committed_file.txt"
  git -C "$repo" add committed_file.txt
  git -C "$repo" commit -qm "session commit 1"
  # staged-but-uncommitted files (git add, no commit) — the reported bug scenario
  for i in 1 2 3; do printf 'staged content %s\n' "$i" > "$repo/staged_file_$i.txt"; done
  git -C "$repo" add staged_file_1.txt staged_file_2.txt staged_file_3.txt
}

run_gates() {  # <script> <repo> <sid> [PRE_FLIGHT_MODE]
  local script="$1" repo="$2" sid="$3" mode="${4:-scoped}"
  ( cd "$repo" \
    && SESSION_ID="$sid" V_TMP_DIR="$repo/.v/tmp" PRE_FLIGHT_MODE="$mode" PROJECT_ROOT="$repo" \
       bash "$script" > "$repo/.v/tmp/out.log" 2> "$repo/.v/tmp/err.log" )
}

echo "== F9-1 :: IN_SCOPE_FILE_COUNT includes STAGED (not just working-tree/unstaged) files =="

SID1="f9test001-0001-4001-8001-000000000001"
REPO1="$WORK/repo1"
make_fixture "$REPO1" "$SID1"
run_gates "$SRC" "$REPO1" "$SID1" scoped
SUM1="$REPO1/.v/tmp/gate-summary-${SID1}.txt"
if [ -f "$SUM1" ]; then
  ok "gate-summary produced for the staged+committed fixture"
else
  no "gate-summary not produced" "$(cat "$REPO1/.v/tmp/err.log" 2>/dev/null | tail -10)"
fi
COUNT1="$(grep -m1 '^IN_SCOPE_FILE_COUNT=' "$SUM1" 2>/dev/null | cut -d= -f2)"
if [ -n "$COUNT1" ] && [ "$COUNT1" -gt 0 ] 2>/dev/null; then
  ok "IN_SCOPE_FILE_COUNT=$COUNT1 (> 0) — staged files counted as in-scope, not '0 dirty files'"
else
  no "IN_SCOPE_FILE_COUNT missing or 0" "got='$COUNT1'; summary follows: $(cat "$SUM1" 2>/dev/null)"
fi
if grep -q '^PREFLIGHT_BLIND=0' "$SUM1" 2>/dev/null; then
  ok "PREFLIGHT_BLIND=0 (the run correctly sees the diff, not falsely blind)"
else
  no "PREFLIGHT_BLIND unexpectedly 1 — the fixture's diff was NOT seen" "$(grep '^PREFLIGHT_BLIND' "$SUM1" 2>/dev/null)"
fi

echo
echo "== RED :: the pre-fix v-run-gates.sh never exported IN_SCOPE_FILE_COUNT at all =="
if [ -f "$SRC_BAK" ]; then
  SID1B="f9test002-0002-4002-8002-000000000002"
  REPO1B="$WORK/repo1b"
  make_fixture "$REPO1B" "$SID1B"
  run_gates "$SRC_BAK" "$REPO1B" "$SID1B" scoped
  SUM1B="$REPO1B/.v/tmp/gate-summary-${SID1B}.txt"
  if [ -f "$SUM1B" ] && ! grep -q '^IN_SCOPE_FILE_COUNT=' "$SUM1B" 2>/dev/null; then
    ok "RED confirmed: pre-fix v-run-gates.sh.pre-item1-bak's summary has NO IN_SCOPE_FILE_COUNT key at all"
  else
    no "RED fixture vacuous — pre-fix backup already had IN_SCOPE_FILE_COUNT" "$(cat "$SUM1B" 2>/dev/null | head -5)"
  fi
else
  ok "RED skipped: no v-run-gates.sh.pre-item1-bak on disk (fixture unavailable, not a failure)"
fi

echo
echo "== F9-3 :: scoped base is PINNED to the durable session-start head-baseline, not a fresh merge-base =="

SID2="f9test003-0003-4003-8003-000000000003"
REPO2="$WORK/repo2"
make_fixture "$REPO2" "$SID2"
EXPECTED_BASE="$(cat "$REPO2/.v/tmp/head-baseline-${SID2}.txt")"
# Simulate a CONCURRENT SIBLING advancing origin/main between two dispatches of the SAME
# session: add a commit to main AFTER bootstrap that has nothing to do with this session.
printf 'sibling churn\n' > "$REPO2/sibling_file.txt"
git -C "$REPO2" add sibling_file.txt
git -C "$REPO2" -c user.email=t@example.com -c user.name=t commit -qm "unrelated sibling commit"
# A NAIVE recompute of merge-base HEAD main after this sibling commit would just be HEAD itself
# (fast-forward, single branch) — i.e. THE OLD BEHAVIOR is drift-prone in exactly this shape.
run_gates "$SRC" "$REPO2" "$SID2" scoped
SUM2="$REPO2/.v/tmp/gate-summary-${SID2}.txt"
ACTUAL_BASE="$(grep -m1 '^BASE_SHA_FOR_DIFF=' "$SUM2" 2>/dev/null | cut -d= -f2)"
if [ "$ACTUAL_BASE" = "$EXPECTED_BASE" ]; then
  ok "BASE_SHA_FOR_DIFF pinned to the session's own head-baseline ($EXPECTED_BASE), not recomputed off the moved HEAD"
else
  no "BASE_SHA_FOR_DIFF drifted from the pinned session-start baseline" "expected=$EXPECTED_BASE got=$ACTUAL_BASE"
fi
if grep -q 'F9-3 — scoped diff base PINNED' "$REPO2/.v/tmp/err.log" 2>/dev/null; then
  ok "F9-3 pin path actually fired (stderr trace present)"
else
  no "F9-3 pin path did not fire" "$(tail -15 "$REPO2/.v/tmp/err.log" 2>/dev/null)"
fi

echo
echo "== F9-2 :: a requested 'full' that auto-downgrades to 'scoped' (P1C) stays VISIBLE =="

SID3="f9test004-0004-4004-8004-000000000004"
REPO3="$WORK/repo3"
make_fixture "$REPO3" "$SID3"
# Seed a completed, non-blind, non-mismatched prior gate-summary for THIS sid so P1C-REVERIFY-SCOPE
# treats this as an iteration-2+ re-verify and downgrades the requested `full` to `scoped`.
{
  echo "DONE_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "PREFLIGHT_BLIND=0"
  echo "TREE_MISMATCH=0"
} > "$REPO3/.v/tmp/gate-summary-${SID3}.txt"
run_gates "$SRC" "$REPO3" "$SID3" full
SUM3="$REPO3/.v/tmp/gate-summary-${SID3}.txt"
MODE3="$(grep -m1 '^MODE=' "$SUM3" 2>/dev/null | cut -d= -f2)"
REQ3="$(grep -m1 '^PFM_REQUESTED=' "$SUM3" 2>/dev/null | cut -d= -f2)"
if [ "$MODE3" = "scoped" ]; then
  ok "P1C-REVERIFY-SCOPE fired as designed (iteration-2+ full auto-downgraded to scoped)"
else
  no "P1C did not fire as expected (test fixture drifted from v-run-gates.sh's actual P1C conditions)" "MODE=$MODE3"
fi
if [ "$REQ3" = "full" ] && [ "$MODE3" = "scoped" ]; then
  ok "PFM_REQUESTED=full survives alongside the effective MODE=scoped — the downgrade is now VISIBLE in the durable summary, not silent"
else
  no "PFM_REQUESTED not preserved through the downgrade" "PFM_REQUESTED=$REQ3 MODE=$MODE3"
fi

echo
echo "== RED :: the pre-fix summary carried no PFM_REQUESTED field, and the dispatch prompt echoed the raw request unconditionally =="
if [ -f "$SRC_BAK" ] && ! grep -q 'echo "PFM_REQUESTED=' "$SRC_BAK" 2>/dev/null; then
  ok "RED confirmed: pre-fix v-run-gates.sh never wrote PFM_REQUESTED= to the summary"
else
  [ -f "$SRC_BAK" ] || ok "RED skipped: no pre-fix backup on disk"
fi
if [ -f "$PROMPT_BAK" ] && grep -qF 'Mode: $PRE_FLIGHT_MODE' "$PROMPT_BAK" 2>/dev/null; then
  ok "RED confirmed: pre-fix dispatch-v-pre-flight.md unconditionally echoed \$PRE_FLIGHT_MODE (the raw REQUEST, not the effective MODE) into the report's Mode: line"
else
  [ -f "$PROMPT_BAK" ] && no "RED fixture vacuous — pre-fix prompt already avoided the raw echo" || ok "RED skipped: no pre-fix prompt backup on disk"
fi

echo
echo "== Wiring checks on the ACTUAL shipped files (not just extracted logic) =="
if grep -q 'git diff --cached --name-only' "$SRC" && grep -q 'IN_SCOPE_FILE_COUNT="\${_TOTAL_CHANGED:-}"' "$SRC"; then
  ok "v-run-gates.sh's IN_SCOPE_FILE_COUNT computation includes 'git diff --cached --name-only' (staged)"
else
  no "IN_SCOPE_FILE_COUNT wiring not found in the shipped script"
fi
if grep -q 'echo "IN_SCOPE_FILE_COUNT=\${IN_SCOPE_FILE_COUNT:-}"' "$SRC" && grep -q 'echo "PFM_REQUESTED=\${_PFM_REQUESTED_ORIG}"' "$SRC"; then
  ok "v-run-gates.sh actually WRITES IN_SCOPE_FILE_COUNT and PFM_REQUESTED to the durable summary (wired, not just computed)"
else
  no "summary-write wiring for IN_SCOPE_FILE_COUNT/PFM_REQUESTED not found"
fi
if grep -q '_F93_HB_PIN' "$SRC"; then
  ok "v-run-gates.sh's BASE_SHA_FOR_DIFF pin logic (_F93_HB_PIN) is present in the shipped script"
else
  no "F9-3 pin logic not found in the shipped script"
fi
if grep -qF 'IN_SCOPE_FILE_COUNT' "$PROMPT" && grep -qF 'MUST be built from `MODE=`' "$PROMPT"; then
  ok "dispatch-v-pre-flight.md instructs the runner to cite IN_SCOPE_FILE_COUNT and build Mode: from MODE= (not \$PRE_FLIGHT_MODE)"
else
  no "dispatch-v-pre-flight.md wiring for the F9 instructions not found"
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
