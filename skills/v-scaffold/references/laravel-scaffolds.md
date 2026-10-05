# Laravel + SaaS scaffold reference

_Last reviewed: 2026-07-05_

> **Persona for this reference:** senior Laravel architect with
> production experience standing up multi-tenant SaaS infrastructure
> end-to-end (teams, billing, RBAC, audit, admin tooling, versioned
> APIs). Loaded on-demand by v-scaffold whenever
> `DETECTED_STACK = laravel`. For other frameworks, the
> framework-detection Pattern Reference in SKILL.md governs.

This reference is the catalog of Laravel-specific scaffolds and
the SaaS composite scaffolds that the operator runs hundreds of
times across projects. Every entry below is a hard-won convention
— some are framework defaults, some are project-instilled patterns
from the operator's CLAUDE.md, and some are prevention rules for
production failures the family of skills has already seen.

When v-scaffold's framework detection resolves to Laravel, this
file is mandatory reading before any file is written. Cross-scaffold
wiring and dependency ordering live here, not in the orchestrator.

---

## Single-class Laravel scaffolds

These are the building blocks. Most v-scaffold invocations produce
one of these.

### Service

**Location:** `app/Services/{ServiceName}.php`

Conventions:
- `namespace App\Services;`
- Constructor injection for dependencies (no static methods)
- Throw typed exceptions from `app/Exceptions/`
- **External API calls ONLY in Jobs**, never in the service directly
- If the service is shared across many call sites, register as a
  singleton in `AppServiceProvider`

The static-method temptation is the most common Laravel
anti-pattern in solo-dev codebases. Static methods can't be
mocked cleanly, can't be replaced via service container, and
make tests slow because they bypass dependency injection. Resist
unless the method is genuinely a pure function (no I/O, no
collaborators).

### Service test

**Location:** `tests/Unit/Services/{ServiceName}Test.php` (or
`tests/Feature/` if the service hits the database).

Use Pest syntax. Include:
- Happy-path test
- Edge case test (empty input, boundary values)
- Error handling test (expects typed exception)

Rules:
- Use factories: `Model::factory()->create()`
- Set `config(['ai.openai.retry_sleep_ms' => [0, 0, 0]])` for
  AI tests — otherwise retries make tests slow and flaky
- **Never** `Model::create()` directly in tests; that path
  silently bypasses factory-defined defaults and FK setup

### Job (when external API is involved)

**Location:** `app/Jobs/{ActionName}Job.php`

```php
public int $tries = 3;  // Note: $tries, NOT $retries
```

The `$tries` vs. `$retries` typo causes silent infinite retries —
Laravel ignores the misspelled property and falls back to
unlimited retries. Catching this in scaffolding prevents weeks
of runaway-job invoice surprises.

Conventions:
- `implements ShouldQueue`
- Uses `Dispatchable, InteractsWithQueue, Queueable, SerializesModels`
- Call the corresponding service from `handle()` — the service
  remains the I/O-free unit of business logic; the job adds
  retry, queueing, and failure semantics on top
- Type-hint dependencies in `handle()` for container injection

### Job (full scaffold)

**Location:** `app/Jobs/{JobName}.php`

Conventions:
- `implements ShouldQueue`
- `$tries` (NOT `$retries`) set to 3
- `$backoff` array for progressive delays: `[10, 30, 60]`
- `$timeout` set appropriately (default 120 for API calls)
- Type-hint dependencies in `handle()` for injection
- Catch typed exceptions, log with context, re-throw for retry
- Pattern for testability: type-hint collaborators on `handle()`
  and let the container resolve them — a concrete class needs no
  binding (the container auto-resolves it via reflection). Do NOT
  gate resolution on `app()->has(Foo::class)` — `has()`/`bound()`
  return `false` for unbound concrete classes, so the ternary would
  almost always fall through to `new Foo(...)` and defeat injection.
  Only use `app()->bound(FooInterface::class)` when `Foo` is an
  interface you conditionally bind in a provider.

