# Step 6 + 6.5: Completion Verification & Merge-Back (extracted from /v SKILL.md)

> Loaded by /v Step 6 ("read this reference before executing Step 6's bash"). The orchestrator-side bash anchors stay inline in /v SKILL.md; the verbose explanatory + per-sub-step protocols live here so /v SKILL.md stays at routing scale.

## Step 6: Completion Verification

### Step 6.-1: Main HEAD Advance Detection (Conc-FND-6 / W22-3)

If the user runs parallel /v sessions in the same project, Session A's merge-back can advance main HEAD while Session B is still working. Session B's pending changes were authored against the old HEAD and may conflict / behave incorrectly with new main state. Surface this BEFORE Step 6 verification so the orchestrator can re-read affected files and re-run pre-flight against the new baseline.

```bash
MAIN_HEAD_AT_START_FILE="$V_TMP_DIR/main-head-at-start-${CLAUDE_SESSION_ID:-$$}.txt"
if [ -f "$MAIN_HEAD_AT_START_FILE" ]; then
  HEAD_AT_START=$(cat "$MAIN_HEAD_AT_START_FILE" | tr -d '[:space:]')
  HEAD_NOW=$(git -C "$PROJECT_ROOT" rev-parse "refs/heads/${MAIN_BRANCH:-${CLAUDE_MAIN_BRANCH:-main}}" 2>/dev/null || echo "")
  if [ -n "$HEAD_AT_START" ] && [ -n "$HEAD_NOW" ] && [ "$HEAD_AT_START" != "$HEAD_NOW" ]; then
    ADVANCED_BY=$(git -C "$PROJECT_ROOT" rev-list --count "$HEAD_AT_START..$HEAD_NOW" 2>/dev/null || echo "?")
    echo "WARN: main advanced by $ADVANCED_BY commits during this session ($HEAD_AT_START → $HEAD_NOW)" >&2
    echo "WARN: a parallel session likely merged back. Verify your changes still apply correctly:" >&2
    # FND-5: reify with actual changed-file list from session-writes log
    CHANGED_FROM_LOG=""
    if [ -f "$V_TMP_DIR/session-writes-${CLAUDE_SESSION_ID:-${SESSION_ID:-}}.txt" ]; then
      CHANGED_FROM_LOG=$(cat "$V_TMP_DIR/session-writes-${CLAUDE_SESSION_ID:-${SESSION_ID:-}}.txt" 2>/dev/null | tr '\n' ' ')
    fi
    if [ -n "$CHANGED_FROM_LOG" ]; then
      echo "WARN:   git -C $PROJECT_ROOT log --oneline $HEAD_AT_START..$HEAD_NOW -- $CHANGED_FROM_LOG" >&2
    else
      echo "WARN:   git -C $PROJECT_ROOT log --oneline $HEAD_AT_START..$HEAD_NOW   # (then add -- <paths> for files you touched)" >&2
    fi
    echo "WARN: if your changes conflict with new main, re-read affected files and re-run /v-pre-flight." >&2
    # Do NOT exit — surfacing is enough; the user / orchestrator can adapt.
    # Worktree sessions are safest because they branched from old main and merge-back
    # rebases automatically. Solo (no-worktree) sessions need the warning most.
  fi
fi
```

This is non-blocking — it surfaces the divergence and lets the orchestrator decide. Worktree sessions handle this transparently via Step 6.5 rebase. Solo sessions on main face the most risk and benefit most from the warning.

### Step 6.0: Wait for Background Reviews (Conc-FND-3 / W21)

If Step 5 dispatched the codex review with `run_in_background: true`, the orchestrator may
arrive at Step 6 before the background agent has finished writing AGENT_REVIEW. The Stop hook
fires at session end and validates AGENT_REVIEW existence + structure. If it fires while
the background write is still in-flight, the hook blocks completion with an opaque error
the user cannot easily diagnose.

