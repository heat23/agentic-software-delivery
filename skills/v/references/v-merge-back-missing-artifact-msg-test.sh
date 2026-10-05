#!/usr/bin/env bash
# v-merge-back-missing-artifact-msg-test.sh — E1 (forensic 2026-06-17).
#
# A production session ran v-merge-back.sh while VERIFY_DONE was still being produced (a gate dispatched with
# run_in_background). PRE_FLIGHT + AGENT_REVIEW were already on disk (in .v/artifacts); only VERIFY_DONE
# was absent. The OLD merge-back error was the generic "PRE_FLIGHT, AGENT_REVIEW, and/or VERIFY_DONE
# missing" — so the model had to manually probe root vs .v/artifacts to discover WHICH one was missing
# (~minutes of thrash + premature re-runs). E1 makes the message name EXACTLY which artifact is absent and
# which are present (control-flow-identical to the old `&&` chain). This harness drives the REAL
# v-merge-back.sh and asserts the precise present/MISSING split, plus that a complete set still merges.
set -u
MB="$HOME/.claude/skills/v/references/v-merge-back.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$MB" ] || { echo "NO v-merge-back.sh missing"; exit 1; }

SID="e1e1e1e1-0000-1111-2222-333344445555"; S8=$(printf '%s' "$SID" | cut -c1-8)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
OUTF="$TMP/out"; RC=0

mk_repo(){  # $1=dir
  rm -rf "$1"; mkdir -p "$1"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main && printf 'l1\nl2\n' > app.php && git add -A && git commit -qm init ) >/dev/null 2>&1
  mkdir -p "$1/.v/tmp" "$1/.v/artifacts"
}
# create an owned worktree (path carries -<sid8> -> ownership proven), commit a non-overlapping change.
wt_setup(){  # $1=repo $2=wt-abs $3=branch $4=newfile
  git -C "$1" worktree add -q "$2" -b "$3" HEAD 2>/dev/null
  ( cd "$2" && echo new > "$4" && git add "$4" && git commit -qm "wt work" ) >/dev/null 2>&1
  printf '%s\n' "$4" > "$1/.v/tmp/session-writes-${SID}.txt"
}
# write a gauntlet artifact (PREFIX) into the repo-root .v/artifacts (a location _gate_have searches).
art(){  # $1=repo $2=PREFIX $3=body
  printf '%b' "$3" > "$1/.v/artifacts/${2}_${SID}.md"
}
PF='Model: haiku\n## Gates\n| PASS | tests |\nbody padding for the preflight artifact minimum size requirement here now.\n'
# H4-6 (PLAN_2026-07-02_orchestrator-hardening-4): v-merge-back.sh's gate now ALSO runs Stop-grade
# semantic validation (validate_review_semantics) on AGENT_REVIEW — this fixture must be minimally
# COMPLIANT (6 metadata fields + the session id embedded) to pass it, same as the real Stop hook
# always required; this test is about the missing-artifact MESSAGE precision, not review content.
AR='Model: haiku\n\n## Agent Review — '"$SID"'\n\n- Status: completed\n- Agents dispatched: none\n- Codex adversarial reviewer: none\n- Hostile adversarial focus: no\n- Dispatch mode: orchestrator_inline\n- Review evidence: No issues found\n- Remediation: no findings\n\n## Findings\n\nno issues — synthetic agent review body padding to satisfy the size floor.\n'
VD='Model: haiku\nMode: scoped\nChanged: 1\n\n## Summary\nok\n\nOverall Verdict: PASS\n'
IM='Model: haiku\nsubsystems:\n- functional_flow\n\nreporting_metrics: n/a\ncache_invalidation: n/a\ndb_integrity: n/a\npadding padding padding padding padding padding padding padding.\n'
QA='Model: haiku\n\n## QA Acceptance\n\nverdict: pass\n\npadding padding padding padding padding padding padding padding padding padding padding.\n'
run_mb(){  # $1=repo $2=wt
  ( cd "$1" && V_TMP_DIR="$1/.v/tmp" REPO_ROOT="$1" bash "$MB" "$SID" "$2" ) > "$OUTF" 2>&1
  RC=$?
}

echo "== v-merge-back missing-artifact message precision (E1) =="

# 1. THE ORIGINAL CASE: PRE_FLIGHT + AGENT_REVIEW present, VERIFY_DONE absent -> error names exactly that.
R1="$TMP/r1"; mk_repo "$R1"
wt_setup "$R1" "$R1/.worktrees/fix-feat01-${S8}" "fix/new-feature-01" "feat01.php"
art "$R1" PRE_FLIGHT_REPORT "$PF"; art "$R1" AGENT_REVIEW "$AR"   # NO VERIFY_DONE
run_mb "$R1" "$R1/.worktrees/fix-feat01-${S8}"
{ grep -q "MISSING: VERIFY_DONE_REPORT" "$OUTF" && grep -qE "present: .*PRE_FLIGHT_REPORT" "$OUTF" && grep -qE "present: .*AGENT_REVIEW" "$OUTF" && [ "$RC" -ne 0 ]; } \
  && ok "1 only VERIFY_DONE absent -> names it MISSING + lists the two present (no manual probing)" \
  || no "1 missing-artifact message imprecise (rc=$RC; out: $(grep -i 'MISSING\|required' "$OUTF" | head -1))"

# 2. background-dispatch hint present (the actual root: gate dispatched in background, not yet written).
grep -q "run_in_background" "$OUTF" \
  && ok "2 message hints at the run_in_background race (the real root)" || no "2 no background-dispatch hint"

# 3. COMPLETE SET (incl. IMPACT_MAP + QA): all present -> merges cleanly (regression — message change is
#    control-flow-neutral; a full gauntlet still passes the gate).
R3="$TMP/r3"; mk_repo "$R3"
wt_setup "$R3" "$R3/.worktrees/fix-feat01b-${S8}" "fix/new-feature-01-b" "feat01b.php"
art "$R3" PRE_FLIGHT_REPORT "$PF"; art "$R3" AGENT_REVIEW "$AR"; art "$R3" VERIFY_DONE_REPORT "$VD"
art "$R3" IMPACT_MAP "$IM"; art "$R3" QA_REPORT "$QA"
run_mb "$R3" "$R3/.worktrees/fix-feat01b-${S8}"
{ [ "$RC" -eq 0 ] && grep -q "new" "$R3/feat01b.php" 2>/dev/null; } \
  && ok "3 complete gauntlet -> merges cleanly (control-flow unchanged)" \
  || no "3 complete gauntlet failed to merge (rc=$RC; out: $(tail -2 "$OUTF" | tr '\n' ' '))"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
