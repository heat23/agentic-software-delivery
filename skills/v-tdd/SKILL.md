---
name: v-tdd
description: "Use when creating failing test skeletons before implementation."
allowed-tools: Read, Write, Edit, Bash, Grep, AskUserQuestion, mcp__plugin_context7_context7__resolve-library-id, mcp__plugin_context7_context7__get-library-docs
argument-hint: "<ClassName | path | route | bug-report | audit-finding | acceptance-criterion>"
user-invocable: false
disable-model-invocation: true
model: sonnet
context: fork
---
<!-- skill: v-tdd | version: 1.2.0 | last-updated: 2026-08-02 -->


# 2026 Canonical Contract

Tier: Orchestration primitive. **Orchestrator-only — not user-invocable.** `v-build` calls this when backend logic requires a red phase; reached via `/v`.

This contract overrides older sections below on conflict.

Follow `_v-core.md` and `_v-exec.md` (always loaded). Load `_v-growth.md` conditionally — only when the test target has a `success_event` annotation, an analytics-touching pattern, or the plan declares growth instrumentation. Pure-refactor or pure-logic TDD runs do not need growth context, need no additional reference files, and should NOT scan for analytics wiring.

Rules:
- **RED invariant (v-tdd Tier-1 fix):** at least one newly-added test fails for the **intended product reason** (missing implementation, wrong behavior, contract violation) AND **zero** newly-added tests fail for setup reasons (syntax error, parse error, import-resolution error, fixture-load error). "All failing" is NOT the invariant — the previous wording in the success banner was wrong; the gate is "right kind of failure," not "everything broken."
- if tests already exist, prefer appending a scoped failing case
- **Test-only writes during RED (v-tdd Tier-1 fix — non-negotiable):** /v-tdd is allowed to Write or Edit ONLY: (1) new test files under `tests/`, `spec/`, `__tests__/`, or sibling `*.test.*` files; (2) test helpers/fixtures/factories under `tests/Helpers/`, `tests/Factories/`, `tests/Fixtures/`, `__mocks__/`; (3) test-config files only when the project has none yet (`pest.config.php`, `vitest.config.ts`, `jest.config.js`). **FORBIDDEN during RED phase:** editing production source files (e.g., `app/`, `src/`, `lib/`, `resources/js/Components/`, `resources/js/Pages/`) — even to "fix setup" or "add a missing class stub." If RED requires a class that doesn't exist, that's the GAP the test is supposed to expose; do NOT create the class. v-build owns the GREEN phase and will create it.
- include instrumentation assertions for user-facing analytics changes when practical
- **Success event validation:** When the plan or `_v-growth.md` specifies a `success_event` for the feature being tested, include at least one assertion verifying: (1) the event listener/dispatcher exists, and (2) it fires with the correct payload on the success path. Missing analytics wiring is a test gap, not a nice-to-have.

```yaml
contract:
  tier: orchestration-primitive
  accepts:
    - class-name              # /v-tdd PaymentService
    - file-path               # /v-tdd app/Services/PaymentService.php
    - route                   # /v-tdd "POST /api/accounts/{id}/subscribe"
    - bug-report              # /v-tdd "users report 500 when canceling subscription mid-cycle"
    - audit-finding-id        # /v-tdd FND-042 (read from AUDIT_REPORT_*.md or AGENT_REVIEW_*.md)
    - test_first-spec         # /v-tdd "from PLAN.md test_first section"  (read PLAN_*.md)
    - acceptance-criterion    # /v-tdd "given X when Y then Z" (Gherkin/Given-When-Then)
    - async-lifecycle-trace   # /v-tdd <reads ASYNC_LIFECYCLE_TRACE_<sid>.md, one test per failure_modes_to_test entry>
    - workflow-blast-radius   # /v-tdd <reads WORKFLOW_BLAST_RADIUS_<sid>.md, one feature/unit test per states_to_verify entry>
    - success-criteria        # /v-tdd <reads SUCCESS_CRITERIA_<sid>.md, one test per verify_by:test|both criterion + backend-observable workflow_states>
    - impact-map              # /v-tdd <reads IMPACT_MAP_<sid>.md, one feature/unit test per tests_to_add entry (downstream subsystem consumers)>
  produces: [test file (RED state)]
  invokes: []
  invoked-by: [/v, /v-build, user]
  estimated_tokens: 8k-20k
  estimated_duration: 2-5 min
```

# /v-tdd - Test-Driven Development Starter

Creates test skeleton first, verifies failure, then signals ready for implementation.

**Usage:** `/v-tdd ClassName` or `/v-tdd path/to/file`

## Skill Boundaries

**SME persona:** This skill is run by a **senior TDD-discipline practitioner** — specialty is the red-green-refactor cycle. Knows that 'fail-loud red' is the difference between TDD and test-after, that boundary tests with manually-computed expected values catch tautological loops, and that refactor is the third step, not the first.

### Best fit

- Writing the RED phase — failing test skeleton — for backend logic (PHP services, jobs, controllers; Python services; Node services)
- React data hooks and stateful logic where logic-vs-render separation makes test-first practical
- Writing the RED phase for new feature implementation when the project's CLAUDE.md mandates TDD discipline (the green/refactor phases happen in `/v-build`)

### Use instead

- `/v-build` — when the next step is full implementation (red + green + refactor); v-build calls v-tdd internally for the red phase
- Direct test writing — for trivial unit tests where the red phase doesn't add value (snapshot tests, simple render tests)

### Not for

- Pure UI component visual tests — use `/v-build` directly; the red phase isn't useful for "does this render"
- Tests for code that already passes — no red phase exists when behavior is already correct
- End-to-end / browser tests — different testing layer; this skill is unit + feature test scope only
- Test refactoring — use `/v-audit-code` (absorbed `/v-refactor` 2026-07-06)


## Workflow

