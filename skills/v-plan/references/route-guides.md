# Route Guides — v-plan

_Last reviewed: 2026-07-06 (design-language consistency pass)_

Detailed question flows, exploration steps, and plan templates for each planning route.
Read the relevant route section when executing that planning path.

---

## Route 1: New Product Planning

**Triggers:** "New product from scratch"
**Output:** `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md`

### Questions (ask together)

```yaml
questions:
  - question: "What's the domain or product name?"
    header: "Domain"
    # Free text - no options

  - question: "Who is the target user?"
    header: "User"
    options:
      - label: "Developers"
        description: "Technical users building software"
      - label: "Small business owners"
        description: "Non-technical business operators"
      - label: "Enterprise teams"
        description: "Large org employees with approval workflows"
      - label: "Consumers"
        description: "General public, B2C"

  - question: "What's the monetization model?"
    header: "Revenue"
    options:
      - label: "Freemium (Recommended)"
        description: "Free tier with paid upgrades"
      - label: "Subscription"
        description: "Monthly/annual recurring"
      - label: "Usage-based"
        description: "Pay per API call, scan, etc."
      - label: "One-time purchase"
        description: "Single payment for lifetime access"

  - question: "What frontend stack?"
    header: "Stack"
    options:
      - label: "React + Inertia (Recommended)"
        description: "Modern SPA feel with Laravel backend"
      - label: "Livewire"
        description: "Server-rendered reactivity"
      - label: "Blade"
        description: "Traditional server-rendered"
```

### Then Generate

1. Check for existing audit artifacts:
   ```bash
   ls -t .v-ecosystem-review/*.json .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md v-*-prompts/SESSION_*.md 2>/dev/null | head -1
   ```
   If found, read and incorporate findings rather than starting analysis from scratch.
2. Research competitors via WebSearch. When a search result surfaces a specific competitor URL worth reading in full (pricing page, feature matrix, changelog, docs), use **WebFetch** on that URL to pull the full page rather than relying on the snippet — full-page reads yield higher-signal pricing tiers, feature lists, and positioning than search excerpts.
3. Generate persona and value prop
4. Design schema with indexes upfront
5. Plan routes and features
6. Include configuration architecture (no hardcoding!)
7. Write `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` starting with the shared `PLAN_SCHEMA` core fields (`Summary`, `Scope`, `Files`, `Tests Required`, `Acceptance Criteria`, `Rollback Notes`), then add these route-specific sections:
   - METADATA (name, date, status)
   - PERSONA (target user details)
   - VALUE_PROP (core value proposition)
   - FEATURES (core/supporting/v1.1 breakdown)
   - ROUTES (URL structure)
   - SCHEMA (database tables with fields)
   - INDEXES (database indexes)
   - PRICING (tiers and features per tier)
   - CONFIGURATION_ARCHITECTURE (no hardcoding!)
   - DESIGN_SYSTEM (shared spec applies — record only the overlay: accent, category pairs, branding, domain components; marketing surfaces via /v-marketing-design — full set per `_v-design.md § Per-Product Overlay`)
   - IMPLEMENTATION_ORDER (what to build first)
   - AI_INTEGRATION (if product uses AI/LLM features):
     - Provider selection (multi-provider with fallback)
     - Token budget management and cost tracking
     - Prompt versioning strategy
     - AI guardrails (input/output filtering, PII detection)
     - Rate limiting and queue management for AI calls
   - NEXT STEPS: Run `/v PLAN_[timestamp].md` → `/v-pre-flight` → `/v-verify-done`

---

## Route 2: Understand Existing Codebase

**Triggers:** "Understand existing codebase"
**Output:** `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md`

### Questions

```yaml
questions:
  - question: "What's your goal with this codebase?"
    header: "Goal"
    options:
      - label: "Document for myself"
        description: "I need to understand how it works"
      - label: "Prepare for v-handoff"
        description: "Someone else will work on this"
      - label: "Find gaps before launch"
        description: "Audit for missing features"
      - label: "All of the above"
        description: "Full documentation and gap analysis"
```

### Then Analyze

