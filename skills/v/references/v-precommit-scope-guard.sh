#!/usr/bin/env bash
# v-precommit-scope-guard.sh — NATIVE-git-hook guard against MEGA-ABSORPTION commits (P-MEGACOMMIT).
#
# Forensic 2026-06-20: a single commit spanning dozens of files from dozens of distinct sessions' writes-logs (the accumulated
# multi-session dirty pile dumped under a garbage message). The Claude Code P12 PreToolUse guard only
# fires INSIDE `claude` sessions — a MANUAL `git commit` in a terminal bypasses it entirely. Wire THIS
# into a repo's `.git/hooks/pre-commit` (it fires on manual commits too) to catch that class.
#
# Blocks (exit 1) when the staged set spans MORE THAN V_COMMIT_SCOPE_MAX_SESSIONS (default 10) distinct
# sessions' writes-logs — the signature of dumping a many-session pile. A legitimate single-wave commit
# touches files authored by only a handful of sessions, so the threshold separates cleanly. Standard
# escape: `git commit --no-verify`.
set -u
MAX="${V_COMMIT_SCOPE_MAX_SESSIONS:-10}"
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
GCD=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0

staged=$(git diff --cached --name-only --diff-filter=d 2>/dev/null | grep -vE '(^|/)\.v/' || true)
[ -n "$staged" ] || exit 0

# Distinct sessions whose writes-log authored ANY staged file (whole-line match; one grep per file).
# SREV-002 (review 2026-06-20): the while-loop output MUST be PIPED through sed|sort|awk — in the earlier
# version they were sequential commands in the subshell (sed read empty stdin), so dedup never ran and
# `sids` held raw log PATHS with duplicates → a single session authoring >10 staged files false-blocked.
sids=$(while IFS= read -r f; do
         [ -n "$f" ] || continue
         grep -lxF -- "$f" "$GCD"/claude-session-writes-*.txt 2>/dev/null
       done <<< "$staged" \
       | sed -E 's@.*/claude-session-writes-@@; s@\.txt$@@' | sort -u | awk 'NF')
n=$(printf '%s\n' "$sids" | awk 'NF' | wc -l | tr -d ' ')

if [ "$n" -gt "$MAX" ]; then
  echo "COMMIT BLOCKED (scope-guard): this commit's files span $n distinct sessions' writes-logs (> $MAX)." >&2
  echo "  That is the mega-absorption signature (forensic 2026-06-20: one commit spanning dozens of sessions' files)," >&2
  echo "  which destroys attribution and corrupts history. Scope the commit to ONE session's work:" >&2
  echo "      git commit -- <your-files>" >&2
  echo "  Deliberate override (e.g. a real consolidation): git commit --no-verify" >&2
  exit 1
fi
exit 0