**Test location:** `tests/Feature/Jobs/{JobName}Test.php`

### Notification

**Location:** `app/Notifications/{NotificationName}.php`

Conventions:
- Extend `Notification`
- Define `via()` channels (mail, database, broadcast)
- `toMail()` returns `MailMessage`
- `toArray()` for database/broadcast
- `implements ShouldQueue` for non-urgent notifications — the
  request handler should not block on email delivery

**Test location:** `tests/Feature/Notifications/{NotificationName}Test.php`

### Form Request

**Location:** `app/Http/Requests/{RequestName}.php`

Conventions:
- `authorize()` returns an actual authorization check, not just
  `return true`. The authorize method is a security boundary —
  bare `true` is a known foot-gun.
- `rules()` uses array syntax (not pipe syntax) — the array form
  is easier to extend and conditionally compose
- Custom messages in `messages()` for user-facing errors
- Type-hint the request in the controller method signature for
  automatic validation

**Tests:** Form Request validation is exercised by the
controller's feature tests.

### Inertia Page (3-file scaffold)

Creates the page component, controller, and route for a new
Inertia page in one shot:

1. `resources/js/Pages/{Dir}/{Name}.tsx` — React page component
2. `app/Http/Controllers/{Resource}Controller.php` — controller
   method calling `Inertia::render()`
3. NAMED route in `routes/web.php` in the matching middleware group

This is the **thinnest-margin scaffold in the catalog** — the
.tsx, controller, route, test, `ziggy.js`, and `mockRoutes` map
must all agree or the page renders blank, throws a Ziggy `route()`
error, or fails the Inertia contract tests. **Sample one existing
page end-to-end (component → controller → route → its feature
test) before writing** — the sample is source of truth; the tables
below are the fallback when no sibling exists.

**Name derivation** (single source for all artifacts). The
argument is the page path `Dir/Name` (e.g. `Reports/Index`,
`Sites/Create`):

| Artifact | Derivation | `Reports/Index` | `Sites/Create` |
|---|---|---|---|
| Page component | `resources/js/Pages/{Dir}/{Name}.tsx` | `Pages/Reports/Index.tsx` | `Pages/Sites/Create.tsx` |
| Controller | `{Resource}Controller` — match the project's singular-vs-plural naming by sampling `app/Http/Controllers/` | `ReportsController` | `SiteController` |
| Method | `{Name}` → REST verb: Index→`index`, Create→`create`, Store→`store`, Edit→`edit`, Update→`update`, Show→`show` | `index` | `create` |
| Route name | dot-namespaced `{resource}.{action}`, matching existing names | `reports.index` | `sites.create` |
| Route URI | path + REST convention (sample existing) | `GET /reports` | `GET /sites/create` |

If the project uses invokable single-action controllers or a
different naming convention, MATCH THAT — the sampled page wins.

**Page kind → required states.** Derive the kind from the trailing
segment and scaffold the states that kind owes (the operator's
React/Inertia rule: every page handles loading, empty, and error):

| Trailing segment | Kind | Required in the .tsx |
|---|---|---|
| Index / List | list | empty state, error/partial-data fallback, pagination; bulk-select + CSV export affordance when the list can exceed ~10 rows |
| Create / Edit | form | Inertia `useForm`, per-field `<InputError>` bound to server-side `errors`, `LoadingButton` disabled while `processing`, dirty-guard where the project has one |
| Show / Detail | detail | not-found / empty state, partial-data fallback |
| (other) | generic | at minimum empty + error state |

**Page component (.tsx) required elements:**
- Local `interface Props { ... }` for the page's own props — NOT
  Inertia's `PageProps` generic on the component. Shared props (if
  needed) are read via `usePage<PageProps>().props`, where
  `PageProps` is the project's own `@/types` export, not
  `@inertiajs/react`'s.