1. Check for existing audit artifacts:
   ```bash
   ls -t .v-ecosystem-review/*.json .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md v-*-prompts/SESSION_*.md 2>/dev/null | head -1
   ```
   If found, read and incorporate findings rather than starting analysis from scratch.
2. Detect stack (React/Livewire/Blade)
3. Run `php artisan route:list`
4. Glob controllers, models, pages
5. Trace user journeys through code
6. Document data model from migrations
7. Identify gaps with file:line references
8. Write `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` starting with the shared `PLAN_SCHEMA` core fields (`Summary`, `Scope`, `Files`, `Tests Required`, `Acceptance Criteria`, `Rollback Notes`), then add these route-specific sections:
   - METADATA (name, date, status)
   - PRODUCT_SUMMARY (what this codebase does)
   - USER_ROLES (anonymous/free/paid capabilities)
   - USER_JOURNEYS (with step status and gaps)
   - FEATURE_INVENTORY (with route/controller/model/view)
   - DATA_MODEL (tables and relationships)
   - ROUTES_SUMMARY (all routes organized)
   - GAP_ANALYSIS (P0/P1/P2 prioritized)
   - NEXT STEPS: Run `/v PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` → `/v-pre-flight` → `/v-verify-done`

---

## Route 3: Specific Feature

**Triggers:** "Specific feature"
**Output:** `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md`

### Phase 1: Understand

```yaml
questions:
  - question: "What should this feature do in one sentence?"
    header: "Goal"
    # Free text

  - question: "How is this triggered?"
    header: "Trigger"
    options:
      - label: "User action (button/form)"
        description: "User clicks something"
      - label: "Automatic (schedule/event)"
        description: "System triggers it"
      - label: "API call"
        description: "External/programmatic"

  - question: "Is this new or modifying existing?"
    header: "Scope"
    options:
      - label: "New feature"
        description: "Doesn't exist yet"
      - label: "Modify existing"
        description: "Changing current behavior"
      - label: "Both"
        description: "Adding to existing"
```

### Phase 2: Explore Codebase

Check for existing audit artifacts:
```bash
ls -t .v-ecosystem-review/*.json .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md v-*-prompts/SESSION_*.md 2>/dev/null | head -1
```
If found, read and incorporate findings rather than starting analysis from scratch.

**Codebase pattern discovery:**
```bash
# Choose one concrete feature term from the request
FEATURE_TERM="billing"
grep -rn "$FEATURE_TERM" app/Services/ app/Http/Controllers/ --include="*.php" -l
grep -rn "$FEATURE_TERM" resources/js/Pages/ --include="*.tsx" -l

# Understand existing structure
ls app/Services/ | head -20
ls app/Http/Controllers/ | head -20
ls resources/js/Pages/ | head -20
ls database/migrations/ | tail -10

# Route patterns
php artisan route:list --json 2>/dev/null | jq '.[].uri' | tail -20

# Check CLAUDE.md for conventions
grep -i "when adding" CLAUDE.md | head -10

# Check for recent audit findings in this area
ls -t .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md .v/artifacts/REFACTOR_PLAN_*.md REFACTOR_PLAN_*.md 2>/dev/null | head -1 | xargs grep -l "$FEATURE_TERM" 2>/dev/null
```

Identify the closest existing feature as the pattern reference. Read its controller, service, and page to understand conventions.

### Phase 2.5: Competitive Context (for features worth differentiating)

Before planning, quickly assess whether competitors already offer this feature:

1. **Check recent audit findings:** If specialist audits or `v-audit-growth` were run recently, read the competitive analysis findings:
   ```bash
   ls -t .v-ecosystem-review/*.json .v-prompt-packs/v-audit-growth-*/*.md .v/artifacts/AUDIT_REPORT_*.json AUDIT_REPORT_*.json 2>/dev/null | head -1
   ```
   If found, extract any competitive findings related to this feature area.

2. **Quick competitive scan:** If no recent audit exists, do a brief search:
   - How do 2-3 direct competitors implement this feature?
   - What's the table-stakes version vs. a differentiating version?
   - What can this product do differently (unique data, workflow, integration)?