0. Resolve project root per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from invocation prompt if present, else `git rev-parse --show-toplevel`; if that does not yield a safe repo root, stop and ask for PROJECT_ROOT explicitly. Do not fall back to `pwd`.
0.5. **Async lifecycle trace check (mandatory):** check for `ASYNC_LIFECYCLE_TRACE_<sid>.md` at `$PROJECT_ROOT/`. If present, this file was written by /v Step 1.5 and contains a `failure_modes_to_test` YAML list where each entry is a **structured object** with these fields:
    ```yaml
    - mode: "<idempotency|retry|ordering|dead-letter|partial-failure|observer-fanout|poison-message>"
      scenario: "<one-line plain-English failure being tested>"
      arrange: "<state/inputs to set up>"
      act: "<what to invoke>"
      assert: "<what must hold>"
    ```
    EVERY entry becomes a separate RED-phase test, using `arrange/act/assert` directly as the test body skeleton. Do NOT write a vague placeholder — the trace gave you scaffolding, use it.

    **Pest mapping (per-test arrange — DO NOT use `beforeEach()`):**
    ```php
    test('idempotency: handler runs twice → same outcome', function () {
        // arrange (inline, per-test)
        $payload = ['user_id' => 1, 'amount' => 100];

        // act
        ProcessPaymentJob::dispatchSync($payload);
        ProcessPaymentJob::dispatchSync($payload);  // second run

        // assert
        expect(Payment::where('user_id', 1)->count())->toBe(1);
    });
    ```
    Use `beforeEach()` ONLY for invariants that apply to ALL failure-mode tests in the file (e.g., `Queue::fake()`, factory-seeded admin user). If you put a single failure-mode's arrange in `beforeEach()`, it leaks into the OTHER failure-mode tests in the same file → cross-contamination.

    **Vitest mapping (same principle):**
    ```typescript
    it('ordering: events arrive out of order', () => {
      // arrange (inline)
      const a = makeEvent({ ts: 100 });
      const b = makeEvent({ ts: 50 });  // earlier ts but arrives later

      // act
      handler.process(a);
      handler.process(b);

      // assert
      expect(handler.state).toMatchObject({ lastTs: 100 });  // not overwritten by stale b
    });
    ```
    Use `beforeEach()` only for shared mock resets (`vi.clearAllMocks()`) or setup that applies to every failure-mode test.

    **Integration-only modes:** the trace may ALSO list `integration_tests_needed` (modes with `test_layer: integration` — race, timeout, split-brain, head-of-line blocking, poison-message-on-real-broker). /v-tdd does NOT generate tests for these (they need a real broker + worker + timing). Surface them in the post-RED report so the operator sees them, but write zero tests for them in this pass.

    The fix at /v-build must make ALL `failure_modes_to_test` entries pass — not just the reported symptom. If the artifact is missing, proceed with normal flow (reported-symptom test only).
0.6. **Workflow scope check (mandatory):** check for `WORKFLOW_BLAST_RADIUS_<sid>.md` (bug-fixes, /v Step 1.6) and `SUCCESS_CRITERIA_<sid>.md` (features, /v Step 1.7) at `$PROJECT_ROOT/`.
    - **`WORKFLOW_BLAST_RADIUS`** carries a `states_to_verify` list (each with `state / scenario / test_layer / arrange / act / assert`). EVERY entry with `test_layer: feature|unit` becomes a separate RED-phase test using arrange/act/assert as the skeleton. The fix must make ALL pass — not just the reported state.
    - **`SUCCESS_CRITERIA`** carries `criteria[]`, a `workflow_states` block, AND a `behavior_coverage` block. Write a failing test for each `criterion` with `verify_by: test|both`, and for each backend-observable `workflow_states` entry that isn't `n/a` (empty/error/permission_denied/concurrent/double_submit are usually feature-testable). **Also write a RED test for each non-`n/a` `behavior_coverage` lens — these are the highest-leverage RED tests (they make the *self-inflicted* bug fail FIRST, so the first draft must be correct):** `inverse` → assert the new behavior does NOT fire in the complementary case (wrong actor/role/tier/input/state); `isolation` → assert two distinct actors get isolated results (A's value never surfaces for B); `branch` → assert every branch of the new conditional, including the one the happy path skips.
    - **`IMPACT_MAP`** (/v Step 1.8) carries `tests_to_add[]` — one entry per impacted downstream subsystem (reporting/metrics value correctness, cache write→read freshness, async/email consumers, DB-integrity rules, authz denials), each with `subsystem / scenario / test_layer / arrange / act / assert`. Write one feature/unit test per entry. These exercise consumers the diff does NOT touch — the highest-value regression catches.
    - **Route→feature test over mock-only unit test (workflow rule):** for any workflow criterion or state with a request/response/DB effect, write a feature test that hits the **real route → real DB** (`$this->post(...)`, `actingAs()`, assert status + payload + DB state). A unit test that mocks the controller/service/HTTP layer is **insufficient evidence** for workflow correctness — it is exactly the green-but-broken case this scope check exists to prevent. (See the over-mocking entries in the anti-pattern catalog.)
    - **Out of scope:** `browser_only_states` and `verify_by: browser` criteria (loading/slow_network/client-rendering/focus) go to `v-workflow-verifier` in /v Step 3.5 — do NOT write tests for them here.
    - If multiple of `ASYNC_LIFECYCLE_TRACE` / `WORKFLOW_BLAST_RADIUS` / `SUCCESS_CRITERIA` / `IMPACT_MAP` exist, MERGE all their lists into one RED set (dedupe overlapping scenarios). If none exist, proceed with normal flow.
1. Parse argument to determine class/component name
2. Detect stack (PHP → Pest, React → Vitest)
3. Find similar test files to follow existing patterns
4. Create test file with skeleton tests — **one test per `failure_modes_to_test` entry if the trace artifact exists; otherwise one test for the reported symptom**
5. Run test — expect RED per the **Rules § RED invariant** (≥1 new test fails for intended reason; 0 new tests fail for setup). NOT "all failing" — that wording is incorrect; see the RED-invariant bullet in the Rules section above.
5.5. **Test-only-writes enforcement gate** (Tier-1 fix): grep the session writes log to confirm no production-source paths were written. See "Step 5.5" below for the bash gate.
6. Report and prompt to implement

## Stack Detection (Tier-3 expanded)

```bash
# PHP
test -f vendor/bin/pest && echo "PEST"
test -f vendor/bin/phpunit && echo "PHPUNIT"

# JavaScript / TypeScript
test -f node_modules/.bin/vitest && echo "VITEST"
test -f node_modules/.bin/jest && echo "JEST"
test -f bun.lockb && echo "BUN_TEST"            # Bun's built-in test runner
test -f deno.json -o -f deno.jsonc && echo "DENO_TEST"

# Compiled languages
test -f Cargo.toml && echo "RUST_CARGO_TEST"
test -f go.mod && echo "GO_TEST"

# Python
test -f pyproject.toml && echo "PYTHON_PYTEST"
test -f setup.py && echo "PYTHON_PYTEST"
test -f Pipfile && echo "PYTHON_PYTEST"

# Ruby
test -f Gemfile && grep -q 'rspec\|minitest' Gemfile 2>/dev/null && echo "RUBY_RSPEC_OR_MINITEST"

# Elixir / Phoenix
test -f mix.exs && echo "ELIXIR_EXUNIT"

# .NET
ls *.csproj 2>/dev/null | head -1 | grep -q . && echo "DOTNET_TEST"

# Java / Kotlin
test -f pom.xml && echo "MAVEN_TEST"
test -f build.gradle -o -f build.gradle.kts && echo "GRADLE_TEST"
```

