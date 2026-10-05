# Async Bug Scope Explosion (Step 1.5) — extracted from /v SKILL.md

> **Loaded by:** /v Step 1.5, after classification = bug-fix AND async signals detected in task content OR diff. Inline /v SKILL.md has a one-line stub.
>
> **Why this exists:** bug-fix workflow normally writes a failing test for the *reported* symptom only. For async/queue/distributed bugs, the reported symptom is almost always one face of a systemic bug — retry logic, idempotency, ordering, race, dead-letter, observer fan-out, timeout, partial-failure. Fixing only the reported face leaves the others live; the bug "comes back" in a different shape in a later session. This step forces broader scope BEFORE TDD writes the test.
>
> **Output:** `ASYNC_LIFECYCLE_TRACE_<sid>.md` at project root. Feeds into /v-tdd as expanded test scope.

## Trigger signals (tiered — 2026-07-01: promoted from the newer SKILL.md inline version; this section is THE authority)

Fires when classification = bug-fix AND **at least one Tier-1 signal** appears in the resolved task content OR the diff. Tier-2 signals require pairing (TWO Tier-2, or ONE Tier-2 + ONE Tier-1) — a single Tier-2 hit alone false-fires on 40-60% of files.

**Tier 1 — high-specificity (single signal fires the step):**
- **File-path:** `app/Jobs/`, `app/Listeners/`, `app/Observers/`, `app/Events/`, `app/Mail/`, `app/Notifications/`, `app/Broadcasting/`
- **Laravel code:** `implements ShouldQueue`, `dispatch(` (with a Job class arg, not `dispatchSync`), `Bus::dispatch`, `Queue::push`, `->onQueue(`, `Horizon::`, `Schedule::` (Laravel scheduler)
- **Cross-stack code:** `Sidekiq`, `perform_async`, `perform_later`, `ActiveJob`, `celery`, `@task`, `@shared_task`, `.apply_async`, `bullmq`, `bull`, `agenda`, `bee-queue`, `kue`, `KafkaConsumer`, `@KafkaListener`, `amqplib`, `basic_publish` (RabbitMQ), `SNS::publish`, `SQS::sendMessage`, `aws-sdk.*Lambda.*InvocationType.*Event`, Temporal/Inngest workflow decorators
- **Streaming/realtime:** `Broadcast::channel`, `ws.on('message'`, `EventSource`, `text/event-stream`, gRPC `stream` keyword
- **Task-language (single signal):** "intermittent", "sometimes fails", "occasionally fails", "race condition", "race-condition", "flaky" — domain-specific enough to fire alone

**Tier 2 — pair-required (need TWO Tier-2 signals OR ONE Tier-2 + ONE Tier-1):**
- `Cache::lock`, `Cache::remember`, `DB::transaction`, `transaction {`, `event(`, `Event::dispatch`, `Mail::queue`, `Notification::send`, `retry(`, `webhook`, `EventEmitter`, `pubsub`, `redis.publish`, `Redis::`, `ioredis`, `.delay(`
- Task-language alone: "queue", "job", "worker", "background", "async" (each requires a paired signal)

**Negative filters (do NOT fire even if signals match):**
- Diff is purely CSS / markup / pure-frontend AND no Tier-1 file-path signal
- Handler's configured queue connection is `sync` (Laravel `QUEUE_CONNECTION=sync`, equivalent in other stacks) AND no `event()`/`Listener` calls — sync execution doesn't have async failure modes
- `Bus::dispatchSync` is the only dispatch call AND no other Tier-1 signals — synchronous dispatch is just a function call

## Lifecycle trace protocol

For the affected handler (Job class, Listener class, Worker function, etc.), produce a structured trace. Use Read + Grep tools; do NOT estimate — every entry must cite `file:line`.

### 1. Dispatch sites

Where is this handler dispatched / pushed / triggered? Grep the codebase for the dispatch pattern:

- Laravel: `grep -rn "\\b<JobClass>\\b\\|dispatch.*<JobClass>" app/ routes/ database/`
- Sidekiq: `grep -rn "<WorkerClass>\\.perform" app/`
- Celery: `grep -rn "<task_name>\\.delay\\|<task_name>\\.apply_async" .`

Output rows: `{ file, line, calling_context_summary }`.

### 2. Side effects of the handler

What does this handler do externally? Read the handler file. Catalog:

- Database writes (which tables, which columns)
- External API calls (which service, idempotent? retryable?)
- Event emissions (which events, which listeners react)
- Other job dispatches (chained jobs — recurse one level)
- Cache writes / reads (which keys, TTL)
- File writes (S3, local FS, logs)

### 3. Observers / listeners / event reactors

For each event the handler emits, what reacts? Use the framework's registry:

- Laravel: read `app/Providers/EventServiceProvider.php` or `app/Providers/AppServiceProvider.php` for `Event::listen` calls; grep `Listeners/` for the event class
- Rails: read `config/initializers/*` for subscribers; `ActiveSupport::Notifications.subscribe`
- Node EventEmitter: grep `\\.on(['"]<eventName>`

