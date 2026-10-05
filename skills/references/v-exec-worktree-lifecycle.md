# Build Worktree Lifecycle (extracted from _v-exec.md)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

When `/v` routes a medium or large feature to `/v-build`, the build runs in an isolated worktree.

## Pre-Creation Safety Check

Before creating a worktree, check for uncommitted changes on the current branch:

```bash
# Check for uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
  echo "WARNING: Uncommitted changes detected on $(git branch --show-current)"
  echo "Options:"
  echo "  1. Commit changes first (recommended)"
  echo "  2. Proceed anyway (worktree will branch from current HEAD, uncommitted changes stay on main)"
fi
```

**Rule:** Before creating a worktree when uncommitted changes exist, remember that the worktree branches from HEAD (the last commit) only. Uncommitted changes are **not included** in the worktree and remain only in the original working directory. Do not assume a `wip:` checkpoint commit is available as a workaround — the live pre-commit gate can block staged code commits until session gates pass. If those dirty files are required for the task, stop and report that safe isolated worktree creation is blocked by the dirty baseline.

**NEVER use `git stash` in worktree workflows.** The stash is a repo-wide LIFO stack shared across all worktrees — if parallel sessions stash, `git stash pop` in one session will pop another session's stash. Worktrees are inherently isolated; stashing is unnecessary and dangerous.

## Creation

1. Verify `.worktrees` directory exists and is listed in `.gitignore`. If not: create directory and add `.worktrees` to `.gitignore` (commit the `.gitignore` change).
2. Record the current branch name (`git branch --show-current`).
3. Create worktree: `git worktree add .worktrees/build-{feature-slug}-${CLAUDE_SESSION_ID} -b build/{feature-slug}-${CLAUDE_SESSION_ID}` (using `${CLAUDE_SESSION_ID}` ensures uniqueness across parallel sessions)
4. `cd` into the worktree.
5. Run project setup if needed (`npm install`, `composer install --no-cache`, etc.). **Concurrent `composer install` safety:** Always use `--no-cache` when worktrees are active — Composer writes to a shared global cache (`~/.composer/cache`) that corrupts under concurrent access. `npm install` is safe — each worktree has its own `node_modules`.
6. Create `.claude-session-lock` in the worktree root.

**EnterWorktree fallback:** If the `WorktreeCreate` hook fires but produces no output (silent failure — observed in production), the lock file may not have been created. After step 3, ALWAYS verify the lock file exists:
```bash
WT=".worktrees/build-{feature-slug}-${CLAUDE_SESSION_ID}"
if [ ! -f "$WT/.claude-session-lock" ]; then
  echo "${CLAUDE_SESSION_ID} $(date +%s)" > "$WT/.claude-session-lock"
  echo "FALLBACK: Manually created .claude-session-lock (WorktreeCreate hook may have failed)" >&2
fi
```
This ensures every worktree has a lock file regardless of hook reliability.

## Merge-Back (after all quality gates pass)

> **Canonical implementation**: `${CLAUDE_SKILLS_DIR:-~/.claude/skills}/v/references/v-merge-back.sh` (executable script invoked from /v Step 6.5). The bash inlined in this section is reference documentation; the script is the source of truth for runtime behavior.

