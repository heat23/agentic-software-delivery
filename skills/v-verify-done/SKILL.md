---
name: v-verify-done
description: "Use at the end of implementation to verify conventions and completion contracts."
user-invocable: true
allowed-tools: Read, Glob, Grep, Bash, Write
context: fork
model: sonnet
---
<!-- skill: v-verify-done | version: 1.1.2 | last-updated: 2026-08-12 -->



# 2026 Canonical Contract

Tier: Orchestration primitive. Most users should let `v` or `v-build` call this automatically.

This contract overrides older sections below on conflict.

Follow `_v-core.md` and `_v-exec.md`.

For changed file detection, read `~/.claude/skills/references/v-core-changed-files.md`.
For user-owned maintenance scope, read `~/.claude/skills/references/v-core-maintenance.md`.

Rules:
- inspect staged, unstaged, and untracked files
- include evidence and confidence for warnings
- if growth triggers apply, verify instrumentation hooks exist
- add `codex-adversarial-reviewer` on ALL implementations when `codex-adversarial-reviewer.md` exists in either `.claude/agents/` (project) or `~/.claude/agents/` (global) — this is mandatory review provenance, not an optional enhancer; if Codex is unavailable or the agent file is missing in both locations, invoke `superpowers:requesting-code-review` via Skill tool as the mandatory fallback; elevate to hostile adversarial focus when changed files touch auth, payments, data deletion, encryption, file upload, or external input handling; degraded self-review wording does not satisfy AGENT_REVIEW ownership

Output:
- `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md`

```yaml
contract:
  tier: orchestration-primitive
  accepts: [changed files via git]
  produces: [VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md]
  invokes: []
  dispatches: codex-adversarial-reviewer (mandatory when the agent file exists, via fork-safe claude -p subprocess — v-dispatch-subagent.sh), superpowers:requesting-code-review (mandatory fallback, via Skill tool)
  invoked-by: [/v, /v-build, /v-maintenance, user, /v-audit-orchestrator]
  estimated_tokens: 10k-30k
  estimated_duration: 3-10 min
```

# /v-verify-done - Deep Verification

**Boundary:** v-verify-done owns "does the code follow conventions and avoid AI-specific mistakes?" — TODO markers, debug statements, missing test files, Mockery identity traps, factory FK drift, lazy loading patterns. v-pre-flight owns "does the project build and pass automated checks?" — tests, builds, linting, type checking. If a CI server would run it, it belongs in pre-flight. If a human reviewer would catch it, it belongs here.

Goes beyond linting and tests to catch convention violations, missing patterns, and common AI mistakes in changed files.

## Skill Boundaries

**SME persona:** This audit is run by a **senior code reviewer focused on convention adherence** — someone who's reviewed thousands of PRs and knows the difference between "this passes the linter" and "this is convention-clean." The output is judgment-call findings with confidence levels (high / medium / low) — not deterministic gates.

**Distinct from `/v-pre-flight`:** v-verify-done runs **JUDGMENT-CALL CONVENTION CHECKS**, v-pre-flight runs **DETERMINISTIC EXECUTABLE GATES** (per the Boundary callout above). Run BOTH — different question types, different output styles.

### Best fit

- Post-implementation convention check across staged + unstaged + untracked files
- Verifying lazy-loading hygiene (eager-load patterns; if stack includes Laravel+Cashier: Cashier methods — see § Laravel+Cashier: Query-Count Convention Check below for concrete grep patterns), DOMPurify usage on `dangerouslySetInnerHTML`, type safety (no `any`), middleware presence on new routes, factory/contract integrity
- Detecting AI-test anti-patterns (snapshot-only tests, no-assertion tests, test that runs the same code as production)
- Producing the `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md` artifact + dispatching mandatory adversarial review agents

### Use instead

