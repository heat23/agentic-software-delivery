#!/usr/bin/env bash
# v-worktree-gc-staged-backstop-test.sh — F3-item3 (2026-07-05) "commit-or-preserve" backstop,
# HARDENED per adversarial review HIGH (same day): commit is the PRIVILEGE, preserve the DEFAULT.
#
# A merged (ahead=0) worktree whose owning session has ENDED may still hold STAGED-but-uncommitted
# content — the false-landed-by-reset precursor (a production repo, 2026-07-04: 8 worktrees hand-recovered
# via "checkpoint(...): preserve staged-only session work..." commits; no automatic backstop existed).
# The backstop's auto-commit is only authorized when ALL hold (else it degrades to preservation):
#   (1) lock SID parseable, (2) SID-bound PRE_FLIGHT_REPORT+AGENT_REVIEW artifacts,
#   (3) PRE_FLIGHT verdict PARSED as 'Overall Status: PASS', (4) both >=200B,
#   (5) both artifacts at least as new as the newest staged file (they graded THIS diff).
#
# Cases:
#   A  all five conditions met            -> --apply COMMITS (checkpoint message convention)
#   B  no reports at all                  -> --apply PRESERVES (marker, staged bytes untouched)
#   C  SID-bound reports but FAIL verdict -> PRESERVE, never commit          (review case a)
#   D  unparseable SID + foreign-SID PASS reports present -> PRESERVE        (review case b)
#   E  PASS reports STALER than the staged writes -> PRESERVE                (review case c)
# Plus: DRY-RUN is non-destructive for all cases (no commit, no marker).
#
# Bite: point V_GC_OVERRIDE at v-worktree-gc.sh.pre-gatesfix-bak (glob-existence-only gates,
# ANY-report fallback on missing SID) -> C, D, E all wrongly COMMIT -> RED.
# Re-run: env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GC="${V_GC_OVERRIDE:-$HERE/v-worktree-gc.sh}"
[ -f "$GC" ] || { echo "SKIP: missing v-worktree-gc.sh"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 -- $2"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP" 2>/dev/null' EXIT
R="$TMP/main"; mkdir -p "$R"
( cd "$R" && git init -q -b main && printf 'a\n' > f.txt && git add -A && git -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1
OLD_TS="$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '-2 hours' +%Y%m%d%H%M.%S 2>/dev/null || echo '')"
OLDER_TS="$(date -v-6H +%Y%m%d%H%M.%S 2>/dev/null || date -d '-6 hours' +%Y%m%d%H%M.%S 2>/dev/null || echo '')"
[ -n "$OLD_TS" ] || { echo "SKIP: date arithmetic unavailable"; exit 0; }

mk_merged_wt(){ # <name> <branch> -> a worktree whose branch is fully merged into main (0 ahead)
  local wt="$TMP/$1" br="$2"
  ( cd "$R" && git worktree add -q -b "$br" "$wt" ) >/dev/null 2>&1
  ( cd "$wt" && printf 'x\n' > "feat_$1.php" && git add -A && git -c commit.gpgsign=false commit -qm "feat $1" ) >/dev/null 2>&1
  ( cd "$R" && git -c commit.gpgsign=false merge -q --no-edit "$br" ) >/dev/null 2>&1
  printf '%s' "$wt"
}
mk_dead_lock(){ # <wt> <sid> -- 3-field lock, dead pid, backdated past AGE_MIN so lock_alive reads DEAD
  printf '%s 99999999 %s\n' "$2" "$(date +%s)" > "$1/.claude-session-lock"
  touch -t "$OLDER_TS" "$1/.claude-session-lock" 2>/dev/null
}
mk_pf(){ # <wt> <sid> <verdict> -- >=200B PRE_FLIGHT with a parsed verdict line
  { printf '# PRE_FLIGHT_REPORT\nModel: haiku\n## Gates\n| PASS | TypeScript | 39s |\n| PASS | PHP Tests | 57 passed |\n'
    printf 'padding to clear the 200B substance floor padding padding padding padding padding padding padding padding\n'
    printf 'Overall Status: %s\n' "$3"; } > "$1/PRE_FLIGHT_REPORT_${2}.md"
}
mk_ar(){ # <wt> <sid> -- >=200B AGENT_REVIEW
  { printf '# AGENT_REVIEW\nModel: haiku\nDispatch mode: subagent-dispatched\n'
    printf 'independent adversarial review completed, no CRITICAL or HIGH findings remain open,\n'
    printf 'padding to clear the 200B substance floor padding padding padding padding padding padding padding\n'; } > "$1/AGENT_REVIEW_${2}.md"
}
stage_file(){ # <wt> <name>
  printf 'staged content %s\n' "$2" > "$1/$2"
  ( cd "$1" && git add "$2" ) >/dev/null 2>&1
}

# ── Case A: full authorization -> COMMIT ─────────────────────────────────────
# Order matters for condition (5): stage FIRST, then write the reports (fresher than the staged file).
WT_A="$(mk_merged_wt wtA featA)"; SID_A="bbbbbbbb-2222-4333-8444-555566667777"
mk_dead_lock "$WT_A" "$SID_A"
stage_file "$WT_A" staged_A.txt
mk_pf "$WT_A" "$SID_A" PASS
mk_ar "$WT_A" "$SID_A"

# ── Case B: no reports at all -> PRESERVE ────────────────────────────────────
WT_B="$(mk_merged_wt wtB featB)"
stage_file "$WT_B" staged_B.txt

# ── Case C (review a): SID-bound reports, FAIL verdict -> PRESERVE ───────────
WT_C="$(mk_merged_wt wtC featC)"; SID_C="cccccccc-3333-4444-8555-666677778888"
mk_dead_lock "$WT_C" "$SID_C"
stage_file "$WT_C" staged_C.txt
mk_pf "$WT_C" "$SID_C" FAIL
mk_ar "$WT_C" "$SID_C"

# ── Case D (review b): unparseable SID + FOREIGN-SID PASS reports -> PRESERVE ─
WT_D="$(mk_merged_wt wtD featD)"; SID_FOREIGN="dddddddd-4444-4555-8666-777788889999"
: > "$WT_D/.claude-session-lock"                      # empty lock -> _lock_sid parses NOTHING
touch -t "$OLDER_TS" "$WT_D/.claude-session-lock" 2>/dev/null   # backdated so lock_alive reads DEAD, not fresh-mtime-alive
stage_file "$WT_D" staged_D.txt
mk_pf "$WT_D" "$SID_FOREIGN" PASS                     # valid, fresh, PASS — but a DIFFERENT session's
mk_ar "$WT_D" "$SID_FOREIGN"

# ── Case E (review c): PASS reports STALER than the staged writes -> PRESERVE ─
WT_E="$(mk_merged_wt wtE featE)"; SID_E="eeeeeeee-5555-4666-8777-888899990000"
mk_dead_lock "$WT_E" "$SID_E"
mk_pf "$WT_E" "$SID_E" PASS
mk_ar "$WT_E" "$SID_E"
touch -t "$OLD_TS" "$WT_E/PRE_FLIGHT_REPORT_${SID_E}.md" "$WT_E/AGENT_REVIEW_${SID_E}.md" 2>/dev/null
stage_file "$WT_E" staged_E.txt                       # staged NOW — the reports graded an EARLIER diff

echo "== v-worktree-gc :: staged-work commit-or-preserve backstop (verdict+SID+freshness gated) =="

echo "-- DRY-RUN (must be non-destructive everywhere: no commit, no marker) --"
OUT_DRY="$(bash "$GC" "$R" 2>&1)"
_dry_ok=1
for _wt in "$WT_A" "$WT_B" "$WT_C" "$WT_D" "$WT_E"; do
  [ -n "$(git -C "$_wt" diff --cached --name-only 2>/dev/null)" ] || _dry_ok=0
  ls "$_wt"/STAGED_WORK_PRESERVED_*.md >/dev/null 2>&1 && _dry_ok=0
done
[ "$_dry_ok" -eq 1 ] && ok "dry-run: all 5 worktrees untouched (still staged, no markers)" \
  || no "dry-run modified state (must be a pure report)" "$OUT_DRY"

echo "-- --apply --"
OUT_APPLY="$(bash "$GC" "$R" --apply 2>&1)"

# A: commits
if [ -d "$WT_A" ] && git -C "$WT_A" diff --cached --quiet 2>/dev/null; then
  ok "A: fully-authorized staged work committed (nothing left in the index)"
else
  no "A: staged content NOT committed despite full authorization" "$OUT_APPLY"
fi
git -C "$WT_A" log --oneline -1 2>/dev/null | grep -qi "preserve staged-only" \
  && ok "A: checkpoint commit uses the established 'preserve staged-only' message convention" \
  || no "A: checkpoint commit message missing/wrong" "$(git -C "$WT_A" log --oneline -2 2>/dev/null)"

# B: preserves
if [ -d "$WT_B" ] && ls "$WT_B"/STAGED_WORK_PRESERVED_*.md >/dev/null 2>&1 \
   && [ "$(git -C "$WT_B" diff --cached --name-only 2>/dev/null)" = "staged_B.txt" ]; then
  ok "B: no reports -> preserved (marker written, staged bytes untouched, no forged commit)"
else
  no "B: no-reports case did not preserve correctly" "$OUT_APPLY"
fi

# C/D/E: MUST preserve, must NEVER commit (the HIGH's three attack shapes)
chk_preserve(){ # <label> <wt> <staged_name>
  local _lbl="$1" _wt="$2" _sf="$3"
  if git -C "$_wt" log --oneline -1 2>/dev/null | grep -qi "preserve staged-only"; then
    no "$_lbl: WRONGLY COMMITTED an unauthorized diff (the HIGH)" "$(git -C "$_wt" log --oneline -2 2>/dev/null)"
    return
  fi
  if [ "$(git -C "$_wt" diff --cached --name-only 2>/dev/null)" = "$_sf" ] \
     && ls "$_wt"/STAGED_WORK_PRESERVED_*.md >/dev/null 2>&1; then
    ok "$_lbl: refused the commit, preserved instead (marker + staged bytes intact)"
  else
    no "$_lbl: neither committed nor properly preserved" "staged=$(git -C "$_wt" diff --cached --name-only 2>/dev/null) marker=$(ls "$_wt"/STAGED_WORK_PRESERVED_*.md 2>/dev/null)"
  fi
}
chk_preserve "C (FAIL verdict)"                      "$WT_C" staged_C.txt
chk_preserve "D (unparseable SID + foreign reports)" "$WT_D" staged_D.txt
chk_preserve "E (reports staler than staged writes)" "$WT_E" staged_E.txt

# No worktree may ever be pruned while dirty (unchanged invariant)
_alive=1; for _wt in "$WT_A" "$WT_B" "$WT_C" "$WT_D" "$WT_E"; do [ -d "$_wt" ] || _alive=0; done
[ "$_alive" -eq 1 ] && ok "no dirty worktree was pruned (data-loss invariant holds)" \
  || no "a dirty worktree directory disappeared" "$OUT_APPLY"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
