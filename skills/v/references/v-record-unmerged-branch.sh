#!/usr/bin/env bash
# v-record-unmerged-branch.sh — B3 (forensic F3, 2026-06-21).
#
# A worktree /v session that completes WITHOUT merging back (the NORMAL fleet pattern — consolidation is
# deferred to a later /v-merge-all) leaves its work on a build/<slug>-<sid> branch. /v-merge-all then
# DISCOVERS work via `git branch --no-merged`, which is fragile: a branch tip that advanced AFTER
# merge-all's scan, or a branch GC'd/removed before merge-all runs, is silently dropped (in one
# session the last commit landed only as an "additional missed commit ... cherry-picked" on recovery).
#
# This writes a DURABLE record — MERGE_PENDING_<sid>.md in REPO_ROOT — naming the branch, its tip SHA,
# and the unmerged commit count, so the work is reliably discoverable by /v-merge-all + the operator even
# if the branch is later deleted. Idempotent: if the branch is (now) fully merged into main, the marker
# is removed. Advisory, NON-BLOCKING — deferring merge is correct under the fleet pattern; this only
# makes the deferral auditable. Exit 0 always.
#
# Usage: bash v-record-unmerged-branch.sh <SID> [REPO_ROOT]
set -uo pipefail
SID="${1:-}"
ROOT="${2:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
MAIN="${CLAUDE_MAIN_BRANCH:-main}"
_UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
printf '%s' "$SID" | grep -qE "$_UUID_RE" || { echo "v-record-unmerged-branch: no/invalid SID" >&2; exit 0; }
MARKER="$ROOT/MERGE_PENDING_${SID}.md"

# Resolve the SID's build branch: lock-owned worktree first, then a boundary-anchored slug match.
SLUG="${SID%%-*}"; BR=""
while IFS= read -r _wt; do
  [ -n "$_wt" ] && [ -f "$_wt/.claude-session-lock" ] || continue
  [ "$(awk '{print $1; exit}' "$_wt/.claude-session-lock" 2>/dev/null)" = "$SID" ] && { BR="$(git -C "$_wt" branch --show-current 2>/dev/null)"; break; }
done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
[ -z "$BR" ] && [ -n "$SLUG" ] && [ "$SLUG" != "$SID" ] && \
  BR="$(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | grep -E "(^|[-_/])${SLUG}([-_/]|\$)" | head -1)"

# No resolvable branch -> nothing to record (inline-on-main session). Clean any stale marker.
[ -n "$BR" ] || { rm -f "$MARKER" 2>/dev/null; exit 0; }
git -C "$ROOT" rev-parse --verify "$BR" >/dev/null 2>&1 || { rm -f "$MARKER" 2>/dev/null; exit 0; }

# Merged already (tip is an ancestor of main) -> no pending work; drop any stale marker (idempotent).
if git -C "$ROOT" merge-base --is-ancestor "$BR" "$MAIN" 2>/dev/null; then
  rm -f "$MARKER" 2>/dev/null; exit 0
fi
TIP="$(git -C "$ROOT" rev-parse "$BR" 2>/dev/null)"
CNT="$(git -C "$ROOT" rev-list --count "${MAIN}..${BR}" 2>/dev/null || echo 0)"
[ "${CNT:-0}" -gt 0 ] || { rm -f "$MARKER" 2>/dev/null; exit 0; }

{
  printf '# MERGE PENDING — worktree session %s left UNMERGED work\n\n' "$SID"
  printf 'This /v session completed with work on a build branch that is NOT yet on `%s`. Under the\n' "$MAIN"
  printf 'parallel-fleet pattern this is normal (consolidation is deferred to /v-merge-all) — this marker\n'
  printf 'is the DURABLE record so the work is not lost if the branch tip advances or the branch is GC'\''d\n'
  printf 'before /v-merge-all runs. /v-merge-all should consolidate this branch/tip; the operator can too.\n\n'
  printf -- '- branch: `%s`\n' "$BR"
  printf -- '- tip_sha: `%s`\n' "$TIP"
  printf -- '- unmerged_commits_ahead_of_%s: %s\n' "$MAIN" "$CNT"
  printf -- '- recover: `git -C %s merge --no-ff %s` (or cherry-pick the tip), then re-run /v-merge-all\n' "$ROOT" "$BR"
} > "$MARKER" 2>/dev/null || true
echo "v-record-unmerged-branch: recorded MERGE_PENDING_${SID}.md (branch=$BR tip=${TIP:0:12} ahead=$CNT)" >&2
exit 0
