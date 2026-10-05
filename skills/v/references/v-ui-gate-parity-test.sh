#!/usr/bin/env bash
# v-ui-gate-parity-test.sh — P1.1 (forensic, 2026-06-15).
#
# A production session shipped React .tsx changes to main with NO UX_CRITIQUE and NO WORKFLOW_VERIFICATION.
# Root cause: the producer self-check detected UI by the model-set flag V_UI_SESSION (the orchestrator
# never set it) while the Stop hook detects UI by PATH — a producer↔gate divergence on the UI axis. The
# merge-back (the irreversible step) didn't path-detect UI either, so the Stop hook's block came too late.
#
# This harness locks the two-pronged fix:
#   PART A — v-merge-back.sh refuses to merge a worktree whose COMMITTED diff touches user-facing UI
#            unless UX_CRITIQUE + WORKFLOW_VERIFICATION (status pass|degraded) exist for the SID.
#   PART B — v-completion-selfcheck.sh path-detects UI (any_user_facing_ui over get_session_writes), so
#            a UI session with no V_UI_SESSION flag still REQUIRES UX/WORKFLOW — agreeing with the Stop hook.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MB="$HERE/v-merge-back.sh"
SELFCHK="${V_SELFCHECK_OVERRIDE:-$HERE/v-completion-selfcheck.sh}"
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset V_MERGE_BACK_SKIP_ARTIFACT_GATE 2>/dev/null || true
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# base gauntlet artifacts so _gate_ok reaches the UI sub-gate (PRE_FLIGHT+AGENT_REVIEW+VERIFY_DONE PASS).
# F3 (2026-06-17): merge-back now also requires IMPACT_MAP + QA for code-gauntlet sessions, so the base set
# must include them to reach the UI sub-gate under test here (the UI gate is downstream of the F3 gate).
plant_base() { local d="$1" sid="$2"
  mkdir -p "$d"
  printf 'Model: haiku\nOverall Status: PASS\n' > "$d/PRE_FLIGHT_REPORT_${sid}.md"
  printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: logic-reviewer (independent subprocess)\n- Codex adversarial reviewer: ran — 0 candidates (background agent)\n- Reviewer model: sonnet\n- Hostile adversarial focus: no\n- Dispatch mode: foreground\n- Review evidence: findings: 0\n- Remediation: 0 — no findings\n\n## Findings\n\nNo issues found.\n' "${sid}" > "$d/AGENT_REVIEW_${sid}.md"
  printf 'Model: haiku\nMode: scoped(writes-log)\nChanged: 1\nOverall Verdict: PASS\n' > "$d/VERIFY_DONE_REPORT_${sid}.md"
  printf 'Model: haiku\nsubsystems:\n- functional_flow\n' > "$d/IMPACT_MAP_${sid}.md"
  printf 'Model: haiku\n## QA Acceptance\nverdict: pass\n' > "$d/QA_REPORT_${sid}.md"
}
# new_repo <name> <sid> <uichange:ui|nonui> -> R, WT, BR
new_repo() { local name="$1" sid="$2" kind="$3"
  R="$WORK/$name"; mkdir -p "$R"; git -C "$R" init -q
  printf '.v/\n.worktrees/\n' > "$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -q -m init
  BR="build/ui-$sid"; WT="$WORK/$name-wt"; git -C "$R" worktree add -q -b "$BR" "$WT" >/dev/null 2>&1
  if [ "$kind" = ui ]; then
    mkdir -p "$WT/resources/js/Pages"; printf 'export default function P(){return null}\n' > "$WT/resources/js/Pages/Dashboard.tsx"
    git -C "$WT" add resources/js/Pages/Dashboard.tsx
  else
    mkdir -p "$WT/app/Services"; printf '<?php class Svc {}\n' > "$WT/app/Services/Svc.php"
    git -C "$WT" add app/Services/Svc.php
  fi
  git -C "$WT" commit -q -m "feat: ui-gate fixture ($kind)"
}

echo "== PART A :: v-merge-back UI gate (committed-diff path detection) =="

# A1 — UI diff, base artifacts, NO UX/WORKFLOW -> BLOCKED
SID=a1a1a1a1-0000-4000-8000-0000000000a1; new_repo a1 "$SID" ui; plant_base "$WT/.v/artifacts" "$SID"
OUT=$(bash "$MB" "$SID" "$WT" 2>&1); RC=$?
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qi 'UX_CRITIQUE.*missing'; } && ok "A1 UI diff w/o UX_CRITIQUE → merge BLOCKED" || no "A1 expected UX block (rc=$RC): $(printf '%s' "$OUT" | grep -i ux | head -1)"
grep -q 'export default' "$R/resources/js/Pages/Dashboard.tsx" 2>/dev/null && no "A1 UI content reached main despite block" || ok "A1 UI content NOT merged"