**Monorepo signals (test commands vary per-package):**
```bash
# yarn workspaces / pnpm / npm-workspaces
test -f package.json && grep -q '"workspaces"' package.json 2>/dev/null && echo "MONOREPO_NPM_WORKSPACES"
# Nx
test -f nx.json && echo "MONOREPO_NX"
# Turborepo
test -f turbo.json && echo "MONOREPO_TURBO"
# Lerna
test -f lerna.json && echo "MONOREPO_LERNA"
# Yarn Berry .yarnrc.yml
test -f .yarnrc.yml && echo "MONOREPO_YARN_BERRY"
```

In a monorepo, the test invocation is per-package. Resolve the target package first:
```bash
# Walk up from target file to find nearest package.json (or composer.json for Laravel monorepos)
T="{target_file_path}"
PKG_DIR=$(dirname "$T")
while [ "$PKG_DIR" != "/" ] && [ ! -f "$PKG_DIR/package.json" ]; do PKG_DIR=$(dirname "$PKG_DIR"); done
# Run test command scoped to that package (e.g., `pnpm --filter "$(basename $PKG_DIR)" test`,
# `yarn workspace <name> test`, `nx test <project>`, etc.)
```

**For stacks without explicit templates below (Rust, Go, Python, etc.):** Use the generic TDD approach — read 2-3 existing test files to discover naming conventions, assertion patterns, and file locations, then scaffold a test following those patterns. The TDD cycle (RED → GREEN → REFACTOR) is universal.

## Test Convention Discovery

Before writing any test, scan existing tests to discover project patterns:

```bash
# Find existing test patterns
ls tests/Feature/*.php 2>/dev/null | head -3
ls tests/Unit/**/*.php 2>/dev/null | head -3
ls resources/js/**/*.test.tsx 2>/dev/null | head -3
```

Extract and cache as mental model:
- **Test runner syntax** (Pest vs PHPUnit vs Vitest vs Jest)
- **Common setup patterns** (beforeEach, setUp, setup functions)
- **Factory usage** (how models are created for testing)
- **Mock patterns** (Mockery, vi.mock, jest.mock conventions)
- **Assertion styles** (expect() vs $this->assert*)
- **Test organization** (describe/it vs test classes)

**Note:** If `v-setup-project` has been run, test conventions may already be documented in `.claude/` overlays or repo-local convention files — check before discovering.

**Reference:** Read `~/.claude/skills/v-tdd/references/v-testing-patterns.md` for centralized testing patterns (factories, mocking, HTTP testing, frontend testing).

**Library-doc lookup (Tier-3 — using allowed MCP tools):** when the project uses a less-common test library (e.g., Pest plugin, custom Vitest matcher, MSW v2, Playwright fixtures) AND the existing tests don't show clear patterns for the assertion you need, look up the library's current API:
1. `mcp__plugin_context7_context7__resolve-library-id` with the library name (e.g., "pestphp/pest", "msw", "playwright")
2. `mcp__plugin_context7_context7__get-library-docs` with the resolved ID + topic (e.g., "matchers", "intercept", "page-object")

Skip this step for first-party libraries that ship with the framework (Pest core, Vitest core, Jest core) — those are well-known and the project's existing tests are the better source. Use the MCP lookup only when discovering a library-specific API you don't already know.

## Entry Point — Input-Type Detection (Tier-2 expanded)

v-tdd accepts ANY of the following input types. Detection runs in order; first match wins.

### A. ASYNC_LIFECYCLE_TRACE artifact (highest priority)

If `ASYNC_LIFECYCLE_TRACE_${CLAUDE_SESSION_ID}.md` exists at `$PROJECT_ROOT/`, /v Step 1.5 ran a lifecycle trace and produced the test scope. Workflow step 0.5 already handles this. Skip the Entry Point detection below — the trace IS the input.

### A.5 WORKFLOW_BLAST_RADIUS / SUCCESS_CRITERIA artifact (high priority)

If `WORKFLOW_BLAST_RADIUS_${CLAUDE_SESSION_ID}.md`, `SUCCESS_CRITERIA_${CLAUDE_SESSION_ID}.md`, or `IMPACT_MAP_${CLAUDE_SESSION_ID}.md` exists at `$PROJECT_ROOT/`, /v Step 1.6/1.7/1.8 produced the test scope. Workflow step 0.6 already handles this — the `states_to_verify` / `criteria` / `tests_to_add` lists ARE the input (one feature/unit test per backend-observable entry; route→feature tests preferred over mocks; `browser_only_states` / `browser_to_verify` deferred to the Step 3.5 verifier). Can co-exist with input type A (merge all lists).

### B. File path / class name (classic TDD)

Invocation prompt names a target file or class (e.g., `/v-tdd app/Services/PaymentService.php` or `/v-tdd PaymentService`). Class type auto-derived from path:
- `app/Services/` or `app/Domain/*/Services/` → service
- `app/Jobs/` → job
- `app/Http/Controllers/` → controller
- `resources/js/Components/` → React component
- `resources/js/Hooks/` → React hook
- Path doesn't match any pattern → resolve the target type by V_DEPTH:
  - **V_DEPTH = 0 (standalone, interactive):** ask the user which skeleton to scaffold using the **`AskUserQuestion`** tool (per `_v-core.md`: all user-facing questions MUST use it) — options: service / controller / job / React component / React hook. Do NOT guess silently.
  - **V_DEPTH ≥ 1 (called by `/v-build` or the orchestrator) OR the programmatic fallback below:** never block on a question — default to the generic service skeleton and note the assumed type in the RED-phase report so the caller can redirect.

### C. Route specification

Invocation prompt contains a route signature: `METHOD /path`, e.g., `/v-tdd "POST /api/accounts/{id}/subscribe"`. Resolve to the controller method via `php artisan route:list` (Laravel), `rails routes` (Rails), or framework-equivalent. Generate a feature test against the route endpoint, not a unit test against the controller class — the route IS the contract.

### D. Bug report (free-form English)

Invocation prompt describes a bug behaviorally, e.g., `/v-tdd "users report 500 when canceling subscription mid-cycle"`. Treat as TDD-from-behavior:
1. Extract the symptom (500 error) + trigger condition (cancel mid-cycle) + affected entity (subscription).
2. Locate the relevant handler via grep — controller method, job handler, or service.
3. Generate a feature test that REPRODUCES the bug. The test should FAIL with the same symptom as the report.
4. If the bug touches async/queue signals → /v Step 1.5 already classified it; defer to the trace artifact (input type A).

### E. Audit finding ID

Invocation prompt cites a finding ID like `FND-042`, `SREV-3`, `CODEX-1`, etc. Search the project root for the most recent artifact containing the ID: `AUDIT_REPORT_*.md`, `AGENT_REVIEW_*.md`, `VERIFY_DONE_REPORT_*.md`, `GAUNTLET_REPORT_*.md`. Read the finding's `description` + `fix` + `file:line` fields and treat the description as the behavior under test.

