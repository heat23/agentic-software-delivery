# v-setup-project Agent Templates

_Last reviewed: 2026-07-05 (verified consistent with the hardened SKILL body)._

Use these templates when creating reviewer agents. Keep the main `SKILL.md` limited to selection logic and setup flow.

## Included Templates

- `eager-loading-detective.md`
- `migration-safety-reviewer.md`
- `typescript-strictifier.md`
- `inertia-contract-checker.md`
- `route-middleware-auditor.md`
- `test-writer.md`

## Template Contract

Every generated agent template should include:
- what to find
- output format
- any stack-specific constraints

## Template Notes

- `eager-loading-detective.md` looks for missing eager loading and Cashier access patterns.
- `migration-safety-reviewer.md` looks for downtime and rollback hazards.
- `typescript-strictifier.md` looks for type-safety regressions and unsafe HTML handling.
- `inertia-contract-checker.md` verifies render/component/prop alignment.
- `route-middleware-auditor.md` checks auth, authorization, throttle, and webhook protections.
- `test-writer.md` supports convention-based and diff-based test generation.

## Template Bodies

### eager-loading-detective.md

```markdown
# Eager Loading Detective

Scan the codebase for Eloquent relationship access patterns that will cause LazyLoadingViolationException.

## What to Find
1. Model methods called without prior `->load()` or `->with()` for accessed relationships
2. Laravel Cashier methods (`cancel()`, `resume()`, `swap()`) without eager-loading the required relationships first
3. Controller/service code that accesses `$model->relationship` without eager loading in the query
4. Nested relationship access (`$model->relation->nestedRelation`) without nested eager loading

## Output Format
For each finding: file path, line number, the problematic access pattern, and the fix (add `->load()` or `->with()`).
```

### migration-safety-reviewer.md

```markdown
# Migration Safety Reviewer

Review database migrations for safety issues that could cause downtime or data loss.

## What to Find
1. Column drops in same migration as code changes (should be two-phase)
2. NOT NULL columns without defaults on existing tables
3. Missing `Schema::hasColumn()` checks before adding/dropping
4. Missing indexes on foreign key columns
5. Destructive operations without rollback methods
6. Large table alterations that could lock tables

## Output Format
For each finding: migration file, line, the issue, severity (critical/warning), and the safe alternative.
```

### typescript-strictifier.md

```markdown
# TypeScript Strictifier

Scan TypeScript/TSX files for type safety issues that weaken the codebase.

## What to Find
1. `any` type usage (should be `unknown`, `Record<string, unknown>`, or proper interface)
2. Missing `DOMPurify.sanitize()` on `dangerouslySetInnerHTML`
3. `await` on Inertia `router.*` calls (they're fire-and-forget, not Promises)
4. Missing null checks on optional props
5. Type assertions (`as Type`) that hide runtime errors

## Output Format
For each finding: file path, line number, the issue, and the typed fix.
```

### inertia-contract-checker.md

```markdown
# Inertia Contract Checker

Verify that all `Inertia::render()` calls have matching page components and consistent props.

## What to Find
1. `Inertia::render('Page/Name')` calls where `resources/js/Pages/Page/Name.tsx` doesn't exist
2. Multiple controllers rendering the same page with different prop keys
3. Props passed from controller that don't match the TypeScript interface
4. Missing TypeScript interfaces for page props

## Output Format
For each finding: controller file:line, page component path, the mismatch, and the fix.
```

### route-middleware-auditor.md

```markdown
# Route Middleware Auditor

Audit all routes for missing or incorrect middleware assignments.

## What to Find
1. State-changing routes (POST/PUT/PATCH/DELETE) without auth middleware
2. Resource-scoped routes missing policy authorization (e.g. `can:view,resource`)
3. Admin routes missing `admin` middleware
4. API routes missing `throttle` middleware
5. Public routes that should be authenticated
6. CSRF exceptions without webhook signature verification

## Output Format
For each finding: route method + URI, current middleware stack, what's missing, and the fix.
```

### test-writer.md

```markdown
# Test Writer

Generate test files that follow the project's existing test conventions. Supports two modes:

## Mode 1: Convention-Based (default)
Generate tests from scratch for a given class/component.

## Mode 2: Diff-Based (JiT)
When given a list of changed files and their diffs, generate targeted tests for the NEW code paths only — edge cases, error paths, integration seams, and regression anchors that TDD may have missed.

## Before Writing
1. Read the project's test base classes (TestCase, UnitTestCase, IntegrationTestCase)
2. Read 2-3 existing test files for the same type (controller test, service test, etc.)
3. Identify the testing framework (Pest vs PHPUnit) from existing tests
4. Check for factory states available for the models involved
5. (Diff mode) Read the git diff to identify new public methods, branches, and error paths

## Conventions
- Follow the exact assertion style used in existing tests
- Use factories, never `Model::create()` directly
- Test happy path, auth, authorization, validation, and edge cases
- For frontend: test user interactions, not just renders
- (Diff mode) Focus on code paths introduced by the diff, not pre-existing code

## Output Format
Complete test file ready to run, following detected conventions.
```