3. **Inform the plan:** Include a "Competitive Context" section noting whether competitors have this feature, the baseline expectation, and the differentiation opportunity.

### Phase 3: Present Options

For each decision point, ask:

**UI Placement:**
```yaml
question: "Where should this appear?"
header: "Placement"
options:
  - label: "Settings page"
  - label: "Inline action"
  - label: "Dropdown menu"
  - label: "Modal trigger"
```

**Success Behavior:**
```yaml
question: "What happens on success?"
header: "Success"
options:
  - label: "Toast notification"
  - label: "Redirect"
  - label: "Inline update"
```

**Error Handling:**
```yaml
question: "What happens on failure?"
header: "Failure"
options:
  - label: "Error toast"
  - label: "Error modal"
  - label: "Inline error"
```

**Confirmation (for destructive actions):**
```yaml
question: "Need confirmation?"
header: "Confirm"
options:
  - label: "Yes, modal"
  - label: "Yes, type to confirm"
  - label: "No"
```

### Phase 4: Interactive Design Decisions

The shared SaaS design system (`_v-design.md`) fixes visual design — palette, typography, spacing, depth, components, and breakpoints are not per-project questions. Do NOT interrogate the user about colors, fonts, or component styling.

The only interactive design decisions are the sanctioned per-product freedoms:
- **Accent + category colors** — `--accent` value and any new category `-bg`/`-text` pairs (recorded in the `.interface-design/system.md` overlay)
- **Branding** — logo, avatar gradient, product naming in the sidebar
- **Domain-component design** — which spec primitives (card tiers, badges, rings, bars) a product-specific component composes

Behavioral decisions (data loading strategy, state placement, validation timing) are resolved autonomously from existing codebase patterns and documented in the plan's Decisions table — ask only when a choice is irreversible and no codebase precedent exists.

### Phase 5: Edge Cases

Present discovered edge cases:
- What if user doesn't have permission?
- What if related data exists?
- What if operation is in progress?

### Phase 6: Write the Plan

Write `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` using the shared `PLAN_SCHEMA` core fields first, then extend it with this feature-specific structure:

```markdown
# PLAN: [Name]
generated: [YYYY-MM-DD]
status: ready

## Summary
[One paragraph describing the feature]

## Scope
- in: [what this feature includes]
- out: [what this feature explicitly excludes]

## User Story
As a [user role], I want to [action] so that [benefit].

## Decisions Made
| Question | Answer | Rationale |
|----------|--------|-----------|
| [From Phase 3-4 questions] | [User's choice] | [Why] |

## Behavior
### Trigger
[How the feature is initiated]

### Flow
1. [Step 1]
2. [Step 2]
3. [etc.]

### Success State
[What happens when it works]

### Failure State
[What happens when it fails]

## Edge Cases
| Case | Behavior |
|------|----------|
| [Edge case 1] | [How handled] |

## Files to Modify
| File | Change |
|------|--------|
| [path/to/file.tsx] | [What changes] |

## Files to Create
| File | Purpose |
|------|---------|
| [path/to/new/file.tsx] | [Why needed] |

## Tests Required
- [ ] [Test case 1]
- [ ] [Test case 2]

## Acceptance Criteria
- [ ] [observable behavior 1]
- [ ] [observable behavior 2]

## Rollback Notes
- application rollback: [how to revert code safely]
- data rollback: [whether data changes are reversible]

## Out of Scope
- [Explicit exclusion 1]
- [Explicit exclusion 2]

## Patterns to Follow
- [Pattern from codebase exploration]

## Next Steps
1. Run `/v PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` to implement
2. Run `/v-pre-flight` to verify quality gates
3. Run `/v-verify-done` for deep convention check
```

---

## Route 4: Refactor or Improvement

**Triggers:** "Refactor or improvement"
**Output:** `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md`

### Questions

```yaml
questions:
  - question: "What kind of improvement?"
    header: "Type"
    options:
      - label: "Code quality / tech debt"
        description: "Clean up messy code"
      - label: "Performance optimization"
        description: "Make it faster"
      - label: "Architecture change"
        description: "Restructure how things work"
      - label: "Test coverage"
        description: "Add missing tests"

  - question: "What's the scope?"
    header: "Scope"
    options:
      - label: "Single file/component"
        description: "Focused, small change"
      - label: "Single feature area"
        description: "One domain, multiple files"
      - label: "Cross-cutting concern"
        description: "Affects many areas"
      - label: "Entire codebase"
        description: "Comprehensive overhaul"
```

