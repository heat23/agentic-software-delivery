---
name: v-scaffold
description: "Use when scaffolding services, jobs, controllers, Inertia pages, React components, models, factories, or tests."
argument-hint: "<name>"
model: sonnet
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, mcp__plugin_context7_context7__resolve-library-id, mcp__plugin_context7_context7__get-library-docs
user-invocable: false
disable-model-invocation: true
---
<!-- skill: v-scaffold | version: 1.2.3 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: Orchestration primitive. **Orchestrator-only — not user-invocable.** Reached via `/v` Scaffold classification ("scaffold", "generate", "stub"); `v` routes here only when scaffolding is the actual task.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-design.md`, `_v-jobs.md` (when scaffolding jobs), and `_v-api.md` (when scaffolding API routes).

Rules:
- use Convention Discovery before applying repo-specific overrides
- only apply the AI test-speed override if repository conventions explicitly require it
- record timeouts, retries, idempotency, and logging expectations for external API jobs
- for Inertia pages: after scaffolding, regenerate Ziggy **the project's way** (discover a `composer ziggy` script or `scripts/ziggy-generate.sh` first; bare `php artisan ziggy:generate` is the fallback only — it drops feature-gated routes and desyncs the committed `ziggy.js`), add the named route to the `mockRoutes` map, and confirm the Inertia contract tests pass. See `references/laravel-scaffolds.md` § Inertia Page.
- update `CLAUDE.md` only per the conditions in § CLAUDE.md Auto-Update (never by default)

```yaml
contract:
  tier: orchestration-primitive
  accepts: [type + name arguments]
  produces: [scaffolded source files, test files]
  invokes: []
  invoked-by: [/v, user]
  estimated_tokens: 5k-15k
  estimated_duration: 1-3 min
