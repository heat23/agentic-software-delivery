#!/usr/bin/env bash
# v-landing-layer-fixes-0707-test.sh — BITE for the 2026-07-07 landing-layer forensic fixes:
#   HIGH-1  v-merge-back.sh: a worktree whose ONLY dirtiness is UNTRACKED files (e.g. a generated `.spec.ts`,
#           or an un-ignored node_modules/) must NOT block the merge — the rebase tolerates untracked files,
#           so the branch's real commits LAND (instead of stranding off main forever). Untracked files are
#           NOT committed (an interim `git add -A` would have landed node_modules onto main); they stay in
#           the worktree. TRACKED modifications still hard-block. V_MERGE_STRICT_CLEAN=1 restores the strict
#           "any dirt blocks" behavior.
#   MED-1   v-drain-deferred-merges.sh: a SID-LESS branch (no `-<uuid>` suffix, e.g.
#           'fix/query-metrics-bounds') must derive a filesystem-safe marker key. Before the fix the
#           raw branch name (with '/') flowed into '.v/artifacts/merge-deferred-fix/…md' →
#           "No such file or directory" and the strand record was silently lost.
# Drives the REAL scripts (no stubs for the code under test). Bite: each assertion fails on the pre-fix source.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MB="${MB_OVERRIDE:-$HERE/v-merge-back.sh}"
DRAINER="${DRAINER_OVERRIDE:-$HERE/v-drain-deferred-merges.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skip(){ printf '  skip %s — %s\n' "$1" "${2:-}"; }   # pre-fix backups are not shipped in the public snapshot
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
[ -f "$MB" ]      || { echo "FATAL: v-merge-back.sh missing at $MB"; exit 2; }
[ -f "$DRAINER" ] || { echo "FATAL: v-drain-deferred-merges.sh missing at $DRAINER"; exit 2; }

BASE="$(mktemp -d)"; trap 'rm -rf "$BASE" 2>/dev/null' EXIT
SID="0a0a0a0a-1111-4111-8111-00000000c005"; S8=$(printf '%s' "$SID" | cut -c1-8)

mk_repo(){ # $1=dir
  rm -rf "$1"; mkdir -p "$1"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main && printf 'l1\nl2\n' > app.php && git add -A && git commit -qm init ) >/dev/null 2>&1
  mkdir -p "$1/.v/tmp" "$1/.v/artifacts"
}
run_mb(){ # $1=repo $2=wt ; sets RC + OUT
  OUT="$( cd "$1" && V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 V_TMP_DIR="$1/.v/tmp" REPO_ROOT="$1" \
          bash "$MB" "$SID" "$2" 2>&1 )"; RC=$?
}

echo "== HIGH-1: an untracked file no longer strands the branch's commits (they land; untracked NOT committed) =="
R="$BASE/r1"; mk_repo "$R"
WT="$R/.worktrees/fix-a11y-${SID}"
git -C "$R" worktree add -q "$WT" -b "fix/a11y-strand-${SID}" HEAD 2>/dev/null
# one real commit (the fix) + one UNTRACKED generated spec (the exact 07-07 stranding trigger)
( cd "$WT" && printf 'l1\nl2\nfix\n' > app.php && git add app.php && git commit -qm "fix: a11y contrast" \
  && printf 'test("a11y", () => {});\n' > admin-a11y.spec.ts ) >/dev/null 2>&1
run_mb "$R" "$WT"
{ [ "$RC" -eq 0 ] && git -C "$R" show main:app.php 2>/dev/null | grep -q '^fix$'; } \
  && ok "untracked-only worktree: the fix COMMIT landed on main (rc=0, no strand)" \
  || no "committed work was NOT landed (rc=$RC) — HIGH-1 strand recurs" "$OUT"
git -C "$R" cat-file -e main:admin-a11y.spec.ts 2>/dev/null \
  && no "the UNTRACKED spec was committed to main (interim add -A behavior — should be left in the worktree)" "$OUT" \
  || ok "the untracked spec was NOT committed to main (left in the worktree, not force-landed)"

