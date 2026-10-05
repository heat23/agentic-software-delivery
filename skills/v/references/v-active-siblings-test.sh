#!/usr/bin/env bash
# v-active-siblings-test.sh — A-4 hardening (forensic Wave-H 2026-06-04): sibling detection
# must see EXTERNAL worktrees (git-registered, e.g. ~/.claude/worktrees/...), not just the
# legacy $REPO/.worktrees tree. H-7 got an empty sibling answer while several sibling
# sessions were live in external worktrees and fell back to editing main directly.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/v-active-siblings.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SELF="11111111-0000-4000-8000-000000000000"
SIB="22222222-0000-4000-8000-000000000000"
SIB2="33333333-0000-4000-8000-000000000000"

R="$WORK/repo"; mkdir -p "$R"
git -C "$R" init -q
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

echo "== v-active-siblings :: external (git-registered) worktrees =="

# External worktree (the Wave-H layout — OUTSIDE the repo) with a sibling lock
EXT="$WORK/external-home/worktrees/repo/build/feat-22222222"
mkdir -p "$(dirname "$EXT")"
git -C "$R" worktree add -q -b "build/feat-22222222" "$EXT" >/dev/null 2>&1
printf '%s pid ts\n' "$SIB" > "$EXT/.claude-session-lock"

OUT=$(bash "$SCRIPT" "$R" "$SELF")
echo "$OUT" | grep -q "^$SIB " && ok "EXTERNAL worktree sibling detected (the H-7 false-negative class)" || no "external sibling missed: '$OUT'"

# Self exclusion: a lock carrying the caller's own SID is not a sibling
EXT2="$WORK/external-home/worktrees/repo/build/feat-11111111"
git -C "$R" worktree add -q -b "build/feat-11111111" "$EXT2" >/dev/null 2>&1
printf '%s pid ts\n' "$SELF" > "$EXT2/.claude-session-lock"
OUT=$(bash "$SCRIPT" "$R" "$SELF")
echo "$OUT" | grep -q "$SELF" && no "caller's own lock reported as sibling" || ok "self SID excluded"
echo "$OUT" | grep -q "^$SIB " && ok "sibling still reported alongside self lock" || no "sibling lost"

echo "== v-active-siblings :: legacy \$REPO/.worktrees location still scanned =="
LEG="$R/.worktrees/legacy-33333333"
mkdir -p "$LEG"
printf '%s pid ts\n' "$SIB2" > "$LEG/.claude-session-lock"
OUT=$(bash "$SCRIPT" "$R" "$SELF")
echo "$OUT" | grep -q "^$SIB2 " && ok "legacy .worktrees lock still detected" || no "legacy location lost: '$OUT'"

echo "== v-active-siblings :: age bound =="
touch -t 202001010000 "$EXT/.claude-session-lock"
OUT=$(bash "$SCRIPT" "$R" "$SELF")
echo "$OUT" | grep -q "^$SIB " && no "stale (2020) lock reported despite age bound" || ok "stale lock excluded by age bound"

echo "== v-active-siblings :: no duplicates when a lock is visible via both scans =="
# A lock inside $REPO/.worktrees that is ALSO a git-registered worktree
DUP="$R/.worktrees/dup-22222222"
git -C "$R" worktree add -q -b "build/dup-22222222" "$DUP" >/dev/null 2>&1
printf '%s pid ts\n' "$SIB" > "$DUP/.claude-session-lock"
OUT=$(bash "$SCRIPT" "$R" "$SELF")
_n=$(echo "$OUT" | grep -c "$DUP/.claude-session-lock" || true)
[ "${_n:-0}" -eq 1 ] && ok "dual-visible lock emitted exactly once (sort -u dedupe)" || no "dup-visible lock emitted $_n times"

echo "== v-active-siblings :: empty output when alone =="
rm -f "$EXT/.claude-session-lock" "$EXT2/.claude-session-lock" "$LEG/.claude-session-lock" "$DUP/.claude-session-lock"
OUT=$(bash "$SCRIPT" "$R" "$SELF")
[ -z "$OUT" ] && ok "no siblings → empty output (the Maintenance-inline guard contract)" || no "expected empty, got: '$OUT'"

echo "== v-active-siblings :: PID liveness for well-formed 3-field 'SID PID EPOCH' locks (2026-07-01 mtime-unsafe fix) =="
# The 240-min mtime window is UNSAFE for the production lock format: it (a) reads an 11h-LIVE session's
# old lock as dead → MISSES a live sibling → merge clobbers it; and (b) reads a just-crashed session's
# fresh lock as alive → false-defers. A production lock is "SID PID EPOCH"; decide liveness by the PID.
sleep 300 & _LIVE=$!
_DEAD=999999   # beyond macOS pid_max — never live; freed pids recycle under churn (2026-07-02)
SIBD="44444444-0000-4000-8000-000000000000"   # 3-field, DEAD pid, FRESH file → must NOT be a sibling
SIBL="55555555-0000-4000-8000-000000000000"   # 3-field, LIVE pid, OLD file   → must STILL be a sibling
DWT="$R/.worktrees/pid-dead"; mkdir -p "$DWT"; printf '%s %s %s\n' "$SIBD" "$_DEAD" "$(date +%s)" > "$DWT/.claude-session-lock"
LWT="$R/.worktrees/pid-live"; mkdir -p "$LWT"; printf '%s %s %s\n' "$SIBL" "$_LIVE" "$(date +%s)" > "$LWT/.claude-session-lock"
touch -t 202001010000 "$LWT/.claude-session-lock"   # OLD mtime — the old code's -mmin window would DROP a LIVE sibling
OUT=$(bash "$SCRIPT" "$R" "$SELF")
echo "$OUT" | grep -q "^$SIBD " && no "3-field DEAD-pid lock wrongly reported as active sibling (false-defer)" || ok "3-field DEAD-pid lock is NOT a sibling (false-defer fixed)"
echo "$OUT" | grep -q "^$SIBL " && ok "3-field LIVE-pid lock with an OLD file mtime IS still a sibling (11h-live-sibling clobber fixed)" || no "LIVE-pid sibling MISSED because its lock file was old (the mtime-unsafe bug)"
kill "$_LIVE" 2>/dev/null || true
rm -rf "$DWT" "$LWT"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "RESULT: PASS"
