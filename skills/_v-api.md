# V API

Shared governance for API design consistency. Centralizes rules currently touched by v-plan (API design step) and v-build (type safety).

_Last reviewed: 2026-08-02 (SME content pass — added Webhooks + Idempotency sections, rewrote Authentication around Sanctum, replaced the rate-limiting algorithm survey with `RateLimiter::for()`, switched API docs to generate-from-source-of-truth, fixed a placeholder collision with `_v-security.md`)_

## Endpoint Naming Convention

Follow RESTful principles with these naming rules:

- **Use plural nouns for resources:** `/api/accounts`, `/api/products`, `/api/invoices` (not `/api/account`, `/api/product`)
- **Use kebab-case for multi-word resources:** `/api/payment-methods`, `/api/audit-logs`, `/api/api-keys` (not `/api/paymentMethods`, `/api/AuditLogs`)
- **Standard resource routes:**
  - `GET /api/accounts` — list all accounts
  - `POST /api/accounts` — create new account
  - `GET /api/accounts/{id}` — get single account
  - `PUT /api/accounts/{id}` — replace account
  - `PATCH /api/accounts/{id}` — partial update
  - `DELETE /api/accounts/{id}` — delete account
- **Sub-resources for relationships:** `/api/accounts/{id}/invoices`, `/api/invoices/{id}/line-items` (not `/api/accounts/{id}/getInvoices`)
- **Actions that don't fit CRUD:** Use descriptive verbs as last segment: `/api/invoices/{id}/send`, `/api/reports/{id}/export`, `/api/auth/refresh-token`

## Response Envelope Format

Ensure consistent response structure across all endpoints:

**Collection response (with pagination):**
```json
{
  "data": [
    { "id": 1, "name": "Alice", "email": "alice@example.com" },
    { "id": 2, "name": "Bob", "email": "bob@example.com" }
  ],
  "meta": {
    "total": 500,
    "per_page": 2,
    "current_page": 1,
    "last_page": 250
  }
}
```

**Cursor-based pagination (for large datasets):**
```json
{
  "data": [...],
  "meta": {
    "cursor": "eyJpZCI6IDIzfQ==",
    "next_cursor": "eyJpZCI6IDI1fQ==",
    "per_page": 25,
    "has_more": true
  }
}
```

**Single resource response (raw object, no envelope):**
```json
{
  "id": 1,
  "name": "Alice",
  "email": "alice@example.com",
  "created_at": "2026-03-29T10:00:00Z"
}
```

**Success response with optional metadata:**
```json
{
  "data": { "id": 1, "status": "published" },
  "meta": { "version": 2, "published_at": "2026-03-29T10:00:00Z" }
}
```

## Error Response Format

Standardize error responses for consistency and client-side handling:

**Basic error:**
```json
{
  "message": "Validation failed",
  "code": "validation_error",
  "errors": {
    "email": ["Email field is required", "Email must be a valid email address"],
    "name": ["Name must be at least 3 characters"]
  }
}
```

**Not found error:**
```json
{
  "message": "Resource not found",
  "code": "not_found"
}
```

**Unauthorized error:**
```json
{
  "message": "Unauthenticated",
  "code": "unauthenticated"
}
```

**Permission error:**
```json
{
  "message": "Insufficient permissions",
  "code": "forbidden"
}
```

**Rate limit error:**
```json
{
  "message": "Too many requests",
  "code": "rate_limit",
  "retry_after": 60
}
```

## Pagination Strategy

Choose pagination method based on use case:

**Cursor-based (default for large/real-time datasets):**
- Use for datasets > 10k records, real-time feeds, or when new items are frequently added
- Example: `/api/transactions?cursor=abc123&per_page=50`
- Response includes `next_cursor` for client to fetch next page
- Advantages: stable pagination (no duplicates if items added), handles deletions, efficient on backend

**Offset-based (for admin/filtered views):**
- Use for smaller datasets, admin panels, filtered exports
- Example: `/api/users?page=2&per_page=25`
- Response includes `total`, `per_page`, `current_page`, `last_page`
- Advantages: jump to specific page, simple to understand

**Always include pagination metadata:**
- Cursor-based: `meta: { cursor, next_cursor, per_page, has_more }`
- Offset-based: `meta: { total, per_page, current_page, last_page }`

## Versioning Strategy

Use URL-based versioning as the default:

