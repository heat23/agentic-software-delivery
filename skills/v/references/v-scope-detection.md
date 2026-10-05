# Step 2: Scope Detection & Task Size Boundaries (extracted from /v SKILL.md)

> Loaded by /v Step 2. The orchestrator runs git commands and applies the scope classification table without operator input — no AskUserQuestion is permitted in Step 2 (per `_v-core.md` § Temporal Constraint).

## Step 2: Scope Detection & Task Size Boundaries

### Maintenance Fast Path

If Step 1 classifies the request as **Maintenance**, skip feature planning and feature-size heuristics. Invoke `/v-maintenance` with:
- the explicit paths already named by the user
- the allowed / forbidden roots from `${CLAUDE_SKILL_DIR}/../references/v-core-maintenance.md`
- the rule that canonical skill edits happen in the canonical root (default: `$HOME/.agents/skills`; configurable via `references/v-core-maintenance.md`) before any mirror sync

Use the maintenance path below instead of the feature path. The goal is lower ceremony with intact tests and hostile review, not a stripped-down quality bar.

### Step 2a: Parallel Session Detection

**Reference:** Read `${CLAUDE_SKILL_DIR}/references/v-scope-boundaries.md` for parallel session detection code and rules. MANDATORY — runs before scope classification. A sibling counts if EITHER bootstrap's `PARALLEL_SESSIONS_DETECTED=1` (the Step-0 start-claim + transcript-liveness signal — race-free, catches a simultaneously-launched fleet and inline siblings before any worktree lock exists) OR `v-active-siblings.sh` prints an active worktree lock. If ANY indicator fires, ALL scopes use a worktree — including Bug fix and Small.

### Step 2c: Dirty Tree Checkpoint (runs when worktree required)

Worktrees branch from latest *commit*, not working tree. Uncommitted main work is invisible to worktrees. (#1 reason sessions skipped worktree isolation: 3 of 9 sessions on 2026-03-18.)

**Rule:** worktree required AND `DIRTY_COUNT > 30`:

```bash
DIRTY_COUNT=$(cd "$REPO_ROOT" && { git diff --name-only HEAD 2>/dev/null; git diff --cached --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u | grep -c . 2>/dev/null || echo "0")
```

→ warn that worktree branches from last commit only, NOT including dirty tree. Pre-commit gate may block WIP commit workaround.

If task depends on dirty files → stop, report dirty baseline prevents safe isolation. If unrelated → continue with worktree, note it intentionally branches from committed state.

**Do NOT skip worktree because tree is dirty.** "Dirty tree → skip worktree" is anti-pattern. Decide whether dirty files matter, then continue (isolated from committed state) or stop (report).

**UX-FND-4 / W22-1: NEVER auto-commit user's WIP without explicit consent.**

The historical anti-pattern AUTO_COMMIT_WITHOUT_REQUEST (observed in production): orchestrator commits dirty main WIP as a "checkpoint" to unblock merge-back, breaking user trust. **Forbidden in W22.**

If main is dirty when merge-back time comes (Step 6.5):
- v-merge-back.sh transparently `git stash push --include-untracked` and `git stash pop` after the ff-merge — non-destructive (user's WIP is preserved in the stash).
- If stash fails (rare — e.g., conflicts with worktree changes), v-merge-back.sh writes `WORKTREE_HANDOFF_<sid>.md` with clear recovery instructions and exits 1 WITHOUT committing.
- The orchestrator must NOT manually commit dirty main as "chore: checkpoint ..." or similar. Always either stash, ask the user, or fail loudly.

Allowed paths to handle dirty main:
1. **Stash** (preferred when user's WIP is unrelated to the worktree task) — automatic in v-merge-back.sh.
2. **Ask user** via AskUserQuestion if the prompt is interactive (not headless).
3. **Abort** with handoff if neither is possible.

Forbidden:
- `git commit -am "chore: checkpoint"` to "unblock" the merge.
- Any commit not requested explicitly by the user.

**Headless override:** `CLAUDE_AUTO_CHECKPOINT=1` opts INTO auto-commit on dirty main. Off by default.

### Step 2d: File Overlap Detection (runs when active worktrees exist)

Two sessions modifying the same file (one on worktree, one on main) → merge conflict on merge-back.

**Rule:** before implementation, check active worktree branches for planned-file overlap:

```bash
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
for WT_DIR in "${REPO_ROOT}"/.worktrees/*/; do
  [ -d "$WT_DIR" ] || continue
  WT_BRANCH=$(git -C "$WT_DIR" branch --show-current 2>/dev/null || echo "")
  [ -z "$WT_BRANCH" ] && continue
  MERGE_BASE=$(git merge-base "$MAIN_BRANCH" "$WT_BRANCH" 2>/dev/null || echo "")
  [ -z "$MERGE_BASE" ] && continue
  WT_FILES=$(git diff --name-only "${MERGE_BASE}..${WT_BRANCH}" 2>/dev/null || true)
  # Compare WT_FILES against your planned file list
done
```

Overlap detected → proceed with worktree per Step 2a, flag for FCFS rebase-and-replay handling on merge-back (per `_v-exec.md` Section Index → "Build Worktree Lifecycle" → `${CLAUDE_SKILL_DIR}/../references/v-exec-worktree-lifecycle.md`; full FCFS loop lands in Pass 3 of v-orchestrator-improvements). Overlap is NOT a stop — it's input to merge-back planning. Both sessions complete; second-to-merge rebases on first.

**Step 2d is ADDITIVE to Step 2a, not subtractive.** Lack of overlap does NOT remove worktree requirement set by 2a.

| Step 2a | Step 2d | Action |
|---|---|---|
| Parallel detected | No overlap | Worktree required (2a). Standard merge-back. |
| Parallel detected | Overlap detected | Worktree required (2a) + FCFS rebase flag (full FCFS rebase loop lands in Pass 3 of v-orchestrator-improvements). |
| No parallel | N/A | Worktree based on scope only (per 2b). |

**Maintenance proportionality clause (W25-F25 — TIGHTENED):** for `Maintenance` workflows ONLY (NOT Bug Fix, NOT Feature anything) with scope ≤ 3 files AND verified zero overlap with active worktrees AND zero hot-file modifications AND zero touches to auth/billing/migration/cron/queue/payment/webhook/admin paths, direct-on-main work is allowed.

**For everything else — including all `Bug Fix` workflows of any size, all `Feature` tiers, all bug-hunt-MD-driven fixes, all audit-driven fixes — a worktree is MANDATORY.** No more "small bug fix can skip worktree" — that exemption was responsible for the 2026-05-11 cross-session contamination where 4 parallel /v sessions ran inline on main and stepped on each other's dirty trees. The cost of worktree creation (~2 seconds) is dramatically less than the cost of contaminated commits.

The worktree is created by Step 2's flow, used throughout Steps 3-6, merged back to main in Step 6.5 (auto-rebase, auto-conflict-resolution, ff-only safety), and **the worktree directory + branch are automatically removed** as part of the merge-back script (`v-merge-back.sh`). No manual cleanup needed.

**Anti-pattern (observed in production):** "Other worktrees had 0 committed changes → no overlap → skip worktree." Wrong: (1) uncommitted changes invisible to git diff but real on disk, (2) Step 2d cannot subtract from 2a regardless. See `references/v-scope-boundaries.md` § Worktree Requirement is Non-Negotiable.

`session-context-loader.sh` hook also detects overlap at session start and writes a notice; orchestrator reads it as merge-back input, not as a question to ask user (forbidden from Step 2 onward per `_v-core.md` § Temporal constraint).

---
