---
name: v-build
description: "Use when executing an existing plan and writing implementation code."
argument-hint: "[PLAN_*.md, AUDIT_REPORT_*.md, REFACTOR_PLAN_*.md, or a raw prompt]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, TaskCreate, TaskUpdate, AskUserQuestion, mcp__plugin_context7_context7__resolve-library-id, mcp__plugin_context7_context7__get-library-docs
user-invocable: false
disable-model-invocation: true
context: fork
model: sonnet
---
<!-- skill: v-build | version: 1.0.5 | last-updated: 2026-08-12 -->
<!-- line-count exception (~722 body lines vs 500 target, >700 ceiling): already 69% extracted —
     6 reference files carry 1608 lines. The inline remainder is the pack-consumption
     contract and scope guard, which callers depend on being present verbatim.
     Documented-exception route, v-anthropic-2026-standards §1 row 6. -->


# 2026 Canonical Contract

Tier: Orchestration primitive. **Orchestrator-only — not user-invocable.** Reached via `/v` (natural language or a `PLAN_*.md`/`AUDIT_REPORT_*.md` artifact reference); start with `/v` or `/v-plan`.

Follow `_v-core.md`, `_v-exec.md`, `_v-growth.md`, `_v-review.md` (for agent adjudication), `_v-design.md` (for UI tasks), `_v-jobs.md` (for async patterns), `_v-api.md` (for API endpoints), and `_v-security.md` (for security compliance).

For worktree operations, read `~/.claude/skills/references/v-exec-worktree.md` and `~/.claude/skills/references/v-exec-worktree-lifecycle.md`.
For TypeScript errors, read `~/.claude/skills/references/v-exec-typescript.md`.
For changed file detection, read `~/.claude/skills/references/v-core-changed-files.md`.
For cross-session learning, read `~/.claude/skills/references/v-core-cross-session.md`.
For pre-existing failures, read `~/.claude/skills/references/v-core-pre-existing.md`.
For user-owned maintenance scope, read `~/.claude/skills/references/v-core-maintenance.md`.
For database migration design, execution, testing, and rollback patterns, read `~/.claude/skills/v-build/references/v-migration-lifecycle.md`.
For feature flag naming, lifecycle, monitoring, and cleanup patterns, read `~/.claude/skills/v-build/references/v-feature-flag-lifecycle.md`.

**Safeguard architecture:** Hooks mechanically enforce the safeguards (migration safety, secret detection, format, type-checking, uncommitted-file gates); this skill owns the parts that need judgment — execution flow, TDD discipline, and build integrity.

Step 0: Resolve project root per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from invocation prompt if present, else `git rev-parse --show-toplevel`; if that does not yield a safe repo root, stop and ask for PROJECT_ROOT explicitly. Do not fall back to `pwd`.

## Skill Boundaries

**SME persona:** This skill is run by a **senior full-stack engineering tech lead** — specialty is converting plans + audit findings into production-quality code via TDD, dispatching domain-specialist personas (security / payments / database / async / integrations / API / designer) at the right moments, and gating delivery through self-review + adversarial agent review. The skill embodies a tech lead's discipline: ship the change, ship the tests, ship nothing else.

### Best fit

- Implementing a known plan (`PLAN_*.md`) or remediating an audit-generated finding (`AUDIT_REPORT_*.md`)
- TDD-driven backend changes (services, jobs, controllers, models) where red→green→refactor is the discipline
- 1–3 file features with a clear problem statement and acceptance criteria
- Bug fixes with a known root cause where the next step is "write the failing test, then fix"

### Use instead

- `/v` (orchestrator) — when unsure whether the work is a bug-fix, feature, audit, or refactor; auto-routes to the right skill
- `/v-plan` — when scope is >3 files OR the problem statement is fuzzy; design the plan first
- `/v-tdd` directly — only when stopping AFTER red (just want a failing test skeleton). v-build internally calls v-tdd for the red phase before continuing to green/refactor; redirecting to v-tdd loses the green/refactor path.
- `/v-new-feature` — for greenfield features ≥4 files with no existing plan
- `/v-audit-code` — for structure-only changes with zero behavior change (absorbed `/v-refactor` 2026-07-06)
- `/v-check` — to merge and push after implementation completes

### Not for

- Pure refactors (no behavior change, no new tests) — use `/v-audit-code`
- Cosmetic UI polish without a plan — use `/v-polish` (or `/v` for routing)
- Bug investigation where the cause is unknown — fix root-cause first, then call this skill
- Audits or analysis-only requests — use the relevant `v-audit-*` skill or `/v-check`
- Operating on a stale plan or audit (>30 days old) — re-run the audit first

## Headless Implementation-Only Mode

If `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1` is present in the environment, this session is a runner-managed remediation execution. In this mode:
- implement the scoped changes through step 7 only
- do **not** invoke `/v-pre-flight`, `/v-verify-done`, `/v-polish`, or agent review from inside `v-build`
- do **not** read `/v-pre-flight/DISPATCH_PROMPT.md`, `/v-verify-done/DISPATCH_PROMPT.md`, or any review dispatch prompt
- do **not** use the `Agent` tool, the `Task` tool, or spawn subagents anywhere in this session
- do **not** launch background tasks or deferred review/gate workflows
- do **not** write `PRE_FLIGHT_REPORT_*`, `AGENT_REVIEW_*`, or `VERIFY_DONE_REPORT_*` from this session; only `IMPLEMENTATION_REPORT_*` is allowed
- do **not** run `/commit`, `git add`, or `git commit`; the external runner owns unstaged changes and any later git operations
- after step 7, **call the `Write` tool** to create `.v/artifacts/IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md` (Phase-2: under `.v/artifacts/` — create the dir via `~/.claude/skills/v/references/v-artifact-dir.sh`) with finding disposition, files changed, and lightweight checks run. Writing only a chat summary is insufficient — the runner's Stop hook checks the filesystem for this file (dual-search: `.v/artifacts/` then the repo root) and reverts every change if it is missing. Do this BEFORE you end the session.
- treat all post-implementation gates as owned by the invoking runner, not this skill session
- this mode overrides every later instruction in this file that mentions `/v-pre-flight`, `/v-verify-done`, `/v-polish`, agent review, dispatch prompts, or the `Agent` tool

### MANDATORY FINAL ARTIFACT — Stop hook enforces this

When headless implementation-only mode is active, your last action before stopping MUST be a `Write` tool call creating this exact file under `<repo_root>/.v/artifacts/` (Phase-2; resolve the dir via `~/.claude/skills/v/references/v-artifact-dir.sh`):

```
IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md
```

Minimum content skeleton:

```markdown
# Implementation Report
Session: ${CLAUDE_SESSION_ID}

## Specs consumed
- <PRICING_SPEC_*.md / CONTENT_SPEC_*.md / MARKETING_DESIGN_SPEC_*.md path or "none — raw plan only">

## Personas engaged
- <persona name>: <triggering files / path patterns>
  - Failure mode anticipated: <description>
  - Test written first: <path or "covered by existing">
  - Reference applied: <persona-lens.md section / project rule>

## Findings addressed
- <finding-id>: <fixed | stale> — <files touched>

## Files changed
- <path/to/file>

## Lightweight checks run
- <pint | typecheck | affected tests> — <result>
```