- **Versioning path:** `/api/v1/users`, `/api/v2/invoices` (version in URL, not header)
- **New version when:** breaking change to contract (removing field, changing type, new required parameter)
- **Extend within version:** adding optional fields, new endpoints, new query params are backwards-compatible
- **Deprecation:** Support both `/api/v1/` and `/api/v2/` during transition period (at least 3 months)
- **Response headers (optional):** Include `X-API-Version: 1.0.0` for additional visibility into API release

Example migration:
```
2026-01-01: Release /api/v1/users, deprecate /api/v0/users
2026-04-01: Sunset /api/v0/users, release /api/v2/users alongside /api/v1/
2026-07-01: Support both /api/v1/ and /api/v2/
```

## Rate Limiting

Document per-route rate limits and enforce consistently:

**Headers in response:**
```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 45
X-RateLimit-Reset: 1711787400
```

**When limit exceeded (429 response):**
```json
{
  "message": "Too many requests",
  "code": "rate_limit",
  "retry_after": 60
}
```

**Example limits:**
- Public endpoints: 60 requests/minute
- Authenticated endpoints: 300 requests/minute
- Payment endpoints: 10 requests/minute (stricter)
- Bulk import endpoints: 5 concurrent operations

**Laravel mechanism — a named limiter per trust tier, not a hand-rolled algorithm:**

```php
// AppServiceProvider::boot() (Laravel 11+ skeletons have no RouteServiceProvider;
// use one if the project still has it)
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Support\Facades\RateLimiter;

RateLimiter::for('api', function (Request $request) {
    return Limit::perMinute(300)->by($request->user()?->id ?: $request->ip());
});

RateLimiter::for('payments', function (Request $request) {
    return Limit::perMinute(10)->by($request->user()?->id ?: $request->ip());
});
```

```php
// routes/api.php
Route::middleware('throttle:api')->group(function () {
    Route::apiResource('invoices', InvoiceController::class);
});

Route::middleware('throttle:payments')->post('/charges', [ChargeController::class, 'store']);
```

- **Key on the authenticated user, fall back to IP.** Keying only on IP lets one authenticated abuser burn the shared budget of every other user behind the same NAT/proxy/office network; keying only on user ID leaves unauthenticated endpoints (login, register, password-reset — see `_v-security.md § Authentication Baseline`) with no limiter at all. `$request->user()?->id ?: $request->ip()` covers both.
- The `429` status and the `X-RateLimit-Limit` / `X-RateLimit-Remaining` / `X-RateLimit-Reset` / `Retry-After` headers shown above are set automatically by the `throttle:` middleware — no manual header code needed.
- One named limiter per trust tier (public, authenticated, payment-critical, bulk-import) with its own number — not one limiter reused everywhere with a different int passed in ad hoc.

## Authentication & Authorization

**Sanctum is the default API auth for this stack** — `php artisan install:api` scaffolds it, and it covers both halves of an Inertia SaaS: the SPA's own cookie session, and tokens for anything that isn't the SPA. One guard covers both: protect routes with `->middleware('auth:sanctum')` and Sanctum resolves cookie-vs-token per request.

**SPA cookie flow** — for the Inertia frontend calling its own backend. No tokens: the SPA hits `/sanctum/csrf-cookie`, logs in through the `web` guard, and every request after that rides the ordinary session cookie. Requires a shared top-level domain (SPA and API may differ by subdomain, not by registrable domain) and `$middleware->statefulApi()` in `bootstrap/app.php`.
```
Cookie: laravel_session=eyJ...
```

**Token flow** — for mobile apps and third-party/programmatic clients. `$user->createToken('name', ['orders:read'])->plainTextToken` issues a personal access token; the client sends it as a bearer token on every request. Real Sanctum tokens have the shape `{id}|{random-string}` — don't reuse a payment provider's key format for this:
```
Authorization: Bearer 3|generic-placeholder-not-a-real-secret-1a2b3c4d5e6f
```

**Decision rule:** first-party SPA calling its own backend → cookie flow, always. Anything that is not your own frontend (native mobile app, partner integration, CLI, another service) → token flow. **Never issue a token to authenticate your own SPA** — cookie mode exists for exactly that case, and a token sitting in browser JS is a stealable long-lived credential a same-origin cookie isn't.

Layer `can:` middleware or a Policy on top for per-resource authorization — `tokenCan()` only checks the token's declared abilities, it does **not** replace a Policy check.

**Distinction:**
- 401 Unauthenticated: no valid session or token; the client must re-authenticate.
- 403 Forbidden: authenticated, but the Policy/ability check failed.

## Webhooks

Inbound requests from a third party (Stripe, GitHub). Every one is hostile until its signature verifies.