# A2 — UI diff + UX_CRITIQUE + WORKFLOW(status: pass) -> MERGE
SID=a2a2a2a2-0000-4000-8000-0000000000a2; new_repo a2 "$SID" ui; plant_base "$WT/.v/artifacts" "$SID"
printf 'Model: haiku\n## UX Critique\nno issues\n' > "$WT/.v/artifacts/UX_CRITIQUE_${SID}.md"
printf 'Model: haiku\n## Workflow Verification\nstatus: pass\n' > "$WT/.v/artifacts/WORKFLOW_VERIFICATION_${SID}.md"
OUT=$(bash "$MB" "$SID" "$WT" 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qi 'UX_CRITIQUE.*missing\|WORKFLOW_VERIFICATION.*missing'; } && ok "A2 UI diff + UX + WORKFLOW(pass) → merge succeeds" || no "A2 expected merge (rc=$RC): $(printf '%s' "$OUT" | tail -3)"
grep -q 'export default' "$R/resources/js/Pages/Dashboard.tsx" 2>/dev/null && ok "A2 UI content merged after gate satisfied" || no "A2 UI content missing post-merge"

# A3 — UI diff + UX + WORKFLOW(status: fail) -> BLOCKED
SID=a3a3a3a3-0000-4000-8000-0000000000a3; new_repo a3 "$SID" ui; plant_base "$WT/.v/artifacts" "$SID"
printf 'Model: haiku\n## UX Critique\nok\n' > "$WT/.v/artifacts/UX_CRITIQUE_${SID}.md"
printf 'Model: haiku\n## Workflow Verification\nstatus: fail\n' > "$WT/.v/artifacts/WORKFLOW_VERIFICATION_${SID}.md"
OUT=$(bash "$MB" "$SID" "$WT" 2>&1); RC=$?
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qi 'WORKFLOW_VERIFICATION status is FAIL'; } && ok "A3 WORKFLOW status:fail → merge BLOCKED" || no "A3 expected fail block (rc=$RC): $(printf '%s' "$OUT" | grep -i workflow | head -1)"

# A4 — UI diff + UX + WORKFLOW(status: degraded) -> MERGE (honest fallback accepted)
SID=a4a4a4a4-0000-4000-8000-0000000000a4; new_repo a4 "$SID" ui; plant_base "$WT/.v/artifacts" "$SID"
printf 'Model: haiku\n## UX Critique\nok\n' > "$WT/.v/artifacts/UX_CRITIQUE_${SID}.md"
printf 'Model: haiku\n## Workflow Verification\nstatus: degraded\ndegraded_reason: no browser env\n' > "$WT/.v/artifacts/WORKFLOW_VERIFICATION_${SID}.md"
OUT=$(bash "$MB" "$SID" "$WT" 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qi 'WORKFLOW_VERIFICATION.*missing\|status is FAIL'; } && ok "A4 WORKFLOW status:degraded → merge succeeds (honest fallback)" || no "A4 expected merge (rc=$RC): $(printf '%s' "$OUT" | tail -3)"

# A5 — NON-UI diff (.php), base artifacts, NO UX/WORKFLOW -> MERGE (UI gate not triggered, no FP)
SID=a5a5a5a5-0000-4000-8000-0000000000a5; new_repo a5 "$SID" nonui; plant_base "$WT/.v/artifacts" "$SID"
OUT=$(bash "$MB" "$SID" "$WT" 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qi 'UX_CRITIQUE\|WORKFLOW_VERIFICATION'; } && ok "A5 non-UI diff → UI gate NOT triggered (no false-block)" || no "A5 expected clean merge (rc=$RC): $(printf '%s' "$OUT" | tail -3)"

echo ""
echo "== PART B :: v-completion-selfcheck UI path-detection (no V_UI_SESSION flag) =="

