# Framework Pitfalls — Bug Classes That Survive Normal Code Review

_Last reviewed: 2026-08-02 (fabricated-API sweep: every code sample and class/method reference in this file checked against `laravel/framework` v13.16.1, `laravel/cashier`, `laravel/pennant`, and `inertiajs/inertia-laravel` vendor source in installed project trees. One stale entry fixed — the Class 1 Laravel grep-signal list carried `public function timeoutAt # overrides $timeout`; that method doesn't exist in any installed Laravel version (11.x-13.x) and never actually overrode `$timeout` even under its old name (it was the pre-Laravel-6 name for what is now `retryUntil()`, which governs the retry deadline, not the single-execution timeout) — folded into the `retryUntil` line instead of left as a separate, wrong signal. Everything else in `§ Verified framework semantics` (UniqueLock::getKey, Cashier swap/swapAndInvoice/subscription(), Pennant Feature API incl. the no-`percentage()` claim, Broadcast::fake() absence, Inertia defer/optional/lazy-deprecated, preventLazyLoading's exact exemption) re-confirmed line-for-line against vendor source — no changes needed there.)_

A portable catalog of bug *classes* that slip past type checkers, logic reviewers, and codebase-fit reviewers — but cause real production incidents. Each entry is framework-agnostic; concrete examples shown for Laravel/Rails/Django/Node where helpful.

Use this catalog from two directions:
- **Implementer side (prevention):** before writing or editing code that touches any pattern below, write the failing test that would catch the wrong implementation.
- **Reviewer side (detection):** `framework-pitfall-reviewer` agent loads this file and greps the diff against each pattern.

The patterns are documented under what they LOOK like in the diff, not what the bug ultimately is. Reviewers can grep without understanding the framework deeply.

---

## Class 1 — Framework-silent-override

**Pattern:** A framework method whose effect overrides a documented public-API knob, without the language compiler enforcing the override relationship. Setter looks set but isn't honored at runtime.

### Diff signals (grep these)

```
# Laravel queue jobs
public function retryUntil       # silently overrides $tries (renamed from timeoutAt() pre-Laravel-6; timeoutAt no longer exists — do not grep for it)
public function backoff(         # method form overrides array $backoff
public function middleware(      # appended; Job::middleware property is overridden if both used

# Rails ActiveJob
retry_on .*, attempts:           # interacts with retry_on Default vs explicit
discard_on                       # silently swallows; never retries

# Sidekiq / queue libraries (generic)
sidekiq_retry_in .* do           # overrides retry_in
sidekiq_options retry:           # max_retries fallback chain

# Django Celery
autoretry_for                    # overrides retry_kwargs.max_retries
acks_late                        # interacts with task_reject_on_worker_lost

# Node Bull / BullMQ
attempts:                        # overrides defaultJobOptions.attempts
backoff: { type: 'custom'        # custom backoff fn ignores attempts cap

# HTTP middleware ordering (Apache/nginx/Laravel)
$middleware->append(             # vs prepend — order matters for security
Route::middleware(['cors'        # before/after auth changes contract
```

### The test to write FIRST

A "framework contract test": dispatch the job (or fire the action) with the public knob set to a sentinel value, then assert the framework actually honored it.

```php
// Laravel example — assert retry budget actually equals $tries, not retryUntil
test('SyncFoo job retry budget honors $tries=3', function () {
    Queue::fake();
    $job = new SyncFoo($site);
    expect($job->tries)->toBe(3);
    expect(method_exists($job, 'retryUntil'))->toBeFalse(
        'retryUntil() silently overrides $tries; remove one or document the interaction'
    );
});
```

The shape is the same in any language:
1. Assert the public knob equals what you set
2. Assert no method exists that would override it
3. Optionally: run a smoke test that exhausts retries and counts attempts

### Why type checkers miss it

PHP/Ruby/Python don't track "this method overrides this property at runtime via reflection in the framework." TypeScript can catch SOME of these (BullMQ types) but not most. The override is in the framework's worker source code, not in the job's declared API.

---

## Class 2 — Env-keyed half-guard

**Pattern:** A guard, security check, or worker registration is conditional on a specific environment, and the conditional excludes valid non-local, non-production envs (preview, staging, integration, qa, demo).

### Diff signals (grep these)

```
# Laravel / Symfony / Rails / Node — all variants
app()->environment('production')
\App::environment() === 'production'
Rails.env.production?
process.env.NODE_ENV === 'production'
config('app.env') === 'production'

# Horizon / Sidekiq / queue worker registration
'environments' => [               # ONLY 'local' and 'production' keys
  'production' => [ ... ],
  'local' => [ ... ],
]

# CI/CD config
if: ${{ github.ref == 'refs/heads/main' }}    # excludes 'staging' branch deploys

# Feature flags
if (env('APP_ENV') === 'production' && ...)   # weakens flag in non-prod
```