**Verify-then-act, NEVER act-then-verify.** Signature verification is the first thing that happens, on the raw body, before any DB write, queue dispatch, or side effect. A handler that processes first and verifies later is not a webhook handler — it is an unauthenticated write endpoint.

- Verify against the **raw** body (`$request->getContent()`), never `$request->all()`. Re-encoding changes bytes (key order, whitespace, numeric formatting) and invalidates a genuinely valid signature.
- **Hand-rolled HMAC (non-Stripe providers — GitHub, custom vendors without an SDK):** compute the expected signature server-side and compare with `hash_equals($expected, $provided)` — never `==`, `===`, or `strcmp()`. A non-constant-time comparison leaks the correct signature one byte at a time through response-timing.
- The route is CSRF-exempt — this is the one sanctioned `$except` entry (`_v-security.md § CSRF Protection`), sanctioned *because* signature verification replaces CSRF, not instead of it.

```php
try {
    $event = \Stripe\Webhook::constructEvent(
        $request->getContent(),                    // raw body
        $request->header('Stripe-Signature'),
        config('services.stripe.webhook_secret'),
    );
} catch (\Stripe\Exception\SignatureVerificationException|\UnexpectedValueException $e) {
    report($e);
    return response()->json(['error' => 'Invalid signature'], 400);
}
// ONLY past this point is the payload trusted.
ProcessStripeWebhook::dispatch($event->toArray());
return response()->json(['received' => true], 200);
```

If Cashier already receives the event, use its bundled `WebhookController` + `VerifyWebhookSignature` middleware instead of hand-rolling verification alongside it — this is verified, not a preference (`references/framework-pitfalls.md § Verified framework semantics`).

- **Replay window:** Stripe's SDK enforces a 5-minute timestamp tolerance — don't widen it. For hand-rolled HMAC schemes, enforce an equivalent window and reject anything outside it *even with a valid signature*.
- **At-least-once delivery is the norm** — the same event WILL arrive twice, sometimes days apart. Record the provider's event ID in a table with a unique constraint (`$table->unique(['provider', 'event_id'])`) and insert-and-catch exactly like § Idempotency — skip processing and return `200` immediately when the insert hits the unique violation. A `SELECT`-then-insert has the same race § Idempotency warns against.
- **Redelivery is not optional to survive.** A provider retries a failing endpoint (any non-2xx response) for an extended window before giving up — Stripe's own docs describe retrying for up to 3 days *(vendor behavior — re-verify at the provider's current webhook docs before relying on the exact figure; do not hardcode a retry count into handler logic)*. A handler that isn't safe to run twice, or that's slow enough to time out, WILL eventually process the same event as a duplicate charge or a duplicate row.
- **Queue the work, return 2xx fast.** The route should do only: verify → dedupe → dispatch job → 200. Slow inline processing triggers provider retries and duplicate deliveries.
- **Dead-letter path is Laravel's own failed-jobs table — don't build a custom one.** Once the dispatched job (`ProcessStripeWebhook` above) exhausts its `$tries`, Laravel writes it to `failed_jobs` automatically. Inspect with `php artisan queue:failed`, replay with `php artisan queue:retry {id|all}`. Alert when a webhook-processing job lands there — it means the provider believes the event was delivered but your side never finished handling it.

## Idempotency

Any POST with side effects (charges, provisioning, email, resource creation) must be safe to retry — clients, retry logic, and flaky networks will send it twice.

- **When a client MUST send one:** any POST/PATCH that is not naturally idempotent AND has a side effect that costs money, provisions a resource, or is hard to undo (charge, subscription change, account/resource creation, sending an email/SMS). A `PUT` that fully replaces a known resource by ID doesn't need one — it's already idempotent by HTTP semantics. If the client genuinely can't send one (a plain browser form POST with no JS), the endpoint needs a different dedup key entirely (e.g. a natural uniqueness constraint on the resource) — don't silently skip protection.
- Client sends a UUID per logical operation as `Idempotency-Key`.
- Key seen + completed → return the ORIGINAL response verbatim, don't redo the effect.
- Key seen + in progress → `409 Conflict`.
- Key unseen → run, store key + response, return.

**The uniqueness guard lives in the DATABASE, not application code:**

```php
$table->unique(['user_id', 'key']);   // a race between two identical retries must be caught here
```

Insert-and-catch, never `SELECT`-then-insert — a prior read cannot close the race:

```php
try {
    $record = IdempotencyKey::create(['user_id' => $request->user()->id, 'key' => $key]);
} catch (\Illuminate\Database\QueryException $e) {
    return response()->json(['error' => 'Request already in progress'], 409);  // concurrent retry
}
```

