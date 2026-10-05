#!/usr/bin/env bash
# v-record-unmerged-branch-test.sh — B3 (forensic F3, 2026-06-21): records a DURABLE
# MERGE_PENDING_<sid>.md for a worktree session whose build branch carries commits not yet on main, so
# /v-merge-all can't silently miss an advanced/GC'd branch tip; idempotently removes it once merged.
# Re-run: env -u CLAUDE_SESSION_ID bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REC="$HERE/v-record-unmerged-branch.sh"
[ -f "$REC" ] || { echo "SKIP: recorder missing"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
( cd "$R" && git init -q -b main && echo base > f.txt && git add -A && git -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1
SID=b3b3b3b3-1111-4111-8111-111111111111; SLUG="${SID%%-*}"
( cd "$R" && git checkout -q -b "build/feat-$SLUG" && echo work > feat.txt && git add -A && git -c commit.gpgsign=false commit -qm "feat work" && git checkout -q main ) >/dev/null 2>&1

echo "== B3 :: durable MERGE_PENDING record for an unmerged worktree branch =="

# 1. Unmerged branch ahead of main -> marker written with branch + tip + count.
CLAUDE_MAIN_BRANCH=main bash "$REC" "$SID" "$R" 2>/dev/null
M="$R/MERGE_PENDING_${SID}.md"
[ -f "$M" ] && ok "unmerged branch -> MERGE_PENDING marker written" || no "no marker for unmerged branch" "$(ls "$R")"
if [ -f "$M" ]; then
  grep -q "build/feat-$SLUG" "$M"  && ok "marker names the build branch" || no "branch missing from marker" "$(cat "$M")"
  grep -q "$(cd "$R" && git rev-parse "build/feat-$SLUG")" "$M" && ok "marker records the durable tip SHA (survives branch GC)" || no "tip sha missing" "$(cat "$M")"
  grep -qE 'unmerged_commits_ahead_of_main: 1' "$M" && ok "marker records the unmerged commit count" || no "count wrong" "$(cat "$M")"
fi

# 2. Idempotent: once the branch is merged into main, the marker is REMOVED.
( cd "$R" && git merge --no-ff -q "build/feat-$SLUG" -m "merge" ) >/dev/null 2>&1
CLAUDE_MAIN_BRANCH=main bash "$REC" "$SID" "$R" 2>/dev/null
[ ! -f "$M" ] && ok "merged branch -> stale MERGE_PENDING marker removed (idempotent)" || no "marker not cleaned after merge" "still present"

# 3. No build branch (inline-on-main session) -> no marker, no false positive.
SID2=b3b3b3b3-2222-4222-8222-222222222222
CLAUDE_MAIN_BRANCH=main bash "$REC" "$SID2" "$R" 2>/dev/null
[ ! -f "$R/MERGE_PENDING_${SID2}.md" ] && ok "no branch -> no marker (no FP)" || no "marker written with no branch" "FP"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
