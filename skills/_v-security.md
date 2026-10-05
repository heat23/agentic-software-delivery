# V Security

Shared governance for security compliance baseline. Centralizes the security policy currently enforced implicitly by v-check audits.

_Last reviewed: 2026-08-02 (SME D-grade remediation: NIST 800-63B misattribution fixed, fabricated resource-route authorization API replaced with verified Laravel 13 idioms, AI/LLM baseline hardened (endpoint authorization, provider-key handling, output exfiltration), Multi-Tenant Data Isolation section added, auth-endpoint rate limiting added alongside lockout, Security Headers rollout/package guidance added, payment trigger cross-linked to `references/framework-pitfalls.md`; fabricated-API sweep: the "GOOD: use policy" Policy Pattern example still called `$this->authorize()` — the exact API this file's own note two sections down says NOT to use as canonical since Laravel 11 removed `AuthorizesRequests` from the base controller — swapped to `Gate::authorize()` for internal consistency, verified against `laravel/framework` v13.16.1 vendor source)_

## Authentication Baseline

All non-public routes require authentication. Enforce these baseline rules:

**Session Management:**
- Regenerate session ID on successful login (Laravel: `Auth::login($user); session()->regenerate();`)
- Destroy session on logout (Laravel: `Auth::logout(); session()->invalidate();`)
- Set appropriate session timeout (default: 2 hours for web, 30 days for remember-me)
- Secure session cookies: `secure`, `httpOnly`, `sameSite=lax` flags set

**Account Lockout:**
- Lock account after N failed login attempts (recommend N=5)
- Lockout duration: 15 minutes minimum, escalating for repeated violations
- Clear lockout counter after successful login or after timeout period
- Log failed attempts with IP address and timestamp

**Rate Limiting (required on every auth endpoint — lockout is not a substitute):**

Lockout above stops one account being brute-forced. It does nothing against credential stuffing spread across many accounts (each tried a handful of times, none tripping its own counter) or a low-and-slow attempt paced under the lockout threshold. CLAUDE.md § Security Defaults requires rate limiting on every auth endpoint regardless of lockout — both controls are required, not either/or.

```php
// AppServiceProvider::boot()
RateLimiter::for('login', function (Request $request) {
    return Limit::perMinute(5)->by($request->ip().'|'.$request->input('email'));
});

// routes/web.php
Route::post('/login', [AuthController::class, 'login'])->middleware('throttle:login');
```

- Key the limiter by IP **and** the submitted identifier (email/username), not IP alone — `->by($request->ip())` alone misses an attacker spreading attempts across many accounts from one IP, or one account attacked from many rotating IPs.
- Apply the same `RateLimiter::for()` + `throttle:<name>` pattern to the four endpoints the house rule names: **login, registration, password reset, and email verification.** A shared `auth`-named limiter reused across all four is acceptable if their traffic shape is the same; give each its own name if it isn't.
- `throttle` is a built-in Laravel middleware alias (`Illuminate\Routing\Middleware\ThrottleRequests`) — no package required.

**Password Requirements (NIST SP 800-63B Rev. 4, 2025):**
- Minimum 8 characters; encourage 12-15+ or a passphrase. Support at least 64 characters — never impose a low maximum that blocks passphrases.
- **No composition mandate.** Do NOT require mixed case, numbers, or symbols. NIST prohibits this: composition rules push users to predictable substitutions (`Password1!`) instead of real entropy.
- Screen against breached-password corpora on every set/change. This is the control NIST *does* mandate — keep it.
- **No periodic/forced rotation.** Require a change only on evidence of compromise (breach-corpus hit, credential-stuffing alert, suspected takeover). Timer-based rotation is explicitly prohibited — it drives users toward weaker, incrementing passwords.
- Do not reuse the last N passwords (minimum 3) — enforced at a compromise-driven reset, not on a timer.

> **Why composition + rotation were REMOVED, not overlooked:** NIST SP 800-63B has prohibited both since Rev. 3 (2017) and reaffirmed it in Rev. 4 (2025). This file previously mandated both *and attributed them to "NIST guidelines"* — asserting NIST's authority for the two practices NIST forbids. Do not reintroduce either from memory. (F35 — misattributed external standard.)
>
> **Refresh trigger:** if NIST publishes SP 800-63B Rev. 5, re-read its authenticator-secret guidance (composition, rotation, breach screening, minimum/maximum length) before touching this section — do not assume Rev. 4's stance carries forward unchanged, and do not re-derive the rule from memory of what a prior revision said.

**Laravel implementation:**
```php
use Illuminate\Validation\Rules\Password;

// AppServiceProvider::boot() — the default every Password::defaults() reference uses
Password::defaults(fn () => Password::min(8)->uncompromised());

// Form Request
'password' => ['required', 'confirmed', Password::defaults()],
```
No `->mixedCase()`, `->numbers()`, or `->symbols()` — those enforce the composition rules NIST prohibits. `->uncompromised()` checks the Have I Been Pwned corpus via k-anonymity (no plaintext password leaves the server).

**Multi-Factor Authentication (where required):**
- Support TOTP (time-based one-time password) for high-value operations
- Support backup codes for account recovery
- Log MFA attempts and verify rates for abuse

## Authorization Baseline

Every resource route must have an associated Policy. No inline permission checks in controllers:

**Policy Pattern:**
```php
// BAD: inline check in controller
if ($user->id === $post->user_id) {
    $post->update($data);
}

// GOOD: use policy
Gate::authorize('update', $post);
$post->update($data);
```

**Policy structure:**
```php
class PostPolicy {
    public function view(User $user, Post $post): bool {
        return $post->is_published || $user->id === $post->user_id;
    }

    public function update(User $user, Post $post): bool {
        return $user->id === $post->user_id && !$post->is_locked;
    }

    public function delete(User $user, Post $post): bool {
        return $user->id === $post->user_id || $user->isAdmin();
    }
}
```

**Apply policies in routes:**
```php
// Option 1 — attribute on the controller action (preferred: the rule sits next to what it guards)
use Illuminate\Routing\Attributes\Controllers\Authorize;

#[Authorize('update', 'post')]
public function update(Post $post) {
    // reached only if PostPolicy@update passes
}

// Option 2 — per-route `can` middleware (authorization visible in routes/ at a glance)
Route::put('/posts/{post}', [PostController::class, 'update'])
    ->middleware('can:update,post');
// equivalent fluent form:
Route::put('/posts/{post}', [PostController::class, 'update'])->can('update', 'post');

// Option 3 — explicitly in the controller body
public function update(Post $post) {
    Gate::authorize('update', $post);
    // ...
}
```

> **There is NO `->can()` chained onto `Route::resource()` that authorizes per action.** This file
> previously taught `Route::resource(...)->middleware('auth')->can('view')` as the canonical GOOD
> example. `->can()` does not exist on a resource-route registrar — it either throws, or ships a
> resource route with authentication but **no authorization**, while reading as authorized. That is
> the worst failure shape for a security example. A resource route needs `#[Authorize]` per method
> (Option 1). Also note a blanket ability across a resource is almost never right: `view`, `update`
> and `delete` need different checks. (F26 — fabricated framework API.)
>
> Use `Gate::authorize()`, not `$this->authorize()`. Since Laravel 11 the base controller no longer
> includes the `AuthorizesRequests` trait, so `$this->authorize()` only works if you re-add it.

**No hardcoded role checks in controllers.** Use policies instead for testability and maintainability.

## Multi-Tenant Data Isolation

An ownership check on a fetched model is not the tenant boundary — the QUERY that fetched it is. A policy that checks `$user->id === $post->user_id` after `Post::find($id)` already ran an unscoped fetch first: the row was retrieved successfully before the check, so a bug that skips the check on one code path, or a leaked timing/error difference, exposes another tenant's row. This is the failure that actually leaks customer A's data to customer B — not a missing policy, a missing `WHERE`.

**Rule: every tenant-owned model is scoped at the query layer, not only the policy layer.**
- Add a global scope to every tenant-owned model — `static::addGlobalScope('tenant', fn (Builder $b) => $b->where('tenant_id', ...))` inside the model's `booted()` method (`Illuminate\Database\Eloquent\Concerns\HasGlobalScopes::addGlobalScope()`), or a reusable trait that every tenant-owned model uses to do the same. Once scoped, every `::find()`, `::where()`, relationship query, and Eloquent collection the app builds for that model is filtered automatically — there is no route or controller that can forget the `WHERE`.
- Policies (`## Authorization Baseline` above) remain required as defense-in-depth for the within-tenant permission — can *this* user, not just this tenant, act on this row. A policy alone, run against an unscoped query, only proves "authorized within *a* tenant"; "which tenant" is a separate check, and skipping the query-layer scope means that second check was never made.
- **Flag every raw `Model::query()`, `DB::table(...)`, `withoutGlobalScope()`, or `withoutGlobalScopes()` call against a tenant-owned table** — each one bypasses the automatic scope and needs its own explicit `where('tenant_id', ...)` reviewed at the call site. Checkable: `grep -rn "::query()\|DB::table('<tenant_owned_table>')\|withoutGlobalScope" app/` for every tenant-owned table name; each hit is a finding until the scope is confirmed re-applied at that call site.
- **Cross-tenant ID disclosure: prefer 404 over 403.** With the model correctly scoped, `findOrFail()` against another tenant's ID throws `ModelNotFoundException` → 404 automatically — the row was never in the queryable set, so there is no "this exists, you may not see it" answer to leak. Reach for an explicit 403 only when the row IS in the requesting user's own tenant and the failure is a same-tenant permission gap (e.g., a teammate's private draft). A 403 on a cross-tenant ID confirms that ID exists somewhere in the system — treat that as an information-disclosure bug, not a stricter error response.

## Input Validation Baseline

Every POST/PUT/PATCH endpoint requires a FormRequest for validation:

```php
// BAD: raw input
Route::post('/users', function (Request $request) {
    User::create($request->input());
});

// GOOD: form request
Route::post('/users', [UserController::class, 'store']);

class StoreUserRequest extends FormRequest {
    public function authorize(): bool {
        return $this->user()->can('create', User::class);
    }

    public function rules(): array {
        return [
            'name' => 'required|string|max:255',
            'email' => 'required|email|unique:users',
            'password' => 'required|min:8|confirmed',
        ];
    }
}
```

**Validation characteristics:**
- Whitelist allowed fields (never use `$request->all()` without validation)
- Type-check all inputs (email, integer, URL, date, etc.)
- Enforce length limits (strings, arrays)
- Use custom rules for business logic (unique email per organization, valid coupon code, etc.)

## Output Encoding

All user-generated content must be escaped in views. No unescaped HTML:

**BAD (unsafe):**
```blade
<h1>{!! $post->title !!}</h1>  {{-- user input rendered as HTML --}}
<p>{{ $user->bio }}</p>        {{-- OK if not user input, but inconsistent --}}
```

**GOOD (safe):**
```blade
<h1>{{ $post->title }}</h1>           {{-- escaped by default --}}
<p>{{ strip_tags($user->bio) }}</p>   {{-- strip HTML tags before output --}}
<div class="html-content">
    {!! Purify::clean($post->content) !!}  {{-- sanitize with HTMLPurifier --}}
</div>
```

**Rules:**
- Use `{{ }}` by default (escapes HTML entities)
- Only use `{!! !!}` with explicitly sanitized content (use `Purify`, `DOMPurifier`, or equivalent)
- Never mix user input with `{!! !!}` without sanitization
- React/Inertia: `dangerouslySetInnerHTML` NEVER without `DOMPurify.sanitize()` and an explicit allowlist (CLAUDE.md § Security Defaults) — applies to AI-generated content, CMS content, and any external HTML; default-config DOMPurify without an allowlist does not meet the bar

## SQL Injection Prevention

Always use parameterized queries. Never construct queries with string concatenation:

**BAD (vulnerable):**
```php
User::whereRaw("email = '{$email}'")         // SQL injection vector
    ->get();

DB::select("SELECT * FROM users WHERE id = {$id}");
```

**GOOD (safe):**
```php
User::where('email', $email)->get();         // parameterized

DB::select("SELECT * FROM users WHERE id = ?", [$id]);

DB::select("SELECT * FROM users WHERE id = :id", ['id' => $id]);
```

**Rules:**
- Use Eloquent methods (where, whereIn, etc.) for standard queries
- Use `DB::select()`, `DB::insert()`, etc. with placeholders for raw queries
- Bind values separately from SQL, never interpolate with `{}`or string concatenation
- Audit legacy code for `whereRaw()` with unbound variables

## CSRF Protection

CSRF tokens must be verified on all state-changing routes:

**Configuration:**
```php
// config/session.php
'secure' => env('SESSION_SECURE_COOKIES', true),
'http_only' => true,
'same_site' => 'lax',

// Add VerifyCsrfToken middleware to web routes
Route::middleware('web')->group(function () {
    // CSRF protection enabled by default
});
```

**In forms:**
```blade
<form method="POST" action="/users">
    @csrf  {{-- automatically includes CSRF token --}}
    <input type="text" name="name">
</form>
```

**In AJAX:**
```javascript
// Include token in request headers
fetch('/api/users', {
    method: 'POST',
    headers: {
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content,
        'Content-Type': 'application/json',
    },
    body: JSON.stringify(data),
});
```

**Rules:**
- Enable `VerifyCsrfToken` middleware on all web routes
- Include `@csrf` in every form
- The only sanctioned `$except` exclusion is a webhook endpoint that verifies a signature instead (CLAUDE.md § Security Defaults: never disable CSRF without webhook signature verification). Bearer-token API routes live outside the `web` middleware group and need no `$except` entry

## Security Headers

Laravel sets none of these by default — add them explicitly via middleware.

- `Content-Security-Policy` — restricts where scripts/styles/images/connections may load from. Highest-value header against XSS.
- `Strict-Transport-Security` (HSTS) — forces HTTPS. Never set on a domain not fully on HTTPS.
- `X-Content-Type-Options: nosniff` — stops MIME-sniffing into an unintended content type.
- `Referrer-Policy: strict-origin-when-cross-origin` — stops full URLs (which may carry tokens/IDs) leaking to third parties.
- `Permissions-Policy` — denies unused browser features, shrinking blast radius if a third-party script is compromised.

```php
// app/Http/Middleware/SecurityHeaders.php
$response->headers->set('X-Content-Type-Options', 'nosniff');
$response->headers->set('Referrer-Policy', 'strict-origin-when-cross-origin');
$response->headers->set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
if ($request->secure()) {
    $response->headers->set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
}
$response->headers->set('Content-Security-Policy',
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'");

// bootstrap/app.php
->withMiddleware(fn (Middleware $middleware) => $middleware->append(\App\Http\Middleware\SecurityHeaders::class))
```

**React/Inertia caveat:** a strict `script-src 'self'` blocks INLINE scripts, breaking Vite dev-mode HMR and third-party inline snippets. Either serve all app JS as external files (the default Inertia build already does — no inline `<script>` needed for your own code), or generate a per-request nonce and add it to both the CSP and that specific tag. **Never** reach for `'unsafe-inline'` on scripts as a shortcut — that disables the header's main protection.

**Implementation pointer:** the hand-written middleware above is the durable default — it has no dependency and the directive values shown (`'self'`-only) don't reference anything that goes stale. If directive-builder ergonomics are worth a dependency (composing per-route CSP exceptions, nonce management), a maintained CSP-specific package is a reasonable substitute for the middleware — verify it is still maintained before adopting; the package landscape here turns over faster than this file does, so no specific package is named as a standing recommendation.

**Rollout rule:** ship a new or tightened CSP as `Content-Security-Policy-Report-Only` first, with a `report-uri`/`report-to` endpoint capturing violations, then flip to enforcing (`Content-Security-Policy`) once a monitoring period shows zero unexpected violations. Shipping a strict CSP directly as enforcing on an existing app is how legitimate app JS gets silently blocked in production.

## File Upload Safety

Validate, size-limit, and store uploads outside the web root:

**Validation:**
```php
class StoreDocumentRequest extends FormRequest {
    public function rules(): array {
        return [
            'file' => 'required|file|mimes:pdf,docx,xlsx|max:10240', // 10MB
        ];
    }
}
```

**Storage:**
```php
// Store outside web root
$path = $request->file('document')->store('uploads', 'private');

// NOT: public disk (accessible via URL)
// NOT: storage_path('app/public')
```

**Access control:**
```php
// Download file with access check
public function download(Document $document) {
    Gate::authorize('view', $document);   // NOT $this->authorize() — see § Authorization Baseline
    return response()->download(
        storage_path("app/uploads/{$document->path}"),
        $document->filename
    );
}
```

**Rules:**
- Validate MIME type, size, AND extension server-side (CLAUDE.md § Security Defaults — a client-side `accept` attribute is UX, not validation)
- Enforce strict size limits (prevent disk exhaustion)
- Store outside web root (`storage/app/` not `public/`)
- Require authorization before download
- Rename files to prevent path traversal (`../../../etc/passwd`)
- Malware-scan uploads whenever the file is (a) re-served to any user other than the uploader, or
  (b) opened/parsed by a server-side processor. Scan in a queued job before the file is marked
  available, never in the request lifecycle. On a positive result: quarantine (do not delete —
  preserve for review), fail the upload closed, and log `user_id`/`action`/`ip` with the detection
  verdict but never the file contents. Private single-user uploads that are only ever streamed
  back verbatim to their own uploader may skip scanning — record that as an explicit decision.

## Secrets Management

Credentials must never appear in code, config files, or URLs:

**WRONG (never):**
```php
// .env or config
'stripe_key' => 'sk_live_abc123xyz...',

// Code
$response = Http::get('https://api.example.com?key=secret123');

// URL parameter
redirect('/callback?token=abc123');
```

**RIGHT:**
```php
// .env (never hardcoded in source; commit policy is per-project — see CLAUDE.md § Security Defaults)
STRIPE_SECRET_KEY=sk_live_abc123xyz...

// Code
$response = Http::withToken(config('services.stripe.secret'))->get('...');

// Authorization header or body parameter
Http::withToken($secret)->get('...');
```

**Rules:**
- All secrets in `.env*` files, never hardcoded in source code. Whether `.env*` files are committed is per-project policy (CLAUDE.md § Security Defaults) — a tracked `.env` is a finding only when it violates the project's stated policy
- Rotate secrets on employee departure
- Use distinct keys for dev/staging/production
- Never log secrets (redact in logs)
- Use environment-specific vaults (AWS Secrets Manager, HashiCorp Vault) for production
- Audit `.env*` history for leaked secrets, re-issue if found

## Dependency Security

Keep dependencies up-to-date and audit for known vulnerabilities:

**Regular audits:**
```bash
composer audit          # PHP dependencies
npm audit              # JavaScript dependencies
```

**Rules:**
- Run audits in CI/CD pipeline on every commit
- Build gate (matches /v-pre-flight + CLAUDE.md quality gates): `composer audit` fails on any advisory; `npm audit --audit-level=critical` fails on critical only. High npm CVEs are P1 audit findings requiring a scheduled fix (≤30 days) — they do not block the build gate
- Update dependencies at least monthly
- Subscribe to security mailing lists (Laravel Security Advisories, Node Security)
- Test updates in dev/staging before production

**Acceptable findings:**
- Low-severity CVEs with documented mitigation
- Medium CVEs with release date scheduled within 30 days
- Deprecated but essential libraries with known workarounds

**Unacceptable findings:**
- High/critical CVEs without timeline for fix
- Zero-day vulnerabilities not yet patched

## Compliance Triggers

Escalate to a full security review when these conditions occur:

1. **New authentication flow** — any change to login/session/MFA
2. **New payment integration** — Stripe, PayPal, or other payment processor. For Stripe specifically: use Cashier's built-in webhook controller/route, not a hand-rolled one (`references/framework-pitfalls.md § Verified framework semantics`)
3. **New file upload** — any feature allowing user file uploads
4. **New admin endpoint** — dashboard, settings, or admin-only routes
5. **Data export feature** — bulk export of user/customer data
6. **API token/key system** — programmatic authentication mechanism
7. **Third-party integrations** — OAuth, webhooks, or external API access
8. **Database schema changes** — new PII, sensitive fields, or retention policies
9. **Email/SMS integrations** — transactional or marketing communications
10. **Encryption/hashing** — new cryptographic operations or algorithm changes
11. **New AI/LLM feature** — chat, agent/tool-calling, RAG/retrieval, or any feature where model output can trigger an action or reach a user

For each trigger, follow the full security review checklist:
- Threat modeling for the feature
- Input validation and output encoding review
- Authentication and authorization policy review
- Secrets and key management review
- Logging and audit trail review
- Dependency security audit
- Penetration testing (high-risk features)

## AI/LLM Feature Security Baseline

Any feature that sends data to a model, or lets model output influence what happens next, is untrusted on BOTH sides. Treat the model as an external, adversarial user — not as your own backend code. Aligned with the OWASP Top 10 for LLM Applications.

**Model output is untrusted — always:**
- Model output gets the same scrutiny as user input before it is rendered, executed, or fed to another system.
- Rendering it as HTML follows the existing rule in `## Output Encoding`: `dangerouslySetInnerHTML` NEVER without `DOMPurify.sanitize()` + an explicit allowlist. AI-generated content is not a special case — it is the *most* likely case.
- Output that looks like SQL, shell, or a file path goes through the same parameterization and validation as if a user typed it. A model "deciding" to run a query does not exempt it from parameterized queries.

**Tool / agent / function-calling side effects:**
- Any side-effecting action the model can trigger (email, charge, delete, external call, file write) needs the SAME authorization check a human-initiated request would need — check the *acting user's* Policy, not "the model asked for it."
- Keep an explicit allowlist of callable tools. Never let the model construct an arbitrary shell command, SQL query, or HTTP target from its own reasoning.
- High-consequence actions (payments, destructive deletes, bulk operations, anything on the CLAUDE.md stop-list) require explicit user confirmation before execution. **Model confidence is not user consent.**
- Log every tool call with inputs and the authorizing user — it is the only way to distinguish "the model did this" from "a user did this" after the fact.

**Endpoint authorization — who may invoke, separate from how much they may spend:**
- A model-backed endpoint is a resource like any other: check the requesting user's Policy for the *feature itself* before dispatching a model call — the same rule as `## Authorization Baseline` above, applied to an AI endpoint instead of a CRUD route. "The request reached the controller" is not authorization, and neither is "the user has an active session."
- A metered or plan-gated feature needs an entitlement/plan check in addition to the ordinary auth check, at the same layer that gates any other paid feature. Do not let the spend cap (below) stand in for "may this user use this feature at all" — a user who is under budget is not automatically a user who is entitled.
- Retrieval feeding a prompt (RAG, document context, search results) is bound by the same tenant/ownership boundary as `## Multi-Tenant Data Isolation` — a model fetching context on the user's behalf is not exempt from the query-layer scope a controller would need for the same data.
- Spend/rate caps are the OTHER half of the metered-endpoint story, not a substitute for the authorization check above — see **Output-length and cost bounds** below.

**Prompt-injection isolation:**
- Any external or retrieved content placed in a prompt (RAG docs, scraped pages, uploaded files, email bodies, third-party API responses) is an injection vector — it can carry instructions aimed at the model.
- Never concatenate untrusted content into the SYSTEM prompt, where it inherits system authority. Keep it in a delimited, lower-trust region and tell the model that region is data, not instructions.
- Treat successful injection as a *possibility, not an edge case*: the allowlist and authorization rules above are the real defense. Prompt wording reduces likelihood; only capability-level containment reduces blast radius.

**Secret hygiene and output exfiltration:**
- Never put API keys, tokens, or internal URLs in a system prompt or model context — anything in the prompt can be echoed back, directly or via injection-driven exfiltration.
- Redact secrets from any logging of prompts, completions, or tool payloads (same rule as `## Secrets Management`).
- If a tool must act with a credential, pass it to the *execution layer*, never through the model's context — the model requests the action without ever seeing the secret.
- **Provider API keys (OpenAI, Anthropic, or equivalent) are server-side secrets like any other** (`## Secrets Management` above) — call the provider only from backend code (a Job — see `_v-jobs.md § Model-Call Jobs`), never from client-side JS with an embedded key, and use distinct provider keys per environment.
- **Treat model output itself as a potential exfiltration channel, not only the prompt.** A response must not surface another user's or tenant's data, or an internal system detail, that made it into the model's context — the retrieval-scoping rule above is the control that prevents this; reviewing output text after generation is not a substitute for never having put the wrong data in context to begin with.

**Output-length and cost bounds:**
- Bound max output tokens and set a per-request timeout on every model call. Unbounded generation is a DoS and cost vector, not just a UX issue.
- Enforce per-user/per-tenant spend caps with a circuit breaker for runaway agent loops. Per CLAUDE.md, external API calls live in Jobs, never the request lifecycle — the cap belongs there too.
- Fail closed on a cost/rate breach: stop and return a clear error. Never silently truncate and present a partial answer as complete.
- The budget-enforcement mechanics (atomic per-user/tenant spend counters, fail-closed dispatch gating, provider-usage-based tracking) live in `_v-jobs.md § Model-Call Jobs`; the worst-case-cost reasoning that number is derived from lives in `references/ai-feature-engineering.md § Cost model` — cite them, don't re-derive the mechanics here.

---

## Checklist for Security Baseline

When implementing auth, API, or data handling:

- [ ] All non-public routes require authentication
- [ ] Session regenerated on login, invalidated on logout
- [ ] Account lockout after N failed attempts (N ≥ 5)
- [ ] Login, registration, password-reset, and email-verification routes rate-limited via `throttle:`/`RateLimiter::for()` — lockout alone is not sufficient
- [ ] Every resource route has a Policy (no inline `if (user->id === ...)`)
- [ ] Every tenant-owned model is scoped at the query layer (global scope/trait) — a Policy alone is not the tenant boundary
- [ ] Every write endpoint has FormRequest validation (no raw `$request->input()`)
- [ ] All user-generated content escaped with `{{ }}` or sanitized with `{!! !!}`
- [ ] All SQL queries parameterized (no string concatenation)
- [ ] CSRF tokens verified on state-changing routes
- [ ] Security headers (CSP, HSTS, `X-Content-Type-Options`, `Referrer-Policy`) set via middleware
- [ ] File uploads validated, size-limited, stored outside web root
- [ ] Secrets in `.env` only, never in code or URLs; provider API keys called only from backend code
- [ ] `composer audit` clean; `npm audit --audit-level=critical` returns no critical CVEs (high CVEs: P1 finding with scheduled fix ≤30 days, not a gate block)
- [ ] AI/LLM features: model output treated as untrusted; tool calls allowlisted + authorized; endpoint authorization checked separately from the spend cap
- [ ] Triggers identified for escalation to full security review