- **Interaction with DB transactions:** the *claim* insert above must be committed (or at least visible) before the side-effecting work starts, so a concurrent retry actually hits the unique-constraint race instead of running past it. Then update that same row to `completed` + store the response as the LAST statement inside the transaction that performs the side effect itself — so either both the effect and the completion marker commit, or neither does. Never mark `completed` before that transaction commits: a crash in between leaves a stored response for an effect that never happened, and a duplicate retry replays a lie.
- Keys apply to the **operation**, not the endpoint — reusing a key with a genuinely different payload is a client bug; return `422` rather than silently running the new payload.
- Prune records on a schedule (24-48h retention).
- Distinct from webhook dedup above: idempotency keys are **client**-supplied for outbound-initiated writes; webhook event IDs are **provider**-supplied for inbound events. Same problem, opposite directions.

> Laravel has no built-in `Idempotency-Key` support — the shape above is the standard insert-and-catch-unique-violation pattern, not a framework primitive. Review it in context rather than pasting blind; the DB-constraint approach is sound, the middleware wiring is illustrative.

## Input Validation

Every write endpoint (POST, PUT, PATCH) must use a form request class:

```php
Route::post('/api/users', [UserController::class, 'store'])
    ->middleware(ValidateJsonRequest::class); // or use form request

class StoreUserRequest extends FormRequest {
    public function rules(): array {
        return [
            'name' => 'required|string|min:3|max:255',
            'email' => 'required|email|unique:users,email',
            'password' => 'required|min:8|confirmed',
        ];
    }

    public function messages(): array {
        return [
            'name.required' => 'Full name is required',
            'email.unique' => 'Email already registered',
        ];
    }
}
```

Anti-pattern:
```php
// WRONG: no form request, raw $request->input()
$user = User::create([
    'name' => $request->input('name'),
    'email' => $request->input('email'),
]);
```

## Documentation

Public APIs must be documented via OpenAPI. **Default: generate the spec from the code's existing source of truth — route definitions, FormRequest rules, and Resource/response classes — not hand-maintained YAML or annotation blocks.** Annotations that must be kept in sync by hand WILL drift from the endpoints they describe. With no human reviewer to catch stale docs before they ship, that drift is invisible until a client breaks against a contract the spec never had — the exact failure class this file exists to prevent.

- **Selection criteria for a generator** (apply this if the named tool below is gone or superseded — don't re-default to hand-written YAML just because one tool aged out): reads route signatures, validation rules, and response/Resource classes directly, with zero required hand-written annotations for the common case; runs as an `artisan` command, not a manual export step; actively maintained (commits/releases within the last 12 months at time of check).
- **Current example — `dedoc/scramble`** *(package recommendation, re-verify still current before relying on it; re-check no later than 2027)*: generates OpenAPI 3.1 from FormRequest rules, route model bindings, and API Resources with no annotations for the common case. Ships `/docs/api` (interactive UI) by default; `php artisan scramble:export` writes a static `api.json`.
- **Fallback — hand-authored OpenAPI:** only for what a generator can't express (webhook payload docs, deprecated-but-still-live endpoints, unusual response shapes). Review hand-authored YAML against the actual route/FormRequest on every PR that touches the endpoint — treat drift here as a bug, not doc-lag.

---

## Checklist for API Endpoint Design

When creating or reviewing an API endpoint:

- [ ] Endpoint uses RESTful naming (plural nouns, kebab-case, standard HTTP methods)
- [ ] Response envelope consistent (collection: data + meta, single: raw object)
- [ ] Error responses follow standard format (message, code, errors)
- [ ] Pagination strategy chosen (cursor vs offset) with proper metadata
- [ ] API versioning in URL path (e.g., `/api/v1/`)
- [ ] `RateLimiter::for()` named limiter applied via `throttle:`, keyed on user falling back to IP
- [ ] Authentication documented (Sanctum: cookie flow for the SPA, token flow for everything else)
- [ ] Input validation uses FormRequest (no raw `$request->input()`)
- [ ] OpenAPI documentation generated from source of truth (default) or hand-authored with a stated reason (fallback)
- [ ] 401 vs 403 distinction applied correctly
- [ ] Inbound webhooks: signature verified on the raw body, replay window enforced, event ID deduped, route CSRF-exempt only for that reason
- [ ] Side-effecting POSTs: `Idempotency-Key` handling documented, or the endpoint is stated to be naturally idempotent