### Then Analyze

Check for existing audit artifacts:
```bash
ls -t .v-ecosystem-review/*.json .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md v-*-prompts/SESSION_*.md 2>/dev/null | head -1
```
If found, read and incorporate findings rather than starting analysis from scratch.

Based on type:
- **Code quality:** Run tech debt analysis
- **Performance:** Profile and identify bottlenecks
- **Architecture:** Map current vs desired state
- **Test coverage:** Identify gaps

Write `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` starting with the shared `PLAN_SCHEMA` core fields (`Summary`, `Scope`, `Files`, `Tests Required`, `Acceptance Criteria`, `Rollback Notes`), then add these route-specific sections:
- METADATA (name, date, status)
- CURRENT_STATE (what exists now, problems)
- PROPOSED_CHANGES (what will change)
- FILES_AFFECTED (list with file paths)
- RISK_ANALYSIS (what could go wrong)
- MIGRATION_STRATEGY (if breaking changes)
- VERIFICATION_CRITERIA (how to confirm success)
- ROLLBACK_PLAN (how to undo if needed)
- NEXT STEPS: Run `/v PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` → `/v-pre-flight` → `/v-verify-done`

---

## Route 5: Growth Planning

**Triggers:** "Growth planning", "growth roadmap", "funnel optimization"
**Output:** `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md`

### Questions