```

# /v-scaffold - Convention-Aware Code Generator

Scaffolds code following the project's detected conventions. Supports services, jobs, notifications, form requests, Inertia pages, and enums.

**Usage:**
- `/v-scaffold ServiceName` — scaffolds a service (default type)
- `/v-scaffold --type model Invoice` — scaffolds a model + factory + migration
- `/v-scaffold --type job ProcessPaymentJob` — scaffolds a job
- `/v-scaffold --type notification PaymentFailedNotification` — scaffolds a notification
- `/v-scaffold --type request StoreReportRequest` — scaffolds a form request
- `/v-scaffold --type page Reports/Index` — scaffolds an Inertia page + controller
- `/v-scaffold --type enum OrderStatus` — scaffolds an enum
- `/v-scaffold` — asks interactively

## Skill Boundaries

**SME persona:** This skill is run by a **senior Laravel architect** — specialty is scaffolding the skeleton (model + migration + factory + policy + form-request + controller + view + test) so the dev pass is purely business-logic implementation. Treats convention as gravity: do what Laravel expects unless there's a specific reason not to.

### Best fit

- Routine Laravel scaffolding (model + migration + factory + policy + form-request + controller + view + test) for a new entity that follows existing project conventions
- Greenfield CRUD-style feature where the data shape is known and convention-over-configuration applies
- Producing the skeleton so the dev pass is purely business-logic implementation, not boilerplate

### Use instead

- Use `/v-new-feature` for greenfield features that need design decisions before scaffold (data model unclear, API surface ambiguous, UI shape needs design)
- Use `/v-build` for changes that don't need full scaffolding (1-3 file modifications)
- Use `/v-audit-code` for restructuring existing code without adding new entities (absorbed `/v-refactor` 2026-07-06)

### Not for

- Non-Laravel projects (this skill is Laravel-specific; Framework Detection branches accordingly)
- Bespoke patterns that intentionally deviate from Laravel convention (use `/v-build` with explicit plan)
- UI-only scaffolding without a backend entity (use `/interface-design` + `/v-build`)


## Framework Detection

Before scaffolding, detect the project stack to determine available scaffold types, file locations, and conventions:

```bash
[ -f composer.json ] && STACK_PHP=$(jq -r '.require // {} | keys[]' composer.json 2>/dev/null | grep -E 'laravel|symfony|slim' | head -1)
[ -f package.json ] && STACK_JS=$(jq -r '.dependencies // {} | keys[]' package.json 2>/dev/null | grep -E 'next|nuxt|svelte|astro|remix|react|vue|angular|express|fastify|hono' | head -1)
[ -f pyproject.toml ] && STACK_PY=$(grep -E 'django|flask|fastapi' pyproject.toml 2>/dev/null | head -1)
[ -f Cargo.toml ] && STACK_RUST=true
[ -f go.mod ] && STACK_GO=true
[ -f Gemfile ] && STACK_RUBY=$(grep -E 'rails|sinatra|hanami' Gemfile 2>/dev/null | head -1)
```

**Scaffold types per framework:**

| Framework | Available Types |
|-----------|----------------|
| Laravel | model (+ factory + migration), service, job, notification, request, page (Inertia), enum, middleware, event, listener, command |
| Next.js | page, api-route, component, hook, middleware, server-action |
| SvelteKit | page, api-route, component, store, hook |
| Django | model, view, serializer, management-command, signal, middleware |
| FastAPI | router, model, schema, dependency, middleware |
| Rails | model, controller, service, job, mailer, channel |
| Express/Fastify/Hono | route, middleware, controller, service |
| Unknown | Ask user for framework → fall back to generic service/test pattern |

If the detected stack doesn't match Laravel, adjust the entry point options and all file locations accordingly. The Pattern Reference step (reading an existing file) is especially critical for non-Laravel projects where conventions may vary.

### Error Handling
- **File already exists:** If a target file already exists, do NOT overwrite. Log `"scaffold_skipped": "file_exists"` and suggest the user run `/v-audit-code` or `/v-build` to modify existing files.
- **Framework detection fails:** If no framework is detected (no package.json, composer.json, Gemfile, etc.), ask the user what framework they're using via AskUserQuestion before proceeding. Do not guess.
- **Framework-specific commands unavailable:** If the project's Ziggy command (`composer ziggy` / `scripts/ziggy-generate.sh`, or bare `php artisan ziggy:generate` as fallback) or a similar framework CLI is not available, skip that step and log it (`ziggy: skipped_not_available`). The scaffold is still valid without generated route helpers.

## Workflow

0. Resolve project root per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from invocation prompt if present, else `git rev-parse --show-toplevel`; if that does not yield a safe repo root, stop and ask for PROJECT_ROOT explicitly. Do not fall back to `pwd`.
1. **Detect framework** (see above)
2. If no type flag, ask: "What should I scaffold?" (options filtered by detected framework)
3. Ask for name (or parse from arguments)
4. If service with external API: ask about external API calls
5. Find existing reference pattern in the codebase (read one similar file)
5a. For UI scaffolds (page, component): design token discovery is superseded by
    `_v-design.md` § Design System Application Order — the canonical token set
    always applies; there are no per-project discovered tokens to explore for.
    Scaffold directly against the canonical tokens (Inter + JetBrains Mono the
    only font families, semantic palette, `html[data-theme]` theming, fixed
    border+shadow depth): never `bg-white` or raw palette colors — light values
    come from the `[data-theme="light"]` override, never per-element light-mode
    classes, and the marketing-hero display font exception never applies to
    scaffolds. Read `.interface-design/system.md` (the per-product OVERLAY) for
    `--accent`, category `-bg`/`-text` pairs, and branding; it cannot override
    palette, typography, spacing, or components.
    - **Canonical `:root`/`@theme` blocks absent or off-spec:** invoke
      `/interface-design` only to INSTALL the canonical blocks (and generate
      the overlay if missing), then continue scaffolding — no stop-and-explore.
      If `/interface-design` is unavailable, install the canonical set directly
      from `_v-design.md` § Canonical Token Set and log
      `design_tokens: installed_from_spec`.
6. Create files (location depends on type AND framework). **For multi-file scaffolds that also APPEND to shared files** (Inertia page → route in `routes/web.php` + entry in the Vitest `mockRoutes` map; SaaS composites → `bootstrap/app.php` registrations): grep the shared file for the identifier (route name, map key, alias) BEFORE appending, and skip if already present — the create-only "file exists → skip" rule does not protect append targets from duplication on re-run.
7. Create test file using the framework's test runner (Pest/PHPUnit for PHP, Vitest/Jest for JS, pytest for Python, RSpec/Minitest for Ruby, cargo test for Rust, go test for Go). **For an Inertia page the RED test is a Pest feature test** hitting the named route and asserting `assertInertia(fn ($page) => $page->component('{Dir}/{Name}')->has(...))`; the `.tsx` existence is enforced separately by the project's page-existence contract test (no new entry needed). See `references/laravel-scaffolds.md` § Inertia Page.
8. Print registration snippet + completion banner. **Laravel is on Laravel 13** — middleware aliases, extra route files, and scheduled tasks register in `bootstrap/app.php` (`->withMiddleware`/`->withRouting`/`->withSchedule`); events/listeners auto-discover. There is no `app/Http/Kernel.php` or `EventServiceProvider` — never emit `Kernel.php`-era registration. See `references/laravel-scaffolds.md` § Registration idiom (Laravel 13)
9. Conditionally update CLAUDE.md — only per the conditions in § CLAUDE.md Auto-Update

## Entry Point

If no argument or `--type` flag, present the 4 scaffold types most relevant to the detected
framework and request (plus the tool's auto "Other" for anything else) — never all of them
at once; the tool hard-caps at 4 explicit options. **When invoked by orchestrator with
explicit type**, use that type directly — no question needed. For Laravel (default), the
full catalog to filter from:
```yaml
question: "What should I scaffold?"
header: "Type"
options:
  # aq-exempt: catalog — model presents the 4 scaffold types most relevant to the detected
  # framework/request + the tool's auto "Other", not all 15 at once.
  - label: "Model"
    description: "Eloquent model + factory + migration + test (hard deletes by default)"
  - label: "Service"
    description: "Service class + test + optional job"
  - label: "Job"
    description: "Queued job + test with retry/backoff"
  - label: "Notification"
    description: "Notification class + test + optional mail template"
  - label: "Form Request"
    description: "Form request with validation rules + test"
  - label: "Inertia Page"
    description: "Page component + controller + route + test"
  - label: "Enum"
    description: "PHP enum + usage documentation"
  - label: "SaaS Base (Recommended for new apps)"
    description: "Full SaaS foundation: team + RBAC + billing + audit + settings — scaffolded in dependency order"
  - label: "Team/Organization"
    description: "Team model + invitations + roles + policies"
  - label: "Billing/Subscription"
    description: "Cashier billing service + webhooks + plan middleware"
  - label: "RBAC/Permissions"
    description: "Roles + permissions + policies + middleware (prerequisite: Team scaffold or existing Team model)"
  - label: "Settings Page"
    description: "Multi-section settings with profile, team, billing, notifications (prerequisite: Team + RBAC + Billing scaffolds or existing equivalents)"
  - label: "Audit Log"
    description: "Audit logging infrastructure with auto-tracking trait"
  - label: "Admin Dashboard"
    description: "Internal admin tools: user lookup, subscription management, impersonation, audit viewer"
  - label: "API Versioning"
    description: "Versioned API routes, version middleware, deprecation headers, response envelope"
