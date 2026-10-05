---
name: v-new-feature
description: "Use when planning a scoped feature before implementation, especially 4+ files."
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion, WebSearch, WebFetch, Skill, mcp__plugin_context7_context7__resolve-library-id, mcp__plugin_context7_context7__get-library-docs
argument-hint: "[feature spec or filepath]"
user-invocable: false
model: sonnet
context: fork
---
<!-- skill: v-new-feature | version: 1.1.2 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: Orchestration primitive. **Orchestrator-only — not user-invocable.** Reached via `/v` feature classification (Medium/Large); start with `/v` or `/v-plan`.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-growth.md`, and `_v-design.md` (when feature involves UI files).

Rules:
- use only for feature implementation specs
- use the shared `PLAN_SCHEMA`
- this skill is a **thin enhancement wrapper** around `v-plan` Route 3. It does NOT re-plan inline. It gathers two pieces of context v-plan does not (competitive landscape + closest-existing-feature pattern reference), then **invokes `/v-plan` via the Skill tool** to do the actual planning, gate, marker, and prompt-pack generation. Reimplementing v-plan's workflow inline is forbidden per `_v-core.md` § Sub-Skill Invocation Rule.

Output:
- `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` (written by `/v-plan`, extended by this skill with competitive context + prescriptive tables)

```yaml
contract:
  tier: orchestration-primitive
  accepts: [feature name/description, feature type selection, "--detail=quick|standard|comprehensive (optional)"]
  produces: ["PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md (via /v-plan; extended with Competitive Context + prescriptive tables)", "PLANNING_PASS_${CLAUDE_SESSION_ID}.md (via /v-plan, standalone runs)", ".v-prompt-packs/v-plan-<MM-DD>/ (via /v-plan, 4+ tasks)"]
  invokes: [/v-plan]
  invoked-by: [/v, user]
  wraps: /v-plan (Route 3 — Specific Feature)
  estimated_tokens: 12k-35k
  estimated_duration: 3-8 min