The full catalog below is 6 funnel stages (Awareness + AARRR). Present the 4 stages most
relevant to the request (e.g. from stage signals in CLAUDE.md or the operator's prompt) plus
the tool's auto "Other" — not all 6 at once.

```yaml
questions:
  - question: "Which funnel stage to focus on?"
    header: "Stage"
    options:
      # aq-exempt: catalog — model presents the 4 stages most relevant to the request +
      # the tool's auto "Other", not all 6 at once.
      - label: "Awareness"
        description: "Getting product in front of target users"
      - label: "Acquisition"
        description: "Converting visitors to signups"
      - label: "Activation"
        description: "Getting users to first success"
      - label: "Retention"
        description: "Keeping users engaged long-term"
      - label: "Revenue"
        description: "Monetization and upgrade conversion"
      - label: "Referral"
        description: "Users inviting other users"

  - question: "Do you have baseline metrics?"
    header: "Metrics"
    options:
      - label: "Yes, I have data"
        description: "I can share conversion rates, engagement data, etc."
      - label: "No baseline yet"
        description: "Just starting, need help defining metrics"

  - question: "What's your growth target?"
    header: "Target"
    # Free text (e.g., "2x user growth in 6 months", "10% upgrade rate")
```

### Then Generate

1. Check for existing audit artifacts:
   ```bash
   ls -t .v-ecosystem-review/*.json .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md .v-prompt-packs/v-audit-growth-*/SESSION_*.md 2>/dev/null | head -1
   ```
   If found (especially v-audit-growth outputs), read and use as baseline for growth roadmap.

2. Extract funnel stage metrics from provided data or existing audits
3. Identify bottlenecks (which stage has lowest conversion?)
4. Generate growth experiments prioritized by expected impact
5. Create A/B test plan with implementation order
6. Write `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` starting with the shared `PLAN_SCHEMA` core fields (`Summary`, `Scope`, `Files`, `Tests Required`, `Acceptance Criteria`, `Rollback Notes`), then add these route-specific sections:
   - METADATA (name, date, status)
   - FUNNEL_BASELINE (current metrics for each stage with confidence)
   - GROWTH_TARGET (quantified goal for the plan period)
   - BOTTLENECK_ANALYSIS (which stage has lowest conversion and why)
   - GROWTH_EXPERIMENTS (prioritized list):
     - Experiment name
     - Funnel stage(s) impacted
     - Expected impact (% improvement)
     - Effort estimate (hours)
     - Implementation complexity (low/medium/high)
     - Success metric and threshold
   - A_B_TEST_PLAN (experimental design):
     - Control group definition
     - Treatment group definition
     - Sample size required
     - Duration needed for significance
     - Statistical test (chi-square, t-test, etc.)
   - IMPLEMENTATION_ORDER (experiments ranked by expected impact / effort ratio)
   - MONITORING_DASHBOARD (what to track):
     - Funnel stage metrics
     - Experiment conversion rates
     - Engagement velocity
     - Cohort retention curves
   - ROLLBACK_CRITERIA (when to stop an experiment)
   - NEXT STEPS: Run `/v PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` → `/v-pre-flight` → `/v-verify-done`

---

## Route 6: User-Owned Maintenance

**Triggers:** "hook", "settings", "mirror sync", "repo-local .claude", "skill tree", "maintenance"
**Output:** either a lightweight maintenance checklist in the PLAN, or a direct hand-off to `/v-maintenance` (no PLAN artifact)

**Route 6 is deliberately lightweight.** Most maintenance work targets owner-managed infrastructure (hooks, settings, skill trees, mirror syncs) where the paths are already named and the change is small. The default is to keep the checklist inline and route straight to execution — do NOT generate the full multi-section PLAN artifact for these.

### Decide: full PLAN or inline checklist?

- **Inline checklist / hand-off (default):** the user already named the maintenance paths and did not explicitly ask for a written PLAN. Skip the PLAN artifact. Produce a short inline checklist (scope, files, targeted tests, hostile-review focus) and route directly to `/v-maintenance`.
- **Full PLAN (only when explicitly requested):** the user asked for a written plan, OR the maintenance spans many files / carries real rollback risk (hook logic changes, gate-behavior changes, settings that affect enforcement). Then produce a `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` with the shared `PLAN_SCHEMA` core fields plus the Route-6 sections below.

### Questions (ask only when scope is unclear — usually skip)

```yaml
questions:
  - question: "What maintenance target?"
    header: "Target"
    options:
      - label: "Hooks / gates"
        description: "Stop hooks, PreToolUse hooks, enforcement scripts"
      - label: "Settings / config"
        description: "settings.json, permissions, env"
      - label: "Skill tree"
        description: "Skill content, references, evals"
      - label: "Mirror / sync"
        description: "Canonical ↔ mirror propagation, repo-local .claude"
```

### Then Scope

1. **Path scoping** — list the exact files in scope (canonical vs. mirror). For owner-managed `~/.claude` infra, honor the canonical-vs-mirror policy in `_v-core.md` / `references/v-core-owner-managed.md`; never edit a mirror when the canonical is the source of truth.
2. **Canonical-vs-mirror policy** — if the change touches a file with a mirror, decide the propagation direction and note it. Hardlinked mirrors need no copy; copy-mirrors do.
3. **Targeted test planning** — identify the specific test(s) that cover the changed file(s). Run ONLY those during iteration (never the full suite). For hook/gate changes under `hooks/`, `hooks/lib/`, `skills/v/references/`, or `scripts/`, a content-validated BITE_LEDGER (red≠0 / green=0) is required — plan the swap-audit that proves each guard bites.
4. **Hostile-review focus** — name the adversarial angle for this change (false-green gate, path drift, self-modification denial, mirror split-brain) so review targets the real risk, not generic lint.

If producing a full PLAN, write `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` starting with the shared `PLAN_SCHEMA` core fields (`Summary`, `Scope`, `Files`, `Tests Required`, `Acceptance Criteria`, `Rollback Notes`), then add these route-specific sections:
   - METADATA (name, date, status)
   - MAINTENANCE_TARGET (what infra is changing and why)
   - CANONICAL_VS_MIRROR (source of truth + propagation direction)
   - TARGETED_TESTS (the specific tests that bite; BITE_LEDGER plan for hook/gate changes)
   - HOSTILE_REVIEW_FOCUS (the adversarial angle to prove safe)
   - NEXT STEPS: hand off to `/v-maintenance` for execution → targeted tests → hostile review

Otherwise, skip the PLAN and hand the inline checklist to `/v-maintenance`.