Hard rules:
- The file MUST live under `<repo_root>/.v/artifacts/` — where `<repo_root>` is `git rev-parse --show-toplevel` (resolve via `~/.claude/skills/v/references/v-artifact-dir.sh`, which also creates the dir). NOT a worktree-only path and NOT `~/.claude`. (Legacy: a bare `<repo_root>/IMPLEMENTATION_REPORT_*.md` still satisfies the Stop hook via dual-search, but write to `.v/artifacts/`.)
- Filename prefix MUST be the literal string `IMPLEMENTATION_REPORT_` followed by your session id and `.md`. No other variants.
- A Stop hook (`check-review-artifact.sh`) reads the filesystem on session exit via dual-search (`.v/artifacts/` first, then the repo root). Missing or mismatched filename → exit 86, every change reverted, prompt quarantined as `missing_or_invalid`.
- A summary in chat is NOT a substitute. Call the `Write` tool.

Rules:
- **Pre-execution semantic validation:** Before executing plan items, scan the plan for red-flag patterns that require the session's single allowed clarification question only when the item is destructive/security-sensitive and cannot be made safe by narrowing scope:
  1. Any plan item that **disables auth, middleware, or validation** (keywords: `withoutMiddleware`, `->except(`, `$this->middleware->except`, `without auth`, `skip validation`, `disable csrf`, `skipAuthorization`, `forgetMiddleware`, `withoutValidation`, `disableCSRF`, `withoutGlobalScopes`, `unguarded`, `forceDelete`)
  2. Any plan item that **creates debug/admin endpoints** not mentioned in the plan's Summary section (keywords: `debug`, `admin/debug`, `test endpoint`, `bypass`)
  3. Any plan item that **modifies .env files or security configuration** (keywords: `.env`, `APP_KEY`, `encryption`, `session config`)
  If any red-flag pattern is found in orchestrator/headless mode, do not prompt-loop. Either narrow to the safe subset and continue, or write `BUILD_BLOCKER_${CLAUDE_SESSION_ID}.md` / `BLOCKED_${CLAUDE_SESSION_ID}.md` with the exact item that needs human authorization. In direct interactive mode, this may consume the single allowed early `AskUserQuestion`.
- Validate against the shared `PLAN_SCHEMA` before executing
- Do not execute against an under-specified plan
- Run `/v-pre-flight` for all quality gates
  Only once after implementation/review-fix cycles, and only when `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY` is not `1` and `V_DEPTH == 0`.
- call `v-polish` after implementation if UI files changed (`.tsx`, `.jsx`, `.css`, `.html`)
  Only when `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY` is not `1` and `V_DEPTH == 0`. When `V_DEPTH >= 1`, the orchestrator owns polish invocation after `v-build` returns at the ownership boundary.
- call `v-verify-done` after execution
  Run `/v-verify-done` for deep validation of changed files. Only when `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY` is not `1` and `V_DEPTH == 0`.
- use `v-tdd` when backend logic requires a red phase
- **`git stash` is forbidden** — enforced by `worktree-safety.sh` hook. Use `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md` or `/v-handoff` for durable progress tracking while gates are still outstanding. Only rely on git commits after the live pre-commit gate requirements are satisfied.
- **Agent review:** Only when `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY` is not `1` and `V_DEPTH == 0`, follow `_v-review.md` § Agent Dispatch Protocol for codex-adversarial-reviewer dispatch and superpowers:requesting-code-review fallback. Elevate to hostile adversarial focus when diff touches auth, payments, data deletion, encryption, file upload, or external input handling.
- **User-owned maintenance:** If the raw prompt is confined to the paths allowed by `~/.claude/skills/references/v-core-maintenance.md`, do not escalate into feature planning or repo-wide exploration. Use a compact inline checklist, keep edits inside allowed roots, edit canonical skills before mirrors, and leave `/v-pre-flight` + hostile review to the caller when implementation-only mode is active.

```yaml
contract:
  tier: orchestration-primitive
  accepts: [PLAN_*.md, AUDIT_REPORT_*.md, REFACTOR_PLAN_*.md, raw prompt]
  produces: [IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md, BUILD_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md]
  invokes: []
  conditional-invokes: [/v-pre-flight (user-invoked only), /v-verify-done (user-invoked only), /v-tdd (backend logic tasks), /v-polish (user-invoked only — never when orchestrator owns flow), /interface-design (new app UI without tokens), /v-marketing-design (new marketing surface without tokens or missing Marketing Surfaces section)]
  invoked-by: [/v, user]
  estimated_tokens: 30k-100k
  estimated_duration: 5-30 min
```

**Accepts:** `PLAN_*.md`, `AUDIT_REPORT_*.md`, `REFACTOR_PLAN_*.md`, or raw prompt (see Entry Point)

Outputs:
- `IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md`
- `BUILD_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md` (on failure)

---

## Entry Point

### Remediation Invocation Mode (highest priority)

If the invocation prompt contains `CLAUDE_ECOSYSTEM_RUNNER=1` **or** `EXECUTION_MODE=implementation-only` **or** `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1`, **and** the prompt body contains any of:
- a `Findings:` block
- a `Target files:` block
- the phrase `Implement the accepted findings below`
- a `Source skills:` block

…then the invocation prompt **IS the raw prompt**. Enter **Raw Prompt Mode** immediately using the invocation body as the task source. The remediation runner does NOT pre-stage a SID-qualified `AUDIT_REPORT_*`, `PLAN_*`, or `REFACTOR_PLAN_*` on disk for these subagent sessions, so **DO NOT run the programmatic fallback disk lookup (`ls -t AUDIT_REPORT_*${CLAUDE_SESSION_ID}*.md …`)** and **DO NOT emit "no plan, audit, or refactor artifacts exist / no raw prompt was provided."** The raw prompt IS the invocation body — its target files, findings, scope, and acceptance criteria are all inline.

This branch takes precedence over every other Entry Point path, including the programmatic orchestrator fallback further down in this file.

### Raw Prompt Mode (general case)

If invoked with a raw prompt (no plan file), enter **Raw Prompt Mode**:
1. Create an inline plan using **all** `PLAN_SCHEMA` core headings: Summary, Scope, Files, Tests Required, Acceptance Criteria, Rollback Notes. **Validation:** Before proceeding, verify all six headings are present. If any are missing, add them — an under-specified inline plan is not executable.
2. For medium scope or larger: write `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` before execution
3. Proceed with TDD execution flow

**Raw Prompt Mode non-goals:**
- do not use raw prompt mode for docs generation, broad audits, or refactor-analysis requests that should route to `/v-docs`, `/v-check`, or `/v-audit-code`
- do not expand small user-owned maintenance prompts into repo-wide planning when `~/.claude/skills/references/v-core-maintenance.md` keeps them narrow
- do not treat scaffolding-only requests as generic build work when `/v-scaffold` is the better fit

### User-Owned Maintenance Fast Path