### The test to write FIRST

Before changing or adding an `if (env === 'production')` block, write the test that proves the guard ALSO fires in any env that isn't `local`/`testing`:

```php
test('cache driver guard fires in preview, staging, and production', function (string $env) {
    Config::set('app.env', $env);
    expect(app(MyGuard::class)->shouldFire())->toBeTrue();
})->with(['production', 'preview', 'staging', 'demo']);
```

Or assert by reading the source:

```php
test('lazy-loading guard does not exclude preview', function () {
    $file = file_get_contents(app_path('Providers/AppServiceProvider.php'));
    expect($file)->not->toMatch(
        '/environment\(\s*[\'"]production[\'"]\s*\)/',
        'use environment([\'production\', \'preview\', ...]) — single-env guards bite when staging is added'
    );
});
```

### Default-safe rewrite

```php
// WRONG — defaults the guard OFF in unknown envs
if (app()->environment('production')) { register_security_guard(); }

// RIGHT — defaults the guard ON in unknown envs; explicitly allow-list local envs
if (! app()->environment(['local', 'testing'])) { register_security_guard(); }
```

The inversion matters. New envs added later (preview, demo, e2e) inherit the safe behavior automatically.

### Why it survives code review

Every reviewer sees `environment('production')` and reads "this fires in prod" — which IS what it does. They don't ask "what about preview?" because the reviewer doesn't know preview exists yet. The bug only manifests when someone introduces preview/staging.

---

## Class 3 — Side-effect-before-verify

**Pattern:** A state mutation (cache write, counter increment, audit log, db row) executes BEFORE the check that's supposed to gate it. Attackers can trigger the side effect repeatedly with junk credentials.

### Diff signals (grep these)

Look for the SEQUENCE of operations, not just one line:

```
# Inside a verify/auth/check function
Cache::add(... nonce ...)                # consume nonce
hash_equals(...)                         # THEN check signature
                                         # ^ should be reversed

# Auth middleware / webhook controllers
$user = User::firstOrCreate(...)         # creates row
$valid = $request->isValid()             # checks signature AFTER

# Payment / order flow
$order->increment('attempts')            # increments
$paid = $gateway->charge()               # then charges

# Email / SMS verification
$code->markUsed()                        # marks consumed
$ok = hash_equals($code, $submitted)     # then compares
```

### The test to write FIRST

```php
test('nonce is NOT consumed when signature is invalid', function () {
    Cache::flush();
    $response = $this->postJson('/webhook', [...], [
        'X-Signature' => 'invalid-junk',
        'X-Nonce'     => 'legit-future-nonce',
    ]);
    expect($response->status())->toBe(403);

    // The legit nonce must still be usable
    $response2 = $this->postJson('/webhook', [...], [
        'X-Signature' => $this->computeSignature($body),
        'X-Nonce'     => 'legit-future-nonce',
    ]);
    expect($response2->status())->toBe(200);
});
```

This single test catches every variant: nonce-burning DoS, counter-inflation, audit-log poisoning, premature OTP consumption.

### Why it survives code review

The function reads top-to-bottom and the verification IS there — just below the side effect. A reviewer scanning for "does this verify?" answers yes. The order matters but isn't visually emphasized.

### Repair pattern

Split the check into pure read (no mutation) and write phases:

```php
// 1. PURE READ — Cache::has, not Cache::add
if (Cache::has($nonceKey)) { abort(409, 'nonce already used'); }

// 2. VERIFY — pure computation
if (! hash_equals($expected, $provided)) { abort(403, 'bad signature'); }

// 3. NOW mutate — after both checks pass
Cache::put($nonceKey, true, $ttl);
```

---

## Class 4 — Hand-rolled framework primitive

**Pattern:** Code reconstructs a framework-internal key, hash, signature, or filename from string concatenation instead of calling the framework's public helper. The format is *currently* what the framework uses, but the framework can change it in a minor version.

### Diff signals (grep these)

```
# Laravel
'laravel_unique_job:'.$class.':'.$id          # use UniqueLock::getKey()
'cache:'.md5($key)                            # use Cache::driver()->getStore()->getPrefix()
hash('sha256', $sessionId.$user->id)          # use Hash::hmac() / signed routes
storage_path('app/'.$path)                    # use Storage::path()

# Rails
"queue:#{queue_name}"                         # use Sidekiq::Queue.new(queue_name)
"#{user_id}-#{token}"                         # use signed_global_id

# Django
'session:'+session_key                        # use SessionStore
'csrf:'+token                                 # use django.middleware.csrf

# Node / Express
'sess:'+id                                    # use req.session helpers
crypto.createHmac('sha256', secret)           # often fine, BUT must match
                                              # framework's exact algorithm if integrating
```

