#!/usr/bin/env bash
# v-merge-back-marker-resurrection-test.sh — H4-12 (PLAN_2026-07-02_orchestrator-hardening-4)
#
# Ground truth: a GAUNTLET_SKIPPED_<sid8> marker was resurrected by a session's FND-2 auto-stash restore
# (mtime proved it was the restored copy) — the marker was on disk at stash-push time, got
# legitimately GC'd (rm -f) by another process in the window before this merge-back's stash APPLY
# ran, and the apply recreated the stale file. This directly exercises v-merge-back.sh's stash
# round-trip: plant a marker, stash it, delete it (simulating the concurrent GC), stash-restore, and
# assert the resurrected copy is removed because the marker's SID gauntlet is provably complete.
set -u
MB="${V_MB_OVERRIDE:-$HOME/.claude/skills/v/references/v-merge-back.sh}"
MB_BAK="$HOME/.claude/skills/v/references/v-merge-back.sh.pre-h4-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

SID="9a9b9c9d-1111-4222-8333-444455556666"; S8=$(printf '%s' "$SID" | cut -c1-8)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
OUTF="$TMP/out"

mk_repo(){
  rm -rf "$1"; mkdir -p "$1"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main && printf 'l1\n' > app.php && git add -A && git commit -qm init ) >/dev/null 2>&1
  mkdir -p "$1/.v/tmp" "$1/.v/artifacts"
}
wt_setup(){
  git -C "$1" worktree add -q "$2" -b "$3" HEAD 2>/dev/null
  ( cd "$2" && echo new > "$4" && git add "$4" && git commit -qm "wt work" ) >/dev/null 2>&1
  printf '%s\n' "$4" > "$1/.v/tmp/session-writes-${SID}.txt"
}
art(){ printf '%b' "$3" > "$1/.v/artifacts/${2}_${SID}.md"; }
PF='Model: haiku\n## Gates\n| PASS | tests |\nbody padding for the preflight artifact minimum size requirement here now.\n'
VD='Model: haiku\nMode: scoped\nChanged: 1\n\n## Summary\nok\n\nOverall Verdict: PASS\n'
IM='Model: haiku\nsubsystems:\n- functional_flow\n\nreporting_metrics: n/a\ncache_invalidation: n/a\ndb_integrity: n/a\npadding padding padding padding padding padding padding padding.\n'
QA='Model: haiku\n\n## QA Acceptance\n\nverdict: pass\n\npadding padding padding padding padding padding padding padding padding padding padding.\n'
AR='Model: haiku\n\n## Agent Review — '"$SID"'\n\n- Status: completed\n- Agents dispatched: none\n- Codex adversarial reviewer: none\n- Hostile adversarial focus: no\n- Dispatch mode: orchestrator_inline\n- Review evidence: No issues found\n- Remediation: no findings\n\n## Findings\n\nNone.\n'

echo "== v-merge-back :: H4-12 stash round-trip must not resurrect a GC'd gauntlet marker =="

R="$TMP/r1"; mk_repo "$R"
wt_setup "$R" "$R/.worktrees/fix-h412-${S8}" "fix/h412-marker" "h412.php"
art "$R" PRE_FLIGHT_REPORT "$PF"; art "$R" AGENT_REVIEW "$AR"; art "$R" VERIFY_DONE_REPORT "$VD"
art "$R" IMPACT_MAP "$IM"; art "$R" QA_REPORT "$QA"

# Plant a GAUNTLET_SKIPPED marker for THIS sid at repo root — the gauntlet is actually COMPLETE
# (all 3 artifacts exist above), so this marker represents STALE information (as if written by an
# earlier partial run, later superseded by the completed gauntlet).
echo "# stale skip marker" > "$R/GAUNTLET_SKIPPED_${SID}.md"

# Force the FND-2 auto-stash path: leave an UNRELATED foreign uncommitted file on main so
# v-merge-back's own dirty-tree stash-push captures the whole working tree (marker included).
echo "foreign wip" > "$R/foreign.txt"

( cd "$R" && V_TMP_DIR="$R/.v/tmp" REPO_ROOT="$R" bash "$MB" "$SID" "$R/.worktrees/fix-h412-${S8}" ) > "$OUTF" 2>&1
RC=$?

[ "$RC" -eq 0 ] && ok "merge-back succeeded (rc=0)" || no "merge-back failed unexpectedly (rc=$RC; out: $(tail -3 "$OUTF" | tr '\n' ' '))"
[ -f "$R/foreign.txt" ] && ok "foreign uncommitted WIP restored after the stash round-trip (FND-2 still works)" \
  || no "foreign.txt not restored — stash restore may be broken"
[ ! -f "$R/GAUNTLET_SKIPPED_${SID}.md" ] \
  && ok "H4-12 fixed: the stale GAUNTLET_SKIPPED marker was NOT resurrected (removed post-restore)" \
  || no "H4-12: the stale marker was resurrected by the stash round-trip"
grep -qi 'H4-12' "$OUTF" && ok "merge-back logged the H4-12 marker-GC action" || no "no H4-12 log line found"

echo "-- RED: pre-edit backup must resurrect the marker (no GC step existed) --"
if [ -f "$MB_BAK" ]; then
  R2="$TMP/r2"; mk_repo "$R2"
  wt_setup "$R2" "$R2/.worktrees/fix-h412b-${S8}" "fix/h412-marker-b" "h412b.php"
  art "$R2" PRE_FLIGHT_REPORT "$PF"; art "$R2" AGENT_REVIEW "$AR"; art "$R2" VERIFY_DONE_REPORT "$VD"
  art "$R2" IMPACT_MAP "$IM"; art "$R2" QA_REPORT "$QA"
  echo "# stale skip marker" > "$R2/GAUNTLET_SKIPPED_${SID}.md"
  echo "foreign wip" > "$R2/foreign.txt"
  ( cd "$R2" && V_TMP_DIR="$R2/.v/tmp" REPO_ROOT="$R2" bash "$MB_BAK" "$SID" "$R2/.worktrees/fix-h412b-${S8}" ) > "$TMP/out2" 2>&1
  [ -f "$R2/GAUNTLET_SKIPPED_${SID}.md" ] \
    && ok "backup: the stale marker WAS resurrected (confirms the bug pre-fix)" \
    || no "backup: expected the marker to survive the round-trip (pre-fix bug)"
else
  echo "  SKIP: no backup at $MB_BAK"
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
