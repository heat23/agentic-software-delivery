# AI Test Anti-Patterns Catalog

_Last reviewed: 2026-07-05_

The canonical catalog of AI-shaped test failures that v-tdd avoids generating and v-verify-done detects. Update this file when a new anti-pattern emerges; both skills load from here.

**Catalog completeness contract:** this file defines exactly 11 entries — A1.1–A1.3 (Tier 1), A2.1–A2.3 (Tier 2), A3.1–A3.3 (Tier 3), A4.1–A4.2 (Tier 4). v-tdd's SKILL.md and v-verify-done MUST cite only these IDs; if either skill references an entry not listed here, fix the citation (do not invent an entry). When adding a new anti-pattern, add it here FIRST, then update both skills' enumerated counts.

**When to load:** v-tdd reads this BEFORE generating test skeletons (Step 1 RED phase). v-verify-done reads this when scanning changed test files for pattern violations.

**Operator context:** solo SaaS, Laravel 13 + Inertia + React + Pest (PHP) + Vitest (TS) stacks. Tests are the only safety net (no human reviewer). Anti-patterns here have been observed in real AI-generated test files for these stacks.

---

## Tier 1 — Tautological tests (BLOCK at v-tdd, FAIL at v-verify-done)

These tests pass without exercising the production code. They are worse than no tests because they create false confidence.

### A1.1 — Self-referential assertions

```php
// BAD
expect(true)->toBe(true);
expect(1)->toEqual(1);
$result = 'foo';
expect($result)->toBe('foo'); // never called the system under test

// BAD (Vitest)
expect(true).toBe(true);
const result = 'foo';
expect(result).toBe('foo');
```

**Detection:** any assertion where the expected value is structurally identical to the actual value AND the actual value is a literal in the same test body (not a function call result).

**Rule:** every assertion must compare a value PRODUCED BY production code against an EXPECTED VALUE that is independently computed or hand-written. If both sides come from the same source, the test is tautological.

### A1.2 — Tests that exercise nothing

```php
// BAD
test('user can be created', function () {
    $user = User::factory()->make();
    expect($user)->toBeInstanceOf(User::class);
});
// Factory is the system under test? No — this tests Eloquent.
```

**Detection:** test runs only framework calls (factory creation, Builder methods); the project's own classes/methods are never invoked.

**Rule:** test must invoke a method/function/component from the project's own source code, not just framework methods.

### A1.3 — Snapshot tests that nobody reads

```tsx
// BAD
test('renders correctly', () => {
  const { asFragment } = render(<Pricing />);
  expect(asFragment()).toMatchSnapshot();
});
```

**Detection:** test ends with `toMatchSnapshot()` and has no other assertion.

**Rule:** snapshot tests are acceptable ONLY for components with stable visual output AND only as ONE assertion among others. A snapshot-only test means nobody reads the diff when it changes — assertion has zero signal.

---

## Tier 2 — Implementation-detail tests (BLOCK at v-tdd, WARN at v-verify-done)

These tests couple to internal implementation, so refactors break tests even when behavior is preserved.

### A2.1 — Mocking what should be tested

```php
// BAD
test('user service creates user', function () {
    $service = Mockery::mock(UserService::class);
    $service->shouldReceive('create')->andReturn(new User);
    expect($service->create([]))->toBeInstanceOf(User::class);
});
```

**Detection:** the mock is the SUT (system under test) itself, not its dependencies.

**Rule:** mock dependencies (HTTP clients, mailers, DB if needed). Never mock the class you're testing.

### A2.2 — Asserting on private methods / internal state

```tsx
// BAD
const component = renderHook(() => useFunnel());
expect(component.result.current._internalCache).toBeDefined();
```

**Detection:** assertion accesses a property/method whose name starts with `_` or is documented as private.

**Rule:** assert on public API behavior. If a private method needs testing, refactor to extract it into a testable unit.

### A2.3 — Testing framework behavior, not yours

```php
// BAD
test('routes are registered', function () {
    $this->get('/dashboard')->assertOk(); // tests Laravel's routing, not your code
});
```

**Detection:** test exercises only framework wiring; the assertion would pass for any controller responding 200.

**Rule:** test must verify a behavior YOUR code introduces — middleware checks, response shape, business logic outputs.

---

## Tier 3 — Coverage gaps (WARN at v-tdd, FAIL at v-verify-done if claimed coverage)

These tests pass but miss the actual behavior they claim to test.

### A3.1 — Skipped assertions

```tsx
// BAD
test.skip('handles error case', ...);
test.todo('handles error case');
// — but the code path it would test is shipping
```

**Detection:** `test.skip` / `test.todo` / `xtest` / `xit` for code paths that are merged.

**Rule:** skipped tests are blockers, not features. Either delete the test or write it. Skipped tests in shipped code = lying about coverage.

### A3.2 — Happy-path-only tests for branching code

```php
// BAD — function has if/else; test only exercises if-branch
function processOrder(Order $order): Status {
    if ($order->total > 1000) {
        return Status::FlaggedForReview;
    }
    return Status::Approved;
}

test('processes orders', function () {
    $order = Order::factory()->create(['total' => 500]);
    expect(processOrder($order))->toBe(Status::Approved);
    // ↑ never tests total > 1000 branch
});
```

**Detection:** function has ≥2 branches (if/else, switch, ternary, try/catch); test exercises only one.

**Rule:** every branch needs at least one test. Use coverage tools to verify branch coverage, not just line coverage.

### A3.3 — Tests with no error-path coverage

```tsx
// BAD — only happy path
describe('login', () => {
  test('logs in valid user', async () => {
    const result = await login('user@example.com', 'correct-password');
    expect(result.success).toBe(true);
  });
});
// No test for: wrong password, locked account, throttled, unverified email, etc.
```

**Detection:** describe block has only happy-path assertions; the function under test has documented error cases.

**Rule:** every documented error case (return value, thrown exception) needs a test. Inferred error cases (network down, DB unavailable) need at least one happy + one explicit failure case.

---

## Tier 4 — Time/order anti-patterns

### A4.1 — Time-dependent tests without freezing

```php
// BAD
test('subscription expires after 30 days', function () {
    $sub = Subscription::factory()->create(['created_at' => now()->subDays(31)]);
    expect($sub->isExpired())->toBeTrue();
});
// Passes today; fails when run on a different timezone or DST boundary
```

**Detection:** test uses `now()`, `Carbon::now()`, `Date.now()`, or `new Date()` without freezing time.

**Rule:** Laravel/Pest: `$this->travel(31)->days()` or `Carbon::setTestNow($fixed)`. Vitest: `vi.useFakeTimers()` + `vi.setSystemTime()`. Time must be deterministic.

### A4.2 — Order-dependent tests

```tsx
// BAD
let counter = 0;
test('first', () => { counter++; expect(counter).toBe(1); });
test('second', () => { counter++; expect(counter).toBe(2); });
// Run in isolation = both pass; run with --shard or random order = second fails
```

**Detection:** tests share mutable state (module-scope variables, file system state, DB without transaction wrapping).

**Rule:** every test must pass in isolation. Use `beforeEach` to reset shared state to known values (counter = 0, fixtures cleared, file-system temp dirs reset). For mutable variables like `let counter = 0` at module scope, `beforeEach(() => { counter = 0 })` is required — `vi.resetAllMocks()` resets MOCKS only and does NOT reset module-scope state. For mock-state isolation use `vi.resetAllMocks()` (not a substitute for state reset). Pest's database transactions wrap each test, isolating DB state.

---