### F. PLAN `test_first` spec

If invocation prompt mentions `PLAN`, `/v-plan`, or a `PLAN_*.md` artifact exists at project root, read it and look for a `test_first:` section. Each entry in that section becomes one RED test. The PLAN's `test_first` schema (per `/v-plan` and `/v-new-feature`) is the contract.

### G. Acceptance criterion (Given-When-Then)

Invocation prompt contains Gherkin-style language: "given X, when Y, then Z." Map directly:
- `given` → test setup / fixtures / factories
- `when` → SUT invocation
- `then` → `expect(...)` assertion

### H. No input — error out (TDD-shape preservation)

If NONE of A-G match AND no explicit target was named, exit with:
```
ERROR: v-tdd requires an explicit target. Pass one of:
  - class name:        /v-tdd PaymentService
  - file path:         /v-tdd app/Services/PaymentService.php
  - route:             /v-tdd "POST /api/accounts/{id}/subscribe"
  - bug report:        /v-tdd "users report 500 when canceling subscription"
  - finding ID:        /v-tdd FND-042
  - acceptance:        /v-tdd "given X when Y then Z"

v-tdd does NOT scan for recently-modified source files lacking tests — that would
be test-AFTER (writing tests for code that already exists), which is the opposite
of TDD. The test exists FIRST, then the source.
```

Do NOT fall back to scanning recently-modified files. The previous behavior (now removed in Tier-2) presented untested existing source files as candidates — that's test-after, not TDD. If you want a coverage-fill pass, use `/v-check` instead.

**Programmatic fallback (when invoked by orchestrator with a target):** auto-derive the type from the file path using Entry Point B's derivation table above (no interactive prompt at V_DEPTH ≥ 1). If the path matches no pattern, default to the generic service skeleton per Entry B's V_DEPTH ≥ 1 rule.

## Anti-AI-test-tells reference (v3.8.5+ — canonical catalog dedup'd in Tier-1 fix)

After scaffolding tests, cross-check each one against the canonical AI test smells catalog at **`~/.claude/skills/references/v-tdd-anti-patterns.md`** (shared with `/v-verify-done` — both skills load from the SAME file to prevent drift where v-tdd generates under one catalog and v-verify-done rejects under another).

The catalog enumerates 11 failure modes (self-referential/tautological assertions, tests that exercise nothing but the framework, snapshot-everything, mocking the system under test, asserting on private/internal state, testing framework behavior instead of yours, skipped assertions on shipped code paths, happy-path-only tests for branching code, missing error-path coverage, time-dependent tests without freezing, order-dependent tests) with detection patterns and concrete re-task prompts.

Older v-tdd guidance referenced a local `v-tdd/references/anti-patterns.md`. That file is now a redirect stub; the canonical catalog is the global file. If you read the local stub, follow its redirect.

The Fail-loud RED gate (after Step 5) verifies the test fails for
the RIGHT reason. The anti-patterns catalog verifies the test is
testing the RIGHT thing. Both are required.

## Mandatory Boundary Tests

**For any method accepting numeric parameters**, every test skeleton MUST include at least one boundary test scenario with a manually computed expected value. This prevents the tautological trap where the AI writes matching formulas in both code and tests.

Boundary test rules:
- **Pagination:** Test the last-page boundary: `ceil(totalItems / perPage)`. Compute the expected value by hand in a test comment (e.g., `// 23 items / 10 per page = ceil(2.3) = 3 pages`).
- **Offset/limit:** Test `offset = 0`, `offset = total - 1`, `offset = total` (just past the end).
- **Currency/pricing:** Test rounding at .5 boundaries (e.g., `9.995 → 10.00 or 9.99?`).
- **Date ranges:** Test month boundaries, leap years, DST transitions.
- **Collections/arrays:** Test empty collection, single item, and exact-boundary-size collection.

The expected value MUST be a literal (e.g., `expect($result)->toBe(3)`) — never a formula that mirrors the implementation (e.g., ~~`expect($result)->toBe(ceil($total / $perPage))`~~).

## PHP Controller Test Skeleton (Pest)

Location: `tests/Feature/{ControllerName}Test.php`

Scenarios:
- `it('requires authentication')` — GET without auth → redirect to login
- `it('requires authorization')` — GET as wrong user → 403
- `it('validates required fields')` — POST empty → session errors
- `it('performs action with valid data')` — POST valid → redirect + DB assertion
- `it('returns 404 for missing resource')` — GET nonexistent → 404
- `it('handles boundary values correctly')` — Test with edge-case inputs (0, max, empty) and manually computed expected results

## PHP Service Test Skeleton (Pest)

Location: `tests/Unit/Services/{ServiceName}Test.php`

Scenarios:
- `it('performs main action successfully')` — Happy path
- `it('handles empty input')` — Edge case
- `it('throws typed exception on invalid input')` — Error handling

## PHP Job Test Skeleton (Pest)

Location: `tests/Feature/Jobs/{JobName}Test.php`

Scenarios:
- `it('can be dispatched')` — Queue::fake + dispatch assertion
- `it('processes successfully')` — Direct handle + side effects
- `it('handles failure gracefully')` — Mock failure + verify error handling

## Laravel Query-Count Assertions (Eager-Loading Enforcement)

The operator's CLAUDE.md mandates eager-loading (relationships loaded before model methods access them — especially Cashier's `$user->subscription('default')`); violations ship green tests + a silent N+1. **For any Laravel controller/service/job test touching a model with relationships**, read `${CLAUDE_SKILL_DIR}/references/v-testing-patterns.md` § **Query-Count Assertions** — the 3 patterns (`LazyLoadingViolationException` strict mode, `DB::enableQueryLog()` bounded-ceiling, optional `assertSeeQueries()` helper), the Cashier bounded-ceiling scenario, and when to skip. Skip the load for pure-unit (no DB) or React/Vitest targets.

## React Component Test Skeleton (Vitest)

When the test target is a React/Vitest component, load the scaffold — detection, scenario checklist, Testing Library skeleton, and hook-testing pattern — from `${CLAUDE_SKILL_DIR}/references/react-test-skeleton.md`. Skip the load for PHP/Pest targets (the PHP Pest skeletons above cover those).

## Pest Browser Test Skeleton (Authenticated Inertia Flows)