- `@/` path-alias imports (`@/Layouts/...`, `@/Components/...`) —
  match the project's alias.
- `<Head title="...">` (from `@inertiajs/react`) on every page — it
  sets the browser-tab title.
- Wrap in the project's app layout. Sample which layout sibling
  pages use (`AppLayout`/`DashboardLayout`/`AuthenticatedLayout`)
  and apply it the SAME way — either the persistent
  `Page.layout = (page) => <Layout>{page}</Layout>` pattern OR JSX
  wrapping. A page with no layout renders bare (no sidebar, no
  theming): that is a defect, not a minimal scaffold.
- Canonical design tokens only (SKILL.md Step 5a / `_v-design.md`)
  — never `bg-white` or raw palette hex.

**Controller required elements:**
- `declare(strict_types=1);`, `namespace App\Http\Controllers;`,
  extends the base `Controller`.
- Named method (not `__invoke`) unless the project uses invokable
  single-action controllers — sample and match.
- Return type `\Inertia\Response`.
- `Gate::authorize(...)` when a matching Policy exists (in
  addition to any `can:` route middleware) — match how sibling
  controllers authorize. Emit `$this->authorize(...)` ONLY if the
  project's base `Controller` has re-added the `AuthorizesRequests`
  trait: Laravel 11+ dropped it, so scaffolding `$this->authorize()`
  into a default skeleton produces a `BadMethodCallException` at
  runtime. Check `app/Http/Controllers/Controller.php` before choosing.
  (`_v-security.md § Authorization Baseline` owns this rule.)
- Route-model binding for entity pages; expose the project's opaque
  identifier (e.g. `public_id`/uuid) in props when the project does
  so — never leak integer PKs if that is the convention.
- Props as an associative array to `Inertia::render('{Dir}/{Name}',
  [...])`. The render string MUST equal the component path exactly
  (the existence contract test asserts this).
- Mutations (Store/Update) take a Form Request — never inline
  `$request->validate()`.

**Route required elements:**
- Explicit, NAMED route (`->name('{resource}.{action}')`) — never
  `Route::resource` unless the project uses it. The name is
  mandatory: Ziggy `route()` and the `mockRoutes` map key off it.
- Placed in the middleware group that matches sibling routes —
  sample `routes/web.php`. Default for authenticated app pages is
  the project's auth group (commonly `['auth','verified']`, often
  plus a policy gate like `can:view,{model}` for entity-scoped
  pages). Guest pages use the project's guest group.