When the raw prompt targets only the allowed roots in `~/.claude/skills/references/v-core-maintenance.md`, use a lighter execution path:
- keep the checklist inline unless the maintenance change is ambiguous or phased
- do not create a PLAN artifact just because multiple maintenance files are involved
- forbid edits in `.codex`, plugin cache, plugin marketplaces, or mirror/generated paths unless the only mirror writes are an explicit post-test sync from canonical files
- run targeted tests first, then rerun the touched suite
- pass the reduced-scope context into `/v-pre-flight` and `/v-verify-done`

This is a lower-ceremony path, not a lower-safety path.

If no plan and no raw prompt, ask:

**Auto-detection sequence** (no question asked in the common case):

1. Look for SID-qualified artifacts in current session:
   `ls -t .v/artifacts/AUDIT_REPORT_*${CLAUDE_SESSION_ID}*.md AUDIT_REPORT_*${CLAUDE_SESSION_ID}*.md .v/artifacts/PLAN_*${CLAUDE_SESSION_ID}*.md PLAN_*${CLAUDE_SESSION_ID}*.md .v/artifacts/REFACTOR_PLAN_*${CLAUDE_SESSION_ID}*.md REFACTOR_PLAN_*${CLAUDE_SESSION_ID}*.md 2>/dev/null | head -5`

2. If exactly ONE candidate found → proceed silently with that artifact.

3. If MULTIPLE candidates found (rare — operator ran multiple plan/audit cycles in same session) → choose the SID-qualified candidate first; otherwise use the most recent candidate and record the assumption.

4. If ZERO candidates in current session → look for cross-session most-recent:
   `ls -t .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md .v/artifacts/PLAN_*.md PLAN_*.md .v/artifacts/REFACTOR_PLAN_*.md REFACTOR_PLAN_*.md 2>/dev/null | head -5`. Same logic: 1 → silent, multiple → most recent with assumption, zero → write `BUILD_BLOCKER_${CLAUDE_SESSION_ID}.md`.

**Execution mode (interactive only):** When V_DEPTH == 0 (operator invoked v-build directly) and `--mode=` is not in the invocation prompt, use the session's single allowed early AskUserQuestion if available. If unavailable, default to Autonomous:

```yaml
question: "Execution mode for this build?"
header: "Build Mode"
multiSelect: false
options:
  - label: "Autonomous"
    description: "Execute all plan items (P0/P1/P2) end-to-end with checkpoints at major sections. Standard build mode."
  - label: "P0-only"
    description: "Execute only P0 (must-fix / blocking) items. Skip P1/P2 — use when shipping fast or scoping a follow-up batch."
```

When V_DEPTH >= 1 (orchestrator-invoked or headless), use the explicit `--mode=` from the invocation prompt; if absent, fall back to Autonomous (the documented headless default). If `--mode=autonomous|p0-only` is passed in the invocation prompt, skip the question and proceed accordingly.

**The single question (only when auto-detection finds multiple candidates):**

```yaml
question: "Which artifact should I implement?"
header: "Source"
multiSelect: false
options:
  - label: "{most-recent AUDIT_REPORT path}"
    description: "{brief from front-matter or first heading}"
  - label: "{next AUDIT_REPORT or PLAN}"
    description: "{...}"
  - label: "{REFACTOR_PLAN if present}"
    description: "{...}"
  - label: "Describe inline (no file)"
    description: "I'll describe the work in the next prompt; you plan inline then build"
```

If only ONE candidate artifact exists, no question is asked — proceed with that artifact silently.

**Programmatic fallback (when invoked by orchestrator):** Auto-detect source from most recent SID-qualified artifact: `ls -t .v/artifacts/AUDIT_REPORT_*${CLAUDE_SESSION_ID}*.md AUDIT_REPORT_*${CLAUDE_SESSION_ID}*.md .v/artifacts/PLAN_*${CLAUDE_SESSION_ID}*.md PLAN_*${CLAUDE_SESSION_ID}*.md .v/artifacts/REFACTOR_PLAN_*${CLAUDE_SESSION_ID}*.md REFACTOR_PLAN_*${CLAUDE_SESSION_ID}*.md 2>/dev/null | head -1`. Falls back to cross-session glob only if no SID match found. Always use Autonomous mode.

**Exception — Remediation Invocation Mode takes precedence:** This disk-lookup fallback does NOT apply when the invocation prompt matches the **Remediation Invocation Mode** trigger at the top of the Entry Point section (orchestrator env flag + inline `Findings:` / `Target files:` / `Source skills:` content). In that case the invocation body IS the source; do not run this `ls` command and do not report "no plan / no raw prompt." The ecosystem remediation runner does not pre-stage SID-qualified `AUDIT_REPORT_*` / `PLAN_*` / `REFACTOR_PLAN_*` files on disk for subagent sessions — it delivers the task inline in the invocation prompt.

---

## Execution Flow

```
1.  Read plan document
1a. **Discover sibling SPEC artifacts.** Design skills (`/v-pricing-design`, `/v-content-create`, `/v-marketing-design`) emit implementation-ready spec files alongside their strategy docs. If any of these are SID-qualified for the current session OR exist as the most-recent unqualified spec, read them in addition to the plan and treat their measurements/values/specifications as authoritative for implementation:
    ```bash
    # SID-qualified SPEC artifacts (preferred)
    ls -t PRICING_SPEC_*${CLAUDE_SESSION_ID}*.md CONTENT_SPEC_*${CLAUDE_SESSION_ID}*.md MARKETING_DESIGN_SPEC_*${CLAUDE_SESSION_ID}*.md 2>/dev/null
    # Fallback: most-recent unqualified SPEC if SID-qualified absent
    ls -t PRICING_SPEC_*.md CONTENT_SPEC_*.md MARKETING_DESIGN_SPEC_*.md 2>/dev/null | head -3
    ```
    If a SPEC is found, log `spec_consumed: [path]` in IMPLEMENTATION_REPORT and use the SPEC tables (price values, layout measurements, section word counts, etc.) verbatim — do not re-derive from the strategy narrative. SPEC values supersede strategy-doc values on conflict; strategy is the *why*, SPEC is the *what*.
2.  Detect stack (React/Livewire/Blade)
2a. **Design token loading (UI tasks only):** If the plan involves UI files
    (.tsx, .jsx, .css, .vue, .svelte), apply the design system per
    `_v-design.md` § Design System Application Order. The canonical token set
    is the design system for ALL products — there is no per-project token
    discovery. All generated UI code MUST use the canonical tokens for colors,
    spacing, and the fixed border+shadow depth system. If
    `.interface-design/system.md` exists, read it as the per-product OVERLAY
    only — it supplies `--accent`, category `-bg`/`-text` pairs, branding, and
    domain components; it cannot override palette, typography, spacing, or
    components. Locate the token implementation (`:root` / Tailwind v4
    `@theme` block) to verify conformance and know which file to edit. If the
    canonical tokens are absent or off-spec, invoke the appropriate design
    skill to install the canonical `:root` + `html[data-theme="light"]`
    blocks:
    - **App UI** (dashboards, admin, settings, tools): invoke `/interface-design`
    - **Marketing surfaces** (landing pages, pricing pages, blog layouts,
      campaign pages, any public-facing marketing page): invoke `/v-marketing-design`
    - **Detection:** classify target files by path — files matching `*landing*`,
      `*pricing*`, `*marketing*`, `*campaign*`, `*welcome*`, `*home*`, `*blog*`
      (layout, not content), `*about*`, `*features*` (public page), `*contact*`,
      `*faq*` are marketing surfaces; all others are app UI. Disambiguate
      compound names using plan context (e.g., `marketing-dashboard.tsx` is
      app UI, not a marketing page). (Canonical glob list lives in
      `_v-design.md § Context Sensitivity Matrix` — keep in lockstep with it
      and with v-plan's marketing-detection glob.)
    Do NOT proceed with framework defaults or raw-palette colors for new UI —
    the spec always wins. If `.interface-design/system.md` exists but lacks a
    `## Marketing Surfaces` section and the current task targets marketing
    pages, invoke `/v-marketing-design` to add the marketing governance layer.
    If modifying existing UI, conform to the canonical set (do not copy
    off-spec values from neighboring components) and log
    `design_tokens: canonical` in IMPLEMENTATION_REPORT.
    **Persona stamp (UI):** Based on the marketing-vs-app classification above,
    engage the matching designer persona for all UI work this session — Senior
    brand designer (marketing surfaces) or Senior product designer (app UI). If
    a single page mixes marketing layout with interactive form behavior (e.g.,
    pricing page with plan-selector form), engage both. Read
    `~/.claude/skills/references/persona-lens.md` § Designers for the 3-question engagement
    protocol and mindset cues to apply during Step 6 implementation and the
    Step 7b craft check. Log engaged personas in IMPLEMENTATION_REPORT.
