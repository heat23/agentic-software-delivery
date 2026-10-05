# SaaS-specific safeguards + async/transaction patterns

_Last reviewed: 2026-07-06 (design-language consistency pass)_

> **Persona for this reference:** senior SaaS backend engineer with
> production exposure to billing, multi-tenancy, queue
> infrastructure, and the asymmetric blast radius of small mistakes
> in those domains. Loaded on-demand by v-build whenever the plan
> touches billing, async, multi-tenant data access, external
> APIs, or any state machine that customers rely on.

These patterns exist because solo SaaS operators discover most of
them only after the first time they bite. A duplicate Stripe
charge, a multi-tenant query missing a `where('user_id', …)`, a
notification fired before a transaction committed and then
rolled back — each has a recovery cost measured in customer-trust
and refunds, not in engineering time. The hooks enforce the
mechanical guardrails (lazy-loading prevention, no-static-methods,
typed exceptions); this reference covers the judgment decisions
that hooks cannot enforce.

When v-build's plan touches any trigger below, this reference is
not optional reading.

---

## Trigger matrix — when this reference governs the work

| Trigger | Action required during build |
|---|---|
| Billing files modified (Cashier, Stripe, subscription, webhooks, plans) | Elevate agent review to **hostile adversarial focus**. Verify eager-loading on every billing/subscription method call. Verify Redis lock around cancel/resume (35s timeout). |
| New routes added or middleware changed | Confirm auth middleware on all new resource routes. Public routes never apply to protected resources. |
| User/tenant model queries in new controller code | Confirm multi-tenant scoping (`Auth::user()->projects()` or scoped route binding); unscoped `Model::find($id)` is a **data leakage vulnerability**, not a style issue. |
| External API call added to request lifecycle | **Block.** External API calls belong in Jobs only. Move the call to a queued job before the build proceeds. |
| Config value hardcoded in frontend | **Block.** TTLs, limits, prices, tier names, feature flags must flow from server-side props. Hardcoding makes pricing changes a code-change ritual. |
| BYOK / external AI API calls in plan | Estimate token / call count and cost. **Confirm with operator if estimated cost exceeds the operator's budget threshold** — BYOK doesn't mean cost-free; quotas, throttles, and billing surprises live there. |
| Multi-step mutation (create + update + notify) | Wrap in `DB::transaction()`. See Database Transactions below — the dispatch-after-commit rule is the most common pattern violation. |
| Webhook handler added | Verify signature validation, idempotency-key check, and out-of-order event handling (`last_webhook_at` tracking where stripe events arrive non-sequentially). |
| Background job added | `$tries` (NOT `$retries`), `$backoff` array, `$timeout`, `failed()` method writing actionable error context. |

Every row above is a build-time decision that, if missed, surfaces
weeks later as a support ticket, refund, or incident.

---

## Database transactions

Wrap multi-table mutations in `DB::transaction()` when **any** of
these is true:

- Creating a resource AND updating related resources (e.g., create
  subscription + update user + provision features)
- Any operation where partial completion leaves data inconsistent
- Bulk operations that should succeed or fail atomically

The pattern that ships cleanly:

```php
// Pattern: transaction with dispatch-after-commit
DB::transaction(function () use ($user, $plan) {
    $subscription = $user->subscriptions()->create([...]);
    $user->update(['plan_id' => $plan->id]);
    FeatureProvisioner::provision($subscription);
});
// Dispatch notifications AFTER the transaction commits — not inside.
$user->notify(new SubscriptionActivated($subscription));
```

**The cardinal rule:** never dispatch jobs or send notifications
inside a transaction. If the transaction rolls back, the job has
already been queued — it will fire on a subscription that no
longer exists, and the customer gets a notification for an event
that didn't happen. Use `afterCommit()` on queued jobs, or
dispatch outside the `DB::transaction(...)` block as shown above.

**Stripe API calls inside transactions:** Stripe is the canonical
counter-example. A Stripe API call inside a transaction can succeed
remotely while the transaction rolls back locally — leaving you
with a Stripe-side subscription that has no local record. Either
take the Stripe call **outside** the transaction (and accept the
asymmetric failure mode with explicit reconciliation), or wrap the
Stripe call in a Redis lock + idempotency key. The
project's billing rules document the lock + 35-second
timeout pattern.

---

## Async operation patterns

For every external API call, payment operation, or queued job,
implement these in combination — picking only one is the failure
mode:

| Pattern | When | Implementation |
|---|---|---|
| **Idempotency keys** | Payment processing, webhook handling | Store a unique key per operation; check before executing; return the cached result if the same key arrives twice. Stripe-style requests use `Idempotency-Key` headers — propagate them. |
| **Retry with backoff** | External API calls | `$tries = 3`, `$backoff = [10, 30, 60]` on jobs. **Never retry non-idempotent operations without an idempotency key** — retries on a non-idempotent endpoint produce duplicate side effects. |
| **Dead letter handling** | Failed jobs after max retries | `failed()` method logs context, notifies admin, writes to `failed_jobs` with an actionable error. "Job failed" is not actionable; "Stripe charge.create returned 402 for user_id=N, plan_id=M, idempotency_key=K" is. |
| **User-facing error recovery** | Payment failures, API timeouts | Show a specific error state with a retry action — not "Something went wrong." Users distinguish "your card was declined" from "our payment processor is having issues" and respond differently. |
| **Timeout protection** | External HTTP calls | Set explicit timeouts: `Http::timeout(10)->retry(3, 100)`. Never use default (infinite) timeouts — a hung external call ties up a worker indefinitely. |