```bash
# Poll for AGENT_REVIEW to land. Bounded retry — fall back to foreground re-dispatch on timeout.
AGENT_REVIEW_FILE="$PROJECT_ROOT/.v/artifacts/AGENT_REVIEW_${SESSION_ID}.md"
MAX_POLL_SECONDS=180   # 3 min — adversarial review on a moderate diff finishes well within this
POLL_INTERVAL=5
ELAPSED=0

if [ ! -f "$AGENT_REVIEW_FILE" ]; then
  echo "INFO: Step 6.0 waiting for background AGENT_REVIEW to land (polling every ${POLL_INTERVAL}s, timeout ${MAX_POLL_SECONDS}s)..." >&2
fi

while [ ! -f "$AGENT_REVIEW_FILE" ] && [ $ELAPSED -lt $MAX_POLL_SECONDS ]; do
  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ ! -f "$AGENT_REVIEW_FILE" ]; then
  echo "WARN: AGENT_REVIEW didn't land within ${MAX_POLL_SECONDS}s — background agent may be stuck" >&2
  echo "WARN: falling back to ORCHESTRATOR_INLINE review per _v-review.md § Agent Dispatch Verification Gate" >&2
  # Orchestrator must conduct the review itself; do NOT proceed to Step 6.5/7 without AGENT_REVIEW.
  # See Step 5 Decision Tree branch 2.IF NOT found OR codex CLI unavailable → ORCHESTRATOR_INLINE.
fi

# Even if file exists, validate it has the structural minimum (Findings header + Status field).
# If missing, that's a partial write — the agent crashed mid-write. Same fallback.
if [ -f "$AGENT_REVIEW_FILE" ]; then
  if ! grep -qE '^## (Findings|Review)' "$AGENT_REVIEW_FILE" || \
     ! grep -qE '^- Status:' "$AGENT_REVIEW_FILE"; then
    echo "WARN: AGENT_REVIEW exists but is incomplete (missing Findings header or Status field)" >&2
    echo "WARN: background agent may have crashed mid-write — falling back to ORCHESTRATOR_INLINE rewrap" >&2
  fi
fi
```

This eliminates the silent stop-hook block for background reviews and gives the orchestrator
deterministic synchronization. The 3-minute cap is empirical — Wave 11 production sessions
finished review in 30-180s; nothing legitimately runs longer.

### Scoped-Mode Final Full-Suite Check (W16-2)