3.  **Detect if running inside a worktree** (git worktree list — record original branch for merge-back)
    - **Orphan worktree check:** If `git worktree list` shows worktrees with missing directories (prunable), log a warning: `orphan_worktree: [path]`. Auto-run `git worktree prune` to clean up orphans (safe operation — only removes stale bookkeeping for already-deleted directories).
    - Note: Worktree lock files expire after 4 hours per _v-exec.md; verify active session ownership
4.  Verify starting state is clean (code compiles, no syntax errors). Do NOT run the full test suite here — the test failure baseline is captured at pre-flight time per `~/.claude/skills/references/v-core-pre-existing.md`.
4a. **Cross-session learning:** Check for prior session artifacts per `~/.claude/skills/references/v-core-cross-session.md`. If recent BUILD_BLOCKER or PROGRESS_NOTE files exist, read them and apply context to avoid repeating known failures.
4b. **Incident/hotfix context:** If the plan or raw prompt indicates a production incident or urgent hotfix, read `~/.claude/skills/v-build/references/v-incident-response.md` for triage, diagnosis, and minimal-scope fix guidance. Hotfixes prioritize speed over ceremony — see the reference for which steps can be abbreviated.
5.  Create the task list (one `TaskCreate` per step; `TaskUpdate` on each transition)
5a. **SaaS safeguard pre-check + persona engagement:** Before executing any tasks, scan the plan for SaaS-sensitive triggers (see SaaS-Specific Safeguards section below). If any trigger matches, note the required action on the relevant todo items BEFORE starting implementation. **At the same time, stamp the matching senior persona on each relevant todo:** billing/Stripe/Cashier → Senior payments engineer; auth/sessions/encryption/CSRF/file-upload → Senior security engineer; migrations/schema changes → Senior database engineer; queued jobs (`ShouldQueue`) and incoming webhooks → Senior async engineer; external API client (HTTP::, Guzzle, vendor SDK) → Senior integrations engineer; new public API endpoint (`routes/api.php`, `app/Http/Controllers/Api/*`) → Senior API engineer; destructive ops (`forceDelete`, `::truncate`, mass `->delete()`) → Senior data engineer (destructive ops); explicit perf-critical path called out in the plan → Senior performance engineer. If 2+ personas match a single todo, engage all (cap at 3 — if 4+ would engage on one todo, the change is too cross-cutting; recommend splitting via `/v-plan` and stop). If zero match, the implicit Senior full-stack engineer applies. Read `~/.claude/skills/references/persona-lens.md` for the 3-question engagement protocol and per-persona mindset cues. This prevents discovering safeguard violations at review time after code is already written.
6.  For each task:
    a. Read target file
    b. Write test FIRST (TDD for backend logic; test-after acceptable for UI)
    c. Watch test fail (red)
    d. Implement minimal code to pass
    d2. For UI implementation: verify new components use the canonical tokens
        (no hardcoded hex, no non-semantic Tailwind colors, and the fixed
        border+shadow system — 1px `var(--border)` on containers plus the two
        shadow tokens). This is a code-time check, not a post-hoc audit.
    e. Watch test pass (green)
    f. Mark todo complete
7.  JiT test gap analysis on diff (see section below)
7a. **Adversarial self-review:** Read every function you wrote or modified in this session. Use the worktree-aware diff from `~/.claude/skills/references/v-core-changed-files.md` (`git diff $MERGE_BASE..HEAD` in worktrees, `git diff HEAD` otherwise) — never rely on memory. For each function, answer these 5 questions:
    1. **What happens when the input is null, empty, or missing?** (missing request params, null model relationships, empty collections)
    2. **What happens at boundary values?** (zero, negative, max-int, empty string, array with 10k items)
    3. **What happens under concurrent access?** (two users hitting the same endpoint, race condition on update)
    4. **What happens when the caller is unauthorized?** (wrong user, missing permission, expired token)
    5. **What happens when an external dependency fails?** (database down, API timeout, cache miss, queue full)
    If ANY of these cases aren't handled and the function is on a request path or processes user input, fix it now. Don't just note it — write the guard clause, add the null check, wrap the try-catch.
    This replaces the old grep-for-TODOs approach. Pattern-matching catches surface issues; adversarial reasoning catches the plausible-but-wrong logic that passes tests but fails in production.
    **Mandatory boundary test generation:** For each numerical boundary identified in question 2, write a specific test case with a **manually computed expected value** — do NOT copy the formula from the implementation. For example:
    - Pagination: compute the expected last page independently as `ceil(total / perPage)` and assert against it
    - Array slicing: compute expected indices by hand for edge cases (first, last, empty, single-element)
    - Date boundaries: compute expected values independently (month boundaries, leap years, timezone crossings)
    - Currency/rounding: compute expected cent values by hand, don't reuse the rounding function under test
    The purpose is to break the tautological loop where the same AI writes both the formula and the test. If you compute the expected value independently and it disagrees with the implementation, you've found a bug.

    **Persona lens:** Answer the 5 questions through the lens of every persona engaged in Step 5a / Step 2a. A senior security engineer's "what happens with null input" answer differs from a generalist's; a senior payments engineer's "what happens under concurrent access" answer includes Redis lock contention specifics; a senior database engineer's "what happens at boundary values" answer thinks about lock duration on big tables. Apply each engaged persona's mindset to the 5 questions before moving on.