echo "== HIGH-1 landmine: an un-ignored untracked node_modules/ is NEVER committed onto main =="
RM="$BASE/rm"; mk_repo "$RM"
WTM="$RM/.worktrees/fix-nplusone-${SID}"
git -C "$RM" worktree add -q "$WTM" -b "fix/nplusone-${SID}" HEAD 2>/dev/null
# real test commit + an un-ignored untracked node_modules dir (a repo with no .gitignore)
( cd "$WTM" && printf 'l1\nl2\nt\n' > app.php && git add app.php && git commit -qm "test: n+1 hardening" \
  && mkdir -p node_modules/pkg && printf 'junk\n' > node_modules/pkg/index.js ) >/dev/null 2>&1
run_mb "$RM" "$WTM"
{ [ "$RC" -eq 0 ] && git -C "$RM" show main:app.php 2>/dev/null | grep -q '^t$'; } \
  && ok "test commit landed on main (rc=0)" || no "test commit did not land (rc=$RC)" "$OUT"
git -C "$RM" ls-tree -r --name-only main 2>/dev/null | grep -q '^node_modules' \
  && no "LANDMINE: node_modules was committed onto main by merge-back" "$(git -C "$RM" ls-tree -r --name-only main | grep node_modules)" \
  || ok "node_modules was NOT committed onto main (landmine defused)"

echo "== HIGH-1 negative: a TRACKED uncommitted modification still hard-blocks (guard not weakened) =="
R2="$BASE/r2"; mk_repo "$R2"
WT2="$R2/.worktrees/fix-tracked-${SID}"
git -C "$R2" worktree add -q "$WT2" -b "fix/tracked-${SID}" HEAD 2>/dev/null
( cd "$WT2" && printf 'l1\nl2\nc\n' > app.php && git add app.php && git commit -qm "wt commit" \
  && printf 'l1\nl2\nc\nUNCOMMITTED-EDIT\n' > app.php ) >/dev/null 2>&1   # tracked, unstaged edit left dirty
run_mb "$R2" "$WT2"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "uncommitted changes"; } \
  && ok "tracked modification: hard block preserved (rc=$RC, non-zero)" \
  || no "tracked modification was NOT blocked (rc=$RC) — guard weakened" "$OUT"

echo "== HIGH-1 opt-out: V_MERGE_STRICT_CLEAN=1 restores the strict blanket block =="
R3="$BASE/r3"; mk_repo "$R3"
WT3="$R3/.worktrees/fix-optout-${SID}"
git -C "$R3" worktree add -q "$WT3" -b "fix/optout-${SID}" HEAD 2>/dev/null
( cd "$WT3" && printf 'l1\nl2\nx\n' > app.php && git add app.php && git commit -qm "wt commit" \
  && printf 'stray\n' > stray.spec.ts ) >/dev/null 2>&1
OUT="$( cd "$R3" && V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 V_TMP_DIR="$R3/.v/tmp" REPO_ROOT="$R3" \
        V_MERGE_STRICT_CLEAN=1 bash "$MB" "$SID" "$WT3" 2>&1 )"; RC=$?
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "uncommitted changes"; } \
  && ok "opt-out honored: untracked-only worktree hard-blocks under V_MERGE_STRICT_CLEAN=1" \
  || no "opt-out ignored (rc=$RC)" "$OUT"

echo "== MED-1: drain writes a filesystem-safe marker for a SID-less branch (no 'No such file or directory') =="
R4="$BASE/r4"; mk_repo "$R4"
WT4="$R4/.worktrees/fix-query-metrics-bounds"
git -C "$R4" worktree add -q "$WT4" -b "fix/query-metrics-bounds" HEAD 2>/dev/null   # NO SID suffix, lockless
( cd "$WT4" && printf 'l1\nl2\ng\n' > app.php && git add app.php && git commit -qm "fix: bounds" ) >/dev/null 2>&1
STUB="$BASE/mb-stub.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB"; chmod +x "$STUB"
OUT="$( V_DRAIN_MERGEBACK="$STUB" V_DRAIN_DEAD_AGE_MIN=0 bash "$DRAINER" "$R4" 2>&1 )"
printf '%s' "$OUT" | grep -qF "No such file or directory" \
  && no "MED-1: SID-less branch still produces an invalid marker path" "$OUT" \
  || ok "MED-1: no 'No such file or directory' — marker path is slash-safe"