- `/v-pre-flight` — for tests/build/lint/types/security audits; v-verify-done runs **alongside** pre-flight, not instead
- Direct code review — for one-off questions or single-file concerns where dispatching agents is overkill
- `/v-check` — for codebase-wide convention audit (this skill scopes to changed files only)

### Not for

- Replacing `/v-pre-flight` — these are complementary, not substitutes
- Behavior verification or bug detection — this is convention check, not functional verification
- Auditing a separate codebase or audit-style review — out of scope; use `/v-check` or `v-audit-*`
- Implementation review on a clean working tree — needs changed files to operate on


## Workflow

1. Resolve project root per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from invocation prompt if present, else `git rev-parse --show-toplevel`; if that does not yield a safe repo root, stop and ask for PROJECT_ROOT explicitly. Do not fall back to `pwd`.
2. **Pre-flight gate check (Gotcha #5 — abort if pre-flight isn't green).** Convention checks are meaningless on a build that doesn't compile or pass tests. Before doing any convention work, look for this session's pre-flight report and read its verdict:
   ```bash
   SID="${CLAUDE_SESSION_ID:-$(cat ~/.claude/runtime/current-session-id 2>/dev/null | tr -d '[:space:]')}"
   PF="$PROJECT_ROOT/PRE_FLIGHT_REPORT_${SID}.md"
   if [ -f "$PF" ]; then
     # Authoritative verdict is the LAST 'Overall Status:' line — the SAME line the Stop hook reads
     # (check-review-artifact.sh); a dispatched-runner report emits ONLY this line, no legacy 'status:'.
     # FAIL or BLOCK → treat as fail. Fall back to the legacy '^status:' line for older reports.
     _pf_verdict=$(grep -iE '^[-* ]*(\*\*)?Overall Status(\*\*)?[[:space:]]*:' "$PF" | tail -1)
     if printf '%s' "$_pf_verdict" | grep -qiE ':[[:space:]]*(\*\*)?(FAIL|BLOCK)'; then PF_STATUS=fail
     elif printf '%s' "$_pf_verdict" | grep -qiE ':[[:space:]]*(\*\*)?PASS'; then PF_STATUS=pass
     else PF_STATUS=$(grep -m1 -oE '^status:[[:space:]]*(pass|fail)' "$PF" | grep -oE '(pass|fail)'); fi
     # not_evaluated count >= 4 (per v-pre-flight gate-schema.md's own DEGRADED threshold) OR an explicit DEGRADED marker
     { [ "$(grep -c 'status: not_evaluated' "$PF")" -ge 4 ] || grep -qi DEGRADED "$PF"; } && PF_DEGRADED=1
   fi
   ```
   - `status: fail` or a DEGRADED pre-flight → **ABORT** convention checks and report: "Pre-flight is FAILED/DEGRADED for this session — fix `/v-pre-flight` first; convention verification on a red build is noise." Do NOT write a PASS `VERIFY_DONE_REPORT` over a red pre-flight.
   - No pre-flight report for this session → note it as a warning in the report header (`pre_flight: not_found`) but continue; the Stop hook, not this skill, enforces pre-flight existence.
   - `status: pass` → proceed.
3. Find changed files via git (worktree-aware detection below)
4. Detect project stack (Convention Discovery below)
5. Categorize changed files by type (PHP, TS/JS, Python, Ruby, Rust, Go)
6. **Dispatch parallel subagent checks** (see Parallel Check Dispatch below)
7. Collect results, merge findings, write report

## User-Owned Maintenance Verification

When the change set is confined to the maintenance roots from `~/.claude/skills/references/v-core-maintenance.md`, add these checks before finishing:
- every changed path stays inside the allowed roots
- no changed path lands in `.codex`, `.claude/plugins`, `.claude/plugins/cache`, or `.claude/plugins/marketplaces`
- canonical skill edits happen **directly** in `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}` (per `v-core-maintenance.md` § Canonical Skill Ownership — this is a single-tree install; a mirror sync to `$HOME/.agents/skills` is NOT required and must not be treated as mandatory). If the install genuinely has a separate `$HOME/.agents/skills` tree AND the project declares a mirror workflow, then mirror changes are sync-only, not standalone edits.
- lighter workflow changes did not remove targeted tests, hostile review, or final verification

Scope leakage or weakened review gates in this mode are hostile-review findings, not acceptable shortcuts.

## Parallel Check Dispatch

**When this applies:** this inline fan-out is for the **interactive path** (direct `/v-verify-done` at `V_DEPTH==0`). When `/v` dispatches this skill on the authoritative gauntlet path it runs as the **`v-verify-done-runner`** — a read-only, Write-less capture subprocess that returns ONLY the VERIFY_DONE_REPORT and does NOT fan out its own checks or dispatch AGENT_REVIEW (the orchestrator owns adversarial review separately). Follow this section only when running interactively.

**Key optimization:** The checks matrix contains independent, self-contained checks with clear inputs (changed file list + stack) and outputs (findings array). Dispatch them as parallel fork-safe `claude -p` subprocesses via `~/.claude/skills/v/references/v-dispatch-subagent.sh` to cut wall-clock time (NOT the Agent tool — this skill runs `context: fork`; nested Agent dispatch fails silently).

**Dispatch groups** (launch simultaneously as subprocesses, each with the mandatory `--prompt-file <briefing>` and `--artifact <path>` flags plus `--model haiku --mode capture`, supervised by `v-supervise-children.sh`):

| Agent | Checks Covered | Input | Fires When |
|-------|---------------|-------|------------|
| **universal-checks** | TODO/FIXME/HACK, hardcoded secrets, debug statements, missing test files, `any` types, DOMPurify | All changed files | Always |
| **framework-checks** | Stack-specific checks (Laravel, Next.js, Django, Rails, Rust, Go) | Changed files filtered by stack | `STACK_*` detected |
| **ai-antipattern-checks** | Mockery identity traps, Queue::fake side-effects, Factory FK drift | Changed test files only | Test files in changeset |

**Each subagent receives this prompt template:**
```
You are a verification subagent. Check the following files for [CATEGORY] issues.

Changed files:
[FILE_LIST]

Stack: [DETECTED_STACK]

Run ONLY grep/read checks — do not modify any files. Return findings as a JSON array:
[{"severity": "critical|high|medium|low", "confidence": "high|medium|low", "file": "path:line", "issue": "summary", "fix": "recommended action"}]

`severity` uses the `critical/high/medium/low` cross-vocabulary row from `[[v-core-severity]]`
(`~/.claude/skills/references/v-core-severity.md`), which maps 1:1 to the canonical P0-P3 scale
(critical=P0, high=P1, medium=P2, low=P3) — consumers that normalize findings across skills
(e.g. `v-audit-consolidate`) can map this output without guessing.

Return an empty array [] if no issues found.
```

**After all agents return:** Merge findings arrays, deduplicate by file+issue, sort by severity, and write the unified `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md`.

**Fallback (mandatory — NEVER skip entirely):** If subprocess dispatch fails or the `claude` CLI is unavailable:
1. Run checks sequentially using inline grep (the Checks Matrix below is the authoritative reference)
2. Then invoke `superpowers:requesting-code-review` via Skill tool as the mandatory review fallback per `_v-review.md` § Agent Dispatch Protocol
3. Log `agent_dispatch_outcome: SKIPPED-GRACEFULLY` or `NOT-APPLICABLE` with reason in the report

## Changed File Detection

Use the worktree-aware pattern from `~/.claude/skills/references/v-core-changed-files.md`. In worktree workflows with checkpoint commits, bare `git diff HEAD` returns nothing — the merge-base approach captures the full session changeset.

```bash
# Worktree-aware changed file detection (canonical pattern)
IS_WORKTREE=false
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
if [ "$(git rev-parse --git-common-dir 2>/dev/null)" != "$(git rev-parse --git-dir 2>/dev/null)" ]; then
  IS_WORKTREE=true
fi

if $IS_WORKTREE; then
  MERGE_BASE=$(git merge-base HEAD "$MAIN_BRANCH" 2>/dev/null || git rev-list --max-parents=0 HEAD 2>/dev/null | head -1 || echo "HEAD")
  CHANGED=$(git diff --name-only "$MERGE_BASE"..HEAD 2>/dev/null)
  UNCOMMITTED=$(git diff --name-only HEAD 2>/dev/null)
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
  ALL_CHANGED=$(printf "%s\n%s\n%s\n" "$CHANGED" "$UNCOMMITTED" "$UNTRACKED" | sed '/^$/d' | sort -u)
else
  CHANGED=$(git diff --name-only HEAD 2>/dev/null)
  STAGED=$(git diff --cached --name-only 2>/dev/null)
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
  if [ -z "$CHANGED" ] && [ -z "$STAGED" ] && [ -z "$UNTRACKED" ]; then
    CHANGED=$(git diff --name-only HEAD~1 2>/dev/null)
  fi
  ALL_CHANGED=$(printf "%s\n%s\n%s\n" "$CHANGED" "$STAGED" "$UNTRACKED" | sed '/^$/d' | sort -u)
fi

echo "$ALL_CHANGED"
```

## Convention Discovery

Before running checks, detect the project stack to select applicable conventions:

```bash
# Detect stack from project files
test -f composer.json && STACK_PHP=true
test -f package.json && STACK_JS=true
test -f Cargo.toml && STACK_RUST=true
test -f go.mod && STACK_GO=true
test -f pyproject.toml && STACK_PYTHON=true
test -f tsconfig.json && STACK_TS=true

# Read CLAUDE.md for project-specific conventions
test -f CLAUDE.md && echo "CLAUDE_MD=true"
```

Apply only checks relevant to the detected stack. Read `references/checks-matrix.md` and execute the rows whose trigger language matches detected files. The reference is the superset; Universal-checks subsection applies to every project regardless of stack.

## Checks Matrix

**Moved to:** `references/checks-matrix.md`.

**Summary:** the canonical convention-check matrix, organized as
universal checks (TODO/FIXME, hardcoded secrets, debug statements,
`any` types, DOMPurify compliance, missing test files) plus
stack-specific check subsections (Laravel/PHP, Next.js/React,
Django/FastAPI/Python, plus framework-specific entries). Each row
lists the trigger condition and method (grep / agent dispatch /
tool invocation). The reference also includes the Billing/Pricing
Cross-Check pattern and the Hook Warning Normalization step
(emit hook-marker advisories under `## Hook Advisories` in the
output report).

**Trigger to load:** every v-verify-done run loads this reference
during the parallel-check-dispatch phase (see Workflow). The
Convention Discovery step determines which framework subsections
apply; load only those rows for the detected stack.

**Behavior unchanged:** check IDs, trigger conditions, and methods
are preserved verbatim. Adding a new check should happen in the
reference, not back inline.

## AI Test Anti-Pattern Detection

These checks catch patterns AI reliably gets wrong when generating tests. Run on all changed test files.

### PHP/Laravel: Mockery Identity Traps

> **Applies to: PHP/Laravel stacks only.** Skip if no `.php` test files are in the changeset.

**Problem:** `$mock->shouldReceive('method')->with($model)` uses `===` identity. Fails when the job/service loads the model from DB (different PHP object).

**Detection:** In changed test `.php` files, grep for Mockery `->with(` where the argument is an Eloquent model variable (e.g., `$site`, `$user`, `$recommendation`). Flag unless wrapped in `Mockery::on(fn($arg) => $arg->id === ...)`.

```bash
# Flag: direct model in ->with() — scope to files that actually use Mockery to avoid false positives on test helpers/traits
grep -rl 'Mockery' tests/ --include='*.php' | xargs grep -n '->with(\$' 2>/dev/null | grep -v 'Mockery::on'
# Correct pattern:
# ->with(Mockery::on(fn($s) => $s->id === $site->id))
```

### PHP/Laravel: Queue::fake + Side-Effect Assertions

> **Applies to: PHP/Laravel stacks only.** Skip if no `.php` test files are in the changeset.

**Problem:** `Queue::fake()` prevents jobs from executing. Tests that fake the queue then assert on DB records, audit logs, or notifications created *inside* jobs will always pass vacuously (the side effect never happened).

**Detection:** In changed test files, find tests with `Queue::fake()` that also assert `assertDatabaseHas`, `Log::shouldReceive`, or notification assertions on data created by the faked job.

```bash
# Flag: Queue::fake() in same test method as assertDatabaseHas
# (heuristic — verify flagged files for false positives before fixing)
grep -l 'Queue::fake' tests/ --include='*.php' -r | xargs grep -l 'assertDatabaseHas\|Log::shouldReceive\|Notification::assert'
```

**Fix:** Either remove `Queue::fake()` (jobs run synchronously in tests via `QUEUE_CONNECTION=sync`) and mock only the external API dependency, or move the side-effect assertions to a separate test that lets the job execute.

### Factory FK Drift

**Problem:** Factories for tenant-scoped models auto-create their own parent via relationship factories. When testing scoped endpoints, the factory's auto-created parent differs from the test's scoping model, causing "0 results found" assertions.

**Detection:** In changed test files creating scoped-model factories, check that the scope FK (e.g., `team_id`, `organization_id`, `site_id`) is explicitly passed pointing to the test's scoping model.

```bash
# Flag: factory()->create() without scope FK in a test that defines a scoping model
grep -n 'factory()->create()' tests/ --include='*.php' | grep -v '_id'
```

**Fix:** Always pass the scope FK explicitly: `ScopedModel::factory()->create(['tenant_id' => $tenant->id])`.

## Audit Cross-Check

If a recent audit report exists, cross-check the implementation against it. Use SID-aware lookup per `_v-core.md` — filter by session ID when checking for current session's audit, use unfiltered glob only for cross-session comparison:

```bash
# Find most recent audit from THIS session first, then fall back to any recent audit
SID="${CLAUDE_SESSION_ID:-}"
LATEST_AUDIT=$(ls -t .v/artifacts/AUDIT_REPORT_*${SID}*.md AUDIT_REPORT_*${SID}*.md 2>/dev/null | head -1)
if [ -z "$LATEST_AUDIT" ]; then
  LATEST_AUDIT=$(ls -t .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md .v-ecosystem-review/*.json 2>/dev/null | head -1)
fi
```

If found:
1. Read the audit's findings that overlap with changed files
2. Verify the implementation didn't reintroduce a previously-flagged issue
3. Flag any regression as `severity: critical` with reference to the original finding ID
4. Note in the report: "Cross-checked against [audit file] — no regressions found" or list regressions

## Agent Dispatch

**Ownership check:** If a semantically completed `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md` already exists (the orchestrator or v-build already ran agent review this session), skip dispatch and cross-reference the existing review's findings against changed files instead. "Semantically completed" here means the artifact shows executed `codex-adversarial-reviewer` or `superpowers:requesting-code-review` fallback provenance, includes the hostile-focus marker when required, and does not contain degraded self-review language. Only dispatch agents when invoked standalone or when no prior valid agent review artifact exists.

**When dispatching:** Always dispatch agents when an agents directory exists — not just for security changes. Agents catch AI-specific mistakes (lazy loading, `any` types, broken Inertia contracts) that grep checks miss.

**Agent directory lookup order** (project-level takes precedence):
1. `.claude/agents/` (project-level, relative to repo root)
2. `~/.claude/agents/` (global, user home directory)

```bash
ls .claude/agents/*.md 2>/dev/null || ls ~/.claude/agents/*.md 2>/dev/null && echo "AGENTS_AVAILABLE"
```

Follow the Agent Dispatch Protocol in `_v-review.md` from the active skill tree for agent selection and worktree-isolated review behavior.

Follow `_v-review.md` § Agent Dispatch Protocol for codex-adversarial-reviewer dispatch and superpowers:requesting-code-review fallback. Elevate to hostile adversarial focus when changed files touch auth, payments, data deletion, encryption, file upload, or external input handling.

## Output

Write `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md` (AI-only artifact; structured YAML inside markdown). Console summary remains for operator visibility.

### MANDATORY ARTIFACTS — Stop hook enforces TWO files from this session

The Stop hook (`check-review-artifact.sh`) blocks session completion unless BOTH of these exist at repo root and pass structural validation:

1. `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md` — this skill's convention-check report. Hook adds a BLOCKING_ISSUES entry "VERIFY_DONE_REPORT not found for this session — run /v-verify-done" if missing or invalid (per AVF-004 structural validation).
2. `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md` — the adversarial review dispatched in Step 5 (codex-adversarial-reviewer or superpowers fallback). Both presence AND semantic completion are checked (a `Status:` line in the first 20 lines whose first word resolves to `completed`/`pass`/`passed`/`approved` — `hooks/lib/validation.sh` § validate_review_semantics; `complete` alone does NOT match).

Rules (mirror v-build § MANDATORY FINAL ARTIFACT):

- Both filenames are exact: prefix + session id + `.md`. No variants.
- Both files MUST live at the repository root.
- A summary in chat is NOT a substitute — call the `Write` tool for each.
- Headless mode does NOT relax these gates (per AVF-002 — headless has MORE checking, not less, because no human is watching).
- When the diff touches auth, payments, data deletion, encryption, file upload, or external input handling, the hook also requires a `Hostile adversarial focus: yes` line in `AGENT_REVIEW` (exact field name — `hooks/lib/validation.sh` greps `Hostile adversarial focus:`; see `_v-review.md` § Agent Dispatch Protocol). Missing → session completion blocked; `wip:` commit messages are not exempt.
- Skipping the agent dispatch in Step 5 → no AGENT_REVIEW → blocked.
- Skipping VERIFY_DONE_REPORT writeback → blocked even if AGENT_REVIEW is present.

**File template** (canonical — identical contract to `v/references/dispatch-v-verify-done.md` § Required Output Format and `_v-artifact-formats.md`; the Stop hook parses THIS shape, so do not improvise. ND-0716: this section previously taught a `status: pass|fail` YAML schema the hook never read — a standalone run writing `status: fail` sailed through as a silent PASS. The ONLY fail signal the hook recognizes is the literal final line `Overall Verdict: FAIL`.)

PASS example:

```markdown
Model: <model that ran this check — haiku on the standard dispatch path>
SID: ${CLAUDE_SESSION_ID}
Mode: <full | scoped(writes-log) | scoped(commit-witness) | scoped(fallback-git-state) | scoped(fallback-git-state:no-isolation) | scoped(postmerge-reverify:...) | user-owned-maintenance>
Changed: <N — integer count of changed files>

## Checks

#### FND-001 | app/Models/User.php:42 | low | high
Missing @property-read annotation for new auditLogs relationship.
fix: add @property-read Collection<int, AuditLog> $auditLogs to the docblock.

(Repeat per finding, sorted critical → high → medium → low; ALL severities reported, no
filtering. Severity vocabulary is `critical/high/medium/low` per
`~/.claude/skills/references/v-core-severity.md` (= P0–P3). If no findings, state
`No findings.` under the header — never leave the section silently empty.)

## Summary
critical:0 high:0 medium:0 low:1

Overall Verdict: PASS
```

FAIL example (any unresolved critical/high convention violation, or a post-merge
re-verify range that was empty/unresolved — Item 10 contract):

```markdown
Model: haiku
SID: ${CLAUDE_SESSION_ID}
Mode: scoped(writes-log)
Changed: 3

## Checks

#### FND-001 | app/Services/FeatureFlags.php:42 | critical | high
Hardcoded API key (sk_live_*) committed in service class.
fix: move to env, retrieve via config('services.flags.key').

## Summary
critical:1 high:0 medium:0 low:0
Reason: unresolved critical convention violation — do not complete until fixed.

Overall Verdict: FAIL
```

**Format rules (hook contract — `check-review-artifact.sh` + `hooks/lib/validation.sh`):**
1. Final non-empty line is EXACTLY `Overall Verdict: PASS` or `Overall Verdict: FAIL` — no bold, no parenthetical. This line is the hook's ONLY pass/fail signal; a `status:` field anywhere is ignored by the hook.
2. `Model:` within the first 5 lines; `Mode:` and `Changed: <integer>` within the first 12 (W52/W53 contract — do NOT collapse `scoped(writes-log)` to bare `scoped`).
3. H2 section header exactly `## Checks` (or `## Verification`) — NOT `## Findings`/`## Review` (those are AGENT_REVIEW headers).
4. `## Summary` H2 with severity counts.
5. Findings use `_v-review.md` FINDING_FORMAT (`#### FND-NNN | file:line | severity | confidence`, description, `fix:` line).
6. A convention FAIL is reported via `Overall Verdict: FAIL` — never by weakening or omitting findings.

Console summary:

```
========================================
  VERIFY-DONE RESULTS
========================================

Changed Files ({N} files):
  app/Services/NewService.php
  resources/js/Pages/NewPage.tsx
  database/migrations/2026_02_28_create_foo.php

Issues Found:

  [CRITICAL] TypeScript `any` type
    NewPage.tsx:15 — Replace `: any` with `Record<string, unknown>`

  [WARNING] Missing factory
    Expected: database/factories/NewModelFactory.php

Checks Passed:
  [PASS] No TODO/FIXME/HACK markers
  [PASS] Inertia page contracts valid
  [PASS] Route middleware correct
  [PASS] Ziggy routes up to date  # Laravel+Ziggy only
  [PASS] No Mockery identity traps
  [PASS] No Queue::fake + side-effect conflicts
  [PASS] Factory FKs explicitly scoped

Summary: {N} critical, {N} warnings, {N} passed
========================================
```

## Progress Checklist (copy into your response, check off as you go)

```markdown
## Verify-done progress

Mirror the section headers from this skill's body workflow (the 7 convention checks documented below) into your response — one checkbox per ### Step / ### Phase / ### Gate as you progress. The body workflow is the single source of truth for what gates exist; treat the checklist as a render of THAT structure, not a parallel definition.

Example (replace with your actual sections as you go):
- [ ] Step 1: <skill-specific name>
- [ ] Step 2: <skill-specific name>
- ...
- [ ] Final: <output artifact written>
```

This avoids drift between the checklist and the body workflow when the body changes — only one source of truth (the body's `### Step N:` headers) needs to stay current. Operator-facing visibility comes from the AI rendering the actual current sections into its response, not from a hard-coded duplicate.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Lazy-loading violation in tests but verify-done passes | Convention check ran on production code only, not tests | Lazy-loading violation check applies to ALL .php/.tsx files including tests; tests reveal the violation at runtime |
| 2 | DOMPurify check passes despite `dangerouslySetInnerHTML` because string isn't quoted | Regex match too narrow | Match `dangerouslySetInnerHTML` regardless of how the value is constructed; presence of the prop = required `sanitizeHtml()` call upstream |
| 3 | Inertia page contract check passes despite missing component _(Laravel+Inertia only)_ | File-existence check used wrong path | Path is `resources/js/Pages/<exact-Inertia::render-arg>.tsx` — case-sensitive, must match render arg precisely |
| 4 | AI-test-anti-pattern check misses `expect(true).toBe(true)` style placeholders | Pattern catalog out of date | `~/.claude/skills/references/v-tdd-anti-patterns.md` contains the canonical list; update there, not here |
| 5 | Run after pre-flight reports DEGRADED but verify-done says PASS | Verify-done shouldn't run on degraded pre-flight | Verify-done MUST check for `PRE_FLIGHT_REPORT` from same session; if degraded/failed, abort with instruction to fix pre-flight first |
## Laravel+Cashier: Query-Count Convention Check (Eager-Loading Enforcement)

> **Applies to: Laravel stacks only.** Skip entirely if `STACK_PHP` is not detected. The Cashier-specific sub-check (2a) additionally requires Laravel Cashier (`laravel/cashier` in `composer.json`).

For Laravel + Inertia projects (per operator CLAUDE.md), every changed
controller/service/job that touches a model with relationships MUST be
checked for eager-loading violations. This is a convention check, not a
deterministic gate — flag with judgment, recommend `/v-build` to fix.

**Detection (run during convention-check phase on staged + unstaged
+ untracked PHP files):**

```bash
# 1. Find controller actions / service methods touched in this changeset
# Resolve PROJECT_ROOT per _v-core.md § Project Root Detection (mandatory under context:fork)
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$PROJECT_ROOT" ] && { echo "ERROR: cannot detect PROJECT_ROOT — convention check skipped"; exit 0; }

CHANGED_PHP=$(git -C "$PROJECT_ROOT" diff --name-only HEAD -- '*.php' 2>/dev/null; git -C "$PROJECT_ROOT" ls-files --others --exclude-standard '*.php' 2>/dev/null | sort -u)

for f in $CHANGED_PHP; do
  # 2a. Cashier-specific: any call to $user->subscription / subscriptions / subscribed* WITHOUT a prior ->load()
  if grep -qE '\$user->(subscription|subscriptions|subscribedToProduct|subscribedToPrice)' "$f"; then
    if ! grep -qE '->load\([^)]*(subscription|subscriptions)' "$f"; then
      echo "FINDING: $f calls a Cashier relationship without preceding ->load() — eager-load violation per CLAUDE.md Critical Gotchas"
    fi
  fi

  # 2b. General: foreach over $model->relation INSIDE a controller/job (potential N+1)
  # Reduce false-positives: skip if the SAME file has a ->load() or ->with() call on a matching relation
  if grep -qE 'foreach[[:space:]]*\([[:space:]]*\$[a-zA-Z]+->[a-z]+[[:space:]]+as' "$f"; then
    RELATIONS=$(grep -oE 'foreach[[:space:]]*\([[:space:]]*\$[a-zA-Z]+->[a-z_]+' "$f" | grep -oE '>[a-z_]+$' | tr -d '>' | sort -u)
    for rel in $RELATIONS; do
      if ! grep -qE "(->load|->with)\([^)]*['\"]${rel}['\"]" "$f"; then
        echo "ADVISORY: $f has 'foreach (\$X->${rel} as ...)' with no apparent ->load('${rel}')/->with('${rel}') in same file — verify eager-loaded upstream OR add eager-load"
      fi
    done
  fi
done
```

**Pair with v-tdd patterns:** every flagged finding should ship with a
recommendation to add a query-count assertion (per `v-tdd § Laravel
Query-Count Assertions`) so the violation can't regress silently.

**Confidence calibration:** Cashier-relationship violations are `high`
confidence (mandated by CLAUDE.md). General foreach-over-relation
violations are `medium` confidence (could be acceptable if the relation
was eager-loaded upstream — reviewer must verify).

## Idempotency

**Idempotent.** Read-only convention check — produces a fresh VERIFY_DONE_REPORT with no mutations.