```

# /v-new-feature - Feature Plan Generator

**This skill delegates to `/v-plan` Route 3 (Specific Feature)** with two enhancements gathered up front: competitive context analysis and codebase pattern discovery. All core planning logic (entry questions, gates, the `PLANNING_PASS` marker, prompt-pack generation) lives in and is executed by `/v-plan` — see the thin-wrapper Rule above; this skill never re-plans inline.

**Usage:** `/v-new-feature FeatureName` or just `/v-new-feature`

## Skill Boundaries

**SME persona:** This skill is run by a **senior product-engineering tech lead** — specialty is taking a greenfield feature idea and producing a full design that engineering can build without re-deriving requirements: data model, API surface, UI shape, error states, observability hooks, rollout plan.

### Best fit

- Greenfield feature design where engineering needs full context (data model, API surface, UI shape, error states, observability hooks, rollout plan) before implementation can begin
- Features that span ≥4 files OR introduce a new domain concept the codebase doesn't already model
- Producing a `PLAN_*.md` artifact that `/v-build` can execute against

### Use instead

- Use `/v-plan` for changes that already have a clear shape and just need scope + files + tests articulated (faster path — skips competitive scan and pattern discovery)
- Use `/v-build` directly when the feature is 1-3 files with obvious implementation
- Use `/v-audit-code` for structural changes with zero behavior change (absorbed `/v-refactor` 2026-07-06)
- Use `/v-scaffold` for routine Laravel scaffolding (model + migration + factory + policy + tests) — convention-over-configuration cases

### Not for

- Bug fixes — those go through `/v-tdd` → `/v-build`
- Tiny features (1-3 files) — `/v-plan` is lighter weight
- Pure refactors — use `/v-audit-code`


## V_DEPTH Parsing (Mandatory)

Parse V_DEPTH from invocation args per `_v-core.md` § V_DEPTH Parsing Protocol. Search for `[V_DEPTH=N` or `V_DEPTH=N` in the prompt. Default to 0 if absent. Record `V_DEPTH` and the invocation `V_CHAIN` — both are re-emitted when invoking `/v-plan` (see Step 6).

**Circular-invocation guard (per `_v-core.md`):** before invoking `/v-plan`, confirm `v-plan` is not already in `V_CHAIN` and `V_DEPTH < 3`. If either check fails, stop and emit `circular_invocation_detected: chain=[V_CHAIN], depth=[V_DEPTH]` instead of invoking.

**When V_DEPTH >= 1 (orchestrator invoked):**
- Skip the dedup confirmation question. Run the dedup search to detect existing PLAN files; if a match is found, log it but proceed with a fresh plan anyway (reusing stale plans in orchestrated workflows causes drift).
- Skip ALL other user prompts (competitive-scan confirmation, growth-hook metric prompt). Resolve every decision autonomously per `_v-core.md` § Interactive User Prompts (temporal constraint).

**When V_DEPTH = 0 (user invoked):** The dedup question below and the entry-point feature-description prompt are permitted (this is the skill's own invocation/classification phase). Every decision AFTER Step 6 (the `/v-plan` handoff) is autonomous.

## Workflow

**This skill's job is Steps 1-5 (gather enhancement context), then Step 6 (hand off to `/v-plan`), then Step 7 (verify + extend the produced plan).** Steps 1-5 read and search only — they never write source files, so a standalone run stays planning-only and the `PLANNING_PASS` marker `/v-plan` writes remains valid.

1. **Resolve project root** per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from the invocation prompt if present, else `git rev-parse --show-toplevel`; if that does not yield a safe repo root, stop and ask for `PROJECT_ROOT` explicitly. Do not fall back to `pwd`. All searches and reads below are rooted at `$PROJECT_ROOT`.
2. **Capability check** (per `_v-exec.md` § Capability Detection): `command -v` for `git`, `jq`, and any stack binary you will use. WebSearch/WebFetch are optional enhancers for the competitive scan — if unavailable, mark `competitive_context: skipped (no web access)` and continue. Context7 is an optional enhancer for library-pattern verification.
3. **Feature description.** If the invocation did not include a feature description, at `V_DEPTH = 0` ask for it via AskUserQuestion; at `V_DEPTH >= 1` derive it from the prompt context (never ask).
4. **Dedup check** (scoped to `$PROJECT_ROOT`):
   ```bash
   ls -t "$PROJECT_ROOT"/.v/artifacts/PLAN_*.md "$PROJECT_ROOT"/PLAN_*.md 2>/dev/null | head -5 \
     | xargs grep -l -i "$FEATURE_TERM" 2>/dev/null | head -1
   ```
   If a matching plan exists and is less than 14 days old: at `V_DEPTH = 0` ask via AskUserQuestion — "I found `{plan_file}` which covers this feature. Use it, or create a fresh plan?"; at `V_DEPTH >= 1` log `dedup_match: {plan_file} (superseded)` and create a fresh plan.
5. **Gather enhancement context** (this skill's value-add — do this BEFORE delegating):
   - **Codebase pattern discovery** — see § Enhanced Codebase Exploration. Identify the closest existing feature and read its handler, service, and page. Produce a short `pattern_reference` block naming the files and conventions the new feature should mirror.
   - **Competitive context** — see § Competitive Context. Produce the `## Competitive Context` block (or mark it skipped).
   - **Design overlay (UI features only)** — if the feature adds or changes UI (pages, components, layouts), read `$PROJECT_ROOT/.interface-design/system.md` (the per-product overlay) if present, and note the accent + category colors + domain components the new UI must conform to per `_v-design.md`. New UI composes canonical spec primitives; it does not introduce an off-spec visual system.
6. **Delegate to `/v-plan` (Route 3) via the Skill tool** — see § Delegation Handoff. Pass the feature description, `PROJECT_ROOT`, depth, incremented `V_DEPTH`/`V_CHAIN`, the `pattern_reference`, the competitive context block, the design-overlay notes, and an explicit instruction to include the § Plan Template Extensions sections. `/v-plan` performs the actual codebase read/decision/write, runs its post-write integrity gate, writes the `PLANNING_PASS` marker, and generates prompt-packs.
7. **Post-delegation verification** — see § Post-Delegation Verification. Confirm the PLAN exists and carries the extension sections; append any that `/v-plan` omitted, editing only the PLAN file. Then show the completion banner.

## Enhanced Codebase Exploration

Before delegating, detect the project stack and explore using stack-appropriate paths. (This informs the `pattern_reference` you hand to `/v-plan`; `/v-plan` still does its own deeper exploration during planning — this step exists only to surface the single closest pattern to mirror.)

```bash
# Stack detection — determines which paths to explore. Run from $PROJECT_ROOT.
cd "$PROJECT_ROOT" || exit 1
STACK="unknown"
test -f composer.json && grep -q "laravel/framework" composer.json 2>/dev/null && STACK="laravel"
test -f package.json && grep -q '"next"' package.json 2>/dev/null && STACK="nextjs"
test -f Gemfile && grep -q "rails" Gemfile 2>/dev/null && STACK="rails"
test -f requirements.txt && grep -q "django" requirements.txt 2>/dev/null && STACK="django"
test -f go.mod && STACK="go"
echo "Detected stack: $STACK"
```

**Stack-specific exploration paths:**

| Stack | Services | Controllers/Handlers | Pages/Views | Migrations/Schema | Routes |
|-------|----------|---------------------|-------------|-------------------|--------|
| Laravel | `app/Services/` | `app/Http/Controllers/` | `resources/js/Pages/` | `database/migrations/` | `php artisan route:list --json` |
| Next.js | `src/lib/`, `lib/` | `src/app/api/`, `pages/api/` | `src/app/`, `pages/` | `prisma/migrations/` | (file-based) |
| Rails | `app/services/` | `app/controllers/` | `app/views/` | `db/migrate/` | `rails routes` |
| Django | `*/services.py` | `*/views.py` | `*/templates/` | `*/migrations/` | grep `urlpatterns` |
| Go | `internal/`, `pkg/` | `cmd/`, `handlers/` | N/A | `migrations/` | grep `Handle\|Route` |

```bash
FEATURE_TERM="<feature keyword>"   # set from the feature description, e.g. "billing"
# Universal search (works for all stacks). Rooted at $PROJECT_ROOT.
grep -rn "$FEATURE_TERM" "$PROJECT_ROOT" --include="*.php" --include="*.ts" --include="*.tsx" --include="*.py" --include="*.rb" --include="*.go" -l 2>/dev/null | head -20
grep -i "when adding" "$PROJECT_ROOT/CLAUDE.md" 2>/dev/null | head -10
ls -t "$PROJECT_ROOT"/.v/artifacts/AUDIT_REPORT_*.md "$PROJECT_ROOT"/AUDIT_REPORT_*.md "$PROJECT_ROOT"/.v/artifacts/REFACTOR_PLAN_*.md "$PROJECT_ROOT"/REFACTOR_PLAN_*.md 2>/dev/null | head -1 | xargs grep -l "$FEATURE_TERM" 2>/dev/null
```

If the stack is not Laravel, skip Laravel-specific commands (`php artisan`, Ziggy, etc.) and use the stack-appropriate alternatives above. Identify the closest existing feature as the pattern reference. Read its handler, service, and page to understand conventions. Capture the result as a `pattern_reference` block (files + conventions to mirror) for the handoff.

## Competitive Context (Enhanced)

Before delegating, systematically assess the competitive landscape for this feature. If web access is unavailable (per the Step 2 capability check), skip this section and mark `competitive_context: skipped (no web access)`.

### Step 1: Gather Intelligence

```bash
# Check recent audit findings for competitive analysis. Rooted at $PROJECT_ROOT.
ls -t "$PROJECT_ROOT"/.v/artifacts/AUDIT_REPORT_*.md "$PROJECT_ROOT"/AUDIT_REPORT_*.md "$PROJECT_ROOT"/.v-ecosystem-review/*.json "$PROJECT_ROOT"/.v-prompt-packs/*/SESSION_*.md 2>/dev/null | head -3 | xargs grep -l -i "compet" 2>/dev/null
```

**WebSearch competitive scan (run up to 3 searches):**
1. `"[feature name] [product category] software"` — find which competitors have this feature
2. `"[product category] comparison [current year]"` — find comparison/review sites listing feature matrices
3. `"[competitor name] [feature name]"` — for top 2-3 known competitors, check their implementation

**WebFetch** the 2-3 most relevant comparison/competitor pages surfaced by the searches to capture concrete implementation detail (not just titles). Cite the URLs in the `sources` field.

### Step 2: Analyze Findings

For each competitor found to have the feature, capture:

| Competitor | Has Feature? | Implementation Approach | Strengths | Weaknesses | Pricing Tier |
|-----------|-------------|----------------------|-----------|------------|-------------|
| [name] | Yes/No/Partial | [how they did it] | [what's good] | [what's missing] | [which plan includes it] |

### Step 3: Classify and Decide

| Classification | Definition | Your Strategy |
|---------------|-----------|---------------|
| **Table stakes** | 3+ competitors have it, users expect it | Match the best implementation, don't over-invest |
| **Differentiator** | 0-1 competitors have it, or all do it poorly | Invest in a superior version, this is your edge |
| **Novel** | No competitor has it | Validate demand before over-building; MVP first |

### Step 4: Produce the Competitive Context block

```markdown
## Competitive Context
- competitors_analyzed: [count searched, count with feature]
- classification: [table_stakes | differentiator | novel]
- table_stakes_version: [minimum viable version based on competitor analysis]
- differentiation_opportunity: [what makes our implementation unique or better]
- pricing_insight: [which tier competitors gate this behind — informs your packaging]
- sources: [URLs of comparison/review pages consulted]
```

Hold this block in context; it is injected into the `/v-plan` handoff (Step 6) and verified into the final PLAN (Step 7). If skipped, inject `competitive_context: skipped (<reason>)` instead.

## Delegation Handoff (Step 6)

Invoke `/v-plan` via the **Skill tool** (never re-plan inline). Pass a self-contained prompt containing:

- **Route + depth:** "Route 3 (Specific Feature). Detail level: `<--detail from invocation, else standard>`." (`/v-plan` at `V_DEPTH >= 1` skips its own entry-point and depth questions and uses these.)
- **Depth context:** `[V_DEPTH=<this skill's V_DEPTH + 1>, V_CHAIN=<incoming V_CHAIN>→/v-new-feature→/v-plan]` and `PROJECT_ROOT=<resolved absolute path>`.
- **Feature description:** the resolved description from Step 3.
- **`pattern_reference`:** the closest-existing-feature files and conventions from Step 5 — instruct `/v-plan` to mirror them.
- **Competitive context block** from § Competitive Context.
- **Design-overlay notes** (UI features) from Step 5.
- **Required extension sections:** an explicit instruction — "In addition to the standard PLAN_SCHEMA sections (keep `## Files` at H2 per § Plan Template Extensions), include these sections verbatim in the written PLAN: `## Competitive Context` (content below), the prescriptive tables in § Plan Template Extensions (Models & Migrations, Services & Jobs, Routes & Middleware), and the persona-promised `## Error States & Recovery`, `## Observability`, and `## Rollout Plan` sections."

`/v-plan` owns everything downstream: entry logic, SaaS-Concerns checklist (Route 3 requires it), API Design step, effort estimation, ADR gate, the plan write, the post-write integrity gate, the `PLANNING_PASS_${CLAUDE_SESSION_ID}.md` marker, and parallel prompt-pack generation. Do not duplicate any of it here.

**Why delegate rather than reimplement:** the integrity gate + `PLANNING_PASS` marker are what let a standalone planning-only run pass the Stop hook without fabricating PRE_FLIGHT/AGENT_REVIEW/VERIFY_DONE artifacts. A hand-rolled plan skips them and either blocks the session or drifts from v-plan as its schema evolves. Delegation keeps one source of truth.

## Post-Delegation Verification (Step 7)

After `/v-plan` returns, confirm the artifact and reconcile the extensions (edit ONLY the PLAN file — writing any other source file would invalidate the `PLANNING_PASS` marker's `FILES_MODIFIED=0`):

```bash
PLAN_PATH=$(ls -t "$PROJECT_ROOT"/.v/artifacts/PLAN_*"${CLAUDE_SESSION_ID}"*.md "$PROJECT_ROOT"/PLAN_*"${CLAUDE_SESSION_ID}"*.md 2>/dev/null | head -1)
[ -s "$PLAN_PATH" ] || { echo "FAIL: /v-plan produced no PLAN for this session"; exit 1; }

# Scope-guard-critical: v-build keys on an exact H2 "## Files" heading (see § Plan Template Extensions); stricter than a prefix match so "## Files changed" does NOT count.
grep -qE "^##[[:space:]]+Files[[:space:]]*$" "$PLAN_PATH" \
  || echo "MISSING/WRONG-LEVEL: ## Files (H2) — v-build Scope Guard will treat every file as unplanned. Fix the PLAN heading via Edit before proceeding."

# Extension sections this skill owns (append any that /v-plan omitted).
for H in "Competitive Context" "Error States & Recovery" "Observability" "Rollout Plan"; do
  grep -qE "^##[[:space:]]+${H}" "$PLAN_PATH" \
    && echo "present: ## ${H}" \
    || echo "MISSING: ## ${H} — append via Edit"
done
```

- If the PLAN is missing (`/v-plan` failed to write): re-invoke `/v-plan` once with the same handoff. If it fails again, surface `status: blocked` (BUILD_BLOCKER — planning delegation failed) and stop.
- If `## Files` is missing or emitted at the wrong heading level: fix that heading in the PLAN via **Edit** (rename `### Files`/`## Files changed` → `## Files`) — the one core-section repair Step 7 must make (rationale in § Plan Template Extensions).
- If the PLAN exists but omits `## Competitive Context`, the prescriptive tables, or the persona-promised `## Error States & Recovery` / `## Observability` / `## Rollout Plan` sections: append them via the **Edit** tool from the blocks you already hold in context. Do not rewrite the file; append only. This is a fallback for when `/v-plan` did not honor the injected extension instruction.
- Do not re-run v-plan's integrity gate — it already ran inside `/v-plan`. Appending additive sections cannot remove the 6 core sections it validated.

Then show the completion banner (per `_v-core.md` § Standard Completion Message).

## Plan Template Extensions

The written PLAN must carry the six shared `PLAN_SCHEMA` core sections — `## Summary`, `## Scope`, `## Files`, `## Tests Required`, `## Acceptance Criteria`, `## Rollback Notes` — plus the standard v-plan Route 3 sections (SaaS Concerns, Effort Estimate, API Design, optional ADR). Those are owned and written by `/v-plan`; do not restate their schema here (reference `_v-core.md`). The sections below are the **v-new-feature-specific extensions** `/v-plan` must include **on top of** that core.

**`## Files` is load-bearing at H2.** It must be `## Files` (H2), not `### Files` (H3) or `## Files changed`. `/v-build`'s Scope Guard keys on the exact `## Files` heading (modify/create lists) to classify which changed files are planned; if it is missing or at the wrong level, the Scope Guard treats **every** changed file as unplanned and the flagship 4+-file pipeline silently over-reverts. `/v-plan` writes it at H2 by default and Step 7 (Post-Delegation Verification) re-checks it.

The SME persona promises **error states, observability hooks, and a rollout plan** — the last three extension sections below deliver each, so the produced design actually contains what the persona guarantees.

```markdown
## Competitive Context
- competitors_with_feature: [list or "none found"]
- classification: [table_stakes | differentiator | novel]
- table_stakes_version: [what's the minimum viable version?]
- differentiation: [what makes our implementation unique?]
- pricing_insight: [tier competitors gate this behind]
- sources: [URLs]

## Models & Migrations
| Model | Table | Key Columns | Relationships | Factory | Migration safety |
{Migration safety column: for a NEW column on an EXISTING table, state nullable-or-default (never a bare NOT NULL); for a DESTRUCTIVE change (column/table drop, type narrowing), state the two-phase deploy split (ship code that stops using the column first, drop the column in a later deploy) — or "new table, N/A" when the migration only creates a new table.}

## Services & Jobs
| Class | Purpose | External API? | Singleton? |

## Routes & Middleware
| Method | URI | Controller@method | Middleware |

## Error States & Recovery
| Failure mode | Detection | User-facing behavior | Recovery / fallback |
{One row per external call, validation boundary, and async job. Partial data > cached fallback > empty state > error page — never a raw exception to the user.}

## Observability
- structured log events: [event name + context keys — user_id, action, duration_ms, ip minimum]
- metrics: [counters/timers this feature emits]
- alerts: [threshold conditions worth acting on, or "none"]

## Rollout Plan
- gating: [feature flag / cohort / direct-ship — see references/v-feature-flag-lifecycle.md if flagged]
- phased steps: [team-only → % rollout → 100%, or "single-step ship" for low-risk]
- rollback trigger: [metric/error that reverts the rollout — ties to core ## Rollback Notes]

## Implementation Order
{Adapt to the DETECTED_STACK — see § Implementation Order below.}
```

**Growth hook:** growth instrumentation is owned by `/v-plan` via `_v-growth.md` (Target Metric / Instrumentation / Post-Launch Readout sections are added when a growth trigger matches). Do **not** prompt the user for a metric here — at `V_DEPTH >= 1` questions are forbidden, and at `V_DEPTH = 0` the question belongs to v-plan's flow. If the feature touches a growth trigger (landing page, pricing, onboarding, checkout, lifecycle emails, referral flows), state that in the handoff so v-plan populates the growth block; if no trigger matches, `target_metric: none` is valid.

### Implementation Order (guidance passed to v-plan)

**Adapt to DETECTED_STACK.** The order below is Laravel/Inertia; for other stacks, generate the equivalent.

**Laravel/Inertia:**
1. Migrations + Models + Factories (TDD)
2. Services + typed exceptions (TDD)
3. Jobs if external API (TDD)
4. Form Requests
5. Controllers (TDD)
6. Routes + Ziggy regeneration the project's way (`composer ziggy` / wrapper script; bare `php artisan ziggy:generate` only as fallback — it drops feature-gated routes, see v-scaffold/references/laravel-scaffolds.md § Inertia Page)
7. React pages + components
8. Frontend tests

**Next.js/React:**
1. Database schema + ORM models (Prisma/Drizzle)
2. API routes + validation (TDD)
3. Server components + data fetching
4. Client components + state
5. Frontend tests

**Django/FastAPI:**
1. Models + migrations
2. Serializers/schemas
3. Views/routers (TDD)
4. Templates/frontend
5. Tests

**Rails:**
1. Models + migrations + factories
2. Services (TDD)
3. Controllers + routes
4. Views/frontend
5. Specs

**Other stacks:** Follow the project's existing implementation patterns discovered in Codebase Exploration.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Feature plan ignores existing patterns; new feature feels bolt-on | Codebase pattern discovery skipped | Step 5 must identify the closest existing feature and pass a `pattern_reference` to v-plan BEFORE delegating; new feature follows existing conventions unless deviation is justified |
| 2 | Plan specifies UI but `.interface-design/system.md` not consulted | Per-product overlay not read | Step 5 reads `.interface-design/system.md` (overlay) when the feature has UI; new UI MUST conform to the canonical design system (`_v-design.md`) — domain components compose spec primitives, and the overlay records new category colors |
| 3 | Plan picks 4-file scope that should have been 1-file fix | "Plan everything" bias | If the problem is well-bounded, route to v-build directly (with inline plan) — don't expand scope to justify v-new-feature invocation |
| 4 | Competitive context section is generic ("competitors do X") | Competitive scan didn't run or didn't fetch | Step 1 of § Competitive Context must WebSearch AND WebFetch 2-3 competitor/comparison pages, OR explicitly mark `competitive_context: skipped (<reason>)` |
| 5 | Session blocked by Stop hook after a standalone planning run | Skill re-planned inline and skipped v-plan's `PLANNING_PASS` marker | Never re-plan inline. Invoke `/v-plan` via the Skill tool (Step 6) — it writes the integrity gate + `PLANNING_PASS` marker that the Stop hook needs |
| 6 | Extension sections (Competitive Context, prescriptive tables) missing from final PLAN | v-plan didn't honor the injected extension instruction | Step 7 greps the produced PLAN and appends any missing extension sections via Edit (PLAN file only) |
| 7 | Artifacts land in the Claude session dir, not the repo | Searches/writes ran from bare `pwd` under `context: fork` | Every search, read, and path resolves under `$PROJECT_ROOT` (Step 1); never bare `pwd` |

## Idempotency

**Idempotent for the feature description.** Re-running on the same description gathers equivalent competitive/pattern context and produces an equivalent design; specific ordering and wording may vary. Filesystem-mutating: delegates the PLAN write to `/v-plan` (which writes `PLAN_*.md`, the `PLANNING_PASS_${CLAUDE_SESSION_ID}.md` marker, and any prompt-packs), then appends extension sections to that same PLAN file. This skill itself writes no other source files, so a standalone run stays planning-only.