printf '%s' "$OUT" | grep -qF "recorded undocumented strand for fix/query-metrics-bounds" \
  && printf '%s' "$OUT" | grep -qE 'merge-deferred-fix-query-metrics-bounds\.md' \
  && ok "MED-1: strand recorded to sanitized key 'merge-deferred-fix-query-metrics-bounds.md'" \
  || no "MED-1: strand record for the SID-less branch was lost (pre-fix behavior)" "$OUT"

echo "== A2a-EXT: an OUT-OF-BAND ADOPTED worktree is re-attributed to the commit-witness owner (not the phantom minter) =="
# forensic: the branch dir/suffix names the MINTER sid which committed NOTHING (empty
# witness, no-isolation verify-done); an adopter session did the real work + filed its gauntlet under ITS sid.
# The drain must re-attribute by the commit-witness that names the branch TIP, or it false-blocks landable work.
R5="$BASE/r5"; mk_repo "$R5"
MINTER="55500000-0000-4000-8000-000000000000"   # branch-suffix UUID; committed NOTHING (phantom)
ADOPTER="ff800000-0000-4000-8000-000000000000"  # did the real work; its witness lists the branch tip
WT5="$R5/.worktrees/fix-deploy-${MINTER}"
git -C "$R5" worktree add -q "$WT5" -b "fix/deploy-${MINTER}" HEAD 2>/dev/null
( cd "$WT5" && printf 'fix\n' >> app.php && git add -A && git commit -qm "adopter work" ) >/dev/null 2>&1
rm -f "$WT5/.claude-session-lock"   # session ended → drain resolves sid via the branch suffix (the MINTER)
TIP5="$(git -C "$R5" rev-parse "fix/deploy-${MINTER}")"
printf '%s\n' "$TIP5" > "$R5/.v/artifacts/commits-${ADOPTER}.txt"   # adopter's HMAC witness names the tip
: > "$R5/.v/artifacts/commits-${MINTER}.txt"                        # minter's witness is EMPTY (phantom)
printf 'Model: haiku\nOverall: APPROVED\ncritical:0 high:0\n' > "$R5/.v/artifacts/AGENT_REVIEW_${ADOPTER}.md"  # C-1 keys on RESOLVED sid
run_drain5(){ V_DRAIN_DRY_RUN=1 V_DRAIN_DEAD_AGE_MIN=0 bash "$1" "$R5" 2>&1; }
OUT="$(run_drain5 "$DRAINER")"
{ printf '%s' "$OUT" | grep -qF "re-attributed fix/deploy-${MINTER}" && printf '%s' "$OUT" | grep -qF "commit-witness owner ${ADOPTER}"; } \
  && ok "A2a-EXT: phantom-minter branch re-attributed to the commit-witness owner (adopter)" \
  || no "A2a-EXT: adopted branch NOT re-attributed to the adopter" "$OUT"
printf '%s' "$OUT" | grep -qF "would drain (session ended): v-merge-back.sh ${ADOPTER}" \
  && ok "A2a-EXT: drain resolves the merge to the ADOPTER sid (its valid gauntlet lands the work)" \
  || no "A2a-EXT: drain did not resolve the merge to the adopter" "$OUT"
BAK5="$DRAINER.pre-adoption-bak"
if [ -f "$BAK5" ]; then
  OUTB="$(run_drain5 "$BAK5")"
  printf '%s' "$OUTB" | grep -qF "commit-witness owner ${ADOPTER}" \
    && no "A2a-EXT RED: pre-fix drain ALSO re-attributed (fix not new)" "$OUTB" \
    || ok "A2a-EXT RED: pre-fix drain trusts the phantom minter UUID (no re-attribution) — the fix is new"
else skip "A2a-EXT RED oracle absent" "$BAK5"; fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