When pre-flight ran in `scoped` or `dirty-tree` mode, scoped tests can MISS regressions in indirect-dependent tests (a test that doesn't touch the changed file but exercises a code path through it). The W16 fast-iteration mode buys ~60-160s on small sessions in exchange for this risk. Mitigate before completion:

```bash
# Run final full-suite check when EITHER:
#   1. Pre-flight ran scoped (PRE_FLIGHT_MODE != "full") — scoped tests miss indirect dependents
#   2. Session is in a worktree (Rel-FND-22 fix: merge-back gate runs git ops only, NOT tests;
#      worktree session can otherwise complete with scoped or zero tests on indirect-dependent
#      bugs). Test post-rebase to catch any regression introduced by main's parallel changes.
WAS_SCOPED=$([ "${MODE:-full}" != "full" ] && echo "true" || echo "false")
IN_WORKTREE=$([ -n "${WORKTREE_ABS_PATH:-}" ] && echo "true" || echo "false")
NEEDS_FINAL_CHECK=$([ "$WAS_SCOPED" = "true" ] || [ "$IN_WORKTREE" = "true" ] && echo "true" || echo "false")

if [ "$NEEDS_FINAL_CHECK" = "true" ]; then
  echo "W16-2/W21: scoped pre-flight OR worktree session → running final full-suite safety check before completion" >&2
  FINAL_PEST_LOG="$V_TMP_DIR/gate-final-pest-${SESSION_ID}.log"
  FINAL_VITEST_LOG="$V_TMP_DIR/gate-final-vitest-${SESSION_ID}.log"

  # W-perf3: this full suite is the per-session regression gate before merge-to-main.
  # It previously ran SINGLE-PROCESS `php artisan test` (~739s on a large
  # production repo). Source the core/concurrency-aware budget and run paratest bounded by the
  # FULL budget; the run below is SERIALIZED via the cross-session suite lock, so it gets
  # the larger budget without oversubscribing cores when sibling sessions check at once.
  _VPB="$HOME/.claude/skills/v/references/v-proc-budget.sh"
  [ -f "$_VPB" ] && . "$_VPB"
  : "${V_PEST_PROCESSES_FULL:=4}"

  # W-perf4: optional paratest worker memory headroom (mirrors v-run-gates.sh:510-511);
  # empty unless PEST_PARALLEL_MEMORY is set, and applied only to a `--parallel` command.
  _FINAL_MEM_PASSTHRU=""
  [ -n "${PEST_PARALLEL_MEMORY:-}" ] && _FINAL_MEM_PASSTHRU="--passthru-php=-d memory_limit=${PEST_PARALLEL_MEMORY}"
  _fc_run_pest() {  # run FINAL_PEST_INVOKE, adding the mem passthru iff it is paratest (--parallel)
    case "$FINAL_PEST_INVOKE" in
      *--parallel*) $FINAL_PEST_INVOKE ${_FINAL_MEM_PASSTHRU:+"$_FINAL_MEM_PASSTHRU"} > "$FINAL_PEST_LOG" 2>&1 ;;
      *)            $FINAL_PEST_INVOKE > "$FINAL_PEST_LOG" 2>&1 ;;
    esac
  }
  _fc_is_crash() {  # non-empty partial log + OOM/render signature + NO "Tests:" tally = INFRA crash
    [ -f "$FINAL_PEST_LOG" ] || return 1
    grep -qE '^[[:space:]]*Tests:[[:space:]]' "$FINAL_PEST_LOG" && return 1
    grep -qiE 'Allowed memory size of [0-9]+ bytes exhausted|WorkerCrashedException|Exit Code (137|143)\)|received (SIGTERM|SIGKILL)|nunomaduro/collision.*Highlighter|token_get_all|PHP Fatal error' "$FINAL_PEST_LOG"
  }

  # FND-14/FND-20: respect a CLAUDE.md test command if present (custom runner / wrapper).
  # Detection (full-suite line, NOT a single-file example) + Sec-FND-2 metachar rejection
  # live in the shared helper v-detect-test-cmd.sh (one source of truth — three drifting
  # copies are what let the old `head -1` pick `pest tests/Feature/SomeTest.php`).
  CLAUDE_PEST_CMD=""; CLAUDE_VITEST_CMD=""
  _DTC="$HOME/.claude/skills/v/references/v-detect-test-cmd.sh"
  if [ -f "$_DTC" ] && [ -f "$PROJECT_ROOT/CLAUDE.md" ]; then
    . "$_DTC"
    CLAUDE_PEST_CMD=$(detect_project_test_cmd "$PROJECT_ROOT/CLAUDE.md" pest)
    CLAUDE_VITEST_CMD=$(detect_project_test_cmd "$PROJECT_ROOT/CLAUDE.md" vitest)
  fi
  # Default to the project's PARALLEL pest binary (bounded by the FULL budget) over
  # single-process `php artisan test`. An explicit, full-suite CLAUDE.md command wins.
  if [ -n "$CLAUDE_PEST_CMD" ]; then
    FINAL_PEST_INVOKE="$CLAUDE_PEST_CMD"
  elif [ -x "./vendor/bin/pest" ] || [ -x "$PROJECT_ROOT/vendor/bin/pest" ]; then
    FINAL_PEST_INVOKE="./vendor/bin/pest --parallel --processes=${V_PEST_PROCESSES_FULL}"
  else
    FINAL_PEST_INVOKE="php artisan test"
  fi
  FINAL_VITEST_INVOKE="${CLAUDE_VITEST_CMD:-npx vitest run}"

  # W-perf3: serialize this full suite across concurrent sessions — it does NOT take the
  # lock today, so K sessions hitting the final check at once would spawn K×N paratest
  # workers → CPU oversubscription on a shared machine. Repo-wide, fail-open (proceed after
  # timeout — never block forever), opt-out via V_NO_SUITE_LOCK=1. Released right after the
  # heavy run, BEFORE classification/exit, so a failure can't leak the lock.
  _FC_LOCK_SH="$HOME/.claude/skills/v/references/v-suite-lock.sh"
  _FC_LOCK_REPO="${WORKTREE_ABS_PATH:-${PROJECT_ROOT:-$(pwd)}}"
  _FC_LOCK_SID="${CLAUDE_SESSION_ID:-${SESSION_ID:-$$}}"
  _FC_LOCK_HELD=0
  if [ -f "$_FC_LOCK_SH" ] && [ "${V_NO_SUITE_LOCK:-0}" != "1" ]; then
    _FC_GT="${V_RUN_GATES_TIMEOUT_SEC:-900}"
    echo "W16-2: acquiring full-suite lock (serializing concurrent final checks in this repo)…" >&2
    bash "$_FC_LOCK_SH" acquire "$_FC_LOCK_REPO" "$_FC_LOCK_SID" "$(( _FC_GT * 2 ))" "$(( _FC_GT * 3 / 2 ))" >&2 || true
    _FC_LOCK_HELD=1
  fi
  _fc_release() { [ "${_FC_LOCK_HELD:-0}" = "1" ] && bash "$_FC_LOCK_SH" release "$_FC_LOCK_REPO" "$_FC_LOCK_SID" >&2 2>/dev/null; _FC_LOCK_HELD=0; }

  # Run the suite (with ONE retry on empty-output INCONCLUSIVE), all under the lock.
  _fc_run_pest & FP_PID=$!
  $FINAL_VITEST_INVOKE > "$FINAL_VITEST_LOG" 2>&1 & FV_PID=$!
  wait $FP_PID;  FINAL_PEST_RC=$?
  wait $FV_PID;  FINAL_VITEST_RC=$?
  # Treat empty-output as INCONCLUSIVE (W10 / FND-17 protection)
  [ ! -s "$FINAL_PEST_LOG" ]   && FINAL_PEST_RC="INCONCLUSIVE"
  [ ! -s "$FINAL_VITEST_LOG" ] && FINAL_VITEST_RC="INCONCLUSIVE"
  # W-perf4: a CRASH (paratest worker OOM / Collision render) leaves a PARTIAL log + non-zero
  # exit but NO "Tests:" tally — INFRA, not a regression. Reclassify to INCONCLUSIVE so it
  # takes the retry/proceed path (with memory headroom) instead of the exit-1 path (two prod
  # sessions each burned ~1h treating a worker OOM as a failing suite, re-running
  # the whole suite in a loop chasing a clean pass).
  if [ "$FINAL_PEST_RC" != "0" ] && [ "$FINAL_PEST_RC" != "INCONCLUSIVE" ] && _fc_is_crash; then
    echo "WARN: final pest run CRASHED (paratest worker OOM / Collision render) — INFRA, not a regression. Treating as INCONCLUSIVE; the retry runs with memory headroom." >&2
    [ -z "${PEST_PARALLEL_MEMORY:-}" ] && { export PEST_PARALLEL_MEMORY=1024M; _FINAL_MEM_PASSTHRU="--passthru-php=-d memory_limit=1024M"; }
    FINAL_PEST_RC="INCONCLUSIVE"
  fi
  case "$FINAL_PEST_RC:$FINAL_VITEST_RC" in
    INCONCLUSIVE:*|*:INCONCLUSIVE)
      echo "WARN: final full-suite check INCONCLUSIVE (pest=$FINAL_PEST_RC, vitest=$FINAL_VITEST_RC) — empty output is usually a runner crash (OOM/disk-full), NOT a regression. Retrying once…" >&2
      _fc_run_pest & FP_PID=$!
      $FINAL_VITEST_INVOKE > "$FINAL_VITEST_LOG" 2>&1 & FV_PID=$!
      wait $FP_PID;  FINAL_PEST_RC=$?
      wait $FV_PID;  FINAL_VITEST_RC=$?
      [ ! -s "$FINAL_PEST_LOG" ]   && FINAL_PEST_RC="INCONCLUSIVE"
      [ ! -s "$FINAL_VITEST_LOG" ] && FINAL_VITEST_RC="INCONCLUSIVE"
      ;;
  esac
  _fc_release   # heavy runs done — drop the lock before classification/reporting/exit

  # FND-10: distinguish real failure from INCONCLUSIVE (don't know vs. failed).
  case "$FINAL_PEST_RC:$FINAL_VITEST_RC" in
    0:0)
      echo "W16-2: final full-suite check PASS — safe to complete" >&2
      ;;
    INCONCLUSIVE:*|*:INCONCLUSIVE)
      echo "WARN: final check still INCONCLUSIVE after retry — proceeding (user must verify manually). Persistent empty output is an infra issue, not a regression — do NOT fail on it." >&2
      ;;
    *)
      echo "ERROR: final full-suite check failed (pest=$FINAL_PEST_RC, vitest=$FINAL_VITEST_RC)" >&2
      echo "  scoped pre-flight passed but full suite found regressions — likely indirect dependent test" >&2
      echo "  fix the regressions, then re-attempt completion" >&2
      exit 1
      ;;
  esac
fi
# W21 / Rel-FND-22: worktree sessions NO LONGER skip this. Step 6.5 merge-back is
# git operations only — it doesn't run tests. Without this final check, worktree sessions
# could complete with scoped or zero tests on indirect-dependent bugs.
```

This safety net catches the "indirect dependent test" edge case while preserving the W16 speedup on the dominant fast-iteration path. On clean sessions (no test failures introduced), the final check adds ~30-60s — which is offset by the ~60-160s saved by scoped pre-flight, so net wall-clock is still better than the pre-W16 baseline.

### Verify-Done Model Tiering (W13 — forward-looking)

The production `enforce-haiku-dispatch.sh` hook auto-corrects v-verify-done dispatches to `model: "haiku"` by default, **but honors `VERIFY_DONE_MODEL_OVERRIDE` (HOOK-10, LANDED)** — when the orchestrator exports `VERIFY_DONE_MODEL_OVERRIDE=sonnet|opus` before dispatch, the hook skips the auto-correct for v-verify-done and lets the override stand. The tiering the orchestrator should apply when computing the override:

| Mode / Diff size | Recommended model | Rationale |
|---|---|---|
| `scoped` ≤ 15 files | haiku | Pure mechanical convention scan |
| `full` mode OR > 30 files | sonnet | Cross-file conventions need broader attention; haiku misclassified pre-existing PHP/JS test failures as session failures in one production session |
| `dirty-tree` mode | sonnet | Mixed pre-existing + session changes are easy to misattribute |

**Implementation status:** the hook support is LIVE (`enforce-haiku-dispatch.sh` HOOK-10 honors `VERIFY_DONE_MODEL_OVERRIDE`). The orchestrator computes the override from `dirty_count` + mode classification before dispatch; when unset, v-verify-done defaults to haiku.

Until the hook is updated, all v-verify-done runs use haiku regardless of mode. This is a known limitation; W12 fixes (SID env, vitest CLI, status-first table) eliminated the format-failure issues that previously dominated verify-done waste, so the practical impact is minor.

### Completion Verification Loop (Mandatory)

Before completion, verify required artifacts exist and are valid for this session:

**Bug fix / Small:**
- `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md` (passing)
- `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md`
- `POLISH_PLAN_*_${CLAUDE_SESSION_ID}.md` (if UI changed — dual-search: `.v/artifacts/` first, bare root as legacy fallback; v-polish writes under `.v/artifacts/` since Phase 2)
- `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md` semantically completed (codex/superpowers/orchestrator-inline provenance, no degraded self-review language, all 8 provenance fields present, including Reviewer model from W13)

**Medium / Large adds:**
- `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md`
- `IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md`
- `AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md` with `mode: scoped`
- Worktree isolation used (or misclassification documented)

If missing: invoke the corresponding skill NOW. Do NOT write a retroactive artifact.

**Forbidden rationalizations** (all invalid):
- "I skipped agent dispatch — implemented inline" (agent review is mandatory ALL implementations)
- "No agents directory" (use `superpowers:requesting-code-review` or ORCHESTRATOR_INLINE fallback)
- "Content-only session" (if ANY code file changed → verify-done mandatory; check by extension, not classification)
- "Small/Polish scope" (code changes determine verify-done, not scope)
- "Deferred to user" (verify-done is automatic last gate)

Skip verify-done ONLY when ZERO code files changed (pure markdown/SVG/image/.env).

### Retroactive scope verification

Count actual files changed (worktree-aware — use merge-base in worktrees):
```bash
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
IS_WORKTREE=false
if [ "$(git rev-parse --git-common-dir 2>/dev/null)" != "$(git rev-parse --git-dir 2>/dev/null)" ]; then
  IS_WORKTREE=true
fi
MERGE_BASE=$(git merge-base HEAD "$MAIN_BRANCH" 2>/dev/null || echo "")
printf '%s\n%s\n%s\n%s\n' \
  "$(git diff --name-only HEAD 2>/dev/null || true)" \
  "$(git diff --cached --name-only 2>/dev/null || true)" \
  "$(git ls-files --others --exclude-standard 2>/dev/null || true)" \
  "$(if [ -n "$MERGE_BASE" ]; then git diff --name-only "$MERGE_BASE"..HEAD 2>/dev/null || true; fi)" \
  | awk 'NF' | sort -u | wc -l
```

If >3 files changed but scope was classified as Bug fix / Small (solo session), this is a scope misclassification — the implementation should have used a worktree. If parallel sessions were detected but no worktree was used, this is a critical isolation failure regardless of file count.

**Medium/Large verification table:**
| Check | Required |
|-------|----------|
| Worktree isolation | Used .worktrees/build-* directory |
| Worktree merged & removed | Step 6.5 merge-back gate exit 0; `git worktree list` does NOT contain ${CLAUDE_SESSION_ID} |
| Plan artifact | PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md exists |
| Scoped audit | AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md with mode: scoped |

### UI change re-verification

Re-run UI file detection:
```bash
printf '%s\n%s\n%s\n' \
  "$(git diff --name-only HEAD -- '*.tsx' '*.jsx' '*.css' '*.html' '*.vue' '*.svelte' 2>/dev/null || true)" \
  "$(git diff --cached --name-only -- '*.tsx' '*.jsx' '*.css' '*.html' '*.vue' '*.svelte' 2>/dev/null || true)" \
  "$(git ls-files --others --exclude-standard -- '*.tsx' '*.jsx' '*.css' '*.html' '*.vue' '*.svelte' 2>/dev/null || true)" \
  | awk 'NF' | sort -u
```

If ANY UI file change is detected but `POLISH_PLAN_*_${CLAUDE_SESSION_ID}.md` does not exist in EITHER `.v/artifacts/` or the bare project root (dual-search — v-polish writes to `.v/artifacts/`; a root-only check would re-trigger polish that already ran): ANY UI file change triggers scoped polish — invoke `/v-polish` now.

### Spec-to-Impl Drift Check (Plan-Provided Sessions)

When session is driven by a provided plan (audit report, `/v-plan` output, structured prompt with numbered findings/items), self-report implementation coverage BEFORE Step 7. Catches partial coverage; surfaces bonus discoveries.

**Procedure:**

1. **Enumerate plan items** — extract numbered items: `Finding 1/2/...`, `1./2./...`, or explicit "what to change" claims.
2. **For each item, classify:**
   - **Implemented** — diff has evidence (file edited, test added, config updated).
   - **Previously fixed** — already resolved before this session. Cite prior SHA via `git log --grep="<keyword>" --oneline | head -3`. Acceptable (observed pattern in a production session).
   - **Skipped intentionally** — out of scope/invalid. Document reason in IMPLEMENTATION_REPORT.
   - **Skipped in error** — missed. **NOT acceptable.** Loop back: implement now before Step 7.
3. **Identify bonus discoveries** — files changed NOT traceable to plan items (parallel bugs, test upkeep, dep updates, type-fix cascades).
4. **Write coverage summary into IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md:**
   ```
   ## Plan Coverage
   - Plan items: <N> total
   - Implemented: <N-1> (items 1-5, 7-10)
   - Previously fixed: 1 (item 6 — commit <sha>, "<commit message>")
   - Skipped in error: 0

   ## Bonus Discoveries
   - <ParallelService>.php had identical bug-class as <PrimaryService>.php (TDD red phase).
   - <N> stale assertions in <test-file>.php updated as test-upkeep.
   ```
5. **Surface in Step 7 line 1 if relevant** — partial coverage = spec violation. Bonus discoveries: cite by count ("+ 2 bonus discoveries logged in IMPLEMENTATION_REPORT").

**Skip when:** sessions without an explicit plan (orchestrator generated its own strategy from a vague prompt). Apply judgment; still surface bonus discoveries. Rationale: V_DESIGN_NOTES.md § Spec-to-Impl Drift.

### Zero-skills critical failure

If you have invoked ZERO sub-skills during this session, this is a critical failure. The rationalization "No skills were needed" is never valid — every implementation requires at minimum v-pre-flight and v-verify-done. **A sanctioned `claude -p --agent` subprocess dispatch (`v-dispatch-subagent.sh` — the fork-required reviewer/runner path) COUNTS as a sub-skill invocation, not zero-skills** — do not flag a session that ran the gauntlet via subprocesses as a failure.

**Before writing the Step 7 report, check for uncommitted changes:**
- If there are uncommitted changes, inform the user: "All quality gates passed. You have uncommitted changes — say `/commit` when ready."
- Do NOT auto-commit. The global commit policy requires explicit user request.
(Note: `uncommitted-changes-gate.sh` Stop hook will block if unstaged tracked changes introduced by this session exist at session end.)



---

---

## Step 6.5: Mandatory Merge-Back Gate (worktree sessions)

If a worktree was created in Step 2/3, it MUST be merged back to main and removed BEFORE Step 7. This is a hard gate, not advisory. The merge-back script handles **parallel safety** (per-project flock, idempotency, conflict→handoff fallback) and works correctly across multiple parallel sessions in the same project AND across different projects.

### Invocation

```bash
SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID}}"
WORKTREE_PATH="${WORKTREE_ABS_PATH:-$(pwd)}"

# W21 / Conc-FND-4: orchestrator-side retry with exponential backoff. Parallel sessions
# in the same project queue on a flock — first succeeds, others wait. With 3-8 parallel
# sessions, the 120s timeout per attempt can be exhausted on tail sessions. Retry up to
# 3 times before surfacing failure.
ATTEMPT=0
MAX_ATTEMPTS=3
RC=0
MERGE_OUT=""
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  ATTEMPT=$((ATTEMPT + 1))
  # Capture output (incl. the W-conc-fix MERGE_BACK_REVERIFY_REQUIRED signal) while still showing it.
  MERGE_OUT=$(bash "${CLAUDE_SKILL_DIR}/references/v-merge-back.sh" "$SESSION_ID" "$WORKTREE_PATH" 2>&1)
  RC=$?
  printf '%s\n' "$MERGE_OUT"
  if [ $RC -eq 0 ] || [ $RC -eq 2 ]; then
    # 0 = success (or no worktree); 2 = config error — retrying won't help
    break
  fi
  # rc=3 (FND-3 DEFERRED) is retryable — a quick backoff may catch a sibling that just finished —
  # so the loop retries it best-effort; if it's STILL deferred after MAX_ATTEMPTS, the case 3) below
  # surfaces it (never silently falls through to completion on unmerged work).
  if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
    BACKOFF=$((30 * ATTEMPT))   # 30s, 60s
    echo "INFO: merge-back attempt $ATTEMPT/$MAX_ATTEMPTS failed (rc=$RC); retry in ${BACKOFF}s..." >&2
    sleep $BACKOFF
  fi
done

case $RC in
  0)
    echo "INFO: merge-back complete (or not applicable)"
    # W-conc-fix: if main advanced during this session (sibling sessions merged in),
    # the merge integrated work this session's gates NEVER ran against. A clean merge
    # is NOT proof the COMBINED main works. Re-run pre-flight on the merged main before
    # declaring done — this is the per-session analogue of /v-merge-all's Step 4.
    if printf '%s' "$MERGE_OUT" | grep -q '^MERGE_BACK_REVERIFY_REQUIRED=1'; then
      echo "WARN (W-conc-fix): main advanced during this session; re-verifying the COMBINED main before completion." >&2
      # Item 8 (2026-07-05): merge-back's advice (MERGE_BACK_REVERIFY_BASE_SHA + the
      # POSTMERGE_REVERIFY contract it documents in its own stderr) was previously ECHOED
      # to the user as prose ("ACTION: run /v-pre-flight on main now") but NEVER actually
      # threaded into the re-dispatch — an orchestrator could satisfy that sentence with a
      # bare full-mode /v-pre-flight, which recomputes BASE_SHA via merge-base(HEAD,main)
      # and finds BASE_SHA==HEAD (main==HEAD right after a ff-merge) → the F1 blind-scope
      # guard never fires because it only fires under scoped/dirty-tree/POSTMERGE_REVERIFY=1
      # — so a 0-diff, contentless "PASS" against the wrong (empty) scope could satisfy this
      # step. Extract the concrete values from MERGE_OUT and REQUIRE this exact invocation.
      _PM_BASE_SHA=$(printf '%s' "$MERGE_OUT" | sed -n 's/^MERGE_BACK_REVERIFY_BASE_SHA=//p' | tail -1)
      if [ -z "$_PM_BASE_SHA" ]; then
        echo "ERROR: MERGE_BACK_REVERIFY_REQUIRED=1 but MERGE_BACK_REVERIFY_BASE_SHA was not found in merge-back output — cannot scope the mandatory re-verify. Treat as BLOCKED (write BLOCKED_${SESSION_ID}.md); do NOT complete on an unverified combined main." >&2
        exit 1
      fi
      echo "ACTION (MANDATORY, not advisory): re-dispatch /v-pre-flight against main with:" >&2
      echo "    POSTMERGE_REVERIFY=1 BASE_SHA=$_PM_BASE_SHA bash \"\${CLAUDE_SKILL_DIR}/references/v-run-gates.sh\"" >&2
      echo "  (Worktree is already removed, so this runs against main directly. PRE_FLIGHT_MODE" >&2
      echo "  is irrelevant here — POSTMERGE_REVERIFY=1 forces the F1 blind-scope guard to fire" >&2
      echo "  on a 0-diff result even in 'full' mode, so a no-op re-verify cannot masquerade as PASS.)" >&2
      echo "  On FAIL: fix-loop or write BLOCKED_${SESSION_ID}.md. Do NOT skip — a clean merge of" >&2
      echo "  independently-green branches can still break main via semantic cross-deps. Do NOT" >&2
      echo "  proceed to Step 7 until this specific re-dispatch has actually run and passed." >&2
      # Item 10 (2026-07-05): the same combined-state gap applies to verify-done, which grades
      # a DIFFERENT diff range than pre-flight and has its own writes-log/git-state fallback that
      # is equally blind post-merge (worktree already removed). Mandate the matching re-dispatch
      # via the Verbatim Dispatch Mechanism, passing END_SHA so verify-done grades the exact
      # combined range instead of falling back to an empty or foreign-WIP scope.
      _PM_END_SHA="$(git -C "$PROJECT_ROOT" rev-parse "refs/heads/${MAIN_BRANCH:-main}" 2>/dev/null || echo "")"
      echo "ACTION (MANDATORY, not advisory): re-dispatch /v-verify-done against main with:" >&2
      echo "    POSTMERGE_REVERIFY=1 BASE_SHA=$_PM_BASE_SHA END_SHA=${_PM_END_SHA:-<current main HEAD>} (per dispatch-v-verify-done.md § Item 10 contract)" >&2
      echo "  A VERIFY_DONE_REPORT with Mode: scoped(postmerge-reverify:...) and Overall Verdict: FAIL" >&2
      echo "  when that range is empty is EXPECTED behavior here, not a bug — fix-loop or BLOCKED," >&2
      echo "  same as the pre-flight re-dispatch above. Do NOT accept a vacuous PASS from this step." >&2
    fi
    ;;
  1)
    echo "ERROR: merge-back failed; WORKTREE_HANDOFF_$SESSION_ID.md written"
    echo "ERROR: Step 6 verification FAILED. User must run /v-merge-all or manual recovery."
    # Do NOT proceed to Step 7
    exit 1
    ;;
  2)
    echo "ERROR: merge-back script config error (usage/ownership)"
    exit 1
    ;;
  3)
    # FND-3: merge-back DEFERRED (retryable) — main carried a concurrent ACTIVE sibling's uncommitted
    # SOURCE WIP, so merging would risk orphaning it. The worktree is INTACT and
    # NOTHING was merged or stashed. This is NOT a hard failure and NOT a manual-merge trigger: the
    # merge must be retried AFTER the active sibling finishes. Do NOT declare the session done on
    # unmerged work — exit non-zero so completion does not proceed.
    echo "DEFERRED: merge-back deferred (rc=3) — an active sibling holds uncommitted SOURCE WIP on main."
    echo "DETAIL:   see .v/tmp/merge-deferred-${SESSION_ID}.md (names the foreign file(s) + active sibling SID)."
    echo "ACTION:   wait for the active sibling(s) to finish (poll v-active-siblings.sh / the dependency-recover loop), then re-run:"
    echo "          bash \"\${CLAUDE_SKILL_DIR}/references/v-merge-back.sh\" $SESSION_ID $WORKTREE_PATH"
    echo "ACTION:   do NOT fall back to a manual git merge, do NOT discard the foreign WIP, do NOT mark the session complete — the worktree is intact and the merge is pending."
    exit 1
    ;;
esac
```

### Parallel Safety Guarantees

- **Same-project parallel sessions**: `flock` at `$REPO_ROOT/.worktrees/.merge-lock` (120s timeout) serializes merges. First session wins; second rebases on top of first's commits before its own ff-merge. Stale locks (>600s, `$LOCK_STALE`) auto-removed — unified across the flock and mkdir-mutex paths.
- **Cross-project parallel sessions**: each project has its own `$REPO_ROOT/.worktrees/.merge-lock`. No shared `/tmp/*` paths. Sessions in different projects never contend.
- **Branch ownership check**: script refuses to merge a branch whose name doesn't contain `$SESSION_ID`. Prevents one session from accidentally clobbering another's worktree.
- **Idempotency**: if the branch is already merged into main (e.g., another path completed it), script cleans up the worktree and exits 0 — no double-merge.

### Autonomous Conflict Resolution (W17-2)

The merge-back script no longer gives up after 3 rebase attempts. It now resolves
conflicts autonomously by file type, so the user is never blocked on routine
rebase noise (lockfile drift, regenerated assets, doc edits, parallel session
overlap on session-owned files).

Resolution rules (during rebase, where `--ours`=main and `--theirs`=worktree):

| File class | Pattern | Resolution | Rationale |
|---|---|---|---|
| Lockfiles | `composer.lock`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Gemfile.lock`, `Cargo.lock`, `poetry.lock`, `uv.lock`, `go.sum` | Take MAIN's version, regenerate after rebase | Lockfiles are derived from manifests; main's is canonical, worktree's deps will be re-resolved |
| Generated/cache | `.cache/`, `public/build/`, `dist/`, `bootstrap/cache/`, `storage/framework/cache/`, `_next/`, `.next/`, `build/`, `coverage/`, `.nyc_output/` | Take MAIN's version | Regeneratable; not source-of-truth |
| Session-owned | Listed in `$V_TMP_DIR/session-writes-${SESSION_ID}.txt` | Take WORKTREE's version | Session deliberately changed these |
| Docs | `*.md`, `docs/**`, `README*` (and not session-owned) | Take WORKTREE's version | Newer iteration; doc-only conflicts are usually harmless to take latest |
| Other code | Anything else NOT in session-writes log | Take MAIN's version | Wasn't session-owned; main's version is what the user / other sessions already merged |

After resolving a commit, `git rebase --continue` advances to the next commit;
the resolver loops up to 10 cycles. Lockfile regeneration runs once at the end
(`composer install` / `npm install`) so the final state has consistent deps.

Resolution log: `$V_TMP_DIR/merge-resolve-${SESSION_ID}.log`.

### Failure Modes & Recovery

| Failure | Behavior | Recovery |
|---|---|---|
| Truly unresolvable conflict (binary requiring 3-way merge, etc.) | After autonomous resolver exhausts strategies, `WORKTREE_HANDOFF_$SESSION_ID.md` written | Manual rebase OR `/v-merge-all` |
| Lock timeout (>120s contention) | exit 1, retry guidance in stderr | Wait + retry, or `/v-merge-all` |
| Uncommitted changes in worktree | exit 1, "commit before merge" message | Commit, then re-run |
| Branch ownership mismatch | exit 2 immediately | Investigate which session owns it |
| **FND-3 deferred — foreign WIP + active sibling** | **exit 3** (retryable); `.v/tmp/merge-deferred-<sid>.md` written; worktree INTACT, nothing stashed/merged | Wait for the active sibling to finish, then re-run merge-back. Do NOT manual-merge / discard the WIP / declare done |
| Lockfile regeneration failure | WARN-only (exit 0); deps may be inconsistent | Run `composer install` / `npm install` manually post-merge |

### Final Assertion

```bash
if git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | grep -q "$SESSION_ID"; then
  echo "ERROR: worktree containing $SESSION_ID still exists; Step 6.5 didn't complete"
  exit 1
fi
```

This MUST be empty before Step 7 proceeds.

---
