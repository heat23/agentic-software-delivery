# Scope Detection & Task Size Boundaries Reference

## Step 2b: Scope Classification

For Bug fix and Feature, estimate scope before starting:

| Size | Definition | Worktree (solo) | Worktree (parallel) | Planning |
|------|-----------|-----------------|---------------------|----------|
| **Bug fix** | Single file, update existing test, no new API surface | No | **Yes** | None |
| **Small** | 1–3 files, minor functionality addition | No | **Yes** | Inline |
| **Medium** | 4–10 files, new API or UI, cross-layer change | **Yes** | **Yes** | `/v-new-feature` |
| **Large** | 10+ files, architectural change, new domain concept | **Yes** | **Yes** | `/v-new-feature` (design doc auto-validated by AI before build) |

## Scope Determination Rules

1. **Scope is set by file count, not perceived effort or conceptual simplicity.** If mid-implementation you discover scope is larger than classified, stop and re-classify.

2. **Content-only sessions are NOT exempt.** Blog articles, copy changes, and markdown edits still modify shared files (templates, routes, frontmatter configs). When parallel sessions are detected, content sessions MUST use worktrees. "It's just content" is not a valid reason to skip isolation.

3. **Scope downgrade anti-patterns (do NOT rationalize these):**
   - "I don't need a worktree for this" — scope determines worktree use, not perceived complexity
   - "I'll keep it inline since I'm already started" — stop and re-classify if scope exceeds initial estimate
   - "It's just a bug fix, no worktree needed" — if parallel sessions are detected, ALL scopes get a worktree
   - "It's just content/blog/copy changes" — content sessions touch shared files too; worktree required in parallel mode
   - "I checked file overlap and there's no conflict, so no worktree needed" — Step 2a (parallel session detected) sets the worktree requirement; Step 2d (file overlap detection) ADDS conflict-shape checking; it does NOT subtract from Step 2a. Lack of overlap is never a reason to skip worktree when parallel sessions exist.
   - "Other worktrees have no committed changes, so they pose no overlap risk" — uncommitted changes in other worktrees are invisible to git diff but real on disk. Other sessions may have staged but uncommitted edits on overlapping files (observed in a production session — main had staged UI-component changes from a sibling session, blocking merge-back). Worktree isolation prevents this regardless of visible overlap.

4. **Worktree flags:**
   - `--worktree` forces worktree regardless of scope
   - `--no-worktree` skips it (even in parallel mode — user takes responsibility for conflicts)

## Parallel Session Detection Rule

**MANDATORY — runs before scope classification**

Before classifying scope, detect whether other Claude sessions are active:

```bash
# PRIMARY (race-free): bootstrap's Step-0 start-claim scan. Each /v session drops a claim marker
# (~/.claude/runtime/v-session-claim-<sid>) the instant it starts — BEFORE classification and BEFORE
# any worktree exists — and bootstrap reports PARALLEL_SESSIONS_DETECTED=1 when a LIVE non-self claim
# is present (liveness = the sibling's transcript .jsonl was touched within the window). This is the
# ONLY signal that catches a SIMULTANEOUSLY-launched fleet and INLINE siblings (no worktree lock yet).
# Read it from the bootstrap key=value output captured at Step 0 — do NOT recompute it here.
PARALLEL_SESSIONS_DETECTED=$(sed -n 's/^PARALLEL_SESSIONS_DETECTED=//p' "$BOOTSTRAP_ENV" | tr -d "'\"")
# SECONDARY (worktree-lock based): visible only AFTER a sibling has created its worktree.
WORKTREE_COUNT=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')
RECENT_LOCKS=$(find .worktrees -name '.claude-session-lock' -mmin -240 2>/dev/null | wc -l | tr -d ' ')
```

**Rule: If ANY parallel session indicator is detected (`PARALLEL_SESSIONS_DETECTED=1` OR WORKTREE_COUNT > 1 OR RECENT_LOCKS > 0), ALL scopes use a worktree — including Bug fix and Small.** This prevents concurrent sessions from clobbering each other's uncommitted changes on the same branch. The only exception is `--no-worktree` explicit flag.

**Why:** Without worktree isolation, parallel sessions share the same working directory. Two sessions editing different files on `main` will create merge conflicts, corrupt each other's `git add` staging area, and produce unpredictable test results. Worktrees are cheap — the overhead is negligible compared to debugging a corrupted working tree.

**Why the claim signal is primary (the startup race it closes):** the worktree-lock indicators (`WORKTREE_COUNT` / `RECENT_LOCKS`) only become true AFTER a sibling has created its worktree. When the operator launches a whole fleet in parallel on shared `main`, every session runs Step 2a within the same second — before anyone has locked — so each reads "solo" and the inline-eligible paths (Maintenance, read-only, worktree-setup-failure fallback) all proceed inline on main and contaminate each other (an observed cross-session leak). The Step-0 start-claim is dropped before classification, so a parallel sibling is visible immediately; bootstrap's transcript-liveness check then distinguishes a still-running sibling from a crashed one. Fail direction is to over-isolate (force a worktree) on ambiguity — a wasted worktree is cheap; a contaminated `main` is not.


## Worktree Requirement is Non-Negotiable When Parallel Sessions Exist

Step 2a (Parallel Session Detection) sets the worktree requirement. Step 2d (File Overlap Detection in `/v` SKILL.md) ADDS conflict-shape analysis; it does NOT subtract from Step 2a's requirement.

**Decision flow:**

| Step 2a result | Step 2d result | Action |
|---|---|---|
| Parallel detected | No overlap | Worktree required (Step 2a wins) |
| Parallel detected | Overlap detected | Worktree required AND flag for FCFS rebase-and-replay loop on merge-back (per `_v-exec.md` Build Worktree Lifecycle — full quorum-resolved rebase loop lands in Pass 3 of v-orchestrator-improvements; until then, overlap is recorded for post-hoc reconciliation) |
| No parallel | No overlap | Worktree based on scope only |
| No parallel | (overlap impossible — no other sessions) | n/a |

**The orchestrator MUST self-detect a Step 2a violation.** If at the start of Step 3 (Execute), `git worktree list` shows the orchestrator is operating on `main` (not inside a worktree) AND parallel sessions were detected at Step 2a, this is a spec violation. Recovery:

1. STOP all in-flight edits immediately.
2. `git stash` is forbidden in worktree workflows. Instead: identify any uncommitted edits made so far, capture the diff with `git diff > $V_TMP_DIR/recovery-<sid>.diff`, then `git checkout -- .` to clean main.
3. Create the worktree per Step 2b's table for the classified size.
4. `cd` to `WORKTREE_ABS_PATH`.
5. Apply the captured diff inside the worktree: `git apply $V_TMP_DIR/recovery-<sid>.diff`.
6. Resume Step 3 from the beginning.

**Anti-pattern: rationalizing past the violation by saying "I've already started, I'll just keep going on main."** That's how a production session ended up violating its own spec. The recovery cost (5 turns, ~3–5k tokens) is bounded; the conflict-recovery cost when a sibling session merges first is much higher.