1. Commit all changes in the worktree branch.
2. Switch back to the original branch directory.
3. **Pre-merge freshness check:** Before attempting merge-back, fetch the latest base branch and rebase the worktree branch onto it. This catches conflicts early — before entering the flock-serialized merge window — reducing lock contention for other parallel sessions.
   ```bash
   cd /path/to/worktree
   git fetch origin
   git rebase origin/{original-branch}
   ```
   If rebase conflicts arise, resolve them in the worktree (where it's safe), then re-run `/v-pre-flight` to verify the resolution doesn't break anything. After successful rebase, proceed to merge-back below.
4. **Acquire merge lock** to serialize concurrent merge-backs:
   ```bash
   MERGE_LOCK=".worktrees/.merge-lock"
   mkdir -p .worktrees
   # Check for stale lock before acquiring (recovery from stuck merge-backs)
   if [ -f "$MERGE_LOCK" ]; then
     LOCK_MTIME=$(stat -c %Y "$MERGE_LOCK" 2>/dev/null || stat -f %m "$MERGE_LOCK" 2>/dev/null || echo 0)
     LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
     if [ "$LOCK_AGE" -gt 300 ]; then
       echo "WARNING: Stale merge lock detected (age: ${LOCK_AGE}s > 300s). Removing stale lock." >&2
       rm -f "$MERGE_LOCK"
     fi
   fi
   # flock serializes merge-backs across parallel sessions
   # Timeout after 120s to prevent indefinite blocking
   exec 9>"$MERGE_LOCK"
   flock -w 120 9 || { echo "ERROR: Could not acquire merge lock after 120s — another merge-back may be stuck. Recovery: rm .worktrees/.merge-lock"; exit 1; }
   ```
5. Attempt fast-forward merge: `git merge --ff-only build/{branch-name}`.
6. If fast-forward fails (original branch moved ahead) — **do NOT stash work; commit everything first** (stash is banned, use commits instead):
   a. In worktree: `git rebase {original-branch}`
   b. If rebase conflicts: attempt to resolve each conflict:
      - For each conflicting file, read both sides (ours + theirs) and the base version
      - Apply the intent of the worktree changes on top of the updated original branch
      - `git add` each resolved file, then `git rebase --continue`
      - After all conflicts resolved, re-run `/v-pre-flight` to verify conflict resolution didn't break anything
      - If any conflict cannot be auto-resolved (ambiguous intent, both sides modified same logic in incompatible ways): **stop**. Report the specific unresolvable conflict, leave worktree intact for manual resolution.
   c. If rebase succeeds (no conflicts or all conflicts resolved): re-run `/v-pre-flight` to verify nothing broke, then retry fast-forward merge.
   d. **Retry limit:** If the fast-forward fails again after a successful rebase (e.g., another parallel session merged to main between your rebase and your merge attempt), repeat the rebase-then-ff cycle up to autonomous resolution per v-merge-back.sh (W17-2: 10-cycle cap with file-class rules). After the W17-2 autonomous resolver exhausts strategies (10-cycle cap), **stop** and report that the base branch is moving too fast for automatic merge-back. Leave the worktree intact for manual merge.
   e. **Concurrent merge-backs are serialized** by the flock in step 4. If another session holds the merge lock, this session waits up to 120s. After the lock is acquired, the rebase-then-ff cycle runs against the now-updated base branch.
7. After successful merge — **release the merge lock** (automatic when fd 9 closes) and verify session ownership, then check for stray artifacts before removing:
   a. Check `.claude-session-lock` in the worktree — only proceed if the `${CLAUDE_SESSION_ID}` matches yours or the lock is missing
   b. **Check for stray artifacts before removing:** `find .worktrees/build-{name} -maxdepth 1 -name '*_${CLAUDE_SESSION_ID}.md' -type f`. If any `*_${CLAUDE_SESSION_ID}.md` artifacts are found, move them to the original working directory first — they would be lost during cleanup.
   c. Remove worktree: `git worktree remove .worktrees/build-{name}`
   d. Delete the build branch: `git branch -d build/{branch-name}`
   e. Verify cleanup: `git worktree list` should no longer show the build worktree

**After successful merge-back, refresh the dirty-file baseline** so the stop hook doesn't flag merged files as session-introduced changes:
```bash
LC_ALL=C git status --porcelain | LC_ALL=C sort > "/tmp/dirty-baseline-${CLAUDE_SESSION_ID}.txt"
```

**Write all session artifacts (`*_${CLAUDE_SESSION_ID}.md`) to the original working directory, not the worktree.** Worktrees are cleaned up after merge-back — any artifacts left inside would be deleted. This applies to all artifact types: `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md`, `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md`, `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md`, `IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md`, etc. Only code changes go in the worktree; reports go in the original directory.

**No stash restore step.** Worktree workflows never stash — `git stash` is a repo-wide LIFO stack that is unsafe with parallel sessions. If uncommitted changes existed pre-creation, they remain untouched in the original working directory throughout.

**Stale worktree cleanup:** After `/v-merge-all` completes, remove all merged worktrees:
```bash
for wt in .worktrees/*/; do
  branch=$(git -C "$wt" branch --show-current 2>/dev/null)
  if [ -n "$branch" ] && git merge-base --is-ancestor "$branch" main 2>/dev/null; then
    git worktree remove "$wt" 2>/dev/null && echo "Cleaned: $wt"
  fi
done
```
If >5 worktrees exist at session start, warn the user: "Consider running `/v-merge-all` to clean up stale worktrees before starting new work."

## Hot File Coordination

Certain files are modified by nearly every feature and are the primary source of merge conflicts in parallel sessions. When creating a worktree, the session should note which hot files it intends to modify:

**Common hot files (auto-detected):**
- Route registrations (`routes/*.php`, `src/routes/*`, `app/router.*`)
- Package manifests (`package.json`, `composer.json`)
- Database migrations (any new file in `database/migrations/` or `migrations/`)
- Configuration files (`config/*.php`, `.env.example`)
- Barrel exports (`index.ts`, `index.js` files that re-export modules)

**Coordination rules:**
1. At worktree creation, scan the PLAN artifact for files matching hot file patterns
2. Write the list to `.worktrees/<name>/.hot-files` as a simple newline-delimited list
3. Before merge-back, check if any other active worktree's `.hot-files` overlaps with ours
4. If overlap detected: rebase onto latest base branch BEFORE the flock merge window (this is the pre-merge freshness check above)
5. For migration timestamp conflicts: regenerate the migration timestamp to current time during merge-back rebase resolution

## Abort / Failure

If the build fails (blocker, 3 failed fix attempts):
- Commit partial work in the worktree branch.
- Write `BUILD_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md` in the **original** working directory (not the worktree).
- Leave the worktree intact — the next session can resume from it.
- Report the worktree path so the user or next session can `cd` into it.
