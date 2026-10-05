# v-testing-patterns: Centralized Testing Patterns for Laravel + React

_Last reviewed: 2026-07-05_

Canonical reference for testing patterns across the full stack (PHP Pest, React Vitest, related frameworks).

## Factory Patterns

### Model Factories (PHP)

Create instances with relationships, states, and sequences:

```php
// Basic factory usage
$user = User::factory()->create();
$users = User::factory(5)->create();

// With state
$user = User::factory()->admin()->create();
$user = User::factory()->unverified()->create();

// With attributes
$user = User::factory()->create(['email' => 'custom@example.com']);

// With relationships
$post = Post::factory()
    ->for(User::factory(), 'author')
    ->create();

// With sequences (auto-increment on multiple creates)
$users = User::factory()
    ->sequence(
        ['name' => 'Alice'],
        ['name' => 'Bob'],
    )
    ->count(2)
    ->create();
```

**State methods:** Define reusable configurations in factory classes.

```php
// In UserFactory
public function admin()
{
    return $this->state(fn (array $attributes) => [
        'role' => 'admin',
    ]);
}

public function verified()
{
    return $this->state(fn (array $attributes) => [
        'email_verified_at' => now(),
    ]);
}
```

**Relationships in factories:** Use `for()` to set parent relationships, `has()` to define children.

```php
$user = User::factory()
    ->has(Post::factory()->count(3))
    ->create();
```

### React/TypeScript Fixtures

For component tests, build fixture objects matching API response shape:

```typescript
// Fixture: minimal shape for happy path
export const userFixture = {
  id: 1,
  name: 'Alice',
  email: 'alice@example.com',
};

// Fixture: empty/error state
export const emptyUsersFixture: User[] = [];

// Fixture: API response wrapper
export const paginatedUsersFixture = {
  data: [userFixture, { id: 2, name: 'Bob', email: 'bob@example.com' }],
  meta: { total: 2, per_page: 10, current_page: 1 },
};
```

## Fixture Patterns: When to Use Fixtures vs Factories

| Scenario | Use | Example |
|----------|-----|---------|
| PHP unit test needing real DB row | Factory | `User::factory()->create()` |
| React component test (no DB) | Fixture | `const user = { id: 1, name: 'Alice' }` |
| Testing relationship logic | Factory with relationships | `User::factory()->has(Post::factory(3))` |
| JSON API response simulation | JSON fixture file | `responses/users-paginated.json` |
| Edge case (empty, null, error) | Fixture | `const emptyList = []` |

### JSON Fixture Files

For API mocking (Vitest + vi.mock), store response shapes in JSON:

```json
// fixtures/user-response.json
{
  "id": 1,
  "name": "Alice",
  "email": "alice@example.com",
  "created_at": "2026-03-01T10:00:00Z"
}

// fixtures/users-paginated.json
{
  "data": [{ "id": 1, "name": "Alice" }, { "id": 2, "name": "Bob" }],
  "meta": { "total": 2, "per_page": 10, "current_page": 1 }
}
```

Usage in tests:

```typescript
import userResponse from '../../fixtures/user-response.json';

vi.mock('@/services/api', () => ({
  getUser: vi.fn().mockResolvedValue(userResponse),
}));
```

## Mocking Strategies

### PHP: Mockery for Services

Mock external services, dependencies, and API calls:

```php
use Mockery\MockInterface;

// Mock a service
$emailService = Mockery::mock(EmailService::class);
$emailService->shouldReceive('send')
    ->with('test@example.com', Mockery::any())
    ->once()
    ->andReturn(true);

$userService = new UserService($emailService);
$userService->register('test@example.com');

// `Mockery::verify()` is not a real Mockery API — there is no standalone verify
// call. `shouldReceive(...)->once()` expectations are verified automatically
// when `Mockery::close()` runs; Laravel's base TestCase calls `Mockery::close()`
// in tearDown() for every test, so no explicit call is needed here.
```

**When to mock:** External APIs, payment gateways, email services, file storage.

**When NOT to mock:** Business logic, database, authentication (use `actingAs` instead).

### JavaScript/TypeScript: vi.mock

Mock modules at the test file level:

```typescript
import { vi } from 'vitest';

vi.mock('@/services/api', () => ({
  getUser: vi.fn().mockResolvedValue({ id: 1, name: 'Alice' }),
  createPost: vi.fn().mockResolvedValue({ id: 100, title: 'Test' }),
}));

// All test cases in this file see mocked API
it('loads user on mount', async () => {
  render(<UserProfile userId={1} />);
  expect(screen.getByText('Alice')).toBeInTheDocument();
});
```

