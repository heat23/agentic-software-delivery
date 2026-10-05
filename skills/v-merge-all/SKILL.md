---
name: v-merge-all
description: "Use when merging multiple parallel /v worktrees or branches back to main safely."
argument-hint: "[--no-push]"
model: sonnet
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, TaskCreate, TaskUpdate, AskUserQuestion, ExitPlanMode
user-invocable: true
disable-model-invocation: true
---
<!-- skill: v-merge-all | version: 1.4.1 | last-updated: 2026-08-12 -->
<!-- 1.3.0 (2026-08-03): closed the unreviewed-capture gap — see git history + v-merge-all-unreviewed-capture-review.test.ts. CAVEAT: the line-number citations in the SIZE note below are from the pre-1.3.0 layout and have NOT been re-verified against the new offsets — re-check before relying on a specific line for a future edit. -->
<!-- SIZE: ~1215 body lines vs a 500-line target / 700-line ceiling (was 1328 / 100% inline).
     2026-08-03 compression pass: extracted the Step 7 report template, the Step 3 conflict-
     resolution + per-branch failure playbook, and the Step 4f cross-session dispatch mechanics
     to references/ (3 files, 141 lines). Unblocked first by fixing v-merge-all-{cleanup,
     remediation}.test.ts, whose readSkill() did a FLAT readFileSync and so diverged from the
     production loader — under it ANY extraction false-failed, which is why this file stayed
     100% inline.

     DOCUMENTED EXCEPTION for the remaining overage — the 700 ceiling is NOT reachable here
     without a worse trade, and this is deliberate, not deferred:
       - Step 6 Cleanup (17.4k chars) is DESTRUCTIVE (worktree removal, branch deletion) and its
         completeness guarantee has NO hook backstop (F3 sole-defense). Moving a destructive
         procedure into an on-demand reference that may not be loaded is strictly worse than the
         token cost of keeping it inline.
       - Step 1 Discovery (9.7k) is what makes the "never lose code — every branch/worktree
         accounted for" guarantee true. Incomplete discovery loses work; it stays where it is read.
       - Steps 2/3/4/5 contain blocks extracted VERBATIM by external harnesses that read this file
         directly and cannot follow references: capture-quarantine-test.sh awk-extracts
         `_v_merge_all_capture_quarantine()` (:373); v-mergeall-witness-test.sh awk-extracts the
         `_MERGE_AFTER=` stanza (:650, exact indentation load-bearing); v-perf3-test.sh greps the
         literal `pest --parallel --processes="${V_PEST_PROCESSES_FULL}"` (:754,:896).
         Step 2 also holds `_stage_or_skip_secret()` (:422) — sole-defense, since
         detect-secrets-in-write.sh fires only on Write|Edit, never on `git add`.
     Re-verify with the harness gate before any further compression; the 2026-07-12 pass on
     v/SKILL.md deleted a guard's cost evidence AND still missed its ceiling.
     v-anthropic-2026-standards §1 row 6. -->


# 2026 Canonical Contract

Tier: User-facing entry point. Run after parallel `/v` sessions complete.

Follow `_v-core.md` and `_v-exec.md`.

For worktree operations, read `~/.claude/skills/references/v-exec-worktree.md` and `~/.claude/skills/references/v-exec-worktree-lifecycle.md`.
For hook details, read `~/.claude/skills/references/v-exec-hooks.md`.

**Purpose:** After running multiple parallel `/v` sessions, or after a clean Claude ecosystem remediation run has synced accepted changes back into the repo root, the codebase may have scattered worktrees, feature branches, runner-owned remediation branches, uncommitted changes, and staged work. This skill consolidates everything into `main`, resolves conflicts, verifies the unified codebase, and pushes to origin without double-applying remediation diffs.

## Skill Boundaries

**SME persona:** This skill is run by a **senior release manager + git workflow specialist** — specialty is multi-worktree merge coordination, conflict resolution discipline (read both sides, never `--theirs`), and the safety rules that prevent worktree contamination from accumulating into a 4-hour rebase nightmare.

### Best fit

- Consolidating completed parallel `/v` sessions, worktrees, and feature branches back into the main branch
- Conflict-aware merge sequencing followed by unified quality gates and a final verified push
- Finalizing repo-root changes after a remediation run whose latest state is cleanly `completed`
- Recovering session artifacts before worktree cleanup
- Sweeping the tree to completion: every non-active worktree and every additive local branch already integrated into main is removed — not just the ones merged in this run (catches prior-run leftovers)

### Use instead

- Use `/v` for the actual implementation sessions before consolidation
- Use `/v-pre-flight` when you only need quality gates on the current branch
- Use `/v-maintenance` for local skill/hook/settings work outside repo branch consolidation
- Use the remediation runner itself until the latest remediation state is `completed` and the prompt queues are drained

### Not for

- Merging while other sessions are actively writing unless the safety gate explicitly allows it
- Replacing normal single-branch development
- Dropping unresolved ambiguous conflicts on the floor to force a push through
- Treating runner-owned remediation worktrees (default `ecosystem-fix*`, but configurable via `CLAUDE_ECOSYSTEM_REMEDIATION_WORKTREE_PREFIX`) as normal merge sources after remediation; they are cleanup-only once the repo root has the synced diff

```yaml
contract:
  tier: entry-point
  accepts: [implicit — discovers worktrees and branches automatically]
  produces: [.v/artifacts/MERGE_ALL_REPORT_${CLAUDE_SESSION_ID}.md]
  invokes: [/v-pre-flight]
  invoked-by: [user, /v]
  estimated_tokens: 30k-120k
  estimated_duration: 5-25 min
```

Rules:
- Never lose code — every branch and worktree must be accounted for
- Never force-push — all merges are local until the final verified push
- `git stash` is forbidden (per `references/v-exec-worktree.md` § rule 7)
- Resolve conflicts by reading both sides and applying the combined intent
- If a conflict is genuinely ambiguous (both sides modified the same logic in incompatible ways), mark it as unresolved and continue with remaining branches
- Run full quality gates on the unified codebase before pushing
- All session artifacts (`*_${CLAUDE_SESSION_ID}.md`) found in worktrees are rescued to repo root before cleanup
- When the latest remediation run is `completed` with zero queued prompt files, the repo root working tree is the source of truth for remediation changes; runner-owned remediation branches under the detected remediation worktree prefix are cleanup candidates, not merge inputs
- **Cleanup is exhaustive, not run-scoped.** After the run, NO non-active worktree whose branch is fully merged into main, and NO local branch already merged into main, may remain — including leftovers from *prior* runs that this run did not itself merge. A worktree/branch is left standing ONLY when it is (a) active (a `.claude-session-lock` < 30 min old / a live session), (b) genuinely divergent and unmergeable (recorded `failed`/`unresolved`), or (c) protected (main/master, the current branch, or a runner-owned remediation entry preserved per its own rule). Every preserved item is reported WITH its concrete reason. This guarantee never destroys WIP: a worktree carrying uncommitted *tracked-source* edits is preserved, never force-removed, and `git branch -d` (merged-only) is the sole branch-delete verb.

---

## Step 0: Plan-Mode Guard (Mandatory — check before Discovery)

This skill's job is to DO the merge/push/cleanup once it's confirmed safe — never to produce a `~/.claude/plans/*.md` file and end the turn. That silent degrade happens only when the outer session is in the harness's global Plan Mode, which intercepts Write/Edit/Bash regardless of what this file instructs; the skill cannot suppress that from inside, only detect it and ask to exit it.

