# Worktree Safety & Isolation (extracted from _v-exec.md)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

## Database Isolation (Parallel Sessions — CRITICAL)

Worktrees isolate **files only** — all sessions share the same local database. Without isolation, parallel sessions corrupt each other's test state, migrations collide, and test data pollutes across sessions.

**Required setup for parallel development:**

1. **Per-worktree test database:** When creating a worktree, create a `.env.testing` override in the worktree root:
   ```bash
   # In the worktree directory, after creation:
   if [ -f .env.testing ]; then
     # Append or override DB_DATABASE for this session
     sed -i.bak "s/^DB_DATABASE=.*/DB_DATABASE=testing_${CLAUDE_SESSION_ID}/" .env.testing
   else
     cp .env .env.testing
     sed -i.bak "s/^DB_DATABASE=.*/DB_DATABASE=testing_${CLAUDE_SESSION_ID}/" .env.testing
   fi
   # Create the test database if it doesn't exist
   mysql -u root -e "CREATE DATABASE IF NOT EXISTS testing_${CLAUDE_SESSION_ID};" 2>/dev/null || \
   psql -c "CREATE DATABASE testing_${CLAUDE_SESSION_ID};" 2>/dev/null || \
   echo "WARNING: Could not auto-create test database testing_${CLAUDE_SESSION_ID} — create manually"
   ```
