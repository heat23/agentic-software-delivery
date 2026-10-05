#!/usr/bin/env bash
# v-artifact-dir-gitignore-test.sh — P4 (fleet forensic 2026-06-20): v-artifact-dir.sh must SELF-HEAL a
# STALE .v/.gitignore that predates the `*` self-ignore template. A repo had an early `.v/.gitignore`
# (tmp/ archive/ traces/) with no `*`, so top-level `.v/<role>-<sid>.*` scratch files (fe-build/gate-
# summary/pre-flight-skeleton/tsbuildinfo) leaked into `git status` and could be `git add -A`-staged.
# Re-run: bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
SCRIPT="$HOME/.claude/skills/v/references/v-artifact-dir.sh"
[ -f "$SCRIPT" ] || { echo "SKIP: missing $SCRIPT"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

BASE=$(mktemp -d); trap 'rm -rf "$BASE" 2>/dev/null' EXIT
R="$BASE/repo"; mkdir -p "$R/.v"
( cd "$R" && git init -q && echo x > .keep && git add -A && git -c commit.gpgsign=false commit -qm init ) >/dev/null 2>&1
# STALE .v/.gitignore (the early-template shape — subdirs only, no `*`).
printf 'tmp/\narchive/\ntraces/\n' > "$R/.v/.gitignore"
: > "$R/.v/fe-build-aaaaaaaa.stamp"   # the exact leaking scratch-file class

echo "== v-artifact-dir :: P4 stale .v/.gitignore self-heal =="

# Baseline: the scratch file leaks (NOT ignored) under the stale gitignore.
( cd "$R" && git check-ignore -q .v/fe-build-aaaaaaaa.stamp ) && pre_ignored=1 || pre_ignored=0
[ "$pre_ignored" -eq 0 ] && ok "baseline: scratch file LEAKS under stale gitignore (reproduces the bug)" || no "scratch already ignored — fixture wrong" "pre=$pre_ignored"

# Run the ensure-helper (as any /v session does when resolving the artifact dir).
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 )

grep -qxF '*' "$R/.v/.gitignore" && ok "stale .v/.gitignore SELF-HEALED (now contains the '*' self-ignore)" || no "stale gitignore not healed" "$(cat "$R/.v/.gitignore")"
( cd "$R" && git check-ignore -q .v/fe-build-aaaaaaaa.stamp ) && ok "scratch file is now git-ignored (no more leak)" || no "scratch still leaks after heal" "$(cd "$R" && git status --porcelain | grep '\.v/')"
# Pre-existing subdir entries preserved (non-destructive).
grep -qxF 'archive/' "$R/.v/.gitignore" && ok "pre-existing entries preserved (non-destructive append)" || no "clobbered existing entries" "$(cat "$R/.v/.gitignore")"

# Idempotent: a second run must NOT duplicate the '*' line.
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 )
[ "$(grep -cxF '*' "$R/.v/.gitignore")" -eq 1 ] && ok "idempotent: '*' appears exactly once after a 2nd run" || no "duplicate '*' appended" "count=$(grep -cxF '*' "$R/.v/.gitignore")"

# Fresh repo (no .v/.gitignore at all) still gets the template (no regression to create-path).
R2="$BASE/fresh"; mkdir -p "$R2"
( cd "$R2" && git init -q && bash "$SCRIPT" >/dev/null 2>&1 )
grep -qxF '*' "$R2/.v/.gitignore" 2>/dev/null && ok "fresh repo: template still created (create-path intact)" || no "fresh repo got no template" "$(ls "$R2/.v" 2>&1)"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