1. Check whether the session is currently in Plan Mode (an `ExitPlanMode` system reminder / active-plan context present).
2. **If in Plan Mode:** do not silently write a plan file and stop. Run Step 1 Discovery read-only first (it's read-only by nature — inventory only, no mutation), then call `ExitPlanMode` with a short concrete plan: "Consolidate N worktree(s)/branch(es) into main: [list]; run pre-flight gates; push to origin; remove merged worktrees/branches." That surfaces the standard approval prompt.
   - Approved → proceed straight through Steps 2-7 without any further pause. The Step 1 V_DEPTH=0 safety gate (line ~225, ambiguous-lock case only) remains the one other legitimate stopping point.
   - Declined → stop; report what would have been done. Do not partially execute.
3. **If not in Plan Mode** (the normal case): skip straight to Step 1 Discovery and run the full Discovery → Merge → Verify → Push → Cleanup → Report sequence to completion. Do not create a plan file. Do not ask for confirmation beyond the safety gates already defined below (V_DEPTH parsing, Step 1 lock-ambiguity gate).

---

## V_DEPTH Parsing (Mandatory)

Parse V_DEPTH from invocation args per `_v-core.md` § V_DEPTH Parsing Protocol. Search for `[V_DEPTH=N` or `V_DEPTH=N` in the prompt. Default to 0 if absent.

**When V_DEPTH >= 1 (orchestrator invoked):** Skip confirmation questions. Still check safety gates (active sessions, stale locks) and apply the programmatic fallback logic:
- If any session lock is < 30 minutes old OR CLAUDE_PROCS > 2: Log the detected active sessions but do NOT ask the user. Use sensible defaults: skip active worktrees to avoid race conditions.
- Proceed directly to merge with automatically determined safety decisions.

**When V_DEPTH = 0 (user invoked):** Ask confirmation questions and let the user decide how to handle active sessions.

---

## Progress Reporting (Mandatory)

**Use `TaskCreate`/`TaskUpdate` at every step transition.** The user must see real-time progress during this long-running operation. Create the step list immediately after discovery (Step 1) with one `TaskCreate` per major step. Move each to `in_progress` with `TaskUpdate` when entering it and `completed` when done. (The harness renamed `TodoWrite` → `TaskCreate`/`TaskUpdate` on 2026-07-05 — see `~/.claude/skills/references/v-core-error-handling.md` § Audit Skill Progress Reporting.)

Typical step items:
```
1. Discover worktrees and branches → in_progress → completed
2. Commit uncommitted work → ...
3. Merge [N] branches into main → ...
4. Run tests and build → ...
5. Push to origin → ...
6. Clean up worktrees and branches → ...
7. Write merge report → ...
```

**Update within long steps too.** During Step 3 (merge loop), update the todo content to show which branch is being merged: e.g., "Merging branch 2/5: build/auth-system".

---

## Step 1: Discovery — Inventory All Work

**Combine discovery into a single bash call** to minimize round-trips:

### 1a: Enumerate worktrees

```bash
echo "=== Active Worktrees ==="
git worktree list --porcelain 2>/dev/null | grep -E '^worktree |^branch |^HEAD ' | paste - - - 2>/dev/null || git worktree list

echo ""
echo "=== Worktree Lock Files ==="
find .worktrees -name '.claude-session-lock' -exec echo -n "{}: " \; -exec cat {} \; 2>/dev/null || echo "(none)"

echo ""
echo "=== Prunable (orphan) Worktrees ==="
git worktree list | grep -i "prunable" || echo "(none)"
```

### 1b: Enumerate feature branches

```bash
echo "=== Feature Branches (not yet merged to main) ==="
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
# Show ALL unmerged branches with common v-* prefixes (build/, fix/, feature/, refactor/, chore/, docs/, test/)
git branch --no-merged "$MAIN_BRANCH" 2>/dev/null | grep -E '^\s*(build/|fix/|feature/|refactor/|chore/|docs/|test/)' | sed 's/^..//'

echo ""
echo "=== Other unmerged branches (may need manual review) ==="
# Show any unmerged branches that DON'T match the standard prefixes — these might be from other workflows
git branch --no-merged "$MAIN_BRANCH" 2>/dev/null | grep -vE '^\s*(build/|fix/|feature/|refactor/|chore/|docs/|test/|\*)' | sed 's/^..//'

echo ""
echo "=== Cleanup candidates: local branches ALREADY merged into main (deleted in Step 6b-sweep) ==="
# These are additive work already integrated — pure clutter. `git branch -d` deletes them safely in Step 6.
git branch --merged "$MAIN_BRANCH" 2>/dev/null | sed 's/^[*+ ]*//' | grep -vE "^(${MAIN_BRANCH}|master|main)$" | grep -vE '^ecosystem-fix' || echo "(none)"

echo ""
echo "=== Cleanup candidates: non-active worktrees whose branch is ALREADY in main (removed in Step 6a-sweep) ==="
# A worktree whose branch tip is an ancestor of main holds nothing not already in main; if it is not
# active and has no uncommitted tracked WIP, Step 6a-sweep removes it (the prior-run "left behind" case).
git worktree list --porcelain 2>/dev/null \
  | awk '/^worktree /{wt=$2} /^branch /{b=$2; sub(/^refs\/heads\//,"",b); print wt"\t"b}' \
  | while IFS=$'\t' read -r _wt _br; do
      case "$_br" in ""|"$MAIN_BRANCH"|master|main|ecosystem-fix*) continue;; esac
      git merge-base --is-ancestor "$_br" "$MAIN_BRANCH" 2>/dev/null && echo "  $_wt ($_br) — branch already in main"
    done || true
```

### 1c: Check for uncommitted work on main

```bash
echo "=== Uncommitted changes on $(git branch --show-current) ==="
git status --porcelain 2>/dev/null | head -20
```

### 1d: Check for active sessions (safety gate)

```bash
echo "=== Active Session Locks ==="
ACTIVE_LOCKS=0
# Scan BOTH the `.worktrees/` glob AND every path git actually tracks as a worktree —
# native/linked worktrees created outside `.worktrees/` carry `.claude-session-lock` too;
# a scan blind to them could merge over a live external session.
LOCK_PATHS=$(
  { find .worktrees -name '.claude-session-lock' -mmin -240 2>/dev/null
    git worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{print $2"/.claude-session-lock"}'
  } | sort -u
)
for LOCK in $LOCK_PATHS; do
  [ -f "$LOCK" ] || continue
  LOCK_MTIME=$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo 0)   # GNU first; see scripts/portability-test.sh
  LOCK_AGE_MIN=$(( ($(date +%s) - LOCK_MTIME) / 60 ))
  LOCK_SID=$(awk '{print $1}' "$LOCK" 2>/dev/null || echo "unknown")
  echo "  $LOCK — session: $LOCK_SID — age: ${LOCK_AGE_MIN}min"
  if [ "$LOCK_AGE_MIN" -lt 30 ]; then
    ACTIVE_LOCKS=$((ACTIVE_LOCKS + 1))
  fi
done
echo "Active (< 30min): $ACTIVE_LOCKS"

echo ""
echo "=== Claude Processes ==="
CLAUDE_PROCS=$(pgrep -f "claude" 2>/dev/null | wc -l | tr -d ' ')
echo "Claude processes detected: $CLAUDE_PROCS"
# >2 suggests other sessions are running (1 = this session's parent, 2 = this session)
```

**Safety gate:** If any session lock is less than 30 minutes old OR more than 2 Claude processes are detected (`CLAUDE_PROCS > 2`), the lock state is ambiguous. Behavior splits by V_DEPTH:

- **V_DEPTH ≥ 1 (orchestrator-invoked or headless, W24):** auto-select "Skip active ones" — merge only worktrees whose locks are > 30 minutes old. The orchestrator already has session authority and won't ask the operator at end-of-run. Log the decision so the operator can see what was skipped.
- **V_DEPTH = 0 (operator-invoked):** WARN the user and ask:

  ```yaml
  question: "These worktrees have recent session locks (< 30min old). Sessions may still be running. Should I proceed with merging?"
  header: "Safety"
  options:
    - label: "Proceed anyway"
      description: "Merge all worktrees including ones with recent locks"
    - label: "Skip active ones"
      description: "Only merge worktrees with locks older than 30 minutes"
    - label: "Wait"
      description: "I'll come back when all sessions are done"
  ```

**Programmatic fallback (when all locks are > 30min AND CLAUDE_PROCS <= 2):** Skip the question regardless of V_DEPTH and proceed automatically.

### 1e: Detect remediation state and classify runner-owned worktrees

If the repo contains `.claude/ecosystem-review`, inspect the latest remediation run **before** merging anything. `/v-merge-all` is allowed to run after remediation only when the latest remediation state is exactly `completed` **and** no numbered prompt files remain in any `v-remediation-phase-*-prompts` queue.

```bash
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$REPO_ROOT" ] || { [ -n "${HOME:-}" ] && [ "$REPO_ROOT" = "$HOME" ]; }; then
  echo "ERROR: Cannot detect a safe repo root. Pass PROJECT_ROOT= explicitly."
  exit 1
fi
case "${REPO_ROOT%/}" in
  /|/Users|/home|/root|/tmp|/var|/usr|/etc|/bin|/sbin|/opt|/private|/System|/Library|/Volumes|/dev|/proc|/sys)
    echo "ERROR: Refusing to use filesystem-level root as REPO_ROOT: $REPO_ROOT"
    exit 1
    ;;
esac
REMEDIATION_STATE_ROOT="$REPO_ROOT/.claude/ecosystem-review"
REMEDIATION_MODE=0
REMEDIATION_READY=0
REMEDIATION_STATUS_JSON=""
REMEDIATION_RUN_ID=""
REMEDIATION_STATE=""
REMEDIATION_PENDING_PROMPTS=0
REMEDIATION_WORKTREE_PREFIX="${CLAUDE_ECOSYSTEM_REMEDIATION_WORKTREE_PREFIX:-ecosystem-fix}"
# W24: repo-local scratch (never host /tmp). Falls back to /tmp only if .v/tmp
# isn't writable (e.g., script run outside any repo).
_V_TMP_DIR="${REPO_ROOT}/.v/tmp"
mkdir -p "$_V_TMP_DIR" 2>/dev/null
[ -w "$_V_TMP_DIR" ] || _V_TMP_DIR="${TMPDIR:-/tmp}"
RUNNER_OWNED_REMEDIATION_MANIFEST="$(mktemp "${_V_TMP_DIR}/v-merge-all-remediation.XXXXXX")"
: > "$RUNNER_OWNED_REMEDIATION_MANIFEST"

if [ -d "$REMEDIATION_STATE_ROOT" ]; then
  REMEDIATION_MODE=1
  latest_remediation_run="$(find "$REMEDIATION_STATE_ROOT/remediation-runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | tail -1)"
  if [ -n "$latest_remediation_run" ] && [ -f "$latest_remediation_run/status.txt" ]; then
    detected_prefix="$(awk -F': ' '$1=="Worktree prefix" {print $2; exit}' "$latest_remediation_run/status.txt" 2>/dev/null || true)"
    if [ -n "$detected_prefix" ]; then
      REMEDIATION_WORKTREE_PREFIX="$detected_prefix"
    fi
  fi
  if [ -n "$latest_remediation_run" ] && [ -f "$latest_remediation_run/status.json" ] && command -v jq >/dev/null 2>&1; then
    REMEDIATION_STATUS_JSON="$latest_remediation_run/status.json"
    REMEDIATION_RUN_ID="$(jq -r '.run_id // empty' "$REMEDIATION_STATUS_JSON" 2>/dev/null || true)"
    REMEDIATION_STATE="$(jq -r '.state // empty' "$REMEDIATION_STATUS_JSON" 2>/dev/null || true)"
  fi

  REMEDIATION_PENDING_PROMPTS="$(find "$REMEDIATION_STATE_ROOT" -maxdepth 2 -type f -path '*/v-remediation-phase-*-prompts/[0-9][0-9][0-9]-*.md' | wc -l | tr -d ' ')"

  git worktree list --porcelain 2>/dev/null | awk -v prefix="$REMEDIATION_WORKTREE_PREFIX" '
    /^worktree / { wt=$2; next }
    /^branch refs\/heads\// {
      branch=$2
      sub(/^refs\/heads\//, "", branch)
      if (index(branch, prefix) == 1) {
        print wt "\t" branch
      }
    }
  ' > "$RUNNER_OWNED_REMEDIATION_MANIFEST"

  if [ "${REMEDIATION_PENDING_PROMPTS:-0}" -eq 0 ] 2>/dev/null && [ "$REMEDIATION_STATE" = "completed" ]; then
    REMEDIATION_READY=1
  fi
fi

echo "=== Remediation State ==="
echo "mode=$REMEDIATION_MODE run_id=${REMEDIATION_RUN_ID:-none} state=${REMEDIATION_STATE:-none} pending_prompts=${REMEDIATION_PENDING_PROMPTS:-0} worktree_prefix=${REMEDIATION_WORKTREE_PREFIX:-ecosystem-fix}"
cat "$RUNNER_OWNED_REMEDIATION_MANIFEST" 2>/dev/null || true
```

**Blocker policy:**
- If `REMEDIATION_MODE=1` and `REMEDIATION_STATE` is anything other than `completed`, stop. States such as `failed`, `phase_completed_with_residual_findings`, `round_verified_with_residual_findings`, `completed_with_residual_findings`, and `stalled_with_residual_findings` are not merge-ready.
- If `REMEDIATION_PENDING_PROMPTS > 0`, stop. Numbered prompt files in `v-remediation-phase-*-prompts` mean the queue is not drained.
- If the status JSON is missing or unreadable while remediation prompt dirs exist, stop and treat the remediation state as unknown rather than guessing.
- Detect the runner-owned remediation branch prefix from `CLAUDE_ECOSYSTEM_REMEDIATION_WORKTREE_PREFIX` first, then from the latest remediation `status.txt`, falling back to `ecosystem-fix`. Do not assume the prefix is always the default.
- If `REMEDIATION_READY=1`, switch to remediation-finalization mode:
  - The repo root working tree is the source of truth for remediation changes because the runner syncs accepted diffs back into the main checkout.
  - Runner-owned remediation worktrees and branches under `$REMEDIATION_WORKTREE_PREFIX*` are cleanup candidates only. Do **not** merge them in Step 3 and do **not** capture new commits inside them in Step 2.

### 1f: Build the merge manifest

Create a structured inventory:

```markdown
## Merge Manifest

| # | Source | Branch | Files Changed | Has Uncommitted | Lock Age | Merge Action | Status |
|---|--------|--------|---------------|-----------------|----------|--------------|--------|
| 1 | worktree: .worktrees/build-auth-abc123 | build/auth-abc123 | 12 | No | 2h | merge | Ready |
| 2 | worktree: .worktrees/fix-typo-def456 | fix/typo-def456 | 2 | Yes (3 files) | 45min | merge | Ready |
| 3 | branch only: build/auto-20260315-141300 | build/auto-20260315-141300 | 8 | N/A | N/A | merge | Ready |
| 4 | main (staged) | main | 0 | Yes (1 file) | N/A | merge | Ready |
| 5 | runner-owned remediation worktree: .worktrees/ecosystem-fix-02-a1b2c3d4 | ecosystem-fix-02-a1b2c3d4 | 0 | No | 10min | cleanup_only | Repo-root synced diff is authoritative |
```

For each worktree/branch, count changed files:
```bash
# For worktree branches
MERGE_BASE=$(git merge-base "$BRANCH" "$MAIN_BRANCH" 2>/dev/null)
git diff --name-only "$MERGE_BASE".."$BRANCH" 2>/dev/null | wc -l
```

---

## Step 2: Pre-Merge Preparation

**Remediation-finalization exception:** When `REMEDIATION_READY=1`, build the merge plan only from manifest rows whose `Merge Action` is `merge`. The repo root working tree already contains the accepted remediation diff, so remediation worktrees under `$REMEDIATION_WORKTREE_PREFIX*` are skipped during commit capture and merge sequencing.

### 2a: Commit all uncommitted work

**Capture-commit hygiene:** a capture commit stages the ENTIRE uncommitted tree indiscriminately.
Two classes of file must never ride a capture commit onto main: (a) telemetry (`SESSION_LOG*` and
the other per-session artifact prefixes), and (b) tracked-source WIP that provably belongs to
ANOTHER live/unlogged session (gracefully *exclude* it here rather than hard-fail the commit).
Run this quarantine function before every capture `git commit` below (source once per worktree):

```bash
_v_merge_all_capture_quarantine() {
  # Unstages (a) telemetry/artifact-prefix files and (b) files provably authored by another
  # session (writes-ledger) from the CURRENTLY STAGED set; prints one QUARANTINED line per
  # excluded path. Fail-open: if the libs are unavailable, nothing is quarantined (never
  # invents false ownership).
  local _apr="$HOME/.claude/hooks/lib/artifact-prefix-registry.sh"
  local _sw="$HOME/.claude/hooks/lib/session-writes.sh"
  [ -f "$_apr" ] && . "$_apr" 2>/dev/null
  [ -f "$_sw" ] && . "$_sw" 2>/dev/null

  local _staged
  _staged=$(git diff --cached --name-only 2>/dev/null)
  [ -n "$_staged" ] || return 0

  # (a) telemetry / per-session artifact prefixes (SESSION_LOG*, markers, etc.)
  if command -v is_session_artifact_path >/dev/null 2>&1; then
    while IFS= read -r _f; do
      [ -n "$_f" ] || continue
      if is_session_artifact_path "$_f"; then
        git reset -q -- "$_f" 2>/dev/null
        echo "QUARANTINED (telemetry, excluded from capture): $_f"
      fi
    done <<< "$_staged"
  fi

  # (b) files attributable to another live/unlogged session (writes-ledger)
  if command -v files_attributable_to_other_sessions >/dev/null 2>&1; then
    local _foreign
    _foreign=$(git diff --cached --name-only 2>/dev/null | files_attributable_to_other_sessions "${CLAUDE_SESSION_ID:-}")
    if [ -n "$_foreign" ]; then
      while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        git reset -q -- "$_f" 2>/dev/null
        echo "QUARANTINED (sibling-owned WIP, excluded from capture): $_f"
      done <<< "$_foreign"
    fi
  fi
}
```

For each worktree with uncommitted changes:
```bash
cd "$WORKTREE_PATH"
git add -u  # tracked files only — no secrets
# Secret-scan gate before auto-staging untracked config. `.json`/`.yaml`/`.yml` are NOT
# inherently safe — service-account keys, firebase configs, `credentials.json`,
# `secrets.yaml`, and CI vars all live in those extensions. Scan content (and skip
# obvious secret-bearing filenames) before adding, or the capture commit leaks credentials.
_SECRET_HOOK="$HOME/.claude/hooks/detect-secrets-in-write.sh"
_stage_or_skip_secret() {
  local f="$1"
  # (1) filename denylist — never auto-stage these even if git-untracked
  case "$(basename "$f")" in
    .env|.env.*|*credential*|*secret*|*.pem|*.key|*serviceaccount*|*service-account*|gha-creds-*.json)
      echo "SKIPPED untracked (secret-bearing name, add manually if intended): $f"; return ;;
  esac
  # (2) content scan for json/yaml via the canonical detect-secrets hook (fail-CLOSED here:
  #     if it emits any SECURITY WARNING, we do NOT stage). Non-config source skips the scan.
  case "$f" in
    *.json|*.yaml|*.yml)
      if [ -f "$_SECRET_HOOK" ] && command -v jq >/dev/null 2>&1; then
        _warn=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":%s}}' \
                  "$f" "$(jq -Rs . < "$f" 2>/dev/null || echo '""')" \
                | bash "$_SECRET_HOOK" 2>&1 >/dev/null)
        if printf '%s' "$_warn" | grep -q 'SECURITY WARNING'; then
          echo "SKIPPED untracked (secret detected in config, NOT staged): $f — $_warn"; return
        fi
      fi
      ;;
  esac
  git add "$f"
}
git status --porcelain | grep '^\?\?' | awk '{print $2}' | while read f; do
  # Only stage new files that look like source code, not secrets
  case "$f" in
    *.php|*.ts|*.tsx|*.js|*.jsx|*.css|*.html|*.vue|*.svelte|*.md|*.json|*.yaml|*.yml)
      _stage_or_skip_secret "$f" ;;
    *)
      echo "SKIPPED untracked: $f (not a recognized source file)" ;;
  esac
done
_v_merge_all_capture_quarantine
# Nothing left staged (everything was telemetry/foreign) → skip the commit, don't create an empty one.
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "merge-all: capture worktree state before consolidation [v-merge-all]"
else
  echo "capture: nothing left to commit after quarantine (all staged changes were telemetry/foreign)"
fi
```

For uncommitted changes on main:
```bash
cd "$REPO_ROOT"
git add -u
_v_merge_all_capture_quarantine
MAIN_ROOT_CAPTURE_SHA=""
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "merge-all: capture main worktree state before consolidation [v-merge-all]"
  MAIN_ROOT_CAPTURE_SHA=$(git rev-parse HEAD)
else
  echo "capture: nothing left to commit after quarantine (all staged changes were telemetry/foreign)"
fi
```

### 2a-i: Unreviewed-capture detection (main-root capture must not reach origin unreviewed)

**Why this exists (2026-08-03, a forensic session):** the capture commit above absorbs
whatever was sitting uncommitted on `main` — often the leftover work of a prior session that was
interrupted before its own gates ran. Step 4f's cross-session review only triggers on cross-BRANCH
overlap or an auto-resolved conflict; a lone capture commit has neither, so without this check that
code sails through Steps 3-5 and reaches `origin` never having been reviewed by anyone — the gap
is only caught reactively, after the push, by the outer session's Stop hook. This check closes that
gap without forcing every merge-all run to pay for a redundant review: a solo release manager
consolidating already-gauntleted branches gains nothing from re-reviewing the same diff twice.

```bash
MAIN_CAPTURE_NEEDS_REVIEW=0
if [ -n "$MAIN_ROOT_CAPTURE_SHA" ]; then
  _CAPTURE_FILES=$(git diff --name-only "${MAIN_ROOT_CAPTURE_SHA}~1" "$MAIN_ROOT_CAPTURE_SHA" 2>/dev/null)
  # Attribute each captured file to the session that wrote it via the same writes-ledger the
  # Step 2a quarantine function already reads. Fail-safe in the SAFE direction throughout:
  # unattributed or unverifiable ⇒ needs review, never ⇒ skip it.
  _CAPTURE_ATTRIBUTED_SIDS=""
  _GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || git rev-parse --git-dir 2>/dev/null)"
  if [ -n "$_GIT_DIR" ] && [ -n "$_CAPTURE_FILES" ]; then
    while IFS= read -r _cf; do
      [ -n "$_cf" ] || continue
      _sid_hit=$(grep -lxF -- "$_cf" "$_GIT_DIR"/claude-session-writes-*.txt 2>/dev/null \
        | sed -E 's#.*claude-session-writes-(.*)\.txt#\1#' | head -1)
      if [ -z "$_sid_hit" ]; then
        MAIN_CAPTURE_NEEDS_REVIEW=1   # unattributed file — fail toward review, never toward skipping it
      else
        case " $_CAPTURE_ATTRIBUTED_SIDS " in *" $_sid_hit "*) ;; *) _CAPTURE_ATTRIBUTED_SIDS="$_CAPTURE_ATTRIBUTED_SIDS $_sid_hit" ;; esac
      fi
    done <<< "$_CAPTURE_FILES"
  else
    MAIN_CAPTURE_NEEDS_REVIEW=1
  fi
  # An attributed SID whose OWN gates never passed (or whose artifacts are gone/archived/unreadable)
  # also forces review — presence + PASS is required, not just presence.
  for _sid in $_CAPTURE_ATTRIBUTED_SIDS; do
    _pf="$REPO_ROOT/.v/artifacts/PRE_FLIGHT_REPORT_${_sid}.md"
    _ar="$REPO_ROOT/.v/artifacts/AGENT_REVIEW_${_sid}.md"
    if ! { [ -f "$_pf" ] && grep -qE 'Overall Status:[[:space:]]*PASS' "$_pf" && [ -s "$_ar" ]; }; then
      MAIN_CAPTURE_NEEDS_REVIEW=1
    fi
  done
  echo "Capture-review check: sha=$MAIN_ROOT_CAPTURE_SHA attributed_sids=[${_CAPTURE_ATTRIBUTED_SIDS# }] needs_review=$MAIN_CAPTURE_NEEDS_REVIEW"
fi
```

If `MAIN_CAPTURE_NEEDS_REVIEW=1`, Step 4f **must** run against `$MAIN_ROOT_CAPTURE_SHA` even when
zero branches are merged this run — see Step 4f — and Step 5 must not push until it clears.

### 2b: Build the merge order

> **Note:** Artifact rescue is handled in Step 6a (before worktree removal), not here.
> Worktree artifacts survive rebase (Step 3) because they're uncommitted root-level files.
> Build the merge order from manifest entries marked `merge` only. Entries marked `cleanup_only` are never fed into the merge loop.

Determine merge order. **Use the fast path when possible:**

**Fast path (≤ 3 branches):** Sort by changeset size (smallest first). Skip the conflict graph — the overhead isn't worth it for a few branches. This covers 90%+ of real-world merge-all invocations.

**Full path (> 3 branches):** Build a conflict-aware ordering:

1. **Extract file lists** for each branch (W24: scratch lives in `$REPO_ROOT/.v/tmp/`, never host `/tmp`):
   ```bash
   _V_TMP_DIR="${REPO_ROOT}/.v/tmp"
   mkdir -p "$_V_TMP_DIR/merge-conflict-graph"
   for BRANCH in $ALL_BRANCHES; do
     MERGE_BASE=$(git merge-base "$BRANCH" "$MAIN_BRANCH")
     git diff --name-only "$MERGE_BASE".."$BRANCH" | sort > "$_V_TMP_DIR/merge-conflict-graph/files-${BRANCH//\//-}"
   done
   ```

2. **Build conflict graph** — two branches conflict if they touch the same file:
   ```bash
   # For each pair, check for overlapping files
   comm -12 "$_V_TMP_DIR/merge-conflict-graph/files-branch-a" "$_V_TMP_DIR/merge-conflict-graph/files-branch-b" | wc -l
   ```

3. **Determine merge order:**
   - **Non-conflicting branches first** (no file overlap with any other branch) — these are safe fast-forwards
   - **Smallest changeset first** among conflicting branches — smaller diffs are easier to rebase after main moves
   - **Branches that touch shared config files last** (tsconfig.json, package.json, routes) — these cause the most cascading conflicts

4. **Record the order** in the merge manifest table.

---

## Step 3: Sequential Merge

Process each branch in the determined order.

If remediation-finalization mode is active, it is valid for the merge list to be empty. In that case, verify and push the repo-root synced remediation diff, then perform cleanup-only handling for runner-owned remediation worktrees in Step 6.

**Acquire merge lock and initialize tracking variables before the loop:**
```bash
# Acquire the merge lock to prevent concurrent merge-backs from other sessions.
# Hold it through Steps 3-5; release in Step 6 cleanup. PORTABLE lock: `flock` does
# NOT exist on macOS — prefer flock where present (Linux/CI), else an atomic mkdir mutex.
MERGE_LOCK=".worktrees/.merge-lock"
MERGE_LOCK_DIR=".worktrees/.merge-lock.d"
mkdir -p .worktrees
_lock_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
if command -v flock >/dev/null 2>&1; then
  if [ -f "$MERGE_LOCK" ] && [ "$(( $(date +%s) - $(_lock_mtime "$MERGE_LOCK") ))" -gt 600 ]; then rm -f "$MERGE_LOCK"; fi
  exec 9>"$MERGE_LOCK"
  flock -w 300 9 || { echo "ERROR: Could not acquire merge lock after 300s — another merge may be in progress."; exit 1; }
  # release: handled by fd close / Step 6 cleanup
else
  # atomic mkdir mutex (macOS / no flock): mkdir fails if the dir exists.
  _waited=0
  while ! mkdir "$MERGE_LOCK_DIR" 2>/dev/null; do
    if [ -d "$MERGE_LOCK_DIR" ] && [ "$(( $(date +%s) - $(_lock_mtime "$MERGE_LOCK_DIR") ))" -gt 600 ]; then
      echo "WARNING: stale merge-lock dir (>600s) — stealing." >&2; rm -rf "$MERGE_LOCK_DIR" 2>/dev/null; continue
    fi
    _waited=$((_waited + 1)); [ "$_waited" -ge 300 ] && { echo "ERROR: Could not acquire merge lock after 300s — another merge may be in progress."; exit 1; }
    sleep 1
  done
  printf '%s %s\n' "${CLAUDE_SESSION_ID:-?}" "$(date +%s)" > "$MERGE_LOCK_DIR/owner" 2>/dev/null || true
  # NOTE: Step 6c cleanup must `rm -rf "$MERGE_LOCK_DIR"` to release this mutex.
fi

MERGED_WORKTREE_PATHS=""
MERGED_BRANCHES=""
RUNNER_OWNED_REMEDIATION_CLEANED=""
RUNNER_OWNED_REMEDIATION_PRESERVED=""
# v1.1.0 FF-shortcut tracking: eligibility for skipping Step 4a-4c when post-merge main
# is byte-identical to a branch tip that ALREADY passed the full gauntlet in its own
# session (see Step 4-pre Gate 1). Starts eligible; ANY disqualifier clears it.
# Fail-safe: cleared or unset → full Step 4 runs unchanged.
MERGE_COUNT=0
FF_SHORTCUT_OK=1
_MAIN_HEAD_AT_MERGE_START=$(git rev-parse "$MAIN_BRANCH" 2>/dev/null)
```

> **⚠️ SINGLE-SHELL CONTRACT (state does NOT survive across separate Bash tool calls).** Each Bash
> tool invocation is a fresh process: shell variables (`MERGED_WORKTREE_PATHS`, `MERGED_BRANCHES`,
> `MERGE_LOCK*`, `REPO_ROOT`, …) set here are GONE in the next Bash call, and the `flock -w 300 9`
> lock is bound to file descriptor 9 in THIS process only — it releases the instant this Bash call
> returns, giving zero cross-call protection. Therefore:
> - **Run Steps 3 → 6 inside ONE continuous Bash invocation** so the lock, the tracking vars, and
>   the merge loop share a single process. Do NOT split the merge/verify/push/cleanup across
>   multiple Bash calls expecting the variables or the flock to persist.
> - If you genuinely must span calls, the **durable lock is the on-disk `mkdir` mutex**
>   (`$MERGE_LOCK_DIR`), NOT flock — re-acquire/verify it at the top of each call, and re-derive
>   every tracking variable from git (`git worktree list`, `git branch --merged`) rather than
>   trusting a stale in-memory value. Persist `MERGED_WORKTREE_PATHS`/`MERGED_BRANCHES` to a temp
>   file under `.worktrees/` if a later call needs them.

### For each manifest entry whose `Merge Action` is `merge`:

```text
3a-pre. GATE CHECK (W-conc-fix — do NOT merge a session that failed its OWN gates).
    Each branch is `build/<slug>-<sid>` / `fix/<slug>-<sid>`; extract <sid>. Check that
    session's artifacts (in repo root OR .v/archive/) BEFORE merging:
      - PRE_FLIGHT_REPORT_<sid>.md ends with `Overall Status: PASS`
      - VERIFY_DONE_REPORT_<sid>.md ends with `Overall Verdict: PASS`
      - QA_REPORT_<sid>.md has `verdict: pass` (or `escalated` + a BLOCKED_<sid>.md)
      - DISPATCH_PROVENANCE_<sid>.log has NO `status=error` line for a runner that
        was never followed by a later `status=ok` for the same artifact
    If a branch's session FAILED a gate, has `verdict: fail`, or has an unresolved
    runner error → do NOT auto-merge it. Mark it `status: skipped-failed-gates` in the
    manifest, leave the branch intact, and surface it in MERGE_ALL_REPORT for the operator.
    Merging a branch whose session never passed ships unverified/known-bad work into main.
    If artifacts are MISSING (cleaned), you cannot confirm pass → mark `status:
    unverified`, skip by default, and list it so the operator can re-run /v-pre-flight
    on that branch or explicitly approve the merge.
3a. Checkout the worktree branch (or switch to it if branch-only)
3a-ff. FF-shortcut tracking (v1.1.0): MERGE_COUNT=$((MERGE_COUNT+1)).
    Record whether this branch ALREADY contains main HEAD (zero-replay — the upcoming
    rebase is a no-op, so the ff-merge makes main byte-identical to this tip):
      git merge-base --is-ancestor "$MAIN_BRANCH" "$BRANCH" && _ZERO_REPLAY=1 || _ZERO_REPLAY=0
    Keep the shortcut eligible ONLY if ALL hold; otherwise FF_SHORTCUT_OK=0:
      - _ZERO_REPLAY=1
      - Step 3a-pre verified this branch's OWN artifacts as PASS (PRE_FLIGHT_REPORT
        `Overall Status: PASS` AND VERIFY_DONE_REPORT `Overall Verdict: PASS`;
        missing/unverified artifacts = disqualified)
      - Step 2a created NO capture commit on this branch (a capture commit adds changes
        the session's gauntlet never saw — the tip is no longer the gauntleted tree)
      - NO staleness marker exists for that SID: `GAUNTLET_STALE_<sid>.md` must be absent
        from `$REPO_ROOT/.v/artifacts/`, the worktree's `.v/artifacts/`, and `.v/archive/`
        (a live marker means the source tree changed AFTER the gauntlet graded it — the
        PASS artifacts no longer describe this tip; skill-review P1, v1.1.0)
      - the gauntlet attestation witness `~/.claude/runtime/v-gauntlet-attestation-<sid>.json`
        exists for that SID (no witness = artifact freshness is unprovable → disqualify and
        run the full Step 4; this fail-safe only ever costs time, never safety)
3b. Rebase onto current main HEAD:
    git rebase "$MAIN_BRANCH"
    (If the rebase replays ANY commit or hits ANY conflict: FF_SHORTCUT_OK=0.)
3c. If rebase conflicts:
    - For each conflicting file:
      i.   Read the base version, ours (branch), and theirs (main)
      ii.  Understand the intent of both changes
      iii. Apply combined intent — keep both changes if they serve different purposes
           (this is the COMMON case for two sessions touching one file: they usually
           changed different things in it — combine them).
      iv.  If the two changes touch the SAME logic incompatibly (can't both hold):
           do NOT silently "pick the newer branch" — that can drop the correct fix and
           ship a bug (the failure mode this guard exists for). Instead:
           - Tentatively keep the branch version to let the rebase proceed, BUT record it
             in MERGE_ALL_REPORT under a `CONFLICT_AUTORESOLVED` list (file + both intents
             + which side was kept + which was dropped), and
           - this MANDATES the Step 4f cross-session review on that file (4f fires whenever
             any conflict was auto-resolved) — 4f verifies the dropped side wasn't
             load-bearing and REVERTS to the other side (or combines) if it was.
           Genuinely incompatible STRUCTURAL conflicts → strategy #5 (leave branch
           unmerged, do not guess).
      v.   git add <resolved-file>
    - git rebase --continue
    - Repeat until rebase completes
3d. After successful rebase, fast-forward main:
    cd "$REPO_ROOT"
    _MERGE_BEFORE=$(git rev-parse HEAD)
    V_MERGE_AUTHORIZED=1 git merge --ff-only "$BRANCH"
    (The V_MERGE_AUTHORIZED=1 prefix marks this as the sanctioned merge-all lifecycle merge —
    worktree-safety.sh Rule 12 (W5F-5) denies RAW `git merge build/*` / session-branch merges
    so ad-hoc sessions cannot bypass the merge-back gate. It is valid ONLY inside this skill's
    Step 3d; never use it to work around a deny in any other context.)
3d-i. Write the per-SID commit witness — EXACTLY as v-merge-back.sh does. WITHOUT this, the
    merged session is witness-less and validate-log.py's _check_sid_commit_witness /
    v-owns-check attribution guards go DORMANT — attribution falls back to base..HEAD on the
    shared main = sibling-commit leakage. The merge lock (Step 3) is held across all merges,
    so `_MERGE_BEFORE..HEAD` is EXACTLY this branch's commits. Best-effort (`|| true`): never
    fail a merge over witness bookkeeping. The SID comes from the /v branch name
    (build/<slug>-<sid> | fix/<slug>-<sid>); a branch with no embedded SID (a non-/v feature
    branch) is correctly skipped — it has no SESSION_LOG to attribute.
    _MERGE_AFTER=$(git rev-parse HEAD)
    _BRANCH_SID=$(printf '%s' "$BRANCH" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    # Short-SID fallback: /v branches commonly carry ONLY the 8-char short SID
    # ('<type>/<slug>-<sid8>'), so the full-UUID extraction above returns EMPTY. Resolve the
    # FULL SID from the worktree's OWN .claude-session-lock (written with the full UUID at
    # creation; still present because worktree cleanup is deferred to Step 6). The full SID
    # is required because /v-session-log reads commits-${FULL_SID}.txt.
    if [ -z "$_BRANCH_SID" ]; then
      # Anchor to the END of the branch name — an 8-hex run inside the slug
      # (e.g. 'oauth-deadbeef-abcd1234') must not be mis-picked as the SID.
      _SID8=$(printf '%s' "$BRANCH" | grep -oiE -- '-[0-9a-f]{8}$' | grep -oiE '[0-9a-f]{8}' | head -1)
      # NEVER read the MAIN-root lock (that is the orchestrator's own SID) — require a distinct
      # worktree path, and bind to the UUID dash so a bare 8-hex prefix-share cannot false-match.
      # If the lock is absent/unreadable, leave the witness UNWRITTEN (the log honestly falls to
      # session_writes_log) — never GUESS a SID: a wrong witness could clobber a sibling's.
      if [ -n "$_SID8" ] && [ -n "$WORKTREE_PATH" ] && [ "$WORKTREE_PATH" != "$REPO_ROOT" ] && [ -f "$WORKTREE_PATH/.claude-session-lock" ]; then
        _lk=$(awk 'NR==1{print $1}' "$WORKTREE_PATH/.claude-session-lock" 2>/dev/null)
        case "$_lk" in "${_SID8}-"*) _BRANCH_SID="$_lk" ;; esac
      fi
    fi
    if [ -n "$_BRANCH_SID" ] && [ -n "$_MERGE_BEFORE" ] && [ -n "$_MERGE_AFTER" ] && [ "$_MERGE_BEFORE" != "$_MERGE_AFTER" ]; then
      mkdir -p "$REPO_ROOT/.v/tmp" "$REPO_ROOT/.v/artifacts" 2>/dev/null || true
      if git rev-list "${_MERGE_BEFORE}..${_MERGE_AFTER}" > "$REPO_ROOT/.v/tmp/commits-${_BRANCH_SID}.txt" 2>/dev/null; then
        # Durable .v/artifacts copy: the .v/tmp copy can be swept by a concurrent sibling's
        # worktree teardown before /v-session-log reads it -> witness lost -> coarse fallback.
        cp -p "$REPO_ROOT/.v/tmp/commits-${_BRANCH_SID}.txt" "$REPO_ROOT/.v/artifacts/commits-${_BRANCH_SID}.txt" 2>/dev/null || true
        echo "INFO: wrote SID commit witness for ${_BRANCH_SID} ($(grep -c . "$REPO_ROOT/.v/tmp/commits-${_BRANCH_SID}.txt" 2>/dev/null || echo 0) commit(s)) -> .v/tmp + .v/artifacts" >&2
      fi
    fi
3e. Log result in merge manifest (NO per-branch validation — tests run once after ALL merges in Step 4):
    status: merged | merged-with-conflicts | failed
3f. Record for deferred cleanup:
    MERGED_WORKTREE_PATHS="${MERGED_WORKTREE_PATHS:-} $WORKTREE_PATH"
    MERGED_BRANCHES="${MERGED_BRANCHES:-} $BRANCH"
    - Do NOT remove worktrees or delete branches here — defer to Step 6 after verification passes.
      Reason: if post-merge verification (Step 4) reveals failures, you need the original branches
      intact to identify which merge caused the issue and potentially revert it.
```

**Moved to:** `references/v-merge-all-conflict-resolution.md` — conflict priority order,
config-file conflict handling, and per-branch failure handling. The hook-enforced
prohibitions (never `--theirs`/`--ours`, never `git stash`) remain in § Gotchas below.
## Step 4: Post-Merge Verification

After all mergeable branches are integrated into main:

### 4-pre: Redundant-verification skip gates (v1.1.0)

These gates only skip work that is **provably redundant** — every existing check still
runs whenever anything could actually have changed. When in doubt, both gates fail safe
to the full unchanged Step 4.

**Gate 1 — FF shortcut (skip 4a–4c and 4e entirely).** Applies ONLY when ALL hold:

- exactly ONE branch was merged this run (`MERGE_COUNT` = 1), and
- `FF_SHORTCUT_OK` is still 1 (per 3a-ff/3b: zero rebase replay, zero conflicts, no
  Step 2a capture commit, no `GAUNTLET_STALE_<sid>.md` marker, and the gauntlet
  attestation witness exists — so post-merge main is byte-identical to a branch tip
  whose PASS artifacts are provably fresh), and
- that branch's session artifacts were verified PASS in Step 3a-pre
  (PRE_FLIGHT_REPORT `Overall Status: PASS` + VERIFY_DONE_REPORT `Overall Verdict: PASS`).

Then the exact tree now at main HEAD already passed the full gauntlet inside its own
session — re-running tests/tsc/build re-verifies an identical tree and can find nothing
new. Skip Steps 4a–4c and 4e and proceed to Step 5. (4f needs no special-casing: with
one branch and zero conflicts its existing trigger never fires.) Record the decision in
MERGE_ALL_REPORT § Post-Merge Verification as:
`skipped — ff-identical to gauntleted tip <sha of main HEAD>`.

If ANY condition fails (2+ branches, rebase replayed commits, any conflict, capture
commit, artifacts missing or unverified), run the full Step 4 unchanged.

**Gate 2 — diff-scoped frontend gates (4b/4c only; 4a and 4f UNCHANGED).** When Gate 1
does not apply, compute the union diff of everything merged this run and check whether
any frontend-relevant file changed:

```bash
FRONTEND_TOUCHED=1  # fail-safe default: if the diff can't be computed, run 4b/4c
if [ -n "$_MAIN_HEAD_AT_MERGE_START" ]; then
  if git diff --name-only "${_MAIN_HEAD_AT_MERGE_START}..HEAD" 2>/dev/null \
       | grep -qiE '\.(ts|tsx|js|jsx|vue|svelte|css|scss)$|\.blade\.php$|(^|/)routes/.*\.php$|(^|/)(package\.json|package-lock\.json|tsconfig[^/]*\.json|vite\.config\.[^/]+|webpack\.config\.[^/]+)$'; then
    FRONTEND_TOUCHED=1
  else
    FRONTEND_TOUCHED=0
    echo "4-pre Gate 2: no frontend-relevant files in union diff — skipping 4b (tsc) and 4c (build)"
  fi
fi
```

Backend-only merges stop paying for a frontend type-check + build they cannot have
broken. The full test suite (4a) still runs for every multi-branch merge, and the 4f
cross-cutting review trigger is untouched.

### 4a: Run the full test suite

```bash
# merge-all is a single SERIALIZED consolidation step (not concurrent /v sessions), so it
# uses the larger FULL parallelism budget and prefers the PARALLEL pest binary over
# single-process `php artisan test`. Source the resolver; fall back if missing.
_VPB="$HOME/.claude/skills/v/references/v-proc-budget.sh"
[ -f "$_VPB" ] && . "$_VPB"
: "${V_PEST_PROCESSES_FULL:=4}"
# Detect stack and run appropriate tests
if [ -f "artisan" ] && { [ -x "./vendor/bin/pest" ] || [ -x "vendor/bin/pest" ]; }; then
  ./vendor/bin/pest --parallel --processes="${V_PEST_PROCESSES_FULL}" 2>&1
elif [ -f "artisan" ]; then
  php artisan test 2>&1
elif [ -f "package.json" ]; then
  npm test 2>&1
elif [ -f "pytest.ini" ] || [ -f "setup.py" ]; then
  pytest 2>&1
fi
```

### 4b: Run TypeScript check (if applicable)

```bash
# v1.1.0: gated by 4-pre Gate 2 — skipped when no frontend-relevant file was merged.
if [ -f "tsconfig.json" ] && [ "${FRONTEND_TOUCHED:-1}" = "1" ]; then
  npx tsc --noEmit 2>&1
fi
```

### 4c: Run build

```bash
# v1.1.0: gated by 4-pre Gate 2 — skipped when no frontend-relevant file was merged.
if [ -f "package.json" ] && grep -q '"build"' package.json && [ "${FRONTEND_TOUCHED:-1}" = "1" ]; then
  npm run build 2>&1
fi
```

### 4d: Fix failures

If tests, TypeScript, or build fail after merging:

1. **Categorize failures:**
   - Import errors (missing exports from merged code) → fix imports
   - Type mismatches (interfaces changed in parallel) → unify interfaces
   - Test failures (conflicting test data or assertions) → update tests
   - Build errors (duplicate identifiers, circular deps) → resolve

2. **Apply fixes** using `references/v-exec-typescript.md` auto-remediation patterns where applicable

3. **Re-run verification** after each fix round (up to 3 iterations)

4. **If failures persist after 3 rounds:** Log remaining failures in MERGE_ALL_REPORT but do NOT push. The user needs to review.

### 4e: Run /v-pre-flight (conditional)

**Skip if Steps 4a-4c all passed cleanly** (tests pass, tsc clean, build succeeds). Pre-flight would repeat those same gates plus lint — and lint already runs via the `lint-on-edit.sh` hook on every Write/Edit. Only invoke pre-flight if any gate in 4a-4c failed and was fixed in 4d, to re-validate the fixes.

When invoked: **dispatch** `/v-pre-flight` — emit its prompt with
`bash ~/.claude/skills/v/references/v-emit-prompt.sh v-pre-flight > "$DISPATCH_FILE"` and run the
`v-pre-flight-runner`. **Never the Skill tool**: `enforce-haiku-dispatch.sh` denies it (Skill runs
inline on the session model, defeating the mechanical-runner cost split). Corrected 2026-08-09 —
this line, `_v-core.md` and `CLAUDE.md` all instructed the denied call, which cost 31 denials across
30 sessions. If pre-flight fails:
- Fix issues that can be auto-fixed (lint, format, type errors)
- Re-run pre-flight once
- If critical gates still fail: log in report, do NOT push

### 4f: Cross-session agent review (conditional — only when cross-cutting risk OR an unreviewed capture exists)

**Skip if all merged branches touched completely disjoint files** (no file was modified by more than one branch) **AND `MAIN_CAPTURE_NEEDS_REVIEW` is not 1**. The point of this step is to catch cross-cutting issues AND to guarantee every diff that reaches origin was reviewed by someone at least once — if branches don't overlap and nothing unreviewed was captured, there is nothing left for this step to catch.

**When cross-cutting files exist** (files touched by 2+ branches) OR any conflict was auto-resolved in Step 3 OR `MAIN_CAPTURE_NEEDS_REVIEW=1` (Step 2a-i captured main-root work that never passed any session's own gates), run a focused review. **This is the ONLY check for "each branch was green but the combination is broken" AND the only backstop against an unreviewed capture-commit reaching origin — it must actually run.** For the capture-only case (no branches merged, nothing to compare across), review is a full first-time hostile pass over `$MAIN_ROOT_CAPTURE_SHA`, not a cross-session-overlap diff — see the reference for the exact dispatch shape.

**Moved to:** `references/v-merge-all-cross-session-review.md` — the codex-via-Bash dispatch
commands and the fork-safe fallback. The WHEN-to-run rule and the must-actually-run mandate
above stay here; only the mechanics moved.
## Step 5: Push to Origin

**Only push if ALL of the following are true:**
- All tests pass
- Build succeeds (if applicable)
- TypeScript clean (if applicable)
- `/v-pre-flight` gates pass (if pre-flight was run — see 4e conditional)
- No unresolved merge conflicts remain
- **No unreviewed main-root capture remains** — if `MAIN_CAPTURE_NEEDS_REVIEW=1`, Step 4f's capture-review pass must have completed with all CRITICAL/HIGH findings fixed before this step runs
- If remediation state was detected, the latest remediation state is `completed` and the remediation prompt queues are empty

### 5-pre: Remove merged worktree directories (REQUIRED before the push gate)

The Step 5a solo-push allow-path requires `git worktree list` to show `worktree_count <= 1` — but a completed merge does **NOT** remove the merged branch's worktree, so consolidating N worktrees leaves `1 + N` worktrees here and the push gate would deny (stranding the merges locally-unpushed — the exact failure this step prevents). Remove the merged worktree **directories** now. Branches are KEPT (deleted only in Step 6b), so every commit stays in both local `main` and its branch — nothing is lost even if the push later fails and is retried. Same untracked-source-WIP guard + artifact rescue as Step 6a (this is that logic, run early; Step 6a's identical loop then becomes a harmless no-op, skipping the already-removed paths via its `[ -d ] || continue`):

```bash
for WT_PATH in $MERGED_WORKTREE_PATHS; do
  [ -d "$WT_PATH" ] || continue  # Skip already-removed worktrees
  # Untracked, never-added SOURCE files are real WIP — rescuing + removal would DESTROY them.
  # Preserve + report instead; never force away. (If preserved, worktree_count stays > 1 and the
  # 5a gate correctly STOPS — commit/move that WIP before retrying the push; do NOT force-remove.)
  if git -C "$WT_PATH" ls-files --others --exclude-standard 2>/dev/null \
       | grep -qiE '\.(php|js|jsx|ts|tsx|vue|svelte|py|rb|go|css|scss|json|yaml|yml|sql|sh|md|txt)$'; then
    echo "PRESERVED (untracked-source WIP, not removed): $WT_PATH"
    continue
  fi
  # Copy session artifacts to repo root before removal (portable — no GNU --backup)
  for ARTIFACT in "$WT_PATH"/*_*.md "$WT_PATH"/*_*.json; do
    [ -f "$ARTIFACT" ] || continue
    BASENAME=$(basename "$ARTIFACT")
    DEST="$REPO_ROOT/$BASENAME"
    if [ -f "$DEST" ]; then
      N=1
      while [ -f "${DEST%.md}.~${N}~.md" ] 2>/dev/null || [ -f "${DEST%.json}.~${N}~.json" ] 2>/dev/null; do
        N=$((N+1))
      done
      EXT="${BASENAME##*.}"
      DEST="${DEST%.${EXT}}.~${N}~.${EXT}"
    fi
    cp "$ARTIFACT" "$DEST"
  done
  touch "$WT_PATH/.artifacts-rescued" 2>/dev/null
  git worktree remove "$WT_PATH" 2>/dev/null || echo "Already removed: $WT_PATH"
done
git worktree prune
```

### 5a: Authorization — use the hook's sanctioned solo-push path (do NOT create a marker)

> **STALE-GUIDANCE FIX (2026-07-14, a forensic session).** This step previously told you to
> mint an HMAC-signed bypass marker at `.worktrees/.merge-all-push-authorized`. **Do not do that.**
> The auto-mode classifier now blocks marker creation as a *permission bypass*, so the old flow
> dead-ends the push and strands the session with merges landed but unpushed. The marker is no longer
> needed anyway: `protect-main-branch.sh` grew a first-class allow-path for exactly this case.

`protect-main-branch.sh` denies a **bare** `git push`, but `_pmb_allow_explicit_solo_main_push`
ALLOWS an **explicit** `git push origin <main>` when both hold:

- you are ON the main branch, and
- `git worktree list` shows `worktree_count <= 1` (**Step 5-pre above removed every merged worktree
  directory precisely so this holds** — a completed merge alone does NOT remove a worktree, so without
  5-pre this count would be `1 + N` for N consolidated worktrees and the push would deny + strand).

Verify both before pushing — if either is false, STOP and report; do not hunt for a bypass:

```bash
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
git rev-parse --abbrev-ref HEAD          # must equal "$MAIN_BRANCH"
git worktree list | wc -l                # must be <= 1
```

**Two environmental bugs silently break the allow-path** (both fixed 2026-07-13 — if a push is denied
despite the two checks passing, suspect a regression in one of these):

1. **Relative `GIT_COMMON_DIR` poisoning** — `resolve_git_paths` exports a RELATIVE
   `GIT_COMMON_DIR=../.git` when invoked from a repo subdirectory, which empties the hook's
   branch lookup and denies the push. Fixed by the `_pmb_git()` wrapper
   (`env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE git ...`).
2. **Tool cwd drift** — the Bash tool's cwd follows recent `cd`s and can land outside the repo
   (e.g. `~/.claude` after editing a hook), where `GIT_ROOT` is empty and the hook cannot confirm
   solo-main. **Run a standalone `cd <repo-root>` as its OWN command first**, then push as a separate
   command.

### 5b: Push

Run this as its own Bash call (not chained after a `cd` or a `grep`). Note the pre-push hook runs
ESLint + tsc + the full JS suite before transfer (~2 min), so background it and read completion via
BashOutput rather than blocking:

```bash
git push origin "$MAIN_BRANCH"
```

**Careful:** do not write the literal string `git push` into an unrelated command (e.g. a `grep`
pattern searching for it) — `protect-main-branch.sh` pattern-matches the command text and will deny
the call. Split the literal (`grep "pu""sh origin"`) if you must search for it.

### 5c: (removed — no marker to clean up)

The old flow required deleting `.worktrees/.merge-all-push-authorized` after the push. The sanctioned
allow-path creates no marker, so there is nothing to clean up. If a marker file exists in a repo, it
is a leftover from the pre-2026-07-14 flow and can be deleted.

**If push fails** (remote has new commits):
```bash
# v1.1.0: fetch first and inspect what's actually incoming BEFORE rebasing, so the
# re-test can be skipped when the remote delta cannot have broken gates that just passed.
git fetch origin "$MAIN_BRANCH"
# Three-dot diff = merge-base..origin/main = ONLY the incoming remote changes.
_INCOMING=$(git diff --name-only "HEAD...origin/${MAIN_BRANCH}" 2>/dev/null)
git pull --rebase origin "$MAIN_BRANCH"
# Re-test ONLY if real code came in. Docs/telemetry-only remote deltas (*.md, *.log,
# *.txt, SESSION_LOG_*, .v/ artifacts) cannot break tests/build. Fail-safe: any file
# NOT matching the harmless patterns (or an uncomputable diff) → full re-test.
if [ -z "$_INCOMING" ] || printf '%s\n' "$_INCOMING" | grep -qvE '^$|\.(md|log|txt)$|(^|/)SESSION_LOG_|^\.v/'; then
  # Re-run tests after pull (same stack detection + bounded-parallel pest as Step 4a)
  _VPB="$HOME/.claude/skills/v/references/v-proc-budget.sh"; [ -f "$_VPB" ] && . "$_VPB"; : "${V_PEST_PROCESSES_FULL:=4}"
  if [ -f "artisan" ] && { [ -x "./vendor/bin/pest" ] || [ -x "vendor/bin/pest" ]; }; then
    ./vendor/bin/pest --parallel --processes="${V_PEST_PROCESSES_FULL}" 2>&1
  elif [ -f "artisan" ]; then
    php artisan test 2>&1
  elif [ -f "package.json" ]; then
    npm test 2>&1
  elif [ -f "pytest.ini" ] || [ -f "setup.py" ]; then
    pytest 2>&1
  fi
else
  echo "push-retry: incoming remote delta is docs/telemetry-only — skipping re-test (v1.1.0)"
fi
# If tests still pass, push again via the SAME sanctioned allow-path as Step 5a.
# (No marker: the auto-mode classifier blocks marker creation as a permission bypass — see 5a.)
# Re-verify the allow-path preconditions; a rebase can leave you on a detached HEAD.
git rev-parse --abbrev-ref HEAD   # must equal "$MAIN_BRANCH"
git worktree list | wc -l         # must be <= 1
git push origin "$MAIN_BRANCH"
```

Retry limit: 3 pull-rebase-push cycles. After 3 failures, report and stop (nothing to clean up —
the allow-path creates no marker).

**If remote branch protection blocks** (GitHub/GitLab rules): report to user that the remote requires a PR and the push must be done manually or protection rules adjusted.

---

## Step 6: Cleanup

After successful push:

### 6a: Rescue artifacts and remove merged worktrees
```bash
# For each merged worktree: rescue artifacts, mark as rescued, then remove.
# The .artifacts-rescued marker tells worktree-remove.sh to allow deletion.
# NOTE: Step 5-pre already ran this exact loop BEFORE the push (so the solo-push gate could pass).
# This pass is now an idempotent fallback — the `[ -d "$WT_PATH" ] || continue` below skips every
# worktree 5-pre already removed, and only cleans up any that were newly resolvable post-push.
for WT_PATH in $MERGED_WORKTREE_PATHS; do
  [ -d "$WT_PATH" ] || continue  # Skip already-removed worktrees
  # SAME untracked-source guard as the 6a-sweep: untracked, never-added SOURCE files are real
  # WIP; rescuing artifacts + `touch .artifacts-rescued` tells worktree-remove.sh to allow
  # deletion, so removal here would DESTROY them. Preserve + report instead — never force away.
  if git -C "$WT_PATH" ls-files --others --exclude-standard 2>/dev/null \
       | grep -qiE '\.(php|js|jsx|ts|tsx|vue|svelte|py|rb|go|css|scss|json|yaml|yml|sql|sh|md|txt)$'; then
    echo "PRESERVED (untracked-source WIP, not removed): $WT_PATH"
    continue
  fi
  # Copy session artifacts to repo root before removal (portable — no GNU --backup)
  for ARTIFACT in "$WT_PATH"/*_*.md "$WT_PATH"/*_*.json; do
    [ -f "$ARTIFACT" ] || continue
    BASENAME=$(basename "$ARTIFACT")
    DEST="$REPO_ROOT/$BASENAME"
    if [ -f "$DEST" ]; then
      N=1
      while [ -f "${DEST%.md}.~${N}~.md" ] 2>/dev/null || [ -f "${DEST%.json}.~${N}~.json" ] 2>/dev/null; do
        N=$((N+1))
      done
      EXT="${BASENAME##*.}"
      DEST="${DEST%.${EXT}}.~${N}~.${EXT}"
    fi
    cp "$ARTIFACT" "$DEST"
  done
  # Create marker so worktree-remove.sh allows deletion
  touch "$WT_PATH/.artifacts-rescued" 2>/dev/null
  git worktree remove "$WT_PATH" 2>/dev/null || echo "Already removed: $WT_PATH"
done
git worktree prune

# ALSO archive repo-root artifacts of UNLOGGED sessions before any consolidation
# cleanup can remove them (inline sessions leave artifacts at repo root, never in a
# worktree — consolidation cleanup would destroy their telemetry unrecoverably).
# Purely additive (cp); never deletes. Each unlogged SID's artifacts -> .v/archive/.
_ARCHIVE="$REPO_ROOT/.v/archive/merge-${CLAUDE_SESSION_ID:-$(date +%s)}"
for _art in "$REPO_ROOT"/PRE_FLIGHT_REPORT_*.md "$REPO_ROOT"/AGENT_REVIEW_*.md \
            "$REPO_ROOT"/VERIFY_DONE_REPORT_*.md "$REPO_ROOT"/QA_REPORT_*.md \
            "$REPO_ROOT"/IMPACT_MAP_*.md "$REPO_ROOT"/DISPATCH_PROVENANCE_*.log; do
  [ -f "$_art" ] || continue
  _sid=$(basename "$_art" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  # Only archive sessions that have NOT been logged yet (logged ones are safe).
  [ -n "$_sid" ] && [ ! -f "$REPO_ROOT/SESSION_LOG_${_sid}.yaml" ] || continue
  mkdir -p "$_ARCHIVE" && cp "$_art" "$_ARCHIVE/" 2>/dev/null || true
done
[ -d "$_ARCHIVE" ] && echo "archived unlogged-session artifacts to $_ARCHIVE (run /v-session-log to capture them)."
```

**Before consolidating, prefer to LOG unlogged sessions first.** If the repo has session artifacts (`PRE_FLIGHT_REPORT_<sid>.md` etc.) with no matching `SESSION_LOG_<sid>.yaml`, those are unlogged sessions whose telemetry will be lost if consolidation cleans untracked files. The archive above is a safety net, but the durable fix is to run `/v-session-log` for each unlogged SID before merge-all cleans up (or let the operator know they exist).

**Remediation cleanup pass:** If Step 1e marked remediation as ready, clean up runner-owned remediation worktrees only after verification and push have already succeeded. Never merge them, and never remove one whose branch still differs from `main`.

```bash
if [ "${REMEDIATION_READY:-0}" = "1" ] && [ -f "$RUNNER_OWNED_REMEDIATION_MANIFEST" ]; then
  while IFS=$'\t' read -r WT_PATH BRANCH; do
    [ -n "$WT_PATH" ] || continue
    [ -d "$WT_PATH" ] || continue
    if [ -n "$BRANCH" ] && git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
      if ! git diff --quiet "$MAIN_BRANCH...$BRANCH" 2>/dev/null; then
        echo "PRESERVED runner-owned remediation worktree: $WT_PATH (branch $BRANCH still differs from $MAIN_BRANCH)"
        RUNNER_OWNED_REMEDIATION_PRESERVED="${RUNNER_OWNED_REMEDIATION_PRESERVED:-} $WT_PATH"
        continue
      fi
    fi
    touch "$WT_PATH/.artifacts-rescued" 2>/dev/null
    git worktree remove "$WT_PATH" 2>/dev/null || echo "Already removed: $WT_PATH"
    RUNNER_OWNED_REMEDIATION_CLEANED="${RUNNER_OWNED_REMEDIATION_CLEANED:-} $WT_PATH"
  done < "$RUNNER_OWNED_REMEDIATION_MANIFEST"
fi
```

### 6a-sweep: remove EVERY remaining non-active worktree whose branch is already in main

The per-run `$MERGED_WORKTREE_PATHS` loop above only removes worktrees THIS run merged. Worktrees from a **prior** run — branch already fast-forwarded into main but the worktree never removed (the classic "3 of 4 left behind" leftover) — slip through it. This sweep closes that gap so cleanup is exhaustive, not run-scoped.

**Safe by construction** — a worktree is removed ONLY when every one of these holds: (a) it is not the main checkout, not detached, not main/master; (b) it is **provably not live** — its `.claude-session-lock` owning PID fails `kill -0` (**mtime is NOT liveness**, per forensics trust hierarchy) AND no `~/.claude/runtime/active-worktree-<sid>` marker exists; a lock whose PID cannot be extracted (old 2-field format) is treated as possibly-live and PRESERVED unless its mtime is ≥30 min; (c) it is not a runner-owned remediation worktree (those have their own pass above); (d) its branch tip is an **ancestor of main** (every commit already integrated) AND it has actually diverged+merged (`main..branch`==0 **and** `branch..main`>0, i.e. real work that main has since advanced past) OR carries an explicit ended-session marker — a **vacuous 0-commit branch (tip == main, 0 ahead / 0 behind) is NEVER swept** (that "already an ancestor" case is exactly a fresh mid-setup live worktree, not a merged leftover; removing it reclaims nothing and can only destroy in-progress work); (e) it has **no uncommitted tracked-source edits and no untracked source files** (real WIP — staged, unstaged, or never-added source — is preserved + reported, never destroyed). Untracked-only build cruft (vendor/, node_modules/, regenerable build output) does NOT block removal. Session artifacts are rescued to repo root first. Anything failing (a)–(e) is **PRESERVED with a recorded reason**.

```bash
MAIN_BRANCH="${MAIN_BRANCH:-${CLAUDE_MAIN_BRANCH:-main}}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
_REM_PREFIX="${REMEDIATION_WORKTREE_PREFIX:-ecosystem-fix}"
_THIS_WT="$(git rev-parse --show-toplevel 2>/dev/null)"
SWEPT_WORKTREES=""
PRESERVED_WORKTREES="${PRESERVED_WORKTREES:-}"
# Process substitution (NOT a pipe) so the result vars survive the loop.
while IFS=$'\t' read -r WT BR; do
  [ -n "$WT" ] && [ -d "$WT" ] || continue
  [ "$WT" = "$_THIS_WT" ] && continue                                  # never the main checkout
  case "$BR" in ""|"$MAIN_BRANCH"|master|main) continue;; esac         # protected / detached
  case "$BR" in ${_REM_PREFIX}*) continue;; esac                       # remediation: own pass above
  _lk_sid=""; _lk_pid=""                                              # reset per-iteration (no stale leakage)
  LOCK="$WT/.claude-session-lock"                                      # (b) liveness gate — kill -0, NOT mtime
  if [ -f "$LOCK" ]; then
    # lock format: "SID PID EPOCH" (hook) or "SID EPOCH" (fallback, no PID). Field 1 = SID.
    _lk_sid=$(awk 'NR==1{print $1}' "$LOCK" 2>/dev/null)
    _lk_pid=$(awk 'NR==1{if (NF>=3 && $2 ~ /^[0-9]+$/) print $2}' "$LOCK" 2>/dev/null)
    # session-cleanup marker: present ⇒ session still owns the tree
    if [ -n "$_lk_sid" ] && [ -e "$HOME/.claude/runtime/active-worktree-$_lk_sid" ]; then
      PRESERVED_WORKTREES="$PRESERVED_WORKTREES ${WT}#active-session-marker"; continue
    fi
    if [ -n "$_lk_pid" ]; then
      if kill -0 "$_lk_pid" 2>/dev/null; then                         # owning process alive ⇒ live
        PRESERVED_WORKTREES="$PRESERVED_WORKTREES ${WT}#live-pid(${_lk_pid})"; continue
      fi
    else                                                              # old 2-field lock: can't prove dead
      LM=$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo 0)
      if [ "$(( ($(date +%s) - LM) / 60 ))" -lt 30 ]; then
        PRESERVED_WORKTREES="$PRESERVED_WORKTREES ${WT}#lock-no-pid-recent"; continue
      fi
    fi
  fi
  if ! git merge-base --is-ancestor "$BR" "$MAIN_BRANCH" 2>/dev/null; then   # (d) branch fully in main?
    PRESERVED_WORKTREES="$PRESERVED_WORKTREES ${WT}#branch-not-merged(${BR})"; continue
  fi
  _ahead=$(git rev-list --count "$MAIN_BRANCH..$BR" 2>/dev/null || echo 0)   # commits on BR not in main
  _behind=$(git rev-list --count "$BR..$MAIN_BRANCH" 2>/dev/null || echo 0)  # commits on main not in BR
  _ended="$WT/.session-ended"; [ -e "$HOME/.claude/runtime/ended-$_lk_sid" ] && _ended="$HOME/.claude/runtime/ended-$_lk_sid"
  # vacuous 0-commit branch (never diverged) = fresh/live mid-setup, NOT a merged leftover → keep
  if [ "$_ahead" = "0" ] && [ "$_behind" = "0" ] && [ ! -e "$_ended" ]; then
    PRESERVED_WORKTREES="$PRESERVED_WORKTREES ${WT}#vacuous-0-commit(no-merged-work)"; continue
  fi
  for ART in "$WT"/*_*.md "$WT"/*_*.json "$WT"/*_*.log; do             # rescue artifacts first (versioned — a basename collision must NOT drop the artifact before --force)
    [ -f "$ART" ] || continue; B=$(basename "$ART"); D="$REPO_ROOT/$B"
    if [ -e "$D" ] && ! cmp -s "$ART" "$D" 2>/dev/null; then           # exists AND differs → keep both
      E="${B##*.}"; N=1; while [ -e "${D%.$E}.~${N}~.$E" ]; do N=$((N+1)); done; D="${D%.$E}.~${N}~.$E"
    fi
    cp -n "$ART" "$D" 2>/dev/null || true                             # -n: identical existing file is a no-op
  done
  if [ -n "$(git -C "$WT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then  # (e) tracked WIP?
    PRESERVED_WORKTREES="$PRESERVED_WORKTREES ${WT}#uncommitted-tracked-WIP"; continue
  fi
  # (e cont.) untracked SOURCE files (never git-added) = real WIP → preserve; build cruft is ignored
  if git -C "$WT" ls-files --others --exclude-standard 2>/dev/null \
       | grep -vE '(^|/)(vendor|node_modules|dist|build|public/build)/' \
       | grep -qiE '\.(php|js|jsx|ts|tsx|vue|svelte|py|rb|go|css|scss|json|yaml|yml|sql|sh|md|txt|html)$'; then
    PRESERVED_WORKTREES="$PRESERVED_WORKTREES ${WT}#untracked-source-WIP"; continue
  fi
  touch "$WT/.artifacts-rescued" 2>/dev/null
  if git worktree remove --force "$WT" 2>/dev/null; then
    SWEPT_WORKTREES="$SWEPT_WORKTREES $WT"
  else
    PRESERVED_WORKTREES="$PRESERVED_WORKTREES ${WT}#remove-failed"
  fi
done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{wt=$2} /^branch /{b=$2; sub(/^refs\/heads\//,"",b); print wt"\t"b}')
git worktree prune 2>/dev/null
[ -n "$SWEPT_WORKTREES" ] && echo "Swept non-active merged worktrees:$SWEPT_WORKTREES"
[ -n "$PRESERVED_WORKTREES" ] && echo "Preserved worktrees (reason after #):$PRESERVED_WORKTREES"
```

### 6b: Delete merged branches
```bash
for BRANCH in $MERGED_BRANCHES; do
  git branch -d "$BRANCH" 2>/dev/null || echo "Already deleted: $BRANCH"
done
```

### 6b-sweep: delete EVERY local branch already merged into main

Same completeness guarantee for branches: the per-run `$MERGED_BRANCHES` loop only deletes branches THIS run merged. Branches merged in a **prior** run (or whose worktree was just swept above) linger as clutter. `git branch -d` is **safe by design** — it REFUSES any branch not fully merged into its upstream/HEAD, so a still-additive (un-integrated) branch is never lost here. Excludes main/master, the current branch, branches still checked out in a PRESERVED worktree, and runner-owned remediation branches (their own pass below).

```bash
MAIN_BRANCH="${MAIN_BRANCH:-${CLAUDE_MAIN_BRANCH:-main}}"
_REM_PREFIX="${REMEDIATION_WORKTREE_PREFIX:-ecosystem-fix}"
_CUR="$(git branch --show-current 2>/dev/null)"
# Branches still checked out in any (preserved) worktree must not be deleted.
_CHECKED_OUT="$(git worktree list --porcelain 2>/dev/null | awk '/^branch /{b=$2; sub(/^refs\/heads\//,"",b); print b}')"
SWEPT_BRANCHES="${SWEPT_BRANCHES:-}"
while read -r BR; do
  [ -n "$BR" ] || continue
  case "$BR" in "$MAIN_BRANCH"|master|main|"$_CUR") continue;; esac
  case "$BR" in ${_REM_PREFIX}*) continue;; esac                       # remediation: own pass below
  printf '%s\n' "$_CHECKED_OUT" | grep -qxF "$BR" && continue          # still checked out somewhere
  git branch -d "$BR" 2>/dev/null && SWEPT_BRANCHES="$SWEPT_BRANCHES $BR"
done < <(git branch --merged "$MAIN_BRANCH" 2>/dev/null | sed 's/^[*+ ]*//')
[ -n "$SWEPT_BRANCHES" ] && echo "Swept merged local branches:$SWEPT_BRANCHES"
```

If remediation-finalization mode is active, delete runner-owned remediation branches only when their diff versus `main` is empty. These branches are cleanup-only artifacts, not durable merge history.

```bash
if [ "${REMEDIATION_READY:-0}" = "1" ] && [ -f "$RUNNER_OWNED_REMEDIATION_MANIFEST" ]; then
  while IFS=$'\t' read -r _ BRANCH; do
    [ -n "$BRANCH" ] || continue
    if ! git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
      continue
    fi
    if git diff --quiet "$MAIN_BRANCH...$BRANCH" 2>/dev/null; then
      git branch -D "$BRANCH" 2>/dev/null || echo "Already deleted: $BRANCH"
    else
      echo "PRESERVED runner-owned remediation branch: $BRANCH (still differs from $MAIN_BRANCH)"
    fi
  done < "$RUNNER_OWNED_REMEDIATION_MANIFEST"
fi
```

### 6c: Clean up lock files and markers
```bash
# Remove session locks ONLY from worktrees that were merged in this run.
# NEVER blanket-delete all locks — other sessions may be actively working.
for WT_PATH in $MERGED_WORKTREE_PATHS; do
  rm -f "$WT_PATH/.claude-session-lock" 2>/dev/null
done
# Remove merge lock (both the flock file and the W-conc-fix mkdir-mutex dir)
rm -f .worktrees/.merge-lock
rm -rf .worktrees/.merge-lock.d
# Remove any LEGACY push-authorization marker. The current flow (Step 5a) creates no marker — it uses
# protect-main-branch.sh's sanctioned solo-push allow-path — so this only sweeps up leftovers from the
# pre-2026-07-14 HMAC flow. Harmless when absent.
rm -f .worktrees/.merge-all-push-authorized
# Remove auto-branch markers — W24 moved to $REPO_ROOT/.v/tmp/hook-markers/;
# clean both locations during the migration window so old sessions don't leak.
rm -f "${REPO_ROOT}/.v/tmp/hook-markers/auto-branch-"* 2>/dev/null
rm -f "${TMPDIR:-/tmp}/claude-hooks/auto-branch-"* 2>/dev/null
```

### 6d: Verify clean state + cleanup-completeness reconciliation
```bash
MAIN_BRANCH="${MAIN_BRANCH:-${CLAUDE_MAIN_BRANCH:-main}}"
echo "=== Final State ==="
echo "Branch: $(git branch --show-current)"
echo "Worktrees: $(git worktree list | wc -l)"
echo "Unmerged branches: $(git branch --no-merged "$MAIN_BRANCH" 2>/dev/null | grep -cE '(build/|fix/|feature/|refactor/|chore/|docs/|test/)' || echo 0)"
echo "Runner-owned remediation branches remaining: $(git branch --list 'ecosystem-fix*' | wc -l | tr -d ' ')"
echo "Uncommitted: $(git status --porcelain | wc -l)"
echo "Remote sync: $(git log origin/$MAIN_BRANCH..$MAIN_BRANCH --oneline 2>/dev/null | wc -l) commits ahead"

# Completeness reconciliation (R-sweep): a NON-active worktree whose branch is fully merged into main,
# or a local branch already merged into main, must NOT remain after the sweeps above. Anything still
# here is either active, genuinely divergent (recorded failed/unresolved), or protected — list each so
# "all additive work cleaned up" is AUDITABLE, not assumed. A non-zero count here is a real leftover the
# operator must look at (active session? uncommitted tracked WIP? remove-failed?), not a silent pass.
echo "--- Cleanup completeness check ---"
_LEFT_MERGED_WT=0
while IFS=$'\t' read -r WT BR; do
  [ -n "$WT" ] && [ -d "$WT" ] || continue
  [ "$WT" = "$(git rev-parse --show-toplevel 2>/dev/null)" ] && continue
  case "$BR" in ""|"$MAIN_BRANCH"|master|main|${REMEDIATION_WORKTREE_PREFIX:-ecosystem-fix}*) continue;; esac
  if git merge-base --is-ancestor "$BR" "$MAIN_BRANCH" 2>/dev/null; then
    L="$WT/.claude-session-lock"; A="no-lock"
    if [ -f "$L" ]; then
      M=$(stat -c %Y "$L" 2>/dev/null || stat -f %m "$L" 2>/dev/null || echo 0)
      A="$(( ($(date +%s)-M)/60 ))min"
    fi
    WIP=$(git -C "$WT" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
    echo "  LEFTOVER merged worktree NOT cleaned: $WT (branch $BR fully in main; lock=$A; tracked-WIP=$WIP files) — investigate"
    _LEFT_MERGED_WT=$((_LEFT_MERGED_WT+1))
  fi
done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{wt=$2} /^branch /{b=$2; sub(/^refs\/heads\//,"",b); print wt"\t"b}')
_LEFT_MERGED_BR=$(git branch --merged "$MAIN_BRANCH" 2>/dev/null | sed 's/^[*+ ]*//' | grep -vE "^(${MAIN_BRANCH}|master|main|$(git branch --show-current))$" | grep -vcE '^ecosystem-fix' || echo 0)
echo "  Merged worktrees still present (expect 0 unless active/WIP/remove-failed): $_LEFT_MERGED_WT"
echo "  Merged local branches still present (expect 0): $_LEFT_MERGED_BR"
# Surface any stash so additive stashed work isn't silently forgotten. NEVER auto-popped (rule 7:
# git stash is forbidden as a workflow verb; popping can conflict) — report it for the operator.
_STASH=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
[ "${_STASH:-0}" -gt 0 ] && echo "  NOTE: $_STASH stash entr(y/ies) present — review with 'git stash show -p stash@{0}'. merge-all never auto-pops a stash; surface it in the report so the work isn't lost."
```

---

## Step 7: Write MERGE_ALL_REPORT

**Moved to:** `references/v-merge-all-report-template.md`  — the full section-by-section
report template (Summary, Per-Branch Detail, Cleanup Completeness, Remediation Context,
Push Status). Read it before writing the report; it is pure formatting, no safety rules.
---

## Error Handling & Abort Conditions

### Retry Loop
When a merge step fails:
1. Attempt rebase with conflict resolution (up to 3 conflicts per file)
2. If rebase succeeds but tests fail: apply auto-remediation
3. If still failing after 3 iterations: skip this branch, continue with others

### Abort Conditions
Abort the **entire process** (write report and stop, do NOT push) if:
- `main` branch has uncommitted changes that cannot be committed (pre-commit hooks fail repeatedly)
- The git repository is in a corrupted state (`git fsck` fails)
- More than 50% of branches fail to merge
- The test suite is fundamentally broken on main BEFORE any merges (pre-existing failure)
- Remediation state exists but the latest run is not exactly `completed`
- Numbered prompt files still exist in `v-remediation-phase-*-prompts`

### Never
- Force push
- Delete non-remediation branches that weren't successfully merged
- Remove worktrees with unmerged changes
- Push with failing tests
- Modify the merge order after starting (deterministic execution)
- Merge runner-owned remediation branches under `$REMEDIATION_WORKTREE_PREFIX*` into `main` after their diff has already been synced to repo root

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Worktree merge introduces conflicts that weren't there in source | `git checkout --theirs` used to resolve conflicts | NEVER `--theirs` — read both sides and merge intent; conflicts are decisions, not noise |
| 2 | Files staged from another worktree contaminate current session's commit | `git add -A` used | Use `git add -u` (tracked files only) or named files; `-A` stages cross-worktree state |
| 3 | Worktree branch deleted but worktree directory persists | `git worktree remove` not run before branch delete | Always `git worktree remove <path>` BEFORE `git branch -d`; orphan worktrees confuse later sessions |
| 4 | Merge succeeds locally but fails to push due to branch protection | Direct push to main blocked, but skill assumed direct-push works | Check `git config branch.main.protect` first. If the remote requires a PR, **STOP and report the constraint — NEVER auto-open a PR** (global policy: NO AUTOMATIC PRS without an explicit user request). The merge stays local; the operator opens the PR or adjusts protection. |
| 5 | Lost changes from `git stash` during multi-worktree work | Stash is shared across all worktrees and gets popped in wrong worktree | NEVER `git stash` — use `PROGRESS_NOTE_*.md` or commit checkpoints instead; stash is forbidden by `worktree-safety.sh` hook |
| 6 | Pre-merge freshness check skipped, merging stale code over newer main | Hot File Coordination protocol from `references/v-exec-worktree-lifecycle.md` not followed | Before merge-back: rebase onto fresh main, re-run pre-flight, only then merge |

## Progress Checklist (copy into your response, check off as you go)

```markdown
## Multi-worktree merge progress

Mirror the section headers from this skill's body workflow (the merge workflow documented below) into your response — one checkbox per ### Step / ### Phase / ### Gate as you progress. The body workflow is the single source of truth for what gates exist; treat the checklist as a render of THAT structure, not a parallel definition.

Example (replace with your actual sections as you go):
- [ ] Step 1: <skill-specific name>
- [ ] Step 2: <skill-specific name>
- ...
- [ ] Final: <output artifact written>
```

This avoids drift between the checklist and the body workflow when the body changes — only one source of truth (the body's `### Step N:` headers) needs to stay current. Operator-facing visibility comes from the AI rendering the actual current sections into its response, not from a hard-coded duplicate.

> **Do NOT re-introduce a hard-coded checklist here.** The body's true order is **merge (Step 3)
> → verify (Step 4) → push (Step 5) → remove worktrees/branches (Step 6)**: cleanup is LAST,
> never before verification or push. Render the body's actual `### Step N:` headers in that
> order; the body is the single source of truth.

## Idempotency

**Conditionally idempotent.** Already-merged worktrees are no-op'd; un-merged worktrees are merged. Re-run after success is a no-op. Mutates git state.