7b. **Visual craft verification (UI changes only):** If any changed files are UI components (.tsx, .jsx, .vue, .svelte, .css), run the spec-conformance gate against the diff:
    1. **Spec-deviation detection:** Run the checks in `_v-design.md` § Spec-Deviation Detection Table against the changed files (non-canonical fonts, off-mechanism theming, off-scale spacing, non-spec breakpoints, brand-tinted status colors, glassmorphism in app UI, arbitrary z-index, size-only hierarchy).
       - Hardcoded colors: `grep -nE '#[0-9a-fA-F]{6}|rgb\(' [changed files]` — if found outside CSS variable definitions, flag: `hardcoded_color: use canonical tokens instead`
    2. **BLOCK checks:** Run `_v-design.md` § Visual Craft Gate BLOCK Check 1 (hardcoded hex in app UI components) and BLOCK Check 2 (off-mechanism theming — `bg-white`/`text-black` without token semantics, `.dark`-class or media-query-only theming instead of `html[data-theme]`). Any BLOCK match must be fixed before proceeding.
    3. **Typography weight conformance:** Check that changed components use the fixed weight scale (400 body / 500 labels-nav / 600 headings / 700 hero-titles) with at least 2 different font weights in the hierarchy (not just `font-medium` everywhere). Single-weight or off-scale hierarchy is off-spec.
    If any blocker-level patterns found, fix them before proceeding.

    **Persona lens:** Run this verification as the engaged designer persona (Senior brand designer for marketing surfaces, Senior product designer for app UI). Their bar exceeds the mechanical pattern checks — brand persona evaluates hero hierarchy, CTA placement, conversion-funnel coherence, and mobile-first responsive breakpoints; product persona evaluates the six UI states — the canonical set defined in `references/saas-patterns.md § UI state management checklist` (loading, error, empty, optimistic-update, submission, stale-data) — keyboard navigation, focus rings inside Radix, and conformance to the canonical tokens and the fixed border+shadow system.

7c. **Growth hook trigger scan:** After implementation, grep changed files for growth hook triggers per `_v-growth.md`: CTA changes, pricing/billing/checkout modifications, onboarding step changes, lifecycle email additions, referral/sharing flow changes. If ANY trigger matches and the PLAN does not include a `growth_hook` JSON block, warn: `growth_trigger_detected: [trigger_type] in [file] — plan missing growth_hook. Add target_metric, success_event, instrumentation before proceeding.`

## ⚠️ OWNERSHIP BOUNDARY — Orchestrator / Runner Stops Here

**When V_DEPTH >= 1 (orchestrator invoked): STOP. Do NOT execute steps 8-15.**

**When invoked by the `/v` orchestrator:** complete steps 1-7 only (through JiT test gap analysis), then return control. The orchestrator owns steps 8-15 (polish, agent review cycles, canonical pre-flight, merge-back, write report), and from there drives its own cross-skill chain: polish → check → pre-flight → agent review → verify-done. **v-build MUST NOT invoke v-polish, v-pre-flight, v-verify-done, or v-check when called by the orchestrator.** The STOP marker at step 7 is absolute — do not rationalize continuing beyond it.

**When `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1`: STOP after step 7, then write `IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md` and exit.** The remediation runner owns polish → pre-flight → agent review → verify-done outside this session. Do not read gate dispatch prompts and do not use the `Agent` tool before stopping.

**When V_DEPTH == 0 and `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY` is not set to `1`: Continue to steps 8-15 below.** **When invoked directly by user** (e.g., `/v-build PLAN_*.md`): execute the full flow including pre-flight, polish, agent review, fix findings, and merge-back. In this mode only, v-build may invoke v-polish because there is no orchestrator to delegate to.

