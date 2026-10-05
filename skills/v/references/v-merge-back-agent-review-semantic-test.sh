#!/usr/bin/env bash
# v-merge-back-agent-review-semantic-test.sh — H4-6 (PLAN_2026-07-02_orchestrator-hardening-4)
#
# v-merge-back.sh's artifact-presence gate previously checked PRESENCE only — never
# validate_review_semantics — so a hostile-undeclared AGENT_REVIEW (a production-session shape: a
# billing/auth diff whose review claims 'Hostile adversarial focus: no') could merge to main even
# though the Stop hook would reject it moments later. This proves the merge's OWN gate now refuses
# that shape directly (defense-in-depth alongside v-gauntlet-attest.sh's own H4-6 check).
set -u
MB="${V_MB_OVERRIDE:-$HOME/.claude/skills/v/references/v-merge-back.sh}"
MB_BAK="$HOME/.claude/skills/v/references/v-merge-back.sh.pre-h4-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
_GW_LIB_CHECK="$HOME/.claude/hooks/lib/validation.sh"
[ -f "$_GW_LIB_CHECK" ] || { echo "SKIP: validation.sh missing"; exit 0; }

SID="6a6b6c6d-1111-4222-8333-444455556666"; S8=$(printf '%s' "$SID" | cut -c1-8)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
OUTF="$TMP/out"; RC=0

mk_repo(){  # $1=dir
  rm -rf "$1"; mkdir -p "$1"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main && printf 'l1\nl2\n' > app.php && git add -A && git commit -qm init \
    && printf 'x\n' > billing.php && git add billing.php && git commit -qm "billing (already-in-history so worktree fork-base includes it; the hostile signal comes from the SESSION-WRITES marker below, matching how the real orchestrator's writes-log works)" ) >/dev/null 2>&1
  mkdir -p "$1/.v/tmp" "$1/.v/artifacts"
}
wt_setup(){  # $1=repo $2=wt-abs $3=branch $4=newfile
  git -C "$1" worktree add -q "$2" -b "$3" HEAD 2>/dev/null
  ( cd "$2" && echo new >> billing.php && git add billing.php && git commit -qm "wt billing work" ) >/dev/null 2>&1
  # session-writes log names billing.php -> v-hostile-required.sh's --sid path finds it hostile.
  printf 'billing.php\n' > "$1/.v/tmp/session-writes-${SID}.txt"
}
art(){ printf '%b' "$3" > "$1/.v/artifacts/${2}_${SID}.md"; }

PF='Model: haiku\n## Gates\n| PASS | tests |\nbody padding for the preflight artifact minimum size requirement here now.\n'
VD='Model: haiku\nMode: scoped\nChanged: 1\n\n## Summary\nok\n\nOverall Verdict: PASS\n'
IM='Model: haiku\nsubsystems:\n- functional_flow\n\nreporting_metrics: n/a\ncache_invalidation: n/a\ndb_integrity: n/a\npadding padding padding padding padding padding padding padding.\n'
QA='Model: haiku\n\n## QA Acceptance\n\nverdict: pass\n\npadding padding padding padding padding padding padding padding padding padding padding.\n'
# HOSTILE-UNDECLARED: claims 'Hostile adversarial focus: no' on a billing diff — the production-session shape.
AR_BAD='Model: haiku\n\n## Agent Review — '"$SID"'\n\n- Status: completed\n- Agents dispatched: none\n- Codex adversarial reviewer: none\n- Hostile adversarial focus: no\n- Dispatch mode: orchestrator_inline\n- Review evidence: No issues found\n- Remediation: no findings\n\n## Findings\n\nNone.\n'
run_mb(){  # $1=script $2=repo $3=wt
  ( cd "$2" && V_TMP_DIR="$2/.v/tmp" REPO_ROOT="$2" bash "$1" "$SID" "$3" ) > "$OUTF" 2>&1
  RC=$?
}

echo "== v-merge-back :: H4-6 AGENT_REVIEW semantic gate (hostile-undeclared class) =="

R1="$TMP/r1"; mk_repo "$R1"
wt_setup "$R1" "$R1/.worktrees/fix-h46-${S8}" "fix/h46-billing" "billing.php"
art "$R1" PRE_FLIGHT_REPORT "$PF"; art "$R1" AGENT_REVIEW "$AR_BAD"; art "$R1" VERIFY_DONE_REPORT "$VD"
art "$R1" IMPACT_MAP "$IM"; art "$R1" QA_REPORT "$QA"
run_mb "$MB" "$R1" "$R1/.worktrees/fix-h46-${S8}"
{ [ "$RC" -ne 0 ] && grep -qi 'semantic' "$OUTF"; } \
  && ok "fixed: hostile-undeclared AGENT_REVIEW on a billing diff -> merge REFUSED (rc=$RC)" \
  || no "fixed: expected refusal citing semantic validation (rc=$RC; out: $(tail -3 "$OUTF" | tr '\n' ' '))"

if [ -f "$MB_BAK" ]; then
  R2="$TMP/r2"; mk_repo "$R2"
  wt_setup "$R2" "$R2/.worktrees/fix-h46b-${S8}" "fix/h46-billing-b" "billing.php"
  art "$R2" PRE_FLIGHT_REPORT "$PF"; art "$R2" AGENT_REVIEW "$AR_BAD"; art "$R2" VERIFY_DONE_REPORT "$VD"
  art "$R2" IMPACT_MAP "$IM"; art "$R2" QA_REPORT "$QA"
  run_mb "$MB_BAK" "$R2" "$R2/.worktrees/fix-h46b-${S8}"
  [ "$RC" -eq 0 ] \
    && ok "backup: hostile-undeclared review WAS merged pre-fix (presence-only gate, confirms the gap)" \
    || no "backup: expected the pre-fix gate to merge anyway (presence-only)" "rc=$RC"
else
  echo "  SKIP: no backup at $MB_BAK"
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
