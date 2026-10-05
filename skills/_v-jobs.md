# V Jobs

Shared governance for async job design. Centralizes rules currently scattered across v-build (implementation), v-scaffold (job template), v-check (queue deployment), and v-check (audit domains).

_Last reviewed: 2026-08-02 (added job uniqueness/overlap, batching, queue monitoring, and model-call job rules — AI-era coverage sweep; fabricated-API sweep same day: `WithoutOverlapping::releaseAfterMinutes()` doesn't exist — real method is `releaseAfter()` (seconds, like `expireAfter()`); `$batch->totalJobs()` is a property not a method; `$this->payload()` inside a job's `failed()` isn't defined on the job itself — it lives on the queue `Job` wrapper (`$this->job?->payload()`), same object `getJobId()` already reads on the line above. All verified against `laravel/framework` v13.16.1 vendor source.)_

## Job Design Rules

Every job must explicitly define these three execution parameters — do not rely on framework defaults:

- `$tries`: Number of retry attempts (e.g., 3 for typical transient errors, 1 for deterministic failures)
- `$backoff`: Delay between retries in seconds, as an array for exponential backoff (e.g., `[10, 60, 300]` = 10s, 1m, 5m)
- `$timeout`: Maximum execution time in seconds, always less than queue worker timeout (e.g., 30 for HTTP calls, 300 for processing)

Example:
```php
class ProcessPaymentJob implements ShouldQueue {
    public $tries = 3;
    public $backoff = [10, 60, 300];  // exponential backoff
    public $timeout = 30;             // 30 seconds max
}
```

## Idempotency Principle

Every job must be safe to run twice with the same payload. If a job has external side effects, use idempotency keys:

- **External API calls:** Store a request ID or idempotency key in the database before calling the API. On retry, check if the key already exists before re-submitting.
- **Payment processing:** Use payment provider's idempotency key support (Stripe, PayPal, etc.)
- **Email sending:** Check if the email was already sent before re-sending
- **File operations:** Store file hash and path to detect duplicates on retry

Non-idempotent jobs must be marked clearly in code and documented why (e.g., "must not retry" comment with reason).

## Job Uniqueness & Overlap Prevention

Idempotency (above) makes a job *safe* to run twice. Uniqueness and overlap prevention stop it from running twice **concurrently** in the first place — a distinct failure mode: two workers picking up the same logical job (a webhook fired twice before the first finishes, a scheduled job still running when the next tick fires) and both racing to do the side effect before either commits its idempotency key.

- **`ShouldBeUnique`** (job-level, dispatch-time dedup): implement `Illuminate\Contracts\Queue\ShouldBeUnique` and define `uniqueId()` (defaults to the job class alone if omitted — usually too coarse to be useful) or `uniqueVia()` to pick the lock's cache store. The framework computes and holds the lock key for you — never hand-roll a matching key string from concatenation (`~/.claude/skills/references/framework-pitfalls.md § Class 4 — Hand-rolled framework primitive` is exactly this failure mode).
- **When to use it:** any job keyed to a real-world entity where a second dispatch for the same entity before the first finishes is a bug, not a feature — sync jobs, report-generation jobs, webhook-triggered jobs, anything a scheduler or a double-clicked button could double-fire.
- **`WithoutOverlapping`** (queue middleware, on the job's `middleware()` method): use instead of, or alongside, `ShouldBeUnique` when the constraint is about *execution* overlap rather than *dispatch* dedup — a job that's fine being queued more than once but must never have two copies executing at the same time (a per-tenant sync, a rebuild job). Size `->releaseAfter()`/`->expireAfter()` explicitly against the job's own `$timeout` — never leave it at the default, or a slow run can let a second copy start before the lock naturally expires. Both take **seconds** (there is no `releaseAfterMinutes()` — `Illuminate\Queue\Middleware\WithoutOverlapping` only defines `releaseAfter()` and `expireAfter()`, verified against `laravel/framework` v13.16.1).
- **Decision rule:** if duplicate *dispatch* is the risk (double-fired webhook, double-clicked bulk action), reach for `ShouldBeUnique`. If duplicate *concurrent execution* is the risk (a long-running per-tenant job that must never overlap itself), reach for `WithoutOverlapping`. Many jobs need both, and neither substitutes for the idempotency key above — uniqueness prevents concurrent duplicates, idempotency handles the sequential retry case uniqueness doesn't cover.

## Batching For Bulk Operations

Any user-triggered bulk action on a list view — the house power-user bar (`~/.claude/CLAUDE.md § Production Standards`: bulk operations on list views >10 items) — needs progress feedback, partial-failure visibility, and a completion signal. `Bus::batch()` is what provides all three; dispatching N independent jobs from a bare loop gives you none of them — no shared identity for the UI to track, and one item's failure is invisible unless you built your own tracking table.

```php
$batch = Bus::batch(
    $selectedIds->map(fn ($id) => new ProcessItemJob($id))
)->then(function (Batch $batch) {
    // all jobs in the batch succeeded
})->catch(function (Batch $batch, Throwable $e) {
    // first job failure — batch continues unless allowFailures(false)
})->finally(function (Batch $batch) {
    // always runs — update the user-facing status record here
})->name('bulk-process-'.$requestId)->dispatch();

// Persist $batch->id against the triggering request/session so a
// status endpoint or broadcast channel can report progress via
// $batch->processedJobs(), $batch->totalJobs (property, not a method), $batch->finished().
```

- **Decision rule:** any action dispatching more than one job per user interaction, or any list-view bulk action, uses `Bus::batch()` — never a bare loop of `dispatch()` calls.
- **Store the batch ID** on the triggering record so the frontend can poll or subscribe for progress — the loading/in-progress UI state for a bulk action is built on this ID (state coverage itself is `~/.claude/skills/v-build/references/saas-patterns.md § UI state management checklist`'s domain — cite it, don't rebuild it here).
- **Decide `allowFailures()` up front.** The default (fail-fast, remaining jobs skipped) is usually wrong for a bulk action, where 9 of 10 items succeeding is a better outcome than rolling all 10 back — call `allowFailures()` explicitly and surface the per-item result rather than a single pass/fail.

## Queue Monitoring

A Redis-backed queue needs monitoring beyond "the worker process is running." Queue depth, the age of the oldest pending job, and the failed-job rate are the three signals that catch a stuck or backed-up queue before it becomes a user-visible incident (a bulk-action batch that silently stalls, a model-call job — below — piling up behind a slow provider).

- **Minimum viable:** the framework's built-in `queue:monitor` command, scheduled and alerting through the same channel as the `failed()` handlers above (`php artisan queue:monitor <queue> --max=1000` wired into the scheduler) catches a queue-depth blowout without adding a dependency.
- **At scale** (multiple queues, worker-count tuning, per-job runtime visibility): a dashboard-backed queue monitor for Redis-driven queues gives per-queue throughput, runtime, and failed-job browsing without hand-building it — a better fit for an unattended operator than a bespoke metrics page.
- **Decision rule:** any project on a Redis queue driver with more than one active queue name, or with any bulk/batch feature (above), needs a monitoring surface — `queue:monitor` alerting at minimum, a dashboard once queue count or volume makes manual `failed_jobs` table inspection impractical.

## Retry Policy

- **Retry on:** Network errors (connection timeout, DNS failure), HTTP 5xx (server error), queue delivery failures, temporary locks/deadlocks
- **Never retry on:** Validation errors (bad input), 4xx errors (except 429 rate limit), business logic failures (insufficient funds), missing dependencies

Use exception types to control retry behavior:

```php
// Retry only for transient failures
if ($response->status() >= 500) {
    $this->release(60); // retry after 60s
} elseif ($response->status() === 429) {
    $this->release(300); // rate limited: wait longer
} else {
    // 4xx or other: don't retry
    $this->fail(new RuntimeException("Payment provider error: {$response->status()}"));
}
```

## Dispatch-After-Commit Pattern

Never dispatch a job inside an active database transaction. If the transaction rolls back, the job has already been queued and will fail trying to process non-existent data.

**Pattern 1: Use Laravel's `afterCommit()`**
```php
DB::transaction(function () {
    $user = User::create([...]);

    // Dispatch only after the transaction commits
    dispatch(new SendWelcomeEmail($user->id))->afterCommit();
});
```

**Pattern 2: Dispatch after transaction scope ends**
```php
DB::transaction(function () {
    $user = User::create([...]);
});

// Outside transaction
dispatch(new SendWelcomeEmail($user->id));
```

**Anti-pattern:**
```php
// WRONG: inside transaction, job dispatched but may be processed before commit
DB::transaction(function () {
    $user = User::create([...]);
    dispatch(new SendWelcomeEmail($user->id)); // UNSAFE
});
```

## Dead Letter Handling

When a job exhausts all retries (`failed()` method is called), do not silently fail. Log structured context and notify:

```php
public function failed(Throwable $exception): void {
    Log::error('PaymentJob failed', [
        'job_id' => $this->job?->getJobId(),
        'payload' => $this->job?->payload(),
        'attempts' => $this->attempts(),
        'error' => $exception->getMessage(),
        'trace' => $exception->getTraceAsString(),
    ]);

    // Notify admin or operations
    Notification::route('slack', config('jobs.deadletter_channel'))
        ->notify(new JobFailedNotification($this, $exception));
}
```

Structured logging enables alerting and post-mortem analysis. Silent failures hide systemic issues.

## Timeout Protection

HTTP calls inside jobs must have explicit timeout configuration. Never rely on default/infinite timeouts:

```php
// BAD: no timeout specified
$response = Http::get('https://api.example.com/data');

// GOOD: explicit timeout
$response = Http::timeout(30)
    ->get('https://api.example.com/data');

// BETTER: timeout + retry + fallback
try {
    $response = Http::timeout(15)
        ->retry(2, 100)
        ->get('https://api.example.com/data');
} catch (ConnectionException $e) {
    $this->release(60); // retry job later
}
```

Set timeout shorter than `$timeout` to allow retry logic to execute before the job times out globally.

## Queue Selection

Route jobs to appropriate queues based on priority and characteristics:

- **High-priority (payment, auth, critical notifications):** Dedicated queue with aggressive worker count
- **Bulk operations (imports, exports, reports):** Separate queue with relaxed timeout
- **Notifications (email, SMS, webhooks):** Shared queue with medium workers
- **Maintenance (cleanup, archival):** Low-priority queue, can run at off-peak hours

```php
dispatch(new ProcessPaymentJob())->onQueue('payments'); // highest priority
dispatch(new ImportUsersJob())->onQueue('bulk');        // relaxed timeout
dispatch(new SendEmailJob())->onQueue('notifications');  // medium priority
```

This prevents bulk operations from blocking critical payment processing.

## Model-Call Jobs

Every model call is an external API call, so it lives in a job like any other — `~/.claude/CLAUDE.md § Stack Conventions` puts external API calls in Jobs only, never the request lifecycle, and that rule doesn't carve out an exception for model calls. But a model call fails differently than a typical HTTP integration, and copying an ordinary job's defaults onto it produces two failure modes unique to this category: runaway spend, and paying for the same guaranteed-to-fail call more than once.

**Unit economics and model-selection criteria are out of scope here** — `~/.claude/skills/references/ai-feature-engineering.md § Cost model` and `~/.claude/skills/references/ai-feature-engineering.md § Model selection criteria` own the reasoning that produces the numbers below; this section owns what the job does with them.

### Budget enforcement — before dispatch, not inside `handle()`

- **Check the per-user/per-tenant spend cap before the job is dispatched**, not as the first line of `handle()`. A cap enforced only inside the job still pays the dispatch overhead for every request that was always going to be rejected, and under burst load several jobs can pass a stale in-`handle()` check before any of them commits its spend. Enforce it at the point that would dispatch the job — the controller/action deciding whether to queue it at all — against the current period's tracked spend for that user/tenant.
- **Fail closed at the cap.** When the cap is hit, do not dispatch — return the degraded path immediately (`~/.claude/skills/references/ai-feature-engineering.md § Degradation UX` owns what the user sees). A job dispatched "just in case" and rejected inside `handle()` has already consumed a queue slot and, on providers that bill per-request rather than per-completion, may have already been charged.
- **Track spend with an atomic counter**, incremented inside a `DB::transaction` (or an atomic `Cache::increment`) at the point spend is confirmed — using the provider's actual reported usage on success, not a pre-call estimate. If you increment optimistically before the call and reconcile after, the increment/decrement pair must be atomic; two concurrent jobs both reading a stale pre-increment count and both passing the cap check is a reliability-class race condition (this file's `## Job Uniqueness & Overlap Prevention` above is the general defense against exactly this shape of bug).

### Timeouts — set from measured latency, not copied from an HTTP job

- Model calls routinely run one to two orders of magnitude slower than a typical REST call, and the spread widens further for larger inputs or multi-step/agentic calls. A `$timeout` copied from an ordinary job (this file's own `## Job Design Rules` example uses 30s) will truncate a legitimate in-progress call.
- **Set both the job's `$timeout` and the HTTP client's per-call timeout from the feature's own observed latency distribution**, not a guess — measure it during the eval-harness pass (`~/.claude/skills/references/ai-feature-engineering.md § Eval harness`), separately per distinct task shape (a short classification call and a long-form generation call do not share a budget), and set the timeout with headroom above the observed p99, not the median.
- The job's `$timeout` must still stay below the queue worker's own timeout (this file's general rule, unchanged), and the retry `$backoff` (below) must give a struggling provider room to recover rather than re-hammering it immediately.

### Retry policy — retryable transport failure vs. non-retryable rejection

This is where model calls diverge from the general `## Retry Policy` above. A model call can fail for reasons no retry will ever fix, and retrying those pays the same cost N times for an outcome you already know:

- **Retry:** connection/timeout errors, provider 5xx, an explicit rate-limit response (honor the provider's own backoff hint if it returns one; otherwise use this file's exponential `$backoff`), and a transient capacity/overload signal where the provider layer distinguishes one.
- **Never retry:** a content/input-validation rejection, a context-length/input-too-large error, a malformed-request error caused by your own code, or a response that came back successfully but failed your eval-harness invariants (`~/.claude/skills/references/ai-feature-engineering.md § Eval harness`) — that last case isn't a transport failure at all, and retrying it burns spend on a result you already know will fail the same check again. Route it straight to the degraded-UX path and to `failed()`-style structured logging so the pattern is visible before it recurs.
- **Decision rule:** before adding a failure to the retry set, ask "will retrying this exact request produce a different outcome?" If no — a deterministic rejection — it belongs in the never-retry set regardless of the HTTP status code it happens to carry. A model provider's 4xx/5xx boundary does not line up with retryable-vs-not the way it does for an ordinary REST API; classify by outcome-determinism, not status-code range.

### The streaming problem

A queued job runs detached from the request that triggered it — it has no open connection to stream tokens back to, unlike a request-lifecycle call to a streaming endpoint. Since every model call is a job (above), any feature that wants an incremental "typing" experience has to solve this explicitly. Two patterns; pick with the decision rule below:

- **Broadcast/WebSocket push.** The job publishes incremental output (or just a completion event) to a channel scoped to the requesting user/session; the frontend subscribes on mount and appends as events arrive. Requires a broadcasting transport already in the stack. Gives the closest experience to a live stream and scales to multiple concurrent model features without added polling load.
- **Client polling a job-status endpoint.** The dispatching request returns a job/batch ID immediately; the frontend polls a status endpoint (or reads the `Bus::batch()` progress fields from `## Batching For Bulk Operations` above, for a batched feature) until the record shows complete, then fetches the result. No broadcasting infrastructure required, but coarser-grained — the poll interval is the UX's minimum latency floor — and polling load scales with concurrent users.
- **Decision rule:** if the stack already has a broadcasting transport wired for another real-time feature, reuse it for anything that reads as a live/"in-progress" surface. If broadcasting isn't already in the stack and this would be the first feature to need it, client polling against a job-status endpoint is the lower-setup-cost default. Either way, run the polling/subscribing UI through the same six canonical states (`~/.claude/skills/v-build/references/saas-patterns.md § UI state management checklist`) — the wait window is the loading state, a job that never completes is the error state, not a silently-spinning one.
- Neither pattern replaces the ordinary completion signal — wire `then()`/`catch()`/`finally()` (or a single-job `failed()`) regardless of which streaming pattern is chosen; streaming the happy path is not a substitute for surfacing the failure path.

## Job Testing

Jobs must be tested in two contexts:

**Test 1: Queue assertion (dispatch behavior)**
```php
Queue::fake();
SomeAction::run($data);
Queue::assertPushed(ProcessPaymentJob::class);
```

**Test 2: Direct invocation (handle logic)**
```php
$job = new ProcessPaymentJob($paymentId);
$job->handle();
// Assert side effects: database state, API calls, etc.
```

The queue fake tests dispatch logic. Direct invocation tests the job's core handle() method and its side effects. Both are required for complete coverage.

---

## Checklist for Job Creation

When scaffolding or reviewing a job:

- [ ] `$tries`, `$backoff`, `$timeout` explicitly set (no defaults)
- [ ] Idempotency strategy documented (key storage, external API check, etc.)
- [ ] Retry logic uses appropriate exception types (not blanket retries)
- [ ] Dispatch happens after DB commit (`.afterCommit()` or outside transaction)
- [ ] `failed()` method logs structured context and notifies
- [ ] HTTP calls have explicit timeout (never default/infinite)
- [ ] Queue assignment matches job priority
- [ ] Uniqueness/overlap strategy declared (`ShouldBeUnique`/`WithoutOverlapping`) or explicitly not needed
- [ ] Bulk/list actions dispatch via `Bus::batch()`, not a bare loop of `dispatch()` calls
- [ ] Redis-backed queues have a `queue:monitor` alert or dashboard covering this queue
- [ ] Model-call jobs: per-user/tenant budget checked and enforced BEFORE dispatch (fail closed at the cap); timeout set from measured latency, not copied from an HTTP job; retry policy separates retryable transport failures from non-retryable content/validation rejections; streaming pattern (broadcast or poll) decided, not defaulted
- [ ] Tests cover both queue assertion and direct handle() invocation
- [ ] Documentation explains idempotency strategy and retry policy