**How to detect invocation mode:** The invocation prompt contains `[V_DEPTH=` (per `_v-core.md` circular invocation guard). V_DEPTH >= 1 → orchestrator is calling; stop at step 7. `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1` → remediation runner is calling; stop after step 7 and write `IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md` (schema at § MANDATORY FINAL ARTIFACT). V_DEPTH absent/0 and implementation-only mode inactive → user invoked directly; execute the full flow (steps 8-15), and v-build may invoke v-polish since there is no orchestrator to delegate to.
8.  If UI files changed (.tsx, .jsx, .css, .html): run /v-polish for UX refinements. Pass V_DEPTH context: `[V_DEPTH=2, V_CHAIN=/v→/v-build→/v-polish]`
9.  **Agent review cycle 1:** Dispatch per `_v-review.md` § Agent Dispatch Protocol. Report ALL severity levels.
10. **Adjudicate and fix ALL valid findings:** ACCEPT (fix now), MODIFY (fix with adjustments now), or REJECT (document reason). No DEFER.
11. **Agent review cycle 2 (if fixes were applied):** Re-dispatch agent review on the files changed by fixes in step 10, PLUS their direct dependents. To find dependents, grep for files that import/use the changed files:
    ```bash
    # For each file changed by fixes, find files that import it
    for f in $FIX_CHANGED_FILES; do
      CLASS_NAME=$(basename "$f" .php | sed 's/\.tsx$//' | sed 's/\.ts$//')
      grep -rl "$CLASS_NAME" app/ tests/ resources/js/ --include='*.php' --include='*.ts' --include='*.tsx' 2>/dev/null
    done | sort -u
    ```
    This expands the re-review to direct dependents without going full-codebase, catching cross-file regressions introduced by fixes. This catches regressions introduced by the fixes (~15% of fix batches introduce new issues). If cycle 2 finds new issues, adjudicate and fix them. Do NOT dispatch a third cycle — cap at 2 to prevent infinite loops. If cycle 1 had zero ACCEPT/MODIFY findings, skip cycle 2 entirely.

    **AGENT_REVIEW_${CLAUDE_SESSION_ID}.md schema (W25-F17 — UNIFIED with codex-adversarial-reviewer.md).** The hook `~/.claude/hooks/check-review-artifact.sh` + `lib/validation.sh` enforce ONE specific format: line 1 must be `Model: <haiku|sonnet|opus>`, then 7 dash-prefix metadata fields after an H2 header, then `## Findings`. Pass this schema requirement verbatim to whichever reviewer is dispatched (codex-adversarial-reviewer OR superpowers:requesting-code-review fallback) — the validator does NOT accept the YAML-block alternative.

    ```markdown
    Model: sonnet

    ## Agent Review — <session-id>
    - Status: completed
    - Agents directory: <path | "not found">
    - Agents dispatched: codex-adversarial-reviewer | superpowers:requesting-code-review
    - Codex adversarial reviewer: ran — N candidates, N accepted, N rejected | superpowers:requesting-code-review fallback | skipped — file not found | codex-adversarial-reviewer (orchestrator-inline fallback)
    - Hostile adversarial focus: yes — <reason> | no
    - Dispatch mode: foreground | background | orchestrator_inline
    - Review evidence: claude_accepted: N | codex_candidates: N | findings: N

    ## Findings

    [Per-finding entries: CODEX-001, CODEX-002, … OR "No issues found." if empty]

    ## Rejected Findings (not returned as action items)

    [Table of rejected findings with rationale, OR "None." if empty]
    ```

    **Critical structural rules (hook-enforced; mismatches block session completion):**
    1. Line 1 MUST be `Model: <name>` exactly. No leading whitespace, no `#`, no YAML frontmatter ABOVE this line.
    2. The 7 metadata fields MUST be dash-prefixed (`- Status:`, `- Agents directory:`, etc.) on consecutive lines after the H2 — order matters for the validator's grep anchors.
    3. Use `Status:` for the AGENT_REVIEW; do NOT use `Verdict:` (that's PRE_FLIGHT_REPORT format). Confusing the two has caused multiple production blocks.
    4. `## Findings` is the canonical section header. `## Review` is accepted as legacy but emits an ADVISORY warning.
    5. When the diff touches auth / oauth / login / register / password / session / token / billing / payment / stripe / cashier / subscription / checkout / invoice / webhook / upload / storage / encrypt / crypto / secret / sanctum / passport (per `enforce-pre-commit-gates.sh` HOSTILE_REVIEW_PATH_PATTERN), the `- Hostile adversarial focus:` field MUST start with "yes". Missing or "no" blocks completion.
    6. File size >500 bytes recommended (typical structured review naturally exceeds this).
    7. `status: complete` semantic completion check — the literal text `- Status: completed` on its own line counts.

    **Why this format (not the YAML one previously documented here):** the validator at `lib/validation.sh:319` requires `Model:[[:space:]]*(haiku|sonnet|opus)` near the top of the file. A YAML-block schema with `# AGENT_REVIEW` H1 + `session:` + nested YAML did NOT have a `Model:` line and failed validation — observed live 2026-05-11 with multiple sessions having to manually append `Model: haiku` and `Status:` lines to make the artifact pass the Stop hook. This unified format is the single source of truth; both codex-adversarial-reviewer.md and v-build now agree.
12. **[V_DEPTH == 0 only]** **Pre-flight (canonical mechanical gate — runs once, here):** Run `/v-pre-flight` via the fork-compatible subprocess helper, not the Agent tool and not the Skill tool. Emit the prompt with `v-emit-prompt.sh v-pre-flight > "$DISPATCH_FILE"`, then run `v-dispatch-subagent.sh --agent v-pre-flight-runner --prompt-file "$DISPATCH_FILE" --mode capture --artifact "$PROJECT_ROOT/PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md"` (`--prompt-file` is mandatory — the helper exits 2 without a readable one) **If `v-emit-prompt.sh` exits 10 (F7 stack gate: no gate-bearing stack), do NOT dispatch — the report is already written mechanically; pre-flight is complete.** so the haiku runner executes independently even though this skill is `context: fork`. **Always runs**, regardless of whether cycle 2 was triggered — this is the single canonical gate that verifies tests, build, lint, types, and security audits all pass after implementation, polish, and any review-cycle fixes are in place. There is no earlier pre-flight in this flow; do not dispatch one before the agent review.
13. If in worktree: before merge-back, run pre-merge freshness check per `_v-exec.md` → Hot File Coordination. Then execute merge-back per _v-exec.md → Build Worktree Lifecycle
14. Write IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md and report completion
15. **Verify artifact exists:** After writing, confirm the file exists with `test -f [path]`. If write failed silently, retry once. Never claim completion without a verified artifact on disk.
```

### Parallel-Safe Step Detection

Before executing, scan the plan for independent steps (different target files, no shared state):

| Condition | Parallelizable? |
|-----------|----------------|
| Different files, no shared imports | Yes |
| Same directory, different files, no shared state | Yes |
| Shared service dependency | No — sequential |
| Database migration + code change | No — migration first |

When independent steps are detected, note them and optionally run via parallel agents.

### Incremental & Static Build Patterns

If the project uses ISR (Incremental Static Regeneration) or static generation:

- **Detect ISR:** `grep -rn "revalidate\|getStaticProps\|generateStaticParams" --include="*.ts" --include="*.tsx" app/ pages/`
- **Validate revalidation config:** Ensure `revalidate` values are reasonable (60-3600s for most content, not 0 or Infinity)
- **On-demand revalidation:** If using `revalidatePath` or `revalidateTag`, verify the trigger path matches the content mutation
- **Static params completeness:** `generateStaticParams` returns all expected slugs (check against database/CMS)
- **Fallback behavior:** `dynamicParams = true` vs `false` — ensure 404 vs on-demand generation is intentional

If the project uses edge middleware:
- **Edge-safe imports:** No Node.js-only modules in middleware or edge routes
- **Middleware matcher:** `config.matcher` is specific, not `"/(.*)"` (catches all routes unnecessarily)

**Reference:** Read `~/.claude/skills/v-build/references/v-frontend-patterns.md` for deep patterns on React Server Components, Inertia.js (shared data, partial reloads, form helpers), and real-time/WebSocket integration.

---

## TDD Approach

**Business logic, services, API endpoints:** TDD required (test first).

```
1. Write test describing desired behavior
2. Run — MUST fail (red)
3. Write minimal code to pass
4. Run — MUST pass (green)
5. Refactor if needed, re-run
```

**UI components, pages, visual changes:** Test-after acceptable.

| Type | When | Location | Speed |
|------|------|----------|-------|
| **Unit** | Pure functions, services, no DB | `tests/Unit/` | <50ms |
| **Feature/Integration** | Controllers, DB, full request | `tests/Feature/` | <500ms |
| **Frontend Unit** | React components, hooks | `resources/js/**/*.test.tsx` | <100ms |

**Coverage baseline** (check before starting — use the command matching your stack):
```bash
# Laravel/PHP (Pest console printer ends with a "Total: NN.N %" line — matched case-insensitively, last line wins)
php artisan test --coverage 2>/dev/null | grep -iE 'Total:' | tail -1
# Node.js (Vitest/Jest — coverage table has an "All files" summary row)
npm run test:coverage 2>/dev/null | grep "All files"
# Python (coverage.py terminal report ends with a "TOTAL" row)
pytest --cov 2>/dev/null | grep "TOTAL"
# Ruby
bundle exec rspec --format documentation 2>/dev/null | tail -5
# Go (per-package "coverage: NN.N% of statements" lines)
go test -cover ./... 2>/dev/null | grep "coverage"
# Rust (tarpaulin prints lowercase "NN.NN% coverage, .../... lines covered")
cargo tarpaulin 2>/dev/null | grep -i coverage | tail -1
```

Targets: Backend 80% line coverage, Frontend 80% line coverage, Critical paths (auth, payments) 100%.

**Coverage vs TDD exemptions:** UI components are exempt from TDD (test-after is acceptable), but they are NOT exempt from the 80% coverage target. Test-after means "write tests after implementation" — it does not mean "skip tests." The 80% target applies to all code regardless of TDD vs test-after workflow.

---

## Task Completion Criteria

| Size | Required Before Claiming Done |
|------|-------------------------------|
| **Bug fix** | Fix implemented + regression test passing |
| **Small** (1–3 files) | All changed files tested + linter clean |
| **Medium** (4–10 files) | Small criteria + integration tests + diff self-review + CHANGELOG entry |
| **Large** (10+ files) | Medium criteria + design doc written pre-build + phased/staged commits (land in reviewable increments, not one mega-commit) + e2e test for new user path |

---

## SaaS-Specific Safeguards + Async/Transaction Safety

**Moved to:** `references/saas-patterns.md`.

**Summary:** judgment-level rules that v-build's hooks cannot
mechanically enforce — billing-change adversarial review, multi-
tenant scoping checks, no-API-calls-in-request-lifecycle, no-
hardcoded-config-in-frontend, BYOK cost estimation, transactions
with dispatch-after-commit, idempotency + retry + dead-letter +
timeout + user-recovery as a combined async pattern (not a
pick-one), the six UI state-machine states, form validation
patterns, type safety, and observability basics.

**Trigger to load:** any plan touching billing, async, multi-
tenancy, external APIs, queued jobs, webhook handlers, or
state-machine UI. Read `references/saas-patterns.md` in full
before implementation begins on those plan items — these are
the failure modes that surface weeks later as customer refunds
or data-leakage incidents, not as test failures.

**Behavior unchanged:** the trigger matrix in the reference is
identical (billing files → hostile review, new routes → auth
verification, external API in request lifecycle → block, etc.).
The four-question async-API litmus test (5xx behavior, timeout
behavior, duplicate-request behavior, permanent-failure
visibility) remains the gate before shipping any external
integration. Transactions still must dispatch notifications
**outside** `DB::transaction(...)` (or via `afterCommit()`).

## Diff-Based Test Generation (JiT)

After all plan items implemented, run targeted test gap analysis on the actual diff:

1. Get changed files using the worktree-aware pattern from `~/.claude/skills/references/v-core-changed-files.md` (filter to `*.php *.ts *.tsx`)
2. For each changed source file lacking corresponding tests or uncovered new code paths:
   - Read the diff for that file
   - Identify new public methods, new branches, new error paths, edge cases
   - Generate targeted tests for those specific paths
3. Run new tests to verify they pass

**JiT targets what TDD may miss:** edge cases in new logic, error paths, integration seams, regression anchors.

**JiT novelty requirement:** Each JiT test must target a code path NOT already covered by TDD tests. Before generating JiT tests, diff the coverage: identify branches, error paths, and edge cases in changed files that have zero test coverage. JiT tests that duplicate existing happy-path coverage are waste — reject and regenerate targeting uncovered branches. If coverage tooling is available (`--coverage`), use it to identify uncovered lines; otherwise, manually trace branches in the diff that lack corresponding test assertions.

**Skip JiT when:** TDD was thorough for every method AND mutation testing MSI ≥80%, OR change was a simple config/copy update, OR pure UI component (test-after anyway).

**Definition of "thorough TDD":** Every new public method has at least one happy-path test AND one error-path test. Every new branch (`if`/`else`, `try`/`catch`, `match`) has at least one test covering each arm. If these conditions are met, TDD is thorough and JiT can be skipped.

---

## Scope Guard

**Definition of "unplanned file":** A file is unplanned if it is NOT listed in the plan's `## Files` section (modify or create lists). Auto-generated files are excluded from the count: `*.lock`, `package-lock.json`, `composer.lock`, route cache files, IDE config files (`.idea/`, `.vscode/`), and any file matching a pattern listed in the plan's `## Scope → out` section.

| Unplanned Files Changed | Action |
|------------------------|--------|
| 1–2 | Proceed, document why in `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md` |
| 3–5 | Log scope expansion warning in IMPLEMENTATION_REPORT, continue if changes are necessary for plan completion |
| >5 | Evaluate: if all changes are required for plan completion (e.g., cascading type changes, shared imports), add them to the plan and continue. If changes indicate the plan underestimated scope, write `BUILD_BLOCKER_${CLAUDE_SESSION_ID}.md` with the exact re-scope recommendation and stop cleanly. |

**Scope expansion decision tree (AI-autonomous):**
- Changes are type-system cascades or import chain effects → proceed, document
- Changes are fixing pre-existing broken tests touched by plan → proceed, document
- Changes are refactoring unrelated code "while we're here" → STOP, revert unplanned changes, stay on plan
- Changes indicate architectural mismatch with plan → STOP, write PROGRESS_NOTE with re-scoping recommendations
- Within a **planned** file, a changed hunk traces to no plan item or necessary cascade (incidental rename, cosmetic reformat, opportunistic "while I'm here" refactor) → revert that hunk. Being listed in the plan's `## Files` is not a license for unrelated edits inside the file — every changed line should trace to the request. (Hunk-level companion to the file-level guard above.)

---

## Checkpoint Protocol

Create a progress checkpoint at:
- After every major plan phase
- After every 5 files changed
- Before any risky operation (migration, external API change, billing path)
- When switching between backend and frontend work

Default checkpoint = update `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md` with phase, files changed, blockers, and next step. If the live pre-commit gate is already satisfied for this session, you may additionally create a git checkpoint commit in a worktree branch. Use `git add -u` (tracked files only) instead of `git add -A` to avoid accidentally staging secrets, .env files, or other untracked sensitive files. If new files need staging, add them explicitly by name.

**Note:** `.env*` files may be tracked per project policy. If `.env` is in `.gitignore`, it won't be staged by `git add -u`. If it IS tracked, staging is expected and safe.

**Note:** The live `enforce-pre-commit-gates.sh` hook blocks staged code commits until this session already has a passing `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md` and a semantically completed `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md`. `wip:` commit messages are not exempt.

### TypeScript Check at Every Checkpoint

After each checkpoint that includes a commit in a worktree, run the commit-check-fix loop defined in `~/.claude/skills/references/v-exec-typescript.md` (up to 3 iterations). If errors remain after 3 iterations, log and continue — the final pre-flight will catch anything truly broken. If the commit gate is not yet satisfied, run the same targeted checks before continuing without creating a commit.

### Context Management for Large Builds

**Proactive context budget tracking:** After every 5 plan items completed or every 15 turns (whichever comes first), assess context pressure:
1. Count remaining plan items vs completed items
2. If more than 40% of work remains and the session is past 20 turns, update `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md`, compact/shrink context when available, and continue. Do not invoke `/v-handoff` or ask the user to start fresh.
3. If less than 40% remains, continue but increase progress-checkpoint frequency to every 2 files

**Before context compaction:** ensure all work is captured in `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md` with: items completed, items remaining, current branch/worktree path, and any in-progress work that needs finishing. Do not assume a checkpoint commit is available before the live commit gate passes.

**If resuming after compaction:** re-read the PLAN_*.md, the most recent PROGRESS_NOTE, and the latest changed-file diff before continuing. Also check for BUILD_BLOCKER files per `~/.claude/skills/references/v-core-cross-session.md`.

Worktree state persists across compaction — the code is safe, but conversation context is not.

At natural breakpoints (section completion), proceed automatically to the next section. Log a brief summary of what was completed in `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md`. Only stop if:
- Build is failing and cannot be auto-fixed (→ Failure Protocol below)
- Context budget is exhausted (→ write PROGRESS_NOTE, compact/shrink context, and continue unless the no-progress circuit breaker has fired)
- All planned items are complete (→ Completion Checklist below)

---

## Failure Protocol

If tests fail after 3 attempts on the same issue:

1. Write `BUILD_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md` with:
   - The blocked step and partial progress
   - Error messages and hypothesis
   - Recovery hint and recommended next action
   - Artifact path so the next session can resume
2. Report to user: what was attempted, what failed, what to try next
3. Do not keep making random changes

**If in a worktree and build fails:**
- Commit partial work in the worktree branch
- **Leave the worktree intact** — next session can resume from this state
- Write `BUILD_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md` in the **original** working directory
- Report the worktree path for resumption

**Worktree safety:** **NEVER** remove a worktree you didn't create. Check `.claude-session-lock` before any worktree cleanup. Follow `_v-exec.md` for full worktree safety rules.

**Never:**
- Push failing code
- Claim completion with failures
- Hide problems
- Modify existing passing tests to make new code pass — if tests conflict with plan, the plan takes precedence. Adapt implementation to satisfy both old tests and plan requirements. If truly irreconcilable (e.g., plan explicitly changes behavior that old tests assert), document the conflict in `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md` and update the affected tests with clear comments explaining the behavioral change.

---

## Error Handling & Abort Conditions

### Retry Loop
When a build step fails (test failure, lint error, type error):
1. Attempt auto-fix using `_v-exec.md` TypeScript auto-remediation or test failure patterns
2. Re-run verification
3. If failure persists after **3 iterations**, classify as a blocker

### Blockers
When a step cannot be completed after 3 retry attempts:
1. Write `BUILD_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md` with:
   - Which plan item failed
   - Error output (last 50 lines)
   - What was tried
   - Suggested manual resolution
2. Skip the blocked item and continue with remaining items that don't depend on it
3. Mark blocked items as `status: blocked` in the build summary
4. Do NOT attempt workarounds that violate the plan's constraints

### Abort Conditions
Abort the entire build (write BUILD_BLOCKER and stop) if:
- More than 50% of plan items are blocked
- A P0 security fix introduced a regression that can't be resolved
- The test suite is fundamentally broken (not just the changed tests)
- Build cannot complete a single plan item successfully

---

## Completion Checklist

**When invoked by /v orchestrator:** Only items 1-3 apply (corresponding to execution flow steps 1-7). The orchestrator owns steps 4-9.
**When invoked directly by user:** All items apply.

Before claiming done:

- [ ] 1. All plan items implemented
  - [ ] Personas engaged at Step 5a / Step 2a (where matched) and logged under `## Personas engaged` in IMPLEMENTATION_REPORT
- [ ] 2. Coverage: 80% target met (100% for auth/payments)
- [ ] 3. JiT test gap analysis complete
- [ ] 4. If UI files changed (`.tsx`, `.jsx`, `.css`, `.html`): `/v-polish` run for UX refinements (direct invocation only)
- [ ] 5. Agent review dispatched — cycle 1 + cycle 2 if fixes applied (`codex-adversarial-reviewer` if agent file found, else `superpowers:requesting-code-review`); `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md` written and semantically completed (direct invocation only)
- [ ] 6. Adjudicate ALL agent findings: ACCEPT (fix now), MODIFY (fix with adjustments), REJECT (document). No DEFER (direct invocation only)
- [ ] 7. `/v-pre-flight` run as the canonical post-fix gate — all gates passed (direct invocation only). This is the only pre-flight in the flow.
- [ ] 8. `/v-verify-done` run (direct invocation only)
- [ ] 9. If in worktree: merged back per `_v-exec.md` Worktree Lifecycle (direct invocation only)
- [ ] Integration checklist verified:
  - [ ] SEO templates exist for all `forPage()` calls
  - [ ] Data transforms pass through all fields (no silent drops)
  - [ ] Config values dynamic — not hardcoded
  - [ ] Backend props match frontend TypeScript interfaces

---

## Ownership: Orchestrator vs Direct Invocation

See § ⚠️ OWNERSHIP BOUNDARY above for the stop rules and invocation-mode detection. In `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1` mode the final `IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md` is mandatory — see § MANDATORY FINAL ARTIFACT for its schema and Stop-hook enforcement.

---

## Post-Execution Report

```markdown
## Build Complete

### Summary
- Items completed: [X/Y]
- Tests: [passing/total]
- Files modified: [count]

### Changes Made
[Brief summary]

### Worktree
- Used: [yes / no]
- Merge: [fast-forward / rebased / N/A]

### Next Steps
**When invoked by /v orchestrator:** Control returned to orchestrator for remaining quality gates (polish, agent review, canonical pre-flight, merge-back).
**When invoked directly:** All in-flow gates ran inside this skill (polish if UI, agent review cycles, canonical pre-flight, verify-done, merge-back). Next user-facing step:
- Run `/v-check` when ready to launch
```

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Subagent prompt-pack writes prompts that re-invoke v-build → infinite recursion | Prompts contain `/v-build` literal string | Subagent generation step (Step 7) MUST NOT include `/v-build` in prompts; emit raw instructions for v-tdd or scaffolding |
| 2 | Implementation completes but PRE_FLIGHT_REPORT and AGENT_REVIEW are missing → Stop hook reverts everything | Headless implementation-only mode required IMPLEMENTATION_REPORT_*.md | When `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1`, write `IMPLEMENTATION_REPORT_${SID}.md` BEFORE end-of-session; chat summary alone fails Stop hook |
| 3 | `git stash` used during build → cross-worktree contamination | `worktree-safety.sh` hook is active but stash is forbidden universally | NEVER `git stash` — use `PROGRESS_NOTE_${SID}.md` for durable progress; commit gates only after pre-commit prerequisites met |
| 4 | TypeScript `any` used in implementation → ESLint pre-commit rejects | Project bans `any` (max-warnings=0) | Use `Record<string, unknown>`, `unknown`, or proper interface; never `any` even for "temporary" code |
| 5 | New route added but test suite fails on missing route in mockRoutes | Ziggy mock not regenerated | After adding route: regenerate Ziggy the project's way — `composer ziggy` / `scripts/ziggy-generate.sh` wrapper first; bare `php artisan ziggy:generate` ONLY as fallback (it drops feature-gated routes and desyncs the committed `ziggy.js` — see v-scaffold/SKILL.md Gotcha 6 + v-scaffold/references/laravel-scaffolds.md § Inertia Page) — AND add to `resources/js/test/setup.ts` mockRoutes |
| 6 | Inertia page test fails because page component doesn't exist | Created controller before component | ALWAYS create the `.tsx` page component first; contract test enforces existence before controller render |
| 7 | Lazy-loading exception in tests | Globally disabled; relationship not eager-loaded | `->load()` / `->loadMissing()` BEFORE accessing relationships; Cashier methods need `->load('owner', 'items.subscription')` |
| 8 | SPEC artifact not consumed; implementation re-derives values | Step 1a SPEC discovery skipped | Step 1a globs `*_SPEC_*.md` and reads them as authoritative; SPEC values OVERRIDE strategy-doc values on conflict |

## Idempotency

**Idempotent for the plan.** Re-running on the same plan produces equivalent code (no-op if already implemented). Re-running with a different plan produces a different changeset. Mutates code in the user's project; gated by /v-pre-flight before completion. The IMPLEMENTATION_REPORT is fresh per session.