The four-question litmus test before shipping any external API
integration:

1. If the third-party returns a 5xx, what happens to the user?
2. If the third-party times out, when does the worker free up?
3. If the same request arrives twice, what happens?
4. If the request fails permanently, who knows and what do they
   do about it?

If any answer is "I don't know" or "the user gets a 500," the
integration is not ready.

---

## UI state management checklist

Every data-fetching component or user-initiated mutation needs
**all six states implemented** — partial implementation is the
most common UI tech-debt source. Visual treatment of each state
(skeleton/empty-state/toast surfaces, tokens, z-index) follows
`_v-design.md` (§ Canonical Token Set, § Z-Index Layer Definitions —
toasts at layer 50; empty states are quality-critical surfaces):

| State | Requirement |
|---|---|
| **Loading** | Skeleton loader matching content shape — never a blank screen. Spinners are acceptable for sub-second mutations; longer waits need skeletons that imply layout. |
| **Error** | Specific error message with a retry action. Distinguish network errors (offline, retry later) from validation errors (fix input) from server errors (try again or report). |
| **Empty** | Meaningful empty state with a call-to-action — not "No data." Guide the user toward populating the view: "No projects yet — create your first one." |
| **Optimistic update** | For toggle, delete, reorder mutations: update the UI immediately, revert on failure, show a toast explaining what happened. |
| **Submission state** | Disable submit during request. Show a loading indicator. Prevent double-submission — the second click is the most common cause of duplicate writes. |
| **Stale data** | After a mutation, invalidate and refetch affected queries. Don't display stale cached data after a write. |

The "submission state" row is what ties async safety to UI
correctness — without disabled submit + double-click prevention,
the idempotency-key pattern earns its keep on every form.

---

## Form validation patterns

1. **Shared schemas where the stack supports it.** Define
   validation rules once (Zod schema, FormRequest mirror) and
   use on both client and server. At minimum, **server-side
   validation is mandatory** — client-side is a UX enhancement,
   not a security control.
2. **Field-level errors.** Display validation errors next to the
   specific field, not just a summary at the top. Top-of-form
   summaries are appropriate for cross-field constraints
   ("password and confirmation don't match"), not per-field
   errors.
3. **Async validation.** For uniqueness checks (email, slug,
   coupon code), debounce client-side calls at 300ms. Faster
   produces noise; slower feels broken.
4. **Error persistence.** Keep error messages visible until the
   user modifies the offending field. Don't clear all errors on
   any keystroke — the user loses context.

---

## Type safety requirements (TypeScript projects)

- **API response types.** Every API response has a TypeScript
  interface. Use `zod` (or similar) for runtime validation at
  the network boundary — types alone don't prevent malformed
  upstream responses from crashing the UI.
- **Form data types.** Type form state and submission payloads.
  No `any`, no unconstrained `Record<string, unknown>` on user
  input. The compiler catches the missing field; the alternative
  catches it in production.
- **Discriminated unions for state machines.** Subscription states
  (`trial | active | past_due | cancelled | expired`), order
  states, fulfilment states — these are union types, not string
  enums or magic strings. Discriminated unions force exhaustive
  switch cases; the compiler catches the missing branch when a
  new state is added.
- **Shared types.** API contracts and form schemas used on both
  client and server live in a shared location, not duplicated.
  Drift between two definitions of the same shape is a
  consistent source of "works on my machine" production bugs.

---

## Observability basics

For every new feature, include:

- **Structured logging.** Log key operations with context
  (`user_id`, `tenant_id`, `action`, `resource_id`) — not
  free-text messages. Free text doesn't aggregate; structured
  fields do.
- **Error context.** When catching exceptions, include the
  operation context (what was being attempted, with what inputs)
  in the error report. "PaymentFailed" without inputs is a
  ticket; "PaymentFailed for user_id=N, amount=X, gateway=Y" is
  a diagnosis.
- **Key metrics.** For user-facing features instrument **latency**
  (operation duration), **error rate** (% failures), and **usage**
  (how often the feature is invoked). The triplet is the
  minimum that lets a solo operator answer "is this thing
  working?" three months from now.

These are not "nice to have." They are the only mechanism by
which a solo operator notices that a feature has degraded
without a customer reporting it.

---

## Cross-references

- Eager-loading enforcement (project CLAUDE.md "Critical Gotchas"
  table) — required reading before billing-touching changes
- Project-level rate-limiting / billing / security rules
  (`.claude/rules/` per project) — load when the trigger matrix
  fires for those domains
- v-build's TDD Approach section — TDD discipline still applies
  inside this reference; transactions and async patterns are
  test-firstable

---

## What this reference is not

This is **not** a comprehensive SaaS engineering manual. It is the
set of patterns that v-build's hooks cannot mechanically enforce
but that the AI implementer must judgment-call during the build.
For broader SaaS engineering content (architectural patterns,
domain modeling, scaling), the operator's broader skill family
covers it elsewhere. This reference exists to keep the build
session honest at the moments where mistakes are silent and
expensive.