**Inline mock for specific test:**

```typescript
it('handles API error', async () => {
  const { getUser } = await vi.importMock('@/services/api');
  getUser.mockRejectedValueOnce(new Error('Network error'));

  render(<UserProfile userId={1} />);
  expect(screen.getByText(/error/i)).toBeInTheDocument();
});
```

**When to mock:** External APIs, complex state management, time-dependent code (dates, intervals).

**When NOT to mock:** Component tree integration, context providers (use `render` with providers instead).

## Database Testing

### RefreshDatabase vs DatabaseTransactions

Both wrap each test in a database transaction and roll it back afterward — that
rollback mechanism is identical between the two traits. The difference is
schema setup, not per-test reset speed:

```php
class UserServiceTest extends TestCase
{
    use RefreshDatabase; // Migrates the schema once per test-run process, THEN wraps each test in a transaction
    // OR
    use DatabaseTransactions; // Assumes the schema already exists; only wraps each test in a transaction
}
```

**RefreshDatabase:** Migrates the schema once per test-run *process* — an
in-memory `RefreshDatabaseState::$migrated` flag (not a persisted migration
hash) tracks whether migrations already ran this process, so within a single
`php artisan test` invocation migrations run once, then every test is wrapped
in a transaction and rolled back, exactly like `DatabaseTransactions`. The
docs describe this as: it "does not migrate your database if your schema is
up to date." It does NOT persist any state across separate `php artisan test`
runs — every fresh process re-migrates. (The recreate-on-change/hash-based
skip behavior belongs to `ParallelTesting` / `--recreate-databases`, not
`RefreshDatabase`.) It does NOT re-run migrations before every individual
test; that would be prohibitively slow. Use it when the schema may not exist yet
or may be stale (fresh checkout, CI, after pulling new migrations).

**DatabaseTransactions:** Skips the migration-state check entirely and assumes
the schema is already correct; only wraps each test in a transaction. Marginally
faster than `RefreshDatabase` when you know the schema is current.

### Test Database Seeding

Pre-populate test database with reference data:

```php
// In test
protected function setUp(): void
{
    parent::setUp();
    $this->seed(TestDatabaseSeeder::class);
}

// Or in individual test
it('lists all roles', function () {
    $this->seed(RoleSeeder::class);
    $roles = Role::all();
    expect($roles)->toHaveCount(3);
});
```

### Asserting Database State

After an action, verify the database changed correctly:

```php
// Assert record exists
$this->assertDatabaseHas('users', [
    'email' => 'alice@example.com',
    'verified' => true,
]);

// Assert record doesn't exist
$this->assertDatabaseMissing('users', [
    'email' => 'bob@example.com',
]);

// Assert count
expect(User::count())->toBe(5);
```

## HTTP Testing

### Authentication: actingAs

Test authenticated routes:

```php
it('requires authentication', function () {
    $response = $this->get('/dashboard');
    expect($response->status())->toBe(302); // Redirects to login
});

it('allows authenticated user', function () {
    $user = User::factory()->create();

    $response = $this->actingAs($user)->get('/dashboard');
    expect($response->status())->toBe(200);
});
```

### Asserting HTTP Responses

```php
$response = $this->postJson('/api/users', [
    'name' => 'Alice',
    'email' => 'alice@example.com',
]);

expect($response->status())->toBe(201);
expect($response->json('data.id'))->toBeGreaterThan(0);

// Assert response structure
$response->assertJsonStructure([
    'data' => ['id', 'name', 'email'],
]);

// Assert validation errors
$response = $this->postJson('/api/users', []);
expect($response->status())->toBe(422);
$response->assertJsonValidationErrors(['name', 'email']);
```

### Testing File Uploads

```php
use Illuminate\Http\UploadedFile;

it('accepts file upload', function () {
    $file = UploadedFile::fake()->image('avatar.jpg');

    $response = $this->postJson('/api/profile/avatar', [
        'avatar' => $file,
    ]);

    expect($response->status())->toBe(200);
    expect(Storage::disk('avatars')->exists('avatar.jpg'))->toBeTrue();
});
```

## Frontend Testing Patterns

### Render with Providers

Components often need context (auth, theme, form state). Wrap renders:

```typescript
function renderWithProviders(component: React.ReactElement) {
  return render(
    <AuthProvider>
      <ThemeProvider>
        <ToastProvider>
          {component}
        </ToastProvider>
      </ThemeProvider>
    </AuthProvider>
  );
}

// Use in tests
it('shows user name from auth context', () => {
  renderWithProviders(<Header />);
  expect(screen.getByText('Alice')).toBeInTheDocument();
});
```