```

For Next.js/SvelteKit/Nuxt (JS-first):
```yaml
options:
  - label: "Page"
    description: "Page component with loader/layout + test"
  - label: "API Route"
    description: "API endpoint with validation + test"
  - label: "Component"
    description: "Reusable component with props interface + test"
  - label: "Hook/Composable"
    description: "Custom hook or composable + test"
```

For Django/FastAPI (Python):
```yaml
options:
  - label: "Model + Migration"
    description: "Database model with migration + admin registration"
  - label: "View/Router"
    description: "API endpoint with serializer/schema + test"
  - label: "Service"
    description: "Business logic service + test"
  - label: "Management Command"
    description: "CLI command + test"
```

For Rails (Ruby):
```yaml
options:
  - label: "Model"
    description: "ActiveRecord model + migration + factory + spec"
  - label: "Controller"
    description: "Controller with actions + routes + specs"
  - label: "Service"
    description: "Service object + spec"
  - label: "Job"
    description: "Background job + spec"
```

Then ask for name:
```yaml
question: "What should I name it?"
header: "Name"
```

Then for services only:
```yaml
question: "Does this service make external API calls?"
header: "External API"
options:
  - label: "No (Recommended)"
    description: "Internal business logic only"
  - label: "Yes"
    description: "Calls external HTTP APIs — will also create a Job"