# self-check fixture: full gauntlet so the ONLY variable is UI detection. UX message keyed.
sc_repo() { local name="$1" sid="$2" kind="$3"
  SR="$WORK/$name"; mkdir -p "$SR/.v/artifacts"
  git -C "$SR" init -q; ( cd "$SR" && echo x>f && git add f && git commit -q -m init )
  local d="$SR/.v/artifacts" PAD; PAD=$(printf 'x%.0s' $(seq 1 1200))
  printf 'Model: haiku\nMode: scoped\n## Gates\n| PASS | Tests | 10/0 |\n%s\nOverall Status: PASS\n' "$PAD" > "$d/PRE_FLIGHT_REPORT_${sid}.md"
  printf 'Model: haiku\n\n## Agent Review — %s\n- Status: completed\n- Agents dispatched: logic-reviewer\n- Codex adversarial reviewer: codex-adversarial-reviewer dispatched (claude_accepted: 1)\n- Hostile adversarial focus: no\n- Dispatch mode: subagent\n- Review evidence: findings: 0\n- Remediation: none\nOverall: APPROVED\n%s\n' "$sid" "$PAD" > "$d/AGENT_REVIEW_${sid}.md"
  printf 'Model: haiku\nOverall Verdict: PASS\n%s\n' "$PAD" > "$d/VERIFY_DONE_REPORT_${sid}.md"
  printf 'Model: haiku\nsubsystems:\n- functional_flow\nreporting_metrics: n/a\ncache_invalidation: n/a\ndb_integrity: n/a\n%s\n' "$PAD" > "$d/IMPACT_MAP_${sid}.md"
  printf 'Model: haiku\n\n## QA Acceptance\nverdict: pass\n%s\n' "$PAD" > "$d/QA_REPORT_${sid}.md"
  printf 'DISPATCH|ts=2026-06-15T00:00:00Z|agent=codex-adversarial-reviewer|mode=foreground|status=ok|artifact=AGENT_REVIEW_%s.md\nDISPATCH|ts=2026-06-15T00:00:00Z|agent=v-qa-reviewer|mode=self-write|status=ok|artifact=QA_REPORT_%s.md\n' "$sid" "$sid" > "$d/DISPATCH_PROVENANCE_${sid}.log"
  # plant the session-writes log get_session_writes reads (git-common-dir)
  if [ "$kind" = ui ]; then printf 'resources/js/Pages/Dashboard.tsx\n' > "$SR/.git/claude-session-writes-${sid}.txt"
  else printf 'app/Services/Svc.php\n' > "$SR/.git/claude-session-writes-${sid}.txt"; fi
}
run_sc() { ( cd "$1" && env -u V_UI_SESSION CLAUDE_CODE_SESSION_ID="$2" CLAUDE_SESSION_ID="$2" bash "$SELFCHK" 2>&1 ); }
UXMSG='UX_CRITIQUE|WORKFLOW_VERIFICATION'

# B1 — UI writes, NO V_UI_SESSION, NO UX/WORKFLOW -> self-check now REQUIRES them (path-detected)
SID=b1b1b1b1-0000-4000-8000-0000000000b1; sc_repo b1 "$SID" ui
run_sc "$SR" "$SID" | grep -qiE "$UXMSG" && ok "B1 UI writes (no V_UI_SESSION) → self-check requires UX/WORKFLOW (path-detected)" || no "B1 path-detection FAILED — /v would ship UI unverified"

# B2 — UI writes + UX_CRITIQUE + WORKFLOW(pass) present -> UI requirement satisfied
SID=b2b2b2b2-0000-4000-8000-0000000000b2; sc_repo b2 "$SID" ui
printf 'Model: haiku\n## UX Critique\nok\n' > "$SR/.v/artifacts/UX_CRITIQUE_${SID}.md"
printf 'Model: haiku\n## Workflow Verification\nstatus: pass\n' > "$SR/.v/artifacts/WORKFLOW_VERIFICATION_${SID}.md"
run_sc "$SR" "$SID" | grep -qiE 'UX_CRITIQUE .*not|WORKFLOW_VERIFICATION .*(not|missing)' && no "B2 UX/WF present but self-check still complains" || ok "B2 UI writes + UX + WORKFLOW(pass) → UI requirement satisfied"

# B3 — NON-UI writes, NO V_UI_SESSION, NO UX/WORKFLOW -> NOT a UI session (no UX requirement; no FP)
SID=b3b3b3b3-0000-4000-8000-0000000000b3; sc_repo b3 "$SID" nonui
run_sc "$SR" "$SID" | grep -qiE "$UXMSG" && no "B3 non-UI session FALSE-required UX/WORKFLOW" || ok "B3 non-UI writes → no UX/WORKFLOW requirement (no false-positive)"

# B4 (codex MEDIUM) — EMPTY writes-log but a COMMITTED UI diff + head-baseline: the self-check must
# fall back to the git diff (baseline..HEAD), like the Stop hook, and still path-detect UI. Without
# this, a forked-runner/inline-on-main UI session (empty writes log) passes the self-check while the
# Stop hook blocks it — the producer↔gate disagreement, re-opened on the empty-writes axis.
SID=b4b4b4b4-0000-4000-8000-0000000000b4; sc_repo b4 "$SID" nonui
rm -f "$SR/.git/claude-session-writes-${SID}.txt"                       # force get_session_writes empty
mkdir -p "$SR/.v/tmp"
_b4base=$(git -C "$SR" rev-parse HEAD); printf '%s\n' "$_b4base" > "$SR/.v/tmp/head-baseline-${SID}.txt"
mkdir -p "$SR/resources/js/Pages"; printf 'export default function P(){return null}\n' > "$SR/resources/js/Pages/Dash.tsx"
( cd "$SR" && git add resources/js/Pages/Dash.tsx && git commit -q -m "feat: committed UI" )
run_sc "$SR" "$SID" | grep -qiE "$UXMSG" && ok "B4 empty writes-log + committed UI diff → git-diff fallback path-detects UI (forked-runner parity)" || no "B4 git-diff fallback did NOT detect UI — producer↔gate gap on empty-writes axis"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