### The test to write FIRST

```php
test('unique lock key matches Laravel framework helper', function () {
    $job = new SyncFoo($site);

    // Use the framework's public helper — what the framework actually uses
    $expected = \Illuminate\Bus\UniqueLock::getKey($job);

    // Whatever your code computes
    $actual = (new MyController)->computeLockKey($job);

    expect($actual)->toBe($expected,
        'do not hand-roll the unique-job key; call UniqueLock::getKey(). Its exact format is '.
        'framework-internal AND version-dependent — Laravel 12+/13 build it from '.
        'hash("xxh128", $job->displayName()) when the job defines displayName() (e.g. Horizon-tagged '.
        'jobs), else get_class($job); Laravel 11.x used plain get_class($job). Asserting any '.
        'hand-built literal string is exactly the brittleness this test exists to prevent — pin to '.
        'the helper output, never to a reconstructed format.'
    );
});
```

### Why it survives code review

The hand-rolled string LOOKS like the framework's documented format (it usually was, at the time the code was written). Reviewers don't have the framework source open. The format silently diverges when the framework adds hashing, prefixing, or versioning.

### Repair pattern

Before writing `'framework_prefix_' . $thing`, grep the framework source:

```bash
# In any vendored framework directory
grep -rn "function getKey\|public function getName\|protected function key" vendor/laravel/framework/src/Illuminate/Bus/
grep -rn "Cache::lock\|UniqueLock\|hashed_key" vendor/
```

If a helper exists, use it. If it doesn't and you MUST hand-roll, add the contract test above so the day the framework changes its format, your test catches it.

---

## Class 5 — Registry / schema drift

**Pattern:** A registry (audit-event schema, allowed-field list, route enum, event-type union) declares the keys/types it supports, but real callers pass keys the registry doesn't declare. Callers don't fail at the type level because the registry's check is runtime-only or uses `Record<string, unknown>` / `mixed`.

### Diff signals (grep these)

```
# Schema/whitelist tables in code
const ALLOWED_FIELDS = ['a', 'b']
const CONTEXT_SCHEMAS = ['sync' => [...]]
type Event = 'view' | 'click'                # exhaustive type
SCHEMA = {'sync': {'site_id', 'error'}}

# Soft-validation that logs instead of throwing
Log::debug('schema_mismatch'                 # the trail left by the bug

# Inertia / API response shape
return inertia('Page', $props)               # $props keys vs Page.tsx contract
```

### The test to write FIRST

A "registry callsite scan" test that uses `Grep` (or `ripgrep`) to enumerate every callsite and assert each passes only declared keys:

```php
test('every sync audit callsite passes only declared keys', function () {
    $schema = AuditService::CONTEXT_SCHEMAS['sync'];

    // Scan ALL callsites of $audit->logAction('sync.*', $ctx) across the codebase
    $callsites = collectCallsites('app/', 'logAction', 'sync.');

    foreach ($callsites as $file => $passedKeys) {
        foreach ($passedKeys as $key) {
            expect($schema)->toContain($key,
                "Callsite $file passes key '$key' that the schema doesn't declare"
            );
        }
    }
});
```

The test re-runs on every commit and catches new drift immediately, not weeks later when someone reads the debug log.

### Why it survives code review