```

**Programmatic fallback (when invoked by orchestrator):** Extract name from invocation context (e.g., "scaffold UserSubscription service" → `UserSubscription`). Auto-detect external API from context keywords ("API", "HTTP", "external", "webhook").

## Pattern Reference (Framework-Aware)

Before creating, find the most similar existing file **for the detected framework**:

```bash
# Laravel
[ "$STACK_PHP" ] && ls app/Services/*.php 2>/dev/null | head -10

# Next.js / React
[ "$STACK_JS" = "next" ] && ls app/**/page.tsx src/app/**/page.tsx 2>/dev/null | head -10

# SvelteKit
[ "$STACK_JS" = "svelte" ] && ls src/routes/**/+page.svelte 2>/dev/null | head -10

# Django
[ "$STACK_PY" ] && ls */views.py */models.py 2>/dev/null | head -10

# Rails
[ "$STACK_RUBY" ] && ls app/services/*.rb app/controllers/*.rb 2>/dev/null | head -10

# Express/Fastify/Hono
[ "$STACK_JS" = "express" ] || [ "$STACK_JS" = "fastify" ] || [ "$STACK_JS" = "hono" ] && ls src/routes/*.ts routes/*.ts 2>/dev/null | head -10

# Go
[ "$STACK_GO" ] && ls cmd/**/*.go internal/**/*.go 2>/dev/null | head -10

# Rust
[ "$STACK_RUST" ] && ls src/**/*.rs 2>/dev/null | head -10
```

Read one file matching the scaffold type to match the project's conventions (imports, naming, patterns, test style).

**For non-Laravel frameworks:** The detailed scaffold templates below are Laravel examples. For other frameworks, the Pattern Reference read is your primary source of truth — match the project's existing conventions, file locations, naming patterns, and test framework. Do NOT apply Laravel patterns to non-Laravel projects.

## Laravel-Specific Scaffolds

**Moved to:** `references/laravel-scaffolds.md`.

**Summary:** the catalog applies only when
`DETECTED_STACK = laravel`. It covers single-class scaffolds
(Service, Job, Notification, Form Request, Inertia Page, Enum)
and SaaS composite scaffolds (Team, Billing, RBAC, Settings,
Audit Log, Admin Dashboard, API Versioning, plus the SaaS Base
composite that runs all of them in dependency order). Each entry
ships with file paths, conventions, prerequisites, and the
test layout.

**Trigger to load:** the framework-detection step (Workflow Step 1)
resolves to `laravel`. Read the reference in full before the first
`Write` call — dependency ordering and cross-scaffold wiring rules
live there, and skipping them produces broken composite scaffolds.

**For other frameworks:** use the Pattern Reference section above
to discover conventions on the fly — this Laravel catalog does
not apply.

## CLAUDE.md Auto-Update

After scaffolding, apply the CLAUDE.md auto-update only when the new class earns a durable entry. Destinations by type:
- New service → add to service catalog in `app/CLAUDE.md`
- New enum → add to Enums table
- New job → add to Jobs section if it has specific behavior
- New page → verify Inertia page contract in `resources/js/CLAUDE.md`

Do **not** auto-update CLAUDE.md for every scaffold by default. Update it only when at least one of these is true:
- the scaffold adds a durable catalog entry the project already maintains in CLAUDE.md
- the scaffold introduces a new convention, contract, route namespace, or operational dependency future sessions must know
- the scaffold changes an existing documented pattern enough that the old CLAUDE.md entry would become misleading

If none of those apply, skip the CLAUDE.md edit and leave the scaffold focused on code and tests.

## Lightweight Verification

After creating files, run a quick verification to confirm scaffolded code compiles:

```bash
# Syntax check per framework:
# PHP:    for f in {files}; do php -l "$f" 2>&1; done
# Python: python -m py_compile {file}
# Ruby:   ruby -c {file}
# Rust:   cargo check 2>&1 | tail -10
# Go:     go vet ./... 2>&1 | tail -10
# TS/TSX: npx tsc --noEmit 2>&1 | tail -10