2. **Migration isolation:** Run `php artisan migrate --database=testing` (or equivalent) inside the worktree only. Never run migrations on the shared default database from a worktree session.
3. **Test runner isolation:** Ensure `phpunit.xml` or `pest` uses `DB_DATABASE` from `.env.testing`. Laravel's `RefreshDatabase` trait handles per-test cleanup, but the database itself must be session-scoped.
4. **Cleanup:** Drop the `testing_${CLAUDE_SESSION_ID}` database after successful merge-back (or leave for debugging — it's cheap).

**For non-Laravel stacks:**
- Django: Use `--settings=config.settings_test` with a dynamic `DATABASES['default']['NAME']`
- Rails: Set `DATABASE_URL` in the worktree's `.env.test`
- Next.js/Prisma: Use `DATABASE_URL` override in `.env.test`

**If database isolation is not configured:** Tests from parallel sessions WILL interfere. At minimum, never run `php artisan test --parallel` from two sessions simultaneously on the same database.

---

## Worktree-Aware Command Execution

When running commands inside a worktree, always verify the working directory is correct. The Bash tool may not preserve `cd` state between calls.

**Pattern for worktree-safe commands:**
```bash
# Always prefix commands with explicit cd when in a worktree
cd "$WORKTREE_PATH" && npm run build
cd "$WORKTREE_PATH" && php artisan test
cd "$WORKTREE_PATH" && npx tsc --noEmit
```

**Critical:** If `test -d "$(pwd)"` returns false, the worktree directory was deleted by another session. Stop immediately — do not fall back to running commands in the main directory.

**WORKTREE PATH RULE:** After creating a worktree at `$WT`, ALL Read/Edit/Write calls MUST use `$WT/...` paths. Never read `./file.tsx` (main copy) then edit `$WT/file.tsx` (worktree copy) — always read `$WT/file.tsx` directly. The Edit tool requires a prior Read of the *exact same path*. Reading from main and editing in the worktree will either fail or edit the wrong copy.

**CREATE WORKTREE FIRST, THEN READ:** When a worktree will be needed (parallel sessions detected, medium+ scope), create it BEFORE reading any files for understanding. Do not read files from main first and then re-read from the worktree for editing — this doubles file read costs. One session wasted ~2 minutes re-reading files it had already read from main paths. Pattern: detect scope → create worktree → read from worktree paths → edit in worktree.

**Explore agent output in worktrees:** After an Explore agent returns file contents, do NOT re-read those files unless you need to Edit them (Edit requires a Read of the exact file path). For worktree sessions, the Explore agent reads from the main directory — you must still Read the *worktree copy* before editing. Trust Explore output for understanding file structure and patterns; re-read only the worktree paths you will edit.

**Test runner isolation:** Some test runners (Vitest, Jest) discover test files recursively and may pick up tests from OTHER worktrees under `.worktrees/`. If test counts are unexpectedly high (e.g., 400+ failures), check for cross-worktree test discovery. Fix: run with `--exclude '.worktrees/**'` or add `.worktrees` to the test runner's exclude config. Consider adding `.worktrees` to `vitest.config.ts` / `jest.config.ts` exclude array as a permanent fix.

---

## Shared Config File Awareness

Some files exist in the repo root and are shared across all worktrees. Modifying them in a worktree creates merge conflicts on merge-back.

**High-conflict files (avoid modifying from worktrees when possible):**
- `tsconfig.json`, `tsconfig.*.json`
- `package.json`, `composer.json` (dependency additions)
- `tailwind.config.*`, `vite.config.*`
- `routes/web.php`, `routes/api.php` (append-only — conflicts on adjacent lines)
- `.env.example`

**When modification is unavoidable:**
1. Document which shared config files were modified in the `IMPLEMENTATION_REPORT`
2. On merge-back, if conflicts arise in these files, prefer the worktree's version for additive changes (new routes, new config keys) and the base branch's version for structural changes
3. The TypeScript auto-remediation protocol (Category 3: `tsconfig.json` modification) should check if the fix already exists before applying

---

## Worktree Safety (Parallel Sessions)

When multiple Claude Code sessions run in parallel, worktrees can be deleted out from under an active session.

Rules:
1. **Before creating a worktree:** Check for existing worktrees with `git worktree list`. Name new worktrees with a session-specific prefix (e.g., `review-{timestamp}`) to avoid collisions.
2. **Before removing a worktree:** Verify the worktree has no uncommitted changes (`git -C <path> status --porcelain`). If changes exist, commit first — never silently discard.
3. **Never remove worktrees you didn't create.** Only remove worktrees whose name matches your session prefix. When cleaning up, only remove worktrees with your session prefix — leave all others untouched.
4. **Before operating on files:** Verify your working directory still exists (`test -d "$(pwd)"`). If it was deleted by another session, stop and emit `status: blocked` with the reason.
5. **Lock file convention:** When creating a worktree for long-running work (agent review, batch operations), create a `.claude-session-lock` file in the worktree root containing the `${CLAUDE_SESSION_ID}` and Unix epoch timestamp (format: `${CLAUDE_SESSION_ID} [unix-epoch]`). Before removing any worktree, check for this lock file — if it exists and is less than 4 hours old and the `${CLAUDE_SESSION_ID}` does not match yours, do not remove. The 4 hours TTL accommodates large features with slow test suites. **Lock age determination:** Hooks use the file's filesystem mtime (`stat -c %Y` on Linux, `stat -f %m` on macOS) as the primary age signal — this is more reliable than parsing the embedded epoch because it survives lock file corruption and doesn't require format validation. The embedded epoch is informational and used as a fallback when `stat` is unavailable.
5a. **Lock file corruption handling:** Before reading a lock file, validate its format: it must contain exactly two space-separated tokens where the second token is a numeric Unix epoch. If the lock file is empty, contains non-numeric epoch, or has unexpected format: treat it as a **stale lock** — log `lock_corrupt: [worktree_path], content: [first 80 chars]`, rename the corrupt file to `.claude-session-lock.corrupt`, and proceed as if no lock exists. Never silently ignore a corrupt lock and never delete the corrupt file (preserve for debugging).
6. **Commit before cleanup:** Always commit work in a worktree before the session ends. Do not rely on the worktree persisting after session exit.
7. **Never use `git stash` in worktree workflows.** The stash is a repo-wide LIFO stack shared across all worktrees. If parallel sessions stash, `git stash pop` will pop the wrong session's changes. Worktrees are inherently isolated — stashing is unnecessary and dangerous. Use commits instead.
8. **Never run repo-wide git maintenance while parallel sessions are active.** Commands like `git gc`, `git prune`, and `git repack` operate on the shared object store and can remove objects another worktree still references, causing corruption or missing-object errors. Defer these to idle periods.
9. **Never switch branches on the main working directory while parallel sessions are active.** Running `git checkout` or `git switch` on the shared working directory changes the branch for every session using that directory — writes go to the wrong branch, reads return unexpected content, and merges target the wrong base. All implementation work must happen inside a worktree (which has its own branch). The main working directory should stay on the base branch (usually `main`) for the entire duration of parallel execution.
