#!/usr/bin/env bash
# v-stash-reconcile-test.sh — P11 reconcile must drop ONLY redundant auto-stashes and KEEP unique ones.
# Builds a repo with: (1) a redundant auto-stash (content also present in the working tree),
# (2) a unique auto-stash (content nowhere but the stash), (3) a NON-auto stash (user's own).
# Asserts dry-run counts, and that --prune drops only #1 — never #2 or #3.
# Re-run: bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
TOOL="${HOME}/.claude/skills/v/references/v-stash-reconcile.sh"
[ -f "$TOOL" ] || { echo "SKIP: missing $TOOL"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

BASE="$(mktemp -d)"; trap 'rm -rf "$BASE" 2>/dev/null' EXIT
R="$BASE/repo"; mkdir -p "$R"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
( cd "$R" && git init -q -b main && printf 'v1\n' > a.php && printf 'v1\n' > b.php \
  && git add -A && git -c commit.gpgsign=false commit -qm init ) >/dev/null 2>&1

# (2) UNIQUE auto-stash: change b.php, stash ONLY b.php; tree reverts → content lives only in the stash.
( cd "$R" && printf 'uniqueX\n' > b.php && git stash push -q -m "v-merge-back auto-stash for SID=uniq" -- b.php ) >/dev/null 2>&1
# (3) NON-auto stash (user's own): change b.php again, stash with a non-matching message.
( cd "$R" && printf 'userwip\n' > b.php && git stash push -q -m "WIP on main: my own work" -- b.php ) >/dev/null 2>&1
# (1) REDUNDANT auto-stash: change a.php→v2, stash a.php, then re-create v2 in the tree → stash==tree.
( cd "$R" && printf 'v2\n' > a.php && git stash push -q -m "v-merge-back auto-stash for SID=red" -- a.php \
  && printf 'v2\n' > a.php ) >/dev/null 2>&1
# (4) UNTRACKED-REDUNDANT auto-stash (SREV-002): stash a NEW untracked file with -u, then recreate the
# SAME content in the tree → its ^3 (untracked-parent) content matches the tree → must be detected
# redundant via the ^3 fallback (before the fix it was over-conservatively KEPT).
( cd "$R" && printf 'untrk\n' > c.php && git stash push -q -u -m "v-merge-back auto-stash for SID=untr" -- c.php \
  && printf 'untrk\n' > c.php ) >/dev/null 2>&1
# (5) MIXED auto-stash (edge — MUST KEEP): one file redundant (content restored to tree) + one UNIQUE
# (content nowhere but the stash). A stash with ANY unique content has recovery value → never pruned.
( cd "$R" && printf 'd1\n' > d.php && printf 'e1\n' > e.php && git add d.php e.php && git -c commit.gpgsign=false commit -qm de ) >/dev/null 2>&1
( cd "$R" && printf 'd2\n' > d.php && printf 'eUNIQUE\n' > e.php \
  && git stash push -q -m "v-merge-back auto-stash for SID=mixed" -- d.php e.php \
  && printf 'd2\n' > d.php ) >/dev/null 2>&1   # d.php restored to stash content (redundant); e.php left at e1 (stash's eUNIQUE is unique)

DRY="$(bash "$TOOL" --repo "$R" 2>&1)"
echo "$DRY" | grep -q 'redundant=2' && ok "dry-run: 2 redundant auto-stashes (tracked + untracked) detected" || no "redundant count wrong" "$DRY"
echo "$DRY" | grep -q 'unique=2'    && ok "dry-run: 2 unique auto-stashes kept (pure-unique + MIXED)"        || no "unique count wrong" "$DRY"
echo "$DRY" | grep -q 'skipped=1'   && ok "dry-run: the user's non-auto stash is skipped"    || no "skip count wrong" "$DRY"

BEFORE=$(cd "$R" && git stash list | wc -l | tr -d ' ')
PRUNE="$(bash "$TOOL" --repo "$R" --prune 2>&1)"
AFTER=$(cd "$R" && git stash list | wc -l | tr -d ' ')
[ "$BEFORE" = 5 ] && [ "$AFTER" = 3 ] && ok "prune dropped 2 redundant (5→3), kept 3 (2 unique + user)" || no "prune count wrong" "before=$BEFORE after=$AFTER"

# The unique auto-stash AND the user's stash must both survive.
LIST="$(cd "$R" && git stash list)"
echo "$LIST" | grep -q 'SID=uniq' && ok "unique auto-stash survived prune (recoverable WIP kept)" || no "unique stash was dropped!" "$LIST"
echo "$LIST" | grep -q 'my own work' && ok "user's non-auto stash untouched" || no "user stash was dropped!" "$LIST"
echo "$LIST" | grep -q 'SID=red'  && no "tracked-redundant stash NOT pruned" "$LIST" || ok "tracked-redundant auto-stash was pruned"
echo "$LIST" | grep -q 'SID=untr' && no "untracked-redundant stash NOT pruned (SREV-002 ^3 fallback)" "$LIST" || ok "untracked-redundant auto-stash pruned (SREV-002)"
echo "$LIST" | grep -q 'SID=mixed' && ok "MIXED stash (1 redundant + 1 unique file) KEPT — recovery value never dropped" || no "mixed stash with unique content was wrongly pruned!" "$LIST"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
