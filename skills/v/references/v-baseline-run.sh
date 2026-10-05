#!/usr/bin/env bash
# v-baseline-run.sh — run a test command with the session's changed files reverted to a
# BASE commit, to classify a failing test as PRE-EXISTING (fails at base too) vs
# SESSION-INTRODUCED (passes at base, fails at HEAD).
#
# WHY (W-perf4): proving a suite failure is pre-existing required hand-rolled, error-prone
# surgery that repeatedly fought the safety hooks (production sessions):
#   - a throwaway baseline `git worktree` lacked vendor/ + .env → confounded
#     BindingResolutionException failures (not the real baseline);
#   - `git checkout <sha>` / `git switch` → BLOCKED by worktree-safety.sh (mutates the
#     shared working dir's branch);
#   - `git stash` → BLOCKED (repo-wide LIFO stack, corrupts parallel worktrees).
# This helper classifies with ZERO git-state mutation and NO new worktree: it backs up the
# WORKING-TREE copy of each changed file (preserving uncommitted edits), overwrites it with
# `git show BASE:file`, runs the test in the SAME tree (correct vendor/.env/caches), then
# restores the working-tree copy via a trap that fires even on failure/interrupt.
#
# Usage:
#   bash v-baseline-run.sh <BASE_SHA> "<file1> <file2> ..." <test-command> [args...]
# Example (is this Pest failure pre-existing?):
#   bash v-baseline-run.sh "$(git merge-base HEAD main)" "app/Services/Foo.php" \
#     ./vendor/bin/pest tests/Feature/SomeTest.php
#
# Output: runs the command, prints `BASELINE-RESULT=<exit-code>`. Compare to the SAME
# command at HEAD: identical pass/fail at base AND HEAD ⇒ PRE-EXISTING (not yours);
# differs (passes at base, fails at HEAD) ⇒ SESSION-INTRODUCED (yours — fix it).
set -u

BASE="${1:-}"; FILES="${2:-}"
shift 2 2>/dev/null || { echo "usage: v-baseline-run.sh <BASE_SHA> \"<files>\" <cmd...>" >&2; exit 2; }
[ -n "$BASE" ] && [ -n "$FILES" ] && [ "$#" -ge 1 ] || {
  echo "usage: v-baseline-run.sh <BASE_SHA> \"<files>\" <cmd...>" >&2; exit 2; }
git rev-parse --verify "${BASE}^{commit}" >/dev/null 2>&1 || {
  echo "v-baseline-run: ERROR — base '$BASE' is not a valid commit" >&2; exit 2; }

_BK=$(mktemp -d)
_restored=0
_restore() {
  [ "$_restored" -eq 1 ] && return 0
  _restored=1
  local f
  for f in $FILES; do
    if [ -f "$_BK/cur/$f" ]; then
      mkdir -p "$(dirname "$f")" 2>/dev/null || true
      cp "$_BK/cur/$f" "$f" 2>/dev/null || true        # restore the exact working-tree copy
    elif [ -f "$_BK/absent/$f" ]; then
      rm -f "$f" 2>/dev/null || true                   # it did not exist before — remove again
    fi
  done
  rm -rf "$_BK" 2>/dev/null || true
}
trap _restore EXIT INT TERM

# Back up each working-tree copy (incl. uncommitted edits), then overwrite with BASE.
for f in $FILES; do
  if [ -f "$f" ]; then
    mkdir -p "$_BK/cur/$(dirname "$f")" 2>/dev/null || true
    # W-perf4 review (logic-reviewer, HIGH): NEVER overwrite a file we could not back up —
    # else a failed backup (disk full / perms) + the BASE overwrite below would destroy the
    # session's uncommitted edit with nothing to restore. Verify the backup, else skip this file.
    if ! cp "$f" "$_BK/cur/$f" 2>/dev/null || [ ! -f "$_BK/cur/$f" ]; then
      echo "v-baseline-run: ERROR — could not back up '$f'; NOT reverting it (refusing to risk your uncommitted edit)" >&2
      continue
    fi
  else
    mkdir -p "$_BK/absent/$(dirname "$f")" 2>/dev/null || true
    : > "$_BK/absent/$f"
  fi
  if git cat-file -e "${BASE}:$f" 2>/dev/null; then
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    git show "${BASE}:$f" > "$f" 2>/dev/null || true
  else
    rm -f "$f" 2>/dev/null || true                     # file is new this session — absent at BASE
  fi
done

echo "v-baseline-run: reverted [$FILES] to $BASE; running: $*" >&2
"$@"
_rc=$?
_restore
echo "BASELINE-RESULT=$_rc"
exit "$_rc"
