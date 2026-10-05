# v-handoff data collection

> **Persona for this reference:** senior session-handoff engineer
> with experience producing transitions between long-running
> Claude sessions for solo SaaS dev work. Loaded on-demand by
> v-handoff Step 1 (Workflow) to gather repository state for the
> handoff document.

The bash commands below are run in parallel to collect everything
the next session needs to pick up where this one left off. Output
is consumed by the synthesis step that produces the HANDOFF
document body.

When working in worktree-isolated workflows, do NOT use
`git stash` — it shares a LIFO stack across worktrees and
contaminates other sessions. Use named patches or commit-then-revert
instead.

---

## Data Collection

Run these in parallel:

```bash
# Anchor cwd FIRST — this skill runs context:fork; the Bash tool's cwd is NOT guaranteed
# to be the project tree, and cwd does not persist across Bash tool calls (_v-core.md
# "NEVER bare pwd in forked/headless contexts"; P1 fix 2026-07-05, skill review).
cd "${WORKTREE_PATH:-${PROJECT_ROOT:?FATAL: PROJECT_ROOT unset — resolve it before data collection}}" || { echo "FATAL: cannot cd to project tree" >&2; exit 1; }
# Branch and status
git branch --show-current
git status --short
git diff --stat

# Recent commits
git log --oneline -10

# Uncommitted work in worktrees (stash is unsafe in worktree workflows)
git worktree list 2>/dev/null
```

Quick test check (bounded to 120s per command using `timeout` for reliable enforcement).

**Worktree-aware:** If running inside a worktree, ensure commands execute in the worktree directory, not the main directory:
```bash
# Determine the correct working directory — prefer the session's worktree, then
# PROJECT_ROOT; bare $(pwd) only as last resort (see cwd-anchor note above).
WORK_DIR="${WORKTREE_PATH:-${PROJECT_ROOT:-$(pwd)}}"
# Portable timeout
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD="timeout 120s"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD="gtimeout 120s"
fi

# Run tests in the correct directory
TEST_EXIT=0
$TIMEOUT_CMD bash -c "cd '$WORK_DIR' && ./vendor/bin/pest" 2>&1 | tail -5; TEST_EXIT=${PIPESTATUS[0]}
if [ "$TEST_EXIT" -eq 124 ]; then
  echo "Tests timed out after 120s — consider running /v-pre-flight for full results"
elif [ "$TEST_EXIT" -ne 0 ]; then
  echo "Tests failed (exit code $TEST_EXIT)"
else
  echo "Tests passed"
fi

BUILD_EXIT=0
$TIMEOUT_CMD bash -c "cd '$WORK_DIR' && npm run build" 2>&1 | tail -5; BUILD_EXIT=${PIPESTATUS[0]}
if [ "$BUILD_EXIT" -eq 124 ]; then
  echo "Build timed out after 120s — consider running /v-pre-flight for full results"
elif [ "$BUILD_EXIT" -ne 0 ]; then
  echo "Build failed (exit code $BUILD_EXIT)"
else
  echo "Build passed"
fi
```

Recent artifact discovery (intentionally session-agnostic — handoff captures recent artifacts for context, regardless of which session created them):

**Freshness filter (NEW — Round 3):** only attach artifacts modified within the last **30 days**. A 6-week-old PLAN from a different feature should not be attached to the current handoff. If the most-recent matching artifact is older than 30 days, render `"None — most recent is N days old, omitted as stale"`.

```bash
# Anchor cwd (same rule as the Data Collection block above).
cd "${WORKTREE_PATH:-${PROJECT_ROOT:?FATAL: PROJECT_ROOT unset}}" || { echo "FATAL: cannot cd to project tree" >&2; exit 1; }
# Freshness window: 30 days.
# Operator override: `$@` is ALWAYS empty in an inline skill bash block (the invocation
# args are not shell args — dead-code class, P1 fix 2026-07-05). Instead: when the user's
# invocation text contains `--include-stale`, the MODEL sets the variable below to 99999
# before running this block. Do not re-introduce a `for arg in "$@"` loop here.
FRESHNESS_DAYS=30   # set to 99999 when the invocation included --include-stale
[ "$FRESHNESS_DAYS" -gt 30 ] && echo "(--include-stale: freshness filter disabled for this run)"

# Portable file-age helper: emits age-in-days or empty string.
# Tries GNU stat (-c %Y), then BSD/macOS stat (-f %m), then python3 fallback.
file_age_days() {
  local f="$1"
  [ -e "$f" ] || { echo ""; return; }
  local mtime
  mtime=$(stat -c %Y "$f" 2>/dev/null) \
    || mtime=$(stat -f %m "$f" 2>/dev/null) \
    || mtime=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$f" 2>/dev/null) \
    || mtime=""
  if [ -n "$mtime" ]; then
    echo $(( ($(date +%s) - mtime) / 86400 ))
  else
    echo ""
  fi
}

for pattern in "PLAN_*.md" "AUDIT_REPORT_*.md" "REFACTOR_PLAN_*.md" "POLISH_PLAN_*.md" "BUILD_BLOCKER_*.md" "IMPLEMENTATION_REPORT_*.md" "PROGRESS_NOTE_*.md" "PRE_FLIGHT_REPORT_*.md" "VERIFY_DONE_REPORT_*.md" "LAUNCH_CHECKLIST_*.md" "DOCS_AUDIT_*.md" "AGENT_REVIEW_*.md"; do
  # find with -mtime -30 returns files modified within last 30 days.
  # Dual-search: planning/report artifacts moved under .v/artifacts/ (Phase 2) —
  # search both roots or relocated artifacts read as missing.
  result=$(find . .v/artifacts -maxdepth 1 -name "$pattern" -type f -mtime -${FRESHNESS_DAYS} 2>/dev/null \
    | sort \
    | tail -1)
  if [ -n "$result" ]; then
    echo "$pattern: $result"
    continue
  fi
  # Fresh match not found — check if a stale match exists, and report age
  stale=$(ls -t $pattern .v/artifacts/$pattern 2>/dev/null | head -1)
  if [ -n "$stale" ]; then
    age_days=$(file_age_days "$stale")
    if [ -n "$age_days" ]; then
      echo "$pattern: None — most recent is ${age_days} days old, omitted as stale"
    else
      echo "$pattern: None — stale match exists but age unknown"
    fi
  else
    echo "$pattern: None"
  fi
done
```

**Override:** if the operator explicitly invokes `/v-handoff --include-stale`, skip the freshness filter (some long-running projects legitimately have artifacts older than 30 days that are still relevant).