Each reactor is an additional code path to consider. List them.

### 4. Idempotency mechanism (or absence)

Is the handler safe to run twice for the same input? Check:
- Unique-job locks (Laravel `WithoutOverlapping`, Sidekiq unique-job plugin)
- Idempotency keys in DB (uniqueness constraints, `INSERT ... ON CONFLICT DO NOTHING`, `firstOrCreate`)
- Cache-based deduplication
- External API idempotency keys (Stripe `Idempotency-Key` header, etc.)

If NONE of the above → idempotency is a documented gap.

### 5. Retry / backoff configuration

- Laravel: `$tries`, `$backoff`, `$timeout`, `retryUntil()` methods on the job
- Sidekiq: `sidekiq_options retry: N`
- Celery: `autoretry_for`, `max_retries`, `retry_backoff`
- BullMQ: queue options `attempts`, `backoff`

If unset → default is framework-dependent (Laravel: 1 try; Sidekiq: 25; Celery: 3). Note the default explicitly.

### 6. Dead-letter / failure-state handling

Where do permanent failures go? Are they noticed?
- Laravel: `failed_jobs` table, `failed()` method on job, Horizon dashboard
- Sidekiq: Sidekiq dead set, web UI
- Celery: `task_failed` handler

If NO mechanism → permanent failures are silently dropped.

### 7. Timeout / hard-kill behavior

What happens at the framework's max execution time?
- Long-running DB transaction holding locks → other handlers stall
- Partial writes already committed → state half-done
- External API request in flight → response lost, retry will duplicate

## Failure-mode checklist (the 11 modes)