The schema check is too lenient (logs a debug, doesn't throw). The callsite "works" — the data is persisted, just with extra fields. No user-visible breakage; just silent drift that nobody notices until you do a bug-hunt.

### Repair pattern

Either:
- **Strict mode:** throw in non-production envs when the schema-mismatch happens (env-keyed but use Class 2's safe inversion — fire in everything except `local`/`testing`)
- **Scanning test:** the test above runs in CI; any drift fails the build
- **Codegen:** generate the schema FROM the callsites (TypeScript discriminated unions; PHP enum + match)

---

## Verified framework semantics — look these up, do NOT re-derive across turns

**Cashier / Pennant / Inertia API currency (do NOT "correct" these to fabricated forms).**
- `$subscription->swapAndInvoice($priceId)` is a **real** Cashier method (swap + immediate proration invoice). `$subscription->swap($priceId)` is also real and MUST be passed a price id. Do not flag either as fabricated.
- A user's subscription is `$user->subscription('default')` (method) or the `subscriptions` relation — there is **no bare `subscription` relation**. Eager-load with `loadMissing('subscriptions')` (see the `preventLazyLoading` note below).
- Pennant has **no** `Feature::percentage()`. Define with `Feature::define('flag', fn (User $u) => Lottery::odds(1, 10))`; check per-scope via `Feature::for($u)->active('flag')`; deactivate scoped via `Feature::deactivate('flag')`. A global kill switch = redefine the feature to `false` + `Feature::purge('flag')` (there is no global percentage switch).
- Broadcasting has **no** `Broadcast::fake()` / `Broadcast::assertBroadcasted()`. Assert a `ShouldBroadcast` event with `Event::fake([...])` + `Event::assertDispatched(SomeEvent::class)`. The env key is `BROADCAST_CONNECTION` (Laravel 11+), not `BROADCAST_DRIVER`.
- Inertia v2 deferred/partial props: `Inertia::defer(fn () => …)` and `Inertia::optional(fn () => …)` (the v2 rename of `lazy`). `Lazy::make` / `Inertia::lazy()` are stale.
- Laravel 13: all config (routes/middleware/exceptions) registers in `bootstrap/app.php`; providers/events auto-discovered. Use Cashier's built-in webhook controller/route, not a hand-rolled one. Global rule: hard deletes, NOT `SoftDeletes`.


When a framework guard does not fire as you expect, **do not theorize the framework's internals over multiple turns.** A production /v session burned ~7 turns inventing a wrong rule for Laravel's `preventLazyLoading` ("it only throws when the model is part of a Collection of >1") and reasoned from it that a production controller needed no `loadMissing` — the opposite of correct. The right move is to look up the verified rule below, apply the convention-correct fix, and write ONE test that forces the **production path**.

**Laravel `Model::preventLazyLoading()` — the real exemption.** A lazy access throws `LazyLoadingViolationException` EXCEPT when, in `handleLazyLoadingViolation`:

```php
if (! $this->exists || $this->wasRecentlyCreated) { return; }   // <-- the ONLY exemption
throw new LazyLoadingViolationException($this, $key);
```

So: **factory-created models in the same test (`wasRecentlyCreated === true`) never throw** — which is why a Cashier/relation test can pass with NO `loadMissing` and still be lazy-loading-unsafe in prod. In production `Auth::user()` is DB-retrieved (`exists === true`, `wasRecentlyCreated === false`) → it WOULD throw (or, if the guard is log-only in prod, silently emit). It is NOT about collection size; a single `Model::find()` accessing an unloaded relation throws just the same. **Implication for reviewers:** a passing relation test does not prove eager-load safety. The contract test must force the production shape — retrieve the model fresh from the DB (not a same-request factory instance) before asserting no violation, e.g. `$u = User::findOrFail($id); ... assert no LazyLoadingViolationException`. (`framework-pitfall-reviewer`: flag any controller/job/observer accessing a Cashier relation — `subscribed()/onTrial()/subscription()` — without `loadMissing('subscriptions')`, and flag any "no lazy-load" test that exercises only a factory-fresh instance.)

---

## How to use this catalog as a reviewer

1. Run `git diff --name-only HEAD` to see changed files
2. For each changed file, grep the diff against Class 1-5 signals
3. For each match, follow the "test to write FIRST" link to verify the contract test exists
4. If the test doesn't exist, that's a finding — severity = the class's blast radius

Severity rubric per class:
- Class 1 → P0/P1 (silent retries can run for hours; budget overruns)
- Class 2 → P1/P2 (works in dev, fails in the env it was meant to protect)
- Class 3 → P0/P1 (security; auth bypass or DoS)
- Class 4 → P1/P2 (works until framework upgrade; then silent)
- Class 5 → P2/P3 (data quality; usually not user-facing)

## How to use this catalog as an implementer

Before writing code that touches any of the signals:
- **For Class 1:** look up the framework's worker/runtime source for your method. Search "overrides" near your method name. Write the contract test first.
- **For Class 2:** never write `environment('production')` unless you ALSO write `environment(['local', 'testing'])`. The default-safe inversion makes the next env (preview, staging, demo) inherit safety automatically.
- **For Class 3:** order your operations: (1) read state, (2) verify, (3) mutate. Never (1) mutate, (2) verify.
- **For Class 4:** grep the framework source for a helper before writing `'prefix_'.$id`. If you must hand-roll, write the contract test.
- **For Class 5:** if you add a registry, also add the callsite-scan test.

## Adding a new class

When you encounter a NEW bug class in the wild (not covered by 1-5), append it here with:
- Pattern: one-sentence description of the SHAPE of the bug
- Diff signals: grep patterns, framework-agnostic if possible
- Test to write first: a paste-able test that pins the contract
- Why it survives review: what makes it invisible
- Repair pattern: the safe rewrite
- Severity rubric

Then update `framework-pitfall-reviewer` agent to scan for the new signals.