# Test: Run the scaffolded test to confirm it reaches RED state (expected to fail)
# PHP:    ./vendor/bin/pest {test_file_path} 2>&1 | tail -5
# JS/TS:  npx vitest run {test_file_path} 2>&1 | tail -5
# Python: pytest {test_file_path} 2>&1 | tail -5
# Ruby:   bundle exec rspec {test_file_path} 2>&1 | tail -5
# Rust:   cargo test {test_name} 2>&1 | tail -5
# Go:     go test -run {TestName} ./... 2>&1 | tail -5
```

If the test file doesn't compile (syntax error, missing import), fix it before reporting completion. The test should FAIL (red state) — a passing test means the skeleton isn't testing anything new.

**Multi-language scaffolds (Inertia page).** A page spans PHP + TS, so run BOTH syntax checks: `php -l` on the controller and `npx tsc --noEmit` (scoped where possible) on the `.tsx`. The RED test is the Pest feature test (Step 7). A `.tsx` that fails typecheck — commonly an unmocked `route()` or a missing `mockRoutes` entry — is a fix-needed error, not an expected RED.

## Completion

```
========================================
  SCAFFOLD COMPLETE: {Type}
  Created:
    - {list all created files}

  Verification:
    - Syntax: {pass/fail}
    - Test: {RED (expected) / ERROR (fix needed)}

  Post-scaffold:
    - {any registration or config needed}

  Next: Implement the {type}, then run tests.
========================================
```

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Scaffolded model has different conventions than existing models in project | Existing model patterns not sampled | Read 2-3 existing models in `app/Models/` before scaffolding; match their style (Laravel-default vs project-customized) |
| 2 | Factory generated for new model has hard-coded values, not Faker | Factory boilerplate stale | Factory MUST use `$this->faker->...()` for variable fields; hard-coded values cause flaky tests |
| 3 | Full CRUD-resource scaffold ran but no migration generated | Scaffold scope incomplete for the requested type | Scope is per scaffold TYPE, not universal. A **single-class** scaffold is complete with just its own artifact(s): `--type model` = model + factory + migration + test; `--type service` = service + test; `--type enum` = enum (+ docs); `--type request` = form request. Only a **full CRUD-resource** scaffold owes the octet (model + migration + factory + policy + form-request + controller + view + test) — flag "incomplete" only when the requested type's own artifacts are missing, never because a Service lacks a migration |
| 4 | Inertia page scaffolded with PHP route but no `.tsx` component | Inertia contract not honored | EVERY `Inertia::render('X/Y')` requires `resources/js/Pages/X/Y.tsx` to exist BEFORE controller is committed (contract test enforces) |
| 5 | Scaffolded controller missing Form Request validation | Validation defaulted to inline | Project policy: every mutation endpoint uses Form Request, never inline `$request->validate()` |
| 6 | New page renders in-app but `ziggy.js` in-sync contract test fails in CI | Regenerated Ziggy with bare `php artisan ziggy:generate` | Regenerate the project's way — `composer ziggy` / `scripts/ziggy-generate.sh` if present. Bare artisan runs against dev `.env` and drops feature-gated routes, desyncing the committed `ziggy.js`. Fallback to bare artisan only when no wrapper exists |
| 7 | Re-running a page scaffold produces a duplicate route line or duplicate `mockRoutes` key | Append targets not guarded; only the `.tsx`/controller got the create-only skip | Grep `routes/web.php` for the route name and the setup file for the map key BEFORE appending; skip if present (see Workflow Step 6 + Idempotency) |
| 8 | Scaffolded page renders bare (no sidebar / no theming) or has no browser-tab title | Layout wrapper and `<Head>` omitted | Wrap in the project's app layout (sample sibling pages; apply via `Page.layout =` or JSX to match) and add `<Head title="...">`. A layout-less page is a defect, not a minimal scaffold |
## Idempotency

**Idempotent for the scaffold target.** Re-running on the same name is a no-op if the scaffold already exists; produces a fresh scaffold otherwise. Filesystem-mutating: creates scaffold files.

**Create-only files** (models, services, jobs, page `.tsx` + controller) are protected by the "file exists → skip" rule. **Append targets are NOT** — a scaffold that also edits a shared file (Inertia page → `routes/web.php` + `mockRoutes`; SaaS composites → `bootstrap/app.php`) must grep for its identifier before appending, or a re-run duplicates the route/mock/registration. Guard every append (see Workflow Step 6, Gotcha #7).