### User Event Simulation

Always use `@testing-library/user-event` for realistic user interactions:

```typescript
import userEvent from '@testing-library/user-event';

it('submits form on button click', async () => {
  const user = userEvent.setup();
  const mockSubmit = vi.fn();

  render(<LoginForm onSubmit={mockSubmit} />);

  await user.type(screen.getByLabelText(/email/i), 'alice@example.com');
  await user.type(screen.getByLabelText(/password/i), 'password123');
  await user.click(screen.getByRole('button', { name: /submit/i }));

  expect(mockSubmit).toHaveBeenCalledWith({
    email: 'alice@example.com',
    password: 'password123',
  });
});
```

### Async Assertion Patterns

Wait for async updates (API calls, state changes):

```typescript
it('displays error message after failed login', async () => {
  const user = userEvent.setup();
  api.login.mockRejectedValueOnce(new Error('Invalid credentials'));

  render(<LoginForm />);

  await user.click(screen.getByRole('button', { name: /login/i }));

  // waitFor: poll until assertion passes
  expect(await screen.findByText(/invalid credentials/i)).toBeInTheDocument();
});

// Or with async query
it('shows loading state', async () => {
  const user = userEvent.setup();

  render(<UserProfile id={1} />);
  expect(screen.getByText(/loading/i)).toBeInTheDocument();

  // Wait for loading to disappear (API response received)
  await waitFor(() => {
    expect(screen.queryByText(/loading/i)).not.toBeInTheDocument();
  });

  expect(screen.getByText('Alice')).toBeInTheDocument();
});
```

### Testing Inertia Pages

Inertia pages are React components that receive props from the server:

```typescript
import { render, screen } from '@testing-library/react';
import { vi } from 'vitest';
import ShowUser from './ShowUser';

// vi.mock() is hoisted by Vitest to the top of the file at compile time —
// it must be declared at module scope, NEVER inside it()/test(). A factory
// that closes over a local variable needs vi.hoisted() so that variable
// exists before the hoisted mock runs (otherwise: "Cannot access before
// initialization").
const { mockInertiaPost } = vi.hoisted(() => ({ mockInertiaPost: vi.fn() }));

vi.mock('@inertiajs/react', () => ({
  useForm: () => ({
    data: { name: 'Alice' },
    post: mockInertiaPost,
    processing: false,
  }),
}));

it('displays user details', () => {
  const props = {
    user: { id: 1, name: 'Alice', email: 'alice@example.com' },
    auth: { user: { id: 1, name: 'Alice' } },
  };

  render(<ShowUser {...props} />);

  expect(screen.getByText('Alice')).toBeInTheDocument();
  expect(screen.getByText('alice@example.com')).toBeInTheDocument();
});

// Test form submission (Inertia.post)
it('updates user on form submit', async () => {
  mockInertiaPost.mockClear(); // module-scope mock persists across tests — reset call state
  const user = userEvent.setup();

  render(<EditUser user={{ id: 1, name: 'Alice' }} />);

  await user.click(screen.getByRole('button', { name: /save/i }));

  expect(mockInertiaPost).toHaveBeenCalled();
});
```

## Test Organization

### Feature vs Unit Tests

**Feature tests:** Test the entire flow (HTTP request → database → response).

```php
// tests/Feature/UserRegistrationTest.php
it('registers new user', function () {
    $response = $this->postJson('/api/register', [
        'name' => 'Alice',
        'email' => 'alice@example.com',
        'password' => 'secret123',
    ]);

    expect($response->status())->toBe(201);
    $this->assertDatabaseHas('users', ['email' => 'alice@example.com']);
});
```

**Unit tests:** Test a single class in isolation (mock dependencies).

```php
// tests/Unit/Services/PasswordHasherTest.php
it('hashes password', function () {
    $hasher = new PasswordHasher();
    $hash = $hasher->hash('secret123');

    expect($hasher->verify('secret123', $hash))->toBeTrue();
    expect($hasher->verify('wrong', $hash))->toBeFalse();
});
```

### Naming Conventions

Use descriptive test names that read like specifications:

```php
// GOOD: describes the condition and expected behavior
it('rejects registration when email is already taken')
it('applies discount when user reaches vip tier')
it('sends confirmation email after successful signup')

// BAD: vague
it('test_register')
it('discount_works')
```

### Test Grouping with Describe

Organize related tests:

```typescript
describe('UserForm', () => {
  describe('validation', () => {
    it('requires name', async () => { /* ... */ });
    it('requires valid email', async () => { /* ... */ });
  });

  describe('submission', () => {
    it('submits form with valid data', async () => { /* ... */ });
    it('shows error on API failure', async () => { /* ... */ });
  });

  describe('dark mode', () => {
    it('applies dark mode styles', () => { /* ... */ });
  });
});
```

Similarly in Pest:

```php
describe('UserService', function () {
    describe('registration', function () {
        it('creates user with valid email', function () { /* ... */ });
        it('hashes password before saving', function () { /* ... */ });
    });

    describe('password reset', function () {
        it('generates reset token', function () { /* ... */ });
        it('expires token after 1 hour', function () { /* ... */ });
    });
});
```

## Pest Datasets (Data-Driven Boundary Tests)

Use a dataset instead of copy-pasted near-identical tests when the same
assertion logic must run against several inputs — this is the Pest-native
way to satisfy the "Mandatory Boundary Tests" rule (empty / single / exact
boundary / just-past-boundary) without four near-duplicate `it()` blocks.

**Inline dataset with `->with()`:**

```php
it('validates email format', function (string $email, bool $valid) {
    expect(filter_var($email, FILTER_VALIDATE_EMAIL) !== false)->toBe($valid);
})->with([
    ['alice@example.com', true],
    ['not-an-email', false],
    ['', false],
]);
```

**Named dataset with `dataset()`** — reusable across multiple tests, and
each case gets a readable label in test output instead of an index:

```php
dataset('pagination boundaries', [
    'empty collection'      => [0, 10, 0],   // total, perPage, expectedPages
    'single item'           => [1, 10, 1],
    'exact page boundary'   => [20, 10, 2],
    'one past the boundary' => [21, 10, 3],
]);

it('computes total pages', function (int $total, int $perPage, int $expectedPages) {
    expect(paginate($total, $perPage))->toBe($expectedPages); // literal, not ceil($total/$perPage)
})->with('pagination boundaries');
```

Keep the expected value a literal per the Mandatory Boundary Tests rule above —
a dataset does not exempt a case from that rule; it just removes the
duplication of writing one `it()` per case.

## Mutation Testing (verifying the tests, not just the code)

Passing tests with high line coverage can still miss real bugs if no
assertion would fail when the underlying logic breaks — mutation testing
checks this by deliberately mutating production code (e.g. flipping `>` to
`>=`, changing a `+` to a `-`) and confirming the test suite fails ("kills")
each mutant. A mutant that survives (tests still pass) means that line has
no real assertion coverage, even if code-coverage tools mark it covered.

**Pest (v3+) ships mutation testing built in** — no extra package:

```bash
./vendor/bin/pest --mutate                        # mutate + run against the whole covered codebase
./vendor/bin/pest --mutate --class="App\Services\UserService"  # scope to one class (--filter is not a --mutate flag; use --class). QUOTE the FQCN — unquoted, bash strips the backslashes and Pest sees "AppServicesUserService", matching nothing.
```