**Test (the scaffold's RED test):** a Pest feature test at
`tests/Feature/{Name}PageTest.php` (or the project's convention)
that hits the route and asserts the Inertia response:

```php
$this->actingAs($user)
    ->get(route('reports.index'))
    ->assertInertia(fn (AssertableInertia $page) => $page
        ->component('Reports/Index')
        ->has('...')            // each top-level prop the controller passes
    );
```

This is the test the Lightweight Verification step runs to confirm
RED. Assert nested/paginated props with `->has('prop.data', N)`;
read raw values via `$page->toArray()['props'][...]`.

**Post-scaffold checklist (all three required for the page to
work):**
1. **Regenerate Ziggy the project's way — do NOT assume bare
   `php artisan ziggy:generate`.** Discover the command first:
   check `composer.json` scripts for a `ziggy` entry (run
   `composer ziggy`) or a wrapper (`scripts/ziggy-generate.sh`);
   use it if present. A bare `artisan ziggy:generate` runs against
   the dev `.env` and DROPS feature-gated routes, so the committed
   `resources/js/ziggy.js` stops matching what the in-sync contract
   test regenerates — a green-looking scaffold that fails CI. Fall
   back to `php artisan ziggy:generate` only when the project has no
   wrapper. **Worktree safety:** Ziggy writes `resources/js/ziggy.js`
   in the CWD — verify `pwd` is the intended root; running in main
   while worktrees are active mutates shared state (warn the
   operator). If no Ziggy command exists at all, skip and log
   `ziggy: skipped_not_available`.
2. **Add the route to `mockRoutes`** in the project's Vitest setup
   (discover the path — commonly `resources/js/test/setup.ts`). Map
   the route name to its URL with `:param` placeholders (e.g.
   `'reports.index': '/reports'`, `'reports.show':
   '/reports/:report'`). Inertia component tests throw on an
   unmocked `route()`; skipping this fails every test touching the
   page.
3. **Verify the Inertia contract tests pass.** The page-existence
   contract test (`tests/Contracts/InertiaPageExistenceTest.php` or
   equivalent) auto-scans every `Inertia::render('X')` for a
   matching `.tsx` — no manual entry needed, but it fails if the
   render string and file path disagree. If a props-consistency
   contract test exists AND another controller already renders the
   same page, the new controller must emit the identical top-level
   prop key set.

**Idempotency (page-specific).** The .tsx and controller are
create-only (skip if present, per SKILL.md Error Handling). The
route line and the `mockRoutes` entry are APPENDS — before adding
either, grep for the route name in `routes/web.php` and the key in
the setup file; skip if already present so a re-run never
duplicates a route or a mock.

### Enum

**Location:** `app/Enums/{EnumName}.php`

Conventions:
- PHP 8.1+ `enum` with `string` backing type
- Include a `label(): string` method for human-readable display
  in UI surfaces
- Document the values and usage in the project's CLAUDE.md schema
  section so they survive across sessions

### Model + Factory (+ migration)

**Usage:** `/v-scaffold --type model {ModelName}`

**Files:**
- `app/Models/{ModelName}.php` — Eloquent model
- `database/factories/{ModelName}Factory.php` — factory
- `database/migrations/*_create_{table}_table.php` — migration

Conventions:
- `use HasFactory;` on the model. **Hard deletes by default** — do
  NOT add `SoftDeletes` unless the project's CLAUDE.md opts this
  model in.
- Declare `$fillable` (or `$guarded = []`) and `$casts` explicitly
  — match the sampling of 2-3 existing models (see SKILL.md Gotcha #1).
- New columns on existing tables are always nullable or have a
  default; foreign keys use `->constrained()->cascadeOnDelete()`
  plus an index.
- Factory MUST use `$this->faker->...()` for variable fields — never
  hard-coded values (see SKILL.md Gotcha #2).
- Relationship methods are added as the surrounding schema requires;
  do not invent relations the migration doesn't back.

**Test location:** `tests/Unit/Models/{ModelName}Test.php` (or
`tests/Feature/` if it exercises the database) — cover casts,
relationships, and any accessor/mutator.

This is a legitimately **complete single-class scaffold** — it does
NOT require the full model+policy+controller+view octet (see SKILL.md
Gotcha #3); that octet applies only to a full CRUD-resource scaffold.

---

## SaaS scaffold types (composite Laravel)

These produce more files than simple scaffolds because SaaS
foundations are inherently cross-cutting: a "team" isn't one
file, it's a model + invitation model + three migrations + a
controller + two form requests + a policy + tests.

Each scaffold below assumes the project's CLAUDE.md sets the
broader conventions (eager loading, delete policy — hard-delete by
default, observer patterns, encryption casts). Scaffold output
respects those project conventions; nothing here overrides them.

### Team / Organization scaffold

**Usage:** `/v-scaffold --type team`

Foundation for multi-tenant team management.

| File | Purpose |
|---|---|
| `app/Models/Team.php` | Team model with owner relationship, member-management methods |
| `app/Models/TeamInvitation.php` | Invitation model with token generation and expiry |
| `database/migrations/*_create_teams_table.php` | `owner_id`, `name`, `slug`, `personal_team` |
| `database/migrations/*_create_team_invitations_table.php` | `team_id`, `email`, `role`, `token`, `expires_at` |
| `database/migrations/*_add_current_team_id_to_users_table.php` | Adds `current_team_id` for active-team switching |
| `app/Http/Controllers/TeamController.php` | CRUD + member management + invitation endpoints |
| `app/Http/Requests/StoreTeamRequest.php` | Team creation validation |
| `app/Http/Requests/InviteTeamMemberRequest.php` | Invitation validation |
| `app/Policies/TeamPolicy.php` | viewAny, view, update, delete, manageMember |
| `tests/Feature/TeamTest.php` | CRUD, invitation flow, member management, authorization |

**Conventions:**
- Team uses `HasFactory`. **Hard deletes by default** — do NOT add
  `SoftDeletes` (the global rule is hard deletes; SoftDeletes caused
  silent data-restoration bugs). Add `SoftDeletes` to this model
  ONLY if the project's CLAUDE.md explicitly opts it in.
- User gets `belongsToMany('teams')` and `currentTeam()` relationship
- All team-scoped queries: `->where('team_id', auth()->user()->current_team_id)`
- Invitation tokens are 64-char random strings with 7-day expiry
- Include team-switching middleware that sets `current_team_id`
  from session/header

### Subscription / Billing scaffold

**Usage:** `/v-scaffold --type billing`

Cashier-based subscription management infrastructure.

| File | Purpose |
|---|---|
| `app/Services/BillingService.php` | Subscription creation, plan changes, cancellation, reactivation |
| `app/Http/Controllers/BillingController.php` | Subscription management UI endpoints |
| `app/Listeners/HandleStripeWebhook.php` | Listener on Cashier's `WebhookReceived` event for app-specific side-effects — Cashier's built-in controller/route already handles signature verification and core subscription sync (do NOT hand-roll a webhook controller) |
| `app/Enums/SubscriptionPlan.php` | Plan enum with features, limits, Stripe price IDs |
| `app/Http/Middleware/RequiresSubscription.php` | Active-subscription gate for route groups |
| `app/Http/Middleware/RequiresPlan.php` | Minimum-plan-tier gate |
| `tests/Feature/BillingTest.php` | Subscribe, upgrade, downgrade, cancel, reactivate, webhook handling |

**Conventions:**
- BillingService wraps **all** Cashier calls — controllers never
  call Cashier directly. This keeps the eager-loading discipline
  (`$user->load('subscriptions')` before `$user->subscription('default')->cancel()`,
  `->resume()`, `->swap($priceId)` / `->swapAndInvoice($priceId)`)
  in one place. Cashier's subscription accessor is
  `$user->subscription('default')` (method) or the `subscriptions`
  relation — there is no bare `subscription` relation.
- Webhooks: use **Cashier's built-in webhook controller + route**
  (auto-registered at `POST /stripe/webhook`, name `cashier.webhook`;
  set `STRIPE_WEBHOOK_SECRET` and register the URL in the Stripe
  dashboard). Cashier already verifies the signature (its
  `VerifyWebhookSignature` middleware) and syncs
  `customer.subscription.updated/deleted` + invoice events. For
  app-specific side-effects (e.g. notify on `invoice.payment_failed`),
  register a listener on `Laravel\Cashier\Events\WebhookReceived`
  (raw payload) or `WebhookHandled` (post-sync) — do NOT hand-roll a
  controller or re-verify the signature.
- Plan enum exposes a `features(): array` method returning the
  feature flags per plan
- All billing operations wrapped in `DB::transaction(...)` with
  **dispatch-after-commit** for notifications
- Tests use Cashier's test helpers and mock all Stripe API calls

### RBAC / Permission scaffold

**Usage:** `/v-scaffold --type rbac`

Role-based access control infrastructure.

| File | Purpose |
|---|---|
| `app/Enums/Role.php` | Role enum: owner, admin, editor, viewer (with `permissions(): array`) |
| `app/Enums/Permission.php` | Permission enum: manage_team, manage_billing, edit_content, view_content, etc. |
| `app/Models/Traits/HasTeamRoles.php` | User trait: `hasPermission()`, `hasRole()`, `teamRole()` |
| `app/Policies/BasePolicy.php` | Abstract policy with `hasTeamPermission()` helper |
| `app/Http/Middleware/RequiresPermission.php` | Route middleware: `->middleware('permission:manage_billing')` |
| `tests/Feature/RBACTest.php` | Role assignment, permission checks, middleware blocking, policy enforcement |

**Conventions:**
- Roles live on the `team_user` pivot table (not a separate
  `roles` table) — keeps the schema simple and team-scoped by
  construction
- Permissions are derived from roles (mapping in the Role enum),
  not stored independently — single source of truth
- `HasTeamRoles` trait checks against `current_team_id` —
  permissions are always team-scoped
- Owner role implicitly has all permissions — never check owner
  permissions individually

### Settings page scaffold

**Usage:** `/v-scaffold --type settings`

Multi-section settings page with save-state management.

| File | Purpose |
|---|---|
| `resources/js/Pages/Settings/Index.tsx` | Layout with sidebar navigation between sections |
| `resources/js/Pages/Settings/Profile.tsx` | Name, email, avatar |
| `resources/js/Pages/Settings/Team.tsx` | Team name, members, invitations |
| `resources/js/Pages/Settings/Billing.tsx` | Plan display, upgrade/downgrade, payment method |
| `resources/js/Pages/Settings/Notifications.tsx` | Notification preferences |
| `app/Http/Controllers/SettingsController.php` | Section routing |
| `tests/Feature/SettingsTest.php` | Section rendering, form submission, authorization |

**Conventions:**
- Sticky section nav on desktop (inside the fixed 240px app sidebar
  layout per the spec); tabs on mobile (below the 700px breakpoint)
- Each section handles its own form state with loading / success /
  error feedback
- Save buttons cycle: "Saving..." → "Saved" → revert to "Save"
  (with timer)
- Destructive actions (delete account, leave team) require a
  confirmation modal
- Apply the canonical token set (`_v-design.md`); the overlay
  (`.interface-design/system.md`) supplies accent/category colors.
  Never hardcode colors, spacing, or typography

### Audit log scaffold

**Usage:** `/v-scaffold --type audit`

Audit logging infrastructure for compliance and debugging.

| File | Purpose |
|---|---|
| `app/Models/AuditLog.php` | `team_id`, `user_id`, `action`, `auditable_type/id`, `old_values`, `new_values`, `ip_address` |
| `app/Models/Traits/Auditable.php` | Trait that auto-logs `created` / `updated` / `deleted` events on any model |
| `database/migrations/*_create_audit_logs_table.php` | Indexes on `team_id`, `auditable`, `created_at` |
| `app/Services/AuditService.php` | Manual logging for non-model events (login, export, permission change) |
| `tests/Feature/AuditLogTest.php` | Auto-logging on model events, manual logging, query by entity |

**Conventions:**
- `Auditable` uses model observers — no manual logging for
  standard CRUD
- `old_values` / `new_values` are JSON columns storing only
  changed attributes (not the full model) — keeps audit-log
  storage bounded
- AuditService handles events that aren't model-bound (login,
  data export, invitation sent)
- Audit logs are append-only — no update or soft-delete
- Retention: include a comment noting that a scheduled job should
  prune logs older than the compliance requirement (default 2
  years)

### SaaS Base composite scaffold

**Usage:** `/v-scaffold --type saas-base`

Generates the full SaaS foundation in dependency order. Equivalent
to running the individual scaffolds sequentially **but** handles
dependency ordering and cross-scaffold wiring automatically.

**Execution order (mandatory — dependencies flow downward):**

1. **Team / Organization** — foundation for all multi-tenant scoping
2. **RBAC / Permissions** — requires Team (roles on `team_user` pivot)
3. **Billing / Subscription** — self-contained but typically team-scoped
4. **Audit Log** — requires models to exist for auto-tracking
5. **Settings Page** — requires Team + RBAC + Billing for section content

After all 5 scaffolds complete, run cross-scaffold wiring:
- Register `HasTeamRoles` trait on the User model (from RBAC)
- Register `Auditable` trait on Team and User models (from Audit)
- Wire BillingController routes into the Settings/Billing page
- Register the emitted middleware aliases + any new route files in
  `bootstrap/app.php` (see § Registration idiom (Laravel 13) below)
- Add the team-scoped middleware group to routes
- Regenerate Ziggy **once** (not per scaffold), using the project's
  command — `composer ziggy` / `scripts/ziggy-generate.sh` if present,
  bare `php artisan ziggy:generate` only as fallback (see § Inertia
  Page → Post-scaffold checklist for why the wrapper matters)

**Output:** All files from the 5 individual scaffolds plus a
`SCAFFOLD_MANIFEST_${CLAUDE_SESSION_ID}.md` listing every created
file, the wiring changes, and next steps.

### SaaS scaffold prerequisites

When scaffolding individual SaaS types (not the composite), check
prerequisites before generating:

| Scaffold Type | Prerequisites | If Missing |
|---|---|---|
| Team / Organization | None | — |
| Billing / Subscription | None (self-contained) | — |
| RBAC / Permissions | Team model with `team_user` pivot | WARN: "RBAC scaffold generates team-scoped roles. Run Team scaffold first, or confirm an existing Team model with a `team_user` pivot." |
| Settings Page | Team + RBAC + Billing | WARN: "Settings scaffold generates Team, Billing, and Notifications sections. Missing scaffolds will produce placeholder sections. Consider running SaaS Base instead." |
| Audit Log | None (trait applied manually) | — |
| Admin Dashboard | Team + User models | WARN: "Admin scaffold generates user/team management views. Confirm Team and User models exist." |
| API Versioning | Existing API routes | WARN: "API versioning scaffold wraps existing routes. Confirm API routes exist in `routes/api.php`." |

### Admin dashboard scaffold

**Usage:** `/v-scaffold --type admin`

Internal admin tooling for support and operations.

| File | Purpose |
|---|---|
| `app/Http/Controllers/Admin/AdminDashboardController.php` | Dashboard overview with key metrics |
| `app/Http/Controllers/Admin/AdminUserController.php` | User lookup, search, status management |
| `app/Http/Controllers/Admin/AdminTeamController.php` | Team management, subscription overview |
| `app/Http/Controllers/Admin/ImpersonationController.php` | Safe user impersonation with audit logging |
| `app/Http/Middleware/RequiresAdmin.php` | Admin access gate |
| `resources/js/Pages/Admin/Dashboard.tsx` | User count, MRR, active teams |
| `resources/js/Pages/Admin/Accounts/Index.tsx` | User list with search, filters, pagination |
| `resources/js/Pages/Admin/Accounts/Show.tsx` | User detail with subscription, activity, impersonate button |
| `tests/Feature/Admin/AdminAccessTest.php` | Authorization, impersonation safety, audit trail |

**Conventions:**
- All admin routes under `/admin` prefix with `RequiresAdmin`
  middleware
- Impersonation creates an audit log entry and sets
  `impersonating_user_id` in the session
- An impersonation banner is shown to the admin with a
  "Stop Impersonating" button
- Admins **cannot** impersonate other admins (prevents
  privilege loops and accidental log-pollution)

### API versioning scaffold

**Usage:** `/v-scaffold --type api-versioning`

API versioning infrastructure for external integrations.

| File | Purpose |
|---|---|
| `app/Http/Middleware/ApiVersion.php` | Reads version from URL prefix or `Accept` header, sets on request |
| `app/Http/Middleware/DeprecationNotice.php` | Adds `Sunset` and `Deprecation` headers for deprecated versions |
| `routes/api/v1.php` | V1 API routes (moved from `routes/api.php`) |
| `routes/api/v2.php` | V2 API routes (initially empty, template) |
| `app/Http/Resources/V1/` | V1 API resource directory |
| `app/Http/Resources/V2/` | V2 API resource directory |
| `tests/Feature/Api/ApiVersioningTest.php` | Version routing, deprecation headers, content negotiation |

**Conventions:**
- URL-based versioning by default (`/api/v1/`, `/api/v2/`)
- `ApiVersion` middleware resolves version and exposes it via
  `$request->apiVersion()`
- Deprecated versions return a `Sunset` header with the removal
  date — third-party integrators rely on this to plan migrations
- Each version gets its own route file and resource directory
- Shared logic stays in services; only response shapes vary
  between versions

---

## Registration idiom (Laravel 13 — `bootstrap/app.php`)

Laravel 11+ (current: **Laravel 13**) has **no `app/Http/Kernel.php`
and no `EventServiceProvider`**. All application wiring lives in
`bootstrap/app.php`. Any scaffold that emits a middleware, a route
file, or a scheduled task MUST register it there — never regenerate
`Kernel.php`-era code.

**Middleware aliases** (for `RequiresSubscription`, `RequiresPlan`,
`RequiresPermission`, `RequiresAdmin`, `ApiVersion`,
`DeprecationNotice`, etc.):

```php
// bootstrap/app.php
->withMiddleware(function (Middleware $middleware): void {
    $middleware->alias([
        'subscription' => \App\Http\Middleware\RequiresSubscription::class,
        'plan'         => \App\Http\Middleware\RequiresPlan::class,
        'permission'   => \App\Http\Middleware\RequiresPermission::class,
        'admin'        => \App\Http\Middleware\RequiresAdmin::class,
    ]);
    // Global/group middleware: $middleware->append(...) / $middleware->appendToGroup('api', ...)
})
```

- **Additional route files** (e.g. `routes/api/v1.php` from the API
  versioning scaffold): register via `->withRouting(then: function () {
  Route::middleware('api')->prefix('api/v1')->group(base_path('routes/api/v1.php')); })`
  in `bootstrap/app.php` — not in a `RouteServiceProvider`.
- **Events/listeners** are **auto-discovered** (Cashier's
  `WebhookReceived` → `HandleStripeWebhook` listener needs no manual
  binding as long as it lives in `app/Listeners` and type-hints the
  event). Only register explicitly in a provider's `boot()` if
  auto-discovery is disabled.
- **Scheduled tasks** (e.g. the audit-log pruning job) go in
  `->withSchedule(function (Schedule $schedule) { ... })` in
  `bootstrap/app.php`, not `app/Console/Kernel.php`.

The SaaS Base composite must apply these registrations as part of its
cross-scaffold wiring step (after the individual scaffolds emit the
middleware/route/listener files).

## Cross-references

- `references/saas-patterns.md` (in v-build) for the runtime
  rules these scaffolds produce code for (transactions, async,
  multi-tenancy, observability)
- Project-level CLAUDE.md "Critical Gotchas" — eager loading,
  job retry property, Inertia contract tests, ziggy regeneration
- Project-level `.claude/rules/billing.md` (where present) for
  Cashier-specific safety patterns

---

## What this reference is not

This catalog covers Laravel + SaaS-specific scaffolds. It does
**not** cover:

- Non-Laravel framework scaffolds (use the Pattern Reference in
  v-scaffold's main SKILL.md to discover conventions on the fly)
- Infrastructure scaffolds (Terraform, K8s manifests) — different
  skill family
- Test-only scaffolds (use the project's existing factory and test
  helpers; v-scaffold scaffolds tests alongside the code, not as
  standalone units)