For each mode below, EVALUATE: `covered` (test exists OR mechanism prevents) / `gap` (mode is live, no test, no mechanism) / `n/a` (mode doesn't apply to this handler).

Modes are also classified by `test_layer`: `unit` (writable as Pest/Vitest/etc.), `integration` (requires real queue + worker + timing — out of /v-tdd scope; produces an integration-test stub or chaos-test note instead), or `observability` (not test-able as a single assertion — documented as a monitoring requirement).

| # | Mode | Question | Default `test_layer` |
|---|---|---|---|
| 1 | Idempotency | What happens if this runs twice with the same input? | `unit` |
| 2 | Retry | What's the retry policy? Does the reported failure trigger retry or fail-fast? | `unit` |
| 3 | Ordering | Does this assume jobs/events arrive in a specific order? What if they don't? | `unit` |
| 4 | Race conditions | Concurrent execution on the same record/key/lock? | `integration` |
| 5 | Dead-letter | Where do permanent failures go? Are they alerted on? | `unit` (handler exists?) + `observability` (alerts firing?) |
| 6 | Timeout | What's the max execution time? What's left half-done on hard-kill? | `unit` (handler) + `integration` (real timeout) |
| 7 | Partial failure | If step N succeeds but N+1 fails, is the state recoverable / cleaned up? | `unit` |
| 8 | Observer fan-out | Does this trigger downstream jobs/events that also need testing? | `unit` |
| 9 | Poison message | Single malformed payload — does it permanently block the queue head, or get routed to DLQ? (Distinct from dead-letter: DLQ requires retry-exhaustion; poison can block immediately.) | `unit` (handler error path) + `integration` (real broker) |
| 10 | Split-brain | Two workers/processes claim ownership of the same resource simultaneously. (Distinct from race: race is concurrent-write, split-brain is concurrent-ownership.) | `integration` |
| 11 | Head-of-line blocking | Slow handler on one partition/queue stalls everything behind it. | `integration` |

**Dropped from prior checklist (now `observability` only — documented in trace but NOT in `failure_modes_to_test`):**
- Backpressure (queue slow / dispatcher block / drop / pile-up) — pure observability concern, no meaningful unit test
- State drift (DB / cache / queue divergence) — reconciliation is an ops topic, not unit-testable

When evaluating, label every mode with `gap` / `covered` / `n/a` AND `test_layer`. Only modes with `gap` + `test_layer: unit` go into `failure_modes_to_test` and feed /v-tdd. Modes with `gap` + `test_layer: integration` go into a separate `integration_tests_needed` list — the orchestrator surfaces these to the user as "these need a real-broker test environment; out of scope for this session" but DOES write them into the report so they aren't forgotten.

## Output artifact (`ASYNC_LIFECYCLE_TRACE_<sid>.md`)

```yaml
async_lifecycle_trace:
  session_id: "<sid>"
  reported_symptom: "<from user task — quote literally>"
  affected_handler:
    class: "<FullyQualified\\ClassName or function path>"
    file: "<path:line>"
  dispatch_sites:
    - { file: "<path:line>", context: "<2-line summary>" }
  side_effects:
    db_writes: ["<table.column or model>"]
    external_apis: ["<service: idempotent?>"]
    event_emissions: ["<EventClass>"]
    chained_dispatches: ["<JobClass>"]
    cache_writes: ["<key>"]
  observers:
    - { class: "<ListenerClass>", event: "<EventClass>" }
  idempotency:
    mechanism: "<unique-job-lock|db-constraint|cache-dedup|external-idempotency-key|NONE>"
    status: "<covered|gap>"
  retry_policy:
    tries: <int or default>
    backoff: "<value or default>"
    on_reported_failure: "<retries|fails-fast|unknown>"
  dead_letter:
    mechanism: "<failed_jobs|sidekiq_dead|task_failed|NONE>"
    alerted: "<yes|no>"
  failure_modes:
    idempotency: "<covered|gap|n/a> — <one-line justification>"
    retry: "<covered|gap|n/a> — <...>"
    ordering: "<...>"
    race: "<...>"
    dead_letter: "<...>"
    timeout: "<...>"
    partial_failure: "<...>"
    observer_fanout: "<...>"
    backpressure: "<...>"
    state_drift: "<...>"
  failure_modes_to_test:
    # ONLY modes with gap + test_layer: unit. These feed into /v-tdd as RED-phase
    # test scope. Each entry is structured so v-tdd has scaffolding, not vague prose.
    - mode: "<idempotency|retry|ordering|dead-letter|partial-failure|observer-fanout|poison-message>"
      scenario: "<one-line plain-English failure being tested>"
      arrange: "<what state/inputs to set up — e.g., 'job dispatched twice with same payload'>"
      act: "<what to invoke — e.g., 'run JobClass::handle() twice'>"
      assert: "<what must hold — e.g., 'DB row count for affected table = 1, not 2'>"
  integration_tests_needed:
    # gap + test_layer: integration. NOT written by /v-tdd. Surfaced to operator.
    - mode: "<race|timeout|split-brain|head-of-line-blocking|poison-message>"
      scenario: "<...>"
      requires: "<what infrastructure — real Redis, two worker processes, controlled timing>"
  observability_gaps:
    # backpressure, state-drift, alerting gaps. Documented; not tested in this session.
    - "<gap description>"
```

## Anti-patterns

**1. Fixing only the reported symptom.** The user reported "job sometimes fails on retry." Don't write a single test for "retry-with-bad-input." Trace the lifecycle, find that idempotency is also a gap, find that the dead-letter handler doesn't alert — write tests for ALL three.

**2. Treating the explosion as documentation-only.** The output MUST feed into /v-tdd. The `failure_modes_to_test` list becomes the RED-phase test cases. If you produce the artifact then write only the reported-symptom test, the explosion was wasted.

**3. Skipping the explosion because "it's just a one-line fix."** The reported symptom may be one-line, but the bug it reveals usually isn't. Spend the 2-5 min on the trace.

**4. Estimating without grep.** Every dispatch site, observer, and side effect must cite `file:line`. "I think this is dispatched from somewhere in the controller" is unacceptable.

**5. Padding the failure_modes_to_test list.** Only include modes that are genuinely live gaps. `n/a` modes don't generate tests. False positives waste the next session.

## Hand-off to /v-tdd

The orchestrator passes the `failure_modes_to_test` list to /v-tdd as the RED-phase test scope. Each entry is a structured object with `mode / scenario / arrange / act / assert` — v-tdd has enough scaffolding to write a real test, not a vague placeholder.

The fix must make ALL `failure_modes_to_test` entries pass, not just the reported symptom.

**Modes NOT in `failure_modes_to_test`:**
- `integration_tests_needed` — surfaced to the operator as "out of scope for this session" but recorded in the artifact so they aren't forgotten. Operator decides whether to spin up a chaos-test env later.
- `observability_gaps` — documented; tracked as future monitoring work, not a code change.

If `failure_modes_to_test` is empty (rare — usually means the bug is purely local synchronous logic that triggered a false async signal via Tier-2 pairs), proceed with normal /v-tdd flow on the reported symptom only.

## Known limitation (v1)

There is currently NO deterministic Stop-hook check enforcing that `ASYNC_LIFECYCLE_TRACE_<sid>.md` exists when classification = bug-fix AND Tier-1 async signals match. Enforcement is by mandatory-language directive in the /v Step 1.5 stub only. A model that rationalizes "the bug is obviously simple" can skip the trace.

If this becomes a problem in real use, add `~/.claude/hooks/enforce-async-trace.sh` as a Stop hook that:
1. Reads `.v/tmp/v-classification-${sid}.txt` (which would require /v Step 1 to write it)
2. Checks if classification = bug-fix
3. Checks `git diff --name-only` for Tier-1 file-path matches OR `git diff` content for Tier-1 code patterns
4. If both AND `ASYNC_LIFECYCLE_TRACE_${sid}.md` is missing → deny completion with the explanation message.