Requires a coverage driver (Xdebug or PCOV) already installed for
`--coverage` to work — mutation testing runs on top of coverage data. Pest
reports a mutation score (not "MSI" — that acronym is Infection's
terminology, not Pest's): the percentage of generated
mutants that were killed. Treat a surviving mutant on a test you just wrote
in the RED phase as a signal the assertion is too weak (e.g. asserting
`->not->toBeNull()` where a literal expected value would catch the mutant).

**When to run it:** not on every RED-phase test (too slow for the fast TDD
loop) — reserve `--mutate` for pre-flight/CI on payment, auth, and
entitlement logic where a weak assertion is expensive to miss, or when a
reviewer flags suspiciously easy 100% coverage on business-critical code.

## Test Execution Quick Reference

```bash
# PHP (Pest)
./vendor/bin/pest                           # All tests
./vendor/bin/pest tests/Feature/            # Feature tests only
./vendor/bin/pest tests/Unit/Services/      # Specific directory
./vendor/bin/pest --filter=UserService      # Tests matching pattern
./vendor/bin/pest --coverage                # Coverage report

# React (Vitest)
npm run test                                 # Watch mode
npm run test:ui                              # Browser UI
npm run test -- UserForm.test.tsx            # Specific file
npm run test -- --coverage                   # Coverage report
```

## Query-Count Assertions (Eager-Loading Enforcement)

> Extracted from `v-tdd/SKILL.md` (2026-07-05) to keep the skill body under the size ceiling. v-tdd loads this section when the target is a Laravel controller/service/job touching a model with relationships (especially Cashier-backed methods).

The operator's CLAUDE.md mandates eager-loading enforcement: relationships
MUST be loaded before model methods that access them are called (especially
Cashier methods like `$user->subscription('default')`, `$user->subscriptions->first()`).
Eager-loading violations produce N+1 queries that pass functional tests but
degrade production performance silently.

**Use these patterns in any controller/service test that touches a model
with relationships.** Pick the strictest pattern your Laravel version
supports.

### Pattern 1: `LazyLoadingViolationException` (Laravel 8.43+, strictest)

Boot-time strict mode that throws on ANY lazy-loaded relationship access.
Best for catching violations close to the source.

```php
// In tests/TestCase.php or a Pest beforeEach:
use Illuminate\Database\Eloquent\Model;
Model::preventLazyLoading(! app()->isProduction());

// In the test itself — no extra assertion needed; the exception fires
// automatically if the controller code lazy-loads.
```

If the test passes with this configured, eager-loading is correct. If
`LazyLoadingViolationException` fires, the controller is missing a
`->load(...)` or `->with(...)` call.

### Pattern 2: `DB::enableQueryLog()` + explicit count

For specific routes/jobs where you want to assert a hard upper bound on
queries, regardless of strict-mode configuration.

```php
test('dashboard loads with bounded query count', function () {
    $user = User::factory()->withSubscription()->create();
    DB::enableQueryLog();

    $this->actingAs($user)->get('/dashboard')->assertOk();

    $queries = DB::getQueryLog();
    expect(count($queries))->toBeLessThanOrEqual(8);  // tune per-route
});
```

The literal number is a per-route ceiling — pick a value that allows the
intended eager-loads plus a small slack. A regression that introduces N+1
typically jumps query count by 10-50x and trips this immediately.

### Pattern 3: Custom `assertSeeQueries()` helper (if your project ships one)

**This is NOT a standard Laravel or Pest method** — Laravel does not ship
`assertSeeQueries`. Some Laravel projects build one as a wrapper around
Pattern 2 for readability. If your project has one (check
`tests/TestCase.php` or `tests/Helpers/`), use it. If not, use Pattern 2
directly or build a helper with this shape:

```php
// tests/TestCase.php — optional helper you can add
protected function assertSeeQueries(int $max, callable $closure): void
{
    \DB::enableQueryLog();
    \DB::flushQueryLog();
    $closure();
    $count = count(\DB::getQueryLog());
    expect($count)->toBeLessThanOrEqual($max, "expected ≤{$max} queries, got {$count}");
}
```

Then in tests:

```php
$this->assertSeeQueries(5, function () use ($user) {
    $this->actingAs($user)->get('/dashboard')->assertOk();
});
```

If you don't want to add the helper, Pattern 2 (direct `DB::getQueryLog()`)
is fine and is the safer default for projects that don't already use this
abstraction.

### Cashier-specific scenario

Tests that invoke Stripe-backed methods (`$user->subscription('default')`,
`$user->subscribedToProduct(...)`, etc.) MUST eager-load `subscriptions`
and `subscriptions.items` first per the operator's CLAUDE.md Critical
Gotchas. Note: `subscription('default')` is a **method** (it filters the
`subscriptions` relation by type) — there is no `subscription` relation to
eager-load; the relation you load is always the plural `subscriptions`. The
test scaffold uses a bounded query-count ceiling (Pattern 2 above) rather
than a substring-matched exact count, because eager-loading `subscriptions`
+ `subscriptions.items` legitimately runs 2 queries and both rows can
contain the substring "subscriptions" (e.g. a `subscription_items` table
name) — an exact-count-of-1 assertion on a substring match is fragile and
will false-fail:

```php
test('upgrade endpoint avoids N+1 on subscription lookup', function () {
    $user = User::factory()->withSubscription()->create();

    DB::enableQueryLog();
    $response = $this->actingAs($user)->post('/billing/upgrade', [...]);

    $queries = DB::getQueryLog();
    expect(count($queries))->toBeLessThanOrEqual(8); // bounded ceiling — tune per-route
});
```

If the count exceeds the ceiling, the controller is calling
`$user->subscription('default')` without first running
`->load('subscriptions', 'subscriptions.items')`.

### When to skip these assertions

- Pure unit tests on services that don't touch the database
- Component-level React tests (Vitest) — query-count is a backend concern
- Routes that legitimately need >20 queries (rare; prefer chunking + a
  bounded-query test per chunk)

### Failure mode this catches (verified real)

Without query-count assertions, an AI-generated controller change that
removes a `->load(...)` call ships green tests + a silent N+1. The
operator's CLAUDE.md explicitly calls this out for Cashier; this skill
provides the scaffolding to enforce it.