When the test target is a `browser_only_states`/`verify_by: browser` entry from a `SUCCESS_CRITERIA_*.md` artifact, OR a bug report / acceptance criterion that explicitly needs real-browser rendering on an authenticated route (client-side JS execution, real navigation, a visual/async state a jsdom render can't produce), check for Pest browser testing capability BEFORE defaulting to a raw Playwright spec:
```bash
grep -q '"pestphp/pest-plugin-browser"' composer.json 2>/dev/null && echo "PEST_BROWSER=true"
{ test -d tests/Browser && find tests/Browser -name '*.php' 2>/dev/null | grep -q .; } && echo "PEST_BROWSER_SPECS=true"
```
If either fires, load the scaffold from `${CLAUDE_SKILL_DIR}/references/pest-browser-test-skeleton.md` — it reuses `actingAs()` instead of re-implementing login as a raw browser fixture, which is materially simpler for this stack's authenticated Inertia flows. If neither fires, this capability isn't available on the project; note it as a candidate for `composer require pestphp/pest-plugin-browser --dev` and defer to `v-workflow-verifier`'s Playwright lane (/v Step 3.5) as today. Standalone Playwright remains the right tool for cross-framework flows or pixel-level visual-diff needs regardless of which capability is present — this is an additional lane, not a replacement.

## Persona Engagement (Tier-2 — imported from v-build trigger matrix)

Before writing test scenarios, scan the target (class / file path / route / bug-report / finding) for triggers that engage senior personas. Each engaged persona contributes a distinct test lens — payment engineers test for concurrency on the same Stripe customer, security engineers test CSRF + authorization-bypass, async engineers test idempotency, etc.

**Trigger matrix (cap 3 personas per test target; 4+ → target is too cross-cutting, recommend `/v-plan` to split):**

| Trigger | Persona engaged | Test lens added |
|---|---|---|
| `Stripe`, `Cashier`, `Billing`, `Payment`, `Subscription`, `Invoice`, `Webhook` (Stripe-tagged) | Senior payments engineer | concurrent same-customer ops, idempotency-key handling, signed-webhook verification, partial-charge rollback, currency rounding |
| `Auth`, `Login`, `Session`, `Token`, `Encryption`, `CSRF`, `Password`, `Reset`, file upload | Senior security engineer | authorization bypass (wrong user/role), CSRF on state-mutating routes, MIME/extension/size validation, secret exposure in error responses, rate limiting |
| `migrations/`, schema change, `ALTER`, foreign-key, `DROP`, `unique` | Senior database engineer | NOT NULL on existing-row tables, FK cascade behavior, two-phase deploy compatibility, index regression, query-count under load |
| `implements ShouldQueue`, `Job`, `Listener`, `Observer`, `Bus::dispatch`, webhook handler | Senior async engineer | idempotency (run twice → same outcome), retry policy on transient failure, dead-letter routing on permanent failure, observer fan-out |
| External API (`HTTP::`, Guzzle, vendor SDK) | Senior integrations engineer | timeout behavior, retry policy on 5xx, response-shape changes, signed-request verification, rate-limit handling |
| New public API endpoint (`routes/api.php`, `app/Http/Controllers/Api/`) | Senior API engineer | versioning, contract stability, pagination boundary, partial-failure response shape, error-envelope schema |
| Destructive ops (`forceDelete`, `::truncate`, mass `->delete()`, `wipe`) | Senior data engineer (destructive) | confirmation flow, soft-delete fallback, cascade on related records, point-in-time recovery test |
| Explicit perf-critical path in the plan | Senior performance engineer | query count assertion, N+1 prevention, response-time budget, cache invalidation |
| Billing/Subscription/Tenant/Team/Permission/Policy/Plan | (SaaS-specific) | tenant isolation (no cross-tenant data leak), permission-boundary on every action, subscription lifecycle (trial → active → past_due → canceled), upgrade/downgrade proration |
| `success_event` annotation in plan / `_v-growth.md` context | (analytics lens) | listener exists, fires with correct payload on success path |

**Engagement protocol (per `~/.claude/skills/references/persona-lens.md`):** for each engaged persona, mentally answer the 3-question lens BEFORE scaffolding tests:
1. What's the most likely failure mode this persona would catch first?
2. What test would prove that failure mode is NOT present?
3. What test would prove the happy path works AND the failure mode is guarded?

**Where to log the persona reasoning:** when invoked by `/v-build` (V_DEPTH ≥ 1), the personas + answers go under `## Personas engaged` in v-build's `IMPLEMENTATION_REPORT` (persona-lens.md default). When run **standalone** (V_DEPTH = 0 — no `IMPLEMENTATION_REPORT` will ever be written this session), record the engaged personas and their 3-question answers inline in the RED-phase completion report instead. Never discard the reasoning silently.

**Test budget + prioritization rule (Tier-3 fix — replaces hand-wavy caps):**

Total RED-phase tests are CAPPED at 8 per session. When multiple sources contribute (async trace + personas + PLAN test_first), apply this prioritization in order — drop excess from the bottom:

1. **ASYNC_LIFECYCLE_TRACE `failure_modes_to_test` entries** (highest priority — these are documented failure modes the bug WILL re-manifest as)
2. **PLAN `test_first` entries** (the human/orchestrator already decided these matter)
3. **Persona-driven tests, ordered by trigger specificity:**
   1. Payments (Stripe/Cashier touch)
   2. Security (auth/CSRF/file-upload)
   3. Database (migrations/destructive ops)
   4. Async (NOT counted separately if async trace already provided tests — avoid double-counting; persona just supplements with non-trace concerns like circuit breaker)
   5. Integrations (external API)
   6. API (new public endpoint)
   7. Performance
4. **Acceptance criteria** (Gherkin) if no other source produced a test for the criterion
5. **Standard skeleton scenarios** (happy path + edge cases per stack template) — fill remaining budget

**Worked example.** Async trace has 5 unit-layer modes; PLAN has 2 test_first; 3 personas (payments + security + async) engage with 2 candidates each = 6 candidates. Raw total: 5 + 2 + 6 = 13. Cap = 8. Must drop **5**. Resolution:
- Take all 5 async-trace tests (priority 1).
- Take both 2 PLAN test_first (priority 2). Running total: 7.
- Take 1 payments persona test (priority 3.1, highest trigger specificity). Running total: 8.
- DROP exactly 5 from the 6 personas (the lowest-priority remaining contributors): 1 payments-2nd, 2 security, 2 async (the 2 async-persona candidates are redundant with the trace-derived tests, so dropping them costs nothing). 6 personas - 5 dropped = 1 persona test kept; matches the "take 1 payments" above.

Document the dropped tests in the post-RED report so the operator knows what was deferred.

**Reference:** Read `${CLAUDE_SKILL_DIR}/references/v-tdd-saas-scenarios.md` for subscription lifecycle, payment edge cases, tenant isolation, permission boundary, and race condition test scenarios (used by the SaaS-tagged personas).

**Composition with other paths:**
- If async lifecycle trace exists (input type A) AND persona triggers match → write BOTH the async failure-mode tests AND 1-2 persona-specific tests. Cap total at 8.
- If `success_event` is in the plan AND persona triggers match → analytics-lens tests join the persona tests.

**TDD integration:** Do NOT dump all scenarios at once. Pick the 3-5 most relevant scenarios for the specific target, write them one at a time following red-green-refactor. The reference is a menu to choose from, not a checklist to complete in one pass.

## Growth Hook Validation

When invoked with a PLAN artifact or when the invoking context includes a `growth_hook` section (per `_v-growth.md`):

1. Check if the PLAN specifies a `success_event` for the feature being tested:
   ```bash
   # SID-SCOPED ONLY — never fall back to an unfiltered `ls -t PLAN_*.md`.
   # Per `_v-core.md` § Session ID rule 8, the unfiltered glob is reserved for
   # INTENTIONAL cross-session comparison. Under the 8-parallel-session operator
   # model an automatic fallback would silently read a DIFFERENT concurrently-running
   # session's PLAN and attach its `success_event` to THIS session's test target.
   # Absence of this session's own PLAN means "no growth hook applies" (skip step 3).
   PLAN_FILE=$(ls -t .v/artifacts/PLAN_*${CLAUDE_SESSION_ID}*.md PLAN_*${CLAUDE_SESSION_ID}*.md 2>/dev/null | head -1)
   [ -n "$PLAN_FILE" ] && grep -A5 "success_event" "$PLAN_FILE" 2>/dev/null
   ```
2. If a `success_event` is found, add a test assertion verifying:
   - The event listener/dispatcher exists (class or function defined)
   - The event fires with the correct payload on the success path
3. If no PLAN or no `success_event`, skip this step — growth hook validation is conditional.

## After Creating Test

Run the test file AND CAPTURE THE EXIT CODE — **always wrap in a bounded-runtime command (`timeout 120` on Linux, `gtimeout 120` on macOS with coreutils) to prevent the test process hanging the orchestrator**.

**Detection + run MUST happen in the SAME Bash tool call** — bash variables do NOT persist across Bash tool invocations (each tool call is a fresh shell). Inline the detection at the top of the test-run bash block:

```bash
# Single Bash call: detect timeout binary AND run the test.
# Bash tool calls don't carry state across invocations — inline both here.

# Detect binary
if command -v timeout >/dev/null 2>&1; then
  TO="timeout 120"
elif command -v gtimeout >/dev/null 2>&1; then
  TO="gtimeout 120"
else
  # Neither available (vanilla macOS without coreutils) — abort with BUILD_BLOCKER.
  echo "ERROR: v-tdd requires 'timeout' (Linux) or 'gtimeout' (macOS coreutils) for bounded test runs." >&2
  echo "Install on macOS: brew install coreutils" >&2
  cat > "BUILD_BLOCKER_$(date +%s)_${CLAUDE_SESSION_ID}.md" <<EOF
# BUILD_BLOCKER — v-tdd missing timeout binary

Neither \`timeout\` (Linux) nor \`gtimeout\` (macOS coreutils) is available on PATH.
v-tdd cannot run tests safely without a wall-clock guard.

Resolution: \`brew install coreutils\` (macOS) OR install \`timeout\` via the system package manager.
EOF
  exit 2
fi

# PHP — bounded run, capture exit code explicitly.
# Worktree vendor preflight (P1e / NEW-CI-003): a SYMLINKED vendor makes ./vendor/bin/pest run MAIN's
# autoloader → "facade root has not been set" / namespace-mangled false failures. Repair it FIRST
# (idempotent; no-op outside a worktree / non-PHP). exit 3 = still symlinked → treat Pest output as
# INCONCLUSIVE, not as real failures.
bash ~/.claude/skills/v/references/v-pest-preflight.sh; PEST_PREFLIGHT=$?
$TO ./vendor/bin/pest {test_file_path}; TEST_EXIT=$?
[ "${PEST_PREFLIGHT:-0}" -eq 3 ] && echo "WARNING: vendor still symlinked — TDD test result above may be a false failure (INCONCLUSIVE)."

# (For React projects, substitute the test line above with:)
# $TO npx vitest run {test_file_path}; TEST_EXIT=$?
# (For other stacks: `$TO <runner>; TEST_EXIT=$?`.)

echo "TDD test exit code: $TEST_EXIT"
```

**Critical:** do NOT split detection and test-run across two Bash tool calls — `TO` won't survive. If your workflow needs them split (e.g., detection in Step 5 init, test-run in Step 5 main), persist via a file: `echo "$TO" > "$V_TMP_DIR/v_to-${CLAUDE_SESSION_ID}.txt"` then `TO=$(cat "$V_TMP_DIR/v_to-${CLAUDE_SESSION_ID}.txt")` in the next call.

**Exit code 124 = timeout fired.** Treat exit 124 as a BUILD_BLOCKER (not a RED failure, not a setup error) — the test runner itself stalled. Write `BUILD_BLOCKER_{timestamp}_${CLAUDE_SESSION_ID}.md` per the Max-retry guard section and stop. Common causes: infinite loop in setup, hung browser process (Vitest jsdom), DB connection wait, queue worker spawn in test boot.

**Exit code 127 = command not found.** If `$TEST_EXIT == 127`, the binary detection above failed mid-flight (e.g., `gtimeout` PATH change). Treat as BUILD_BLOCKER, not RED — exit 127 must NEVER be misread as "test failed."

### Fail-loud RED gate (REQUIRED — v3.8.5 hardening)

After running, verify (in order):

1. **`$TEST_EXIT` is non-zero** (test process failed). If `$TEST_EXIT == 0`
   the test PASSED on first run — see ABORT block below. Do NOT
   infer pass/fail from textual output; the exit code is authoritative.
2. **At least one of the newly-added tests is named in the failure
   output** (not just an existing unrelated test that was already
   broken). Cross-reference the test names from your scaffolded file
   against the test runner's failure list.
3. **The failure mode is "missing implementation"** — illustrative
   examples: "method `foo` does not exist", "Class not found",
   "expected X to be Y, got null", "Route [name] not defined", "404
   from /api/...", "element with role X not in DOM", "type error:
   property does not exist". The list is illustrative, not
   exhaustive — any failure that traces back to the unit-under-test
   not being implemented is acceptable. NOT acceptable: syntax
   error, parse error, import-resolution error, fixture-load error
   (those mean the test never reached the assertion).

**If the test PASSES on first run (exit 0): ABORT.**

This is always wrong in TDD. Possible causes:
- The assertion is testing the mock instead of the behavior under test
- The test asserts on data that already exists in the seed/fixture
- The test uses `expect(true).toBe(true)` placeholder
- The implementation already exists and the test is redundant

Re-task with this exact prompt:

> Your test passed on the first run, exit code 0. TDD requires
> the test to fail before implementation exists. One of these is true:
> (1) the assertion is wrong — you're testing the mock, not the
> behavior; (2) you're asserting on data that already exists in the
> fixture; (3) the implementation already exists and this test is
> redundant. Inspect each new test, identify which case applies, and
> rewrite to test the actual behavior the user requested. Then re-run
> and confirm RED.

**If the test fails for a SETUP reason** (syntax error in the test,
missing import, fixture not found, parse error): also ABORT — that's
not RED, that's BROKEN. Re-task with: "Your test failed for a setup
reason ({specific error}). The skeleton itself is broken. Fix the
test file structure first, then re-run."

**If the test fails for the RIGHT reason** (missing implementation):
proceed to Step 5.5 below (test-only-writes enforcement gate), THEN the success banner.

### Step 5.5: Test-only-writes enforcement gate (Tier-1 fix — runtime check, not just documentation)

Before emitting the success banner, audit the session-writes log to confirm v-tdd did NOT touch production source files during this RED phase. The Rules section's **"Test-only writes during RED"** bullet forbids it; this gate enforces it.

```bash
# Resolve the ACTUAL writes-log path (per ~/.claude/hooks/lib/session-writes.sh:84).
# The log is at ${git_common_dir}/claude-session-writes-${SESSION_ID}.txt — NOT under
# $V_TMP_DIR and NOT named session-writes-${SID}.txt (those were earlier-iteration
# wrong paths; track-session-writes.sh actually writes claude-session-writes-).
GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null)
if [ -n "$GIT_COMMON_DIR" ] && [ -d "$GIT_COMMON_DIR" ]; then
  # Resolve to absolute if relative
  case "$GIT_COMMON_DIR" in
    /*) ;;
    *)  GIT_COMMON_DIR="$(pwd)/$GIT_COMMON_DIR" ;;
  esac
  WRITES_LOG="${GIT_COMMON_DIR}/claude-session-writes-${CLAUDE_SESSION_ID}.txt"
else
  WRITES_LOG=""
fi

# Allowlist regex — covers Pest, Vitest, Jest, Cypress, Playwright, Storybook,
# Laravel factories/seeders, and common test-config filenames.
ALLOWLIST_RE='(^|/)(tests?|spec|__tests__|__mocks__|cypress|playwright|e2e)/|\.(test|spec|stories)\.[a-z]+$|(^|/)(pest|vitest|jest|playwright|cypress)\.config\.[a-z]+$|(^|/)database/(factories|seeders)/'

# Primary source: session-writes log (written by ~/.claude/hooks/track-session-writes.sh)
SCAN_SOURCE=""
if [ -n "$WRITES_LOG" ] && [ -f "$WRITES_LOG" ] && [ -s "$WRITES_LOG" ]; then
  SCAN_SOURCE="$WRITES_LOG"
  FORBIDDEN_WRITES=$(grep -vE "$ALLOWLIST_RE" "$WRITES_LOG" 2>/dev/null | grep -vE '^\.v/tmp/|^/tmp/' | sort -u)
else
  # Fallback: log missing or empty (hook didn't fire, bulk-edit, etc.).
  # Use git diff against HEAD to catch what actually changed.
  SCAN_SOURCE="git diff (fallback — session-writes log missing or empty)"
  FORBIDDEN_WRITES=$( {
    git diff --name-only HEAD 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -vE "$ALLOWLIST_RE" | grep -vE '^\.v/tmp/|^/tmp/' )
fi

if [ -n "$FORBIDDEN_WRITES" ]; then
  echo "VTDD-WRITE-GUARD-FAIL: v-tdd wrote to production paths during RED phase." >&2
  echo "Scan source: $SCAN_SOURCE" >&2
  echo "Forbidden writes:" >&2
  echo "$FORBIDDEN_WRITES" | sed 's/^/  /' >&2
  echo "" >&2
  echo "ABORT: revert the production-source edits OR document the exception in BUILD_BLOCKER and stop." >&2
  echo "RATIONALE: TDD's contract is that GREEN (implementation) follows RED (test). If v-tdd writes" >&2
  echo "production code, you've collapsed both phases and lost the ability to verify the test" >&2
  echo "actually exposes a missing-implementation gap." >&2
  echo "" >&2
  echo "If a forbidden write is a legitimate exception (rare; see allowlist exceptions below)," >&2
  echo "prefix the test file's first comment block with '// v-tdd-allowlist-exception: <reason>'." >&2
  exit 2
fi
```

**Exceptions allowlist (rare; document each in the test file's leading comment if invoked):**
- Adding ONLY a `use` statement / import to make a new test file resolve a dependency.
- Creating a brand-new test stub file under `app/` ONLY IF the project's test convention requires the SUT to exist as an empty class for the test framework to autoload it (rare; verify by reading 2+ existing tests in the project).
- Inertia projects: a brand-new empty Inertia page component under `resources/js/Pages/` MAY be created IF the test asserts the route renders THAT page name — but the page must have ZERO behavior (just `<>NoOp</>`). Real content goes in /v-build's GREEN phase.

When invoking an exception, prefix the test file's first comment block with `// v-tdd-allowlist-exception: <reason>` so /v-verify-done can audit the deviation.

**Max-retry guard (v3.8.5):** the orchestrator may re-task this gate
at most TWICE per skill invocation. After 2 re-task attempts where
the test still passes on first run (or still fails for a setup
reason), STOP and write `BUILD_BLOCKER_{timestamp}_${CLAUDE_SESSION_ID}.md`
(SID-suffixed per v-build convention — required for parallel-session
binding and `v-core-cross-session.md` lookup) to the project root with:
```
# BUILD_BLOCKER — v-tdd RED gate failed twice

Test file: {path}
Re-task attempts: 2 (max)
Last failure mode: {pass-on-first-run | setup-error | timeout-exit-124}
Last test runner output: {tail -20 of last run}

Recommended next step:
- If pass-on-first-run: the requested behavior may already exist;
  operator should review whether implementation is already complete
  and the test is redundant.
- If setup-error: the test scaffold has a structural issue beyond
  the agent's ability to fix; operator should manually inspect the
  test file.
```

Then exit cleanly. Do NOT silently re-task a third time — that wastes
tokens on a stuck loop.

**Stop-hook escape for the BUILD_BLOCKER exit (REQUIRED — verified against `check-review-artifact.sh:310`):** `BUILD_BLOCKER` is a recognized artifact NAME but is **NOT** in the Stop hook's accepted-escape set (only `PRE_FLIGHT_REPORT / AGENT_REVIEW / VERIFY_DONE_REPORT / TRIVIAL_PASS / HANDOFF / CYCLE_CAP_HANDOFF` are). Every BUILD_BLOCKER exit path in this skill (max-retry, missing `timeout` binary, exit-124 timeout, exit-127 command-not-found) fires **after** a test file was already written this session, so the Stop hook WILL gate the session. Resolve by V_DEPTH:
- **Standalone (V_DEPTH = 0):** also write `HANDOFF_${CLAUDE_SESSION_ID}.md` (≥80 bytes, starts with `# Handoff`) alongside the BUILD_BLOCKER — same as the Standalone Mode "Stop at RED intentionally" escape, but documenting the blocker instead. Point it at the BUILD_BLOCKER file and the recommended next step. Without this, the session dead-locks in an impossible gate (the same trap the PROGRESS_NOTE warning below calls out).
- **Called by `/v-build` (V_DEPTH ≥ 1):** BUILD_BLOCKER alone is fine — v-build owns the gate and surfaces the blocker to the orchestrator; do NOT write a HANDOFF (it would mislead the orchestrator into treating the session as an intentional abandonment).

Emit the `_v-core.md` § Standard Completion Message (4-5 lines, no banner):

```
v-tdd Complete
  Status: RED (≥1 new test fails for missing-implementation; 0 setup failures)
  Artifacts: {test_file_path}
  Tests: {count} new, {failing_count} failing for intended reason, 0 setup failures
  Next step: run /v-build to implement, then re-run tests
```

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Test "fails" but only because of import error, not failing assertion | Fail-loud red gate not honored | Test must fail because the ASSERTION fails, not because of compile/import errors. If test errors before assertion runs, RED phase is invalid |
| 2 | Generated test asserts implementation detail rather than behavior | TDD pattern not loaded | Read **canonical** `~/.claude/skills/references/v-tdd-anti-patterns.md` (shared with v-verify-done) before generating tests; assert behavior visible at the API boundary, not internal state |
| 3 | Pest test uses Laravel-specific helpers but project is plain PHP | Framework detection skipped | Detect framework first; Pest + Laravel uses `LaravelTestCase` patterns; Pest + plain PHP uses different setup |
| 4 | Vitest test imports React component but project uses Preact | Import-style mismatch | Run `references/react-test-skeleton.md` § Detection **Step 1** (`grep -E '"(preact\|solid-js)"' package.json`) BEFORE scaffolding; test imports follow the resolved framework's paradigm (`@testing-library/preact` / `@solidjs/testing-library` vs `@testing-library/react`) |
| 5 | Test passes immediately after generation (no red phase achieved) | Test generated against existing code, not future code | TDD requires the implementation NOT YET EXIST; if it does, this is test-after, not TDD — use direct test generation instead |
## Standalone Mode Stop-Hook Contract

When `/v-tdd` is invoked **standalone** (V_DEPTH = 0 — user typed `/v-tdd ServiceName` rather than v-build calling it internally), the test file mutation triggers the same Stop-hook artifact gate as any other code-changing skill.

**Per `_v-artifact-formats.md` § Hook-binding artifacts, `check-review-artifact.sh` blocks session completion unless ALL of these exist at repo root:**
- `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md`
- `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md`
- `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md`
- `IMPACT_MAP_${CLAUDE_SESSION_ID}.md` and `QA_REPORT_${CLAUDE_SESSION_ID}.md` (when **production** code changed — these come from the /v orchestrator's Step 1.8 / Step 6.4.9, NOT from /v-build alone)

The hook ALSO accepts these as alternative-satisfactions: `TRIVIAL_PASS_${CLAUDE_SESSION_ID}.md`, `PLANNING_PASS_${CLAUDE_SESSION_ID}.md` (planning-only sessions), or a valid `HANDOFF_${CLAUDE_SESSION_ID}.md` (≥80 bytes, starts with `# Handoff`). **A RED-only test session has no product to impact-analyze or QA — take the HANDOFF escape (option 2 below); it satisfies the gate without IMPACT_MAP/QA_REPORT.**

**`PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md` is NOT accepted by the Stop hook** (verified against `check-review-artifact.sh`). Older v-tdd guidance recommending PROGRESS_NOTE as a standalone-exit was WRONG — using it traps the session in an impossible gate.

v-tdd intentionally produces NO implementation — the RED state IS the deliverable. Standard `/v-pre-flight` will fail because tests are red.

**Standalone exit options (pick one before ending the session):**

1. **Continue to green (default expectation):** invoke `/v-build` next — it picks up the failing test, drives green-refactor, runs `/v-pre-flight` + agent review + `/v-verify-done` at the end. **Caveat:** `/v-build` alone produces the triad but NOT `IMPACT_MAP`/`QA_REPORT` (those are orchestrator Step 1.8 / 6.4.9). If production code changed, run the original task through the **`/v` orchestrator** (which calls v-tdd → v-build internally AND produces the full gate set) rather than `/v-build` standalone — otherwise the Stop hook will block on the missing IMPACT_MAP/QA_REPORT. Standalone `/v-build` is only gate-complete for changes that don't trip those gates.

2. **Stop at RED intentionally** (e.g., "I just wanted the test skeleton; I'll implement later"): write `.v/artifacts/HANDOFF_${CLAUDE_SESSION_ID}.md` (≥80 bytes, starts with `# Handoff`; Phase-2 — create the dir; the Stop hook reads it dual-search, root is a legacy fallback) documenting:
   - Test file(s) created (paths)
   - Why gates were skipped: "RED-only stop at user request; implementation deferred to next session"
   - Expected next-session command: `/v-build` or `/v <bug-fix-prompt>`

   This is the hook-accepted abandonment escape per `check-review-artifact.sh:250-280`. Do NOT write `PROGRESS_NOTE` — it will block.

**When invoked by `/v-build` (V_DEPTH ≥ 1):** this contract does NOT apply — v-build owns the gates and will write `PRE_FLIGHT_REPORT` + `AGENT_REVIEW` + `VERIFY_DONE_REPORT` after green-refactor. v-tdd inside v-build is a phase, not a session boundary.

## Idempotency

**Conditionally idempotent.** Same target + same trace artifact → same set of failing tests written. Re-invocation behavior:
- If the test file already exists with the expected test names → no-op (don't duplicate tests; report "RED already established for this target").
- If the test file exists but is missing some expected tests (e.g., new entries in ASYNC_LIFECYCLE_TRACE) → append the missing tests; do NOT rewrite existing ones.
- If the test file exists AND all expected tests now PASS → ABORT (the target has been implemented in another session; v-tdd is for RED phase only, not regression testing).

**Mutates ONLY test files + test helpers/fixtures/factories** (per Rules § "Test-only writes during RED" + Step 5.5 enforcement gate). v-tdd MUST NOT mutate production source. GREEN-phase implementation is v-build's job, not v-tdd's. Old wording ("Mutates code + test files") was wrong — corrected in Tier-1 fix.
