#!/usr/bin/env bash
# v-precommit-scope-guard-test.sh — the native-hook scope guard must BLOCK a staged set that spans more
# than V_COMMIT_SCOPE_MAX_SESSIONS distinct sessions' writes-logs (the mega-absorption signature), and
# ALLOW a normally-scoped commit. Configurable threshold.
# Re-run: bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
GUARD="$HOME/.claude/skills/v/references/v-precommit-scope-guard.sh"
[ -f "$GUARD" ] || { echo "SKIP: missing $GUARD"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

BASE=$(mktemp -d); trap 'rm -rf "$BASE" 2>/dev/null' EXIT
R="$BASE/repo"; mkdir -p "$R/app"
( cd "$R" && git init -q -b main && echo x > app/seed.php && git add -A && git -c commit.gpgsign=false commit -qm init ) >/dev/null 2>&1
GCD="$(cd "$R" && git rev-parse --git-common-dir)"; case "$GCD" in /*) : ;; *) GCD="$R/$GCD" ;; esac
# 12 files, each authored by a DISTINCT session (per its writes-log).
i=0; while [ "$i" -lt 12 ]; do
  printf 'm%s\n' "$i" > "$R/app/mega$i.php"
  printf 'app/mega%s.php\n' "$i" > "$GCD/claude-session-writes-ses$i-0000-0000-0000-00000000000$i.txt"
  i=$((i+1))
done

echo "== v-precommit-scope-guard :: mega-absorption (native hook) =="

# Case 1: stage all 12 (12 distinct sessions > default 10) → BLOCK.
( cd "$R" && git add app/mega*.php ) >/dev/null 2>&1
OUT=$( cd "$R" && bash "$GUARD" 2>&1 ); RC=$?
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'scope-guard' && printf '%s' "$OUT" | grep -q '12 distinct'; } \
  && ok "12-session mega-commit (>10) BLOCKED with a scoped-commit hint" || no "mega-commit not blocked (rc=$RC)" "$OUT"

# Case 2: scoped commit — 3 sessions → ALLOW.
( cd "$R" && git restore --staged . 2>/dev/null; git add app/mega0.php app/mega1.php app/mega2.php ) >/dev/null 2>&1
OUT2=$( cd "$R" && bash "$GUARD" 2>&1 ); RC2=$?
[ "$RC2" -eq 0 ] && ok "normally-scoped commit (3 sessions ≤ 10) ALLOWED (no false positive)" || no "scoped commit wrongly blocked (rc=$RC2)" "$OUT2"

# Case 3: configurable threshold — MAX=2 blocks the same 3-session commit.
OUT3=$( cd "$R" && V_COMMIT_SCOPE_MAX_SESSIONS=2 bash "$GUARD" 2>&1 ); RC3=$?
[ "$RC3" -ne 0 ] && ok "threshold configurable (V_COMMIT_SCOPE_MAX_SESSIONS=2 blocks the 3-session commit)" || no "threshold not honored" "$OUT3"

# Case 5 (SREV-002 regression): ONE session authoring MANY (5) staged files must NOT block (n=1, not 5).
# This is the false-positive the dedup-pipeline bug caused; it is masked unless one log lists >1 staged file.
j=0; while [ "$j" -lt 5 ]; do printf 'solo%s\n' "$j" > "$R/app/solo$j.php"; j=$((j+1)); done
printf 'app/solo0.php\napp/solo1.php\napp/solo2.php\napp/solo3.php\napp/solo4.php\n' \
  > "$GCD/claude-session-writes-onlyone-0000-0000-0000-000000000001.txt"   # 5 files, ONE session
( cd "$R" && git restore --staged . 2>/dev/null; git add app/solo*.php ) >/dev/null 2>&1
OUT5=$( cd "$R" && bash "$GUARD" 2>&1 ); RC5=$?
[ "$RC5" -eq 0 ] && ok "5 files from ONE session -> n=1 ≤ 10, ALLOWED (SREV-002 dedup pipeline)" || no "single-session multi-file commit false-blocked (rc=$RC5)" "$OUT5"

# Case 4: empty staged set → no-op (exit 0).
( cd "$R" && git restore --staged . 2>/dev/null ) >/dev/null 2>&1
OUT4=$( cd "$R" && bash "$GUARD" 2>&1 ); RC4=$?
[ "$RC4" -eq 0 ] && ok "empty staged set -> no-op (exit 0)" || no "empty staged set not a no-op (rc=$RC4)" "$OUT4"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
