# v-security-baseline: Security Policy Baseline for v-check Audits

_Last reviewed: 2026-08-02 (fabricated-API sweep, verified against `laravel/framework` v13.16.1 vendor source of two production projects: (1) CSRF section taught the pre-Laravel-11 `VerifyCsrfToken extends Middleware` exemption pattern — neither project has that file by default; replaced with the real `bootstrap/app.php` → `$middleware->validateCsrfTokens(except: [...])` idiom, version-gated like the adjacent Policy Registration section; (2) `$this->authorize()` used in two "GOOD" examples as if always available — since Laravel 11 the base `Controller` no longer includes `AuthorizesRequests` (confirmed both projects), and the file's own owner (`_v-security.md § Authorization Baseline`) already mandates `Gate::authorize()` instead — aligned both examples to stop conflicting with the file it says wins on conflict; (3) HSTS example referenced an undefined `$this->app` and single-env-keyed its guard (`framework-pitfalls.md § Class 2 — Env-keyed half-guard`) — switched to `app()->environment([...])` with the default-safe inversion; (4) `Auth::attempt($request->credentials())` — `credentials()` doesn't exist on Request/FormRequest/Breeze's LoginRequest — replaced with the real `$request->only('email', 'password')`; (5) noted `currentTeam` in the BOLA example is a project-level relation (Jetstream or equivalent), not a core Laravel API. Theme-consistency sweep B (2026-07-06) content otherwise intact.)_

v-check's audit-check expansion of the canonical security policy owners — `~/.claude/skills/_v-security.md` + CLAUDE.md § Security Defaults. On conflict, those owners win. Used by security domain audits to verify compliance.

**Standard tracked:** This baseline tracks **OWASP Top 10 (current) + OWASP LLM Top 10** — verify the live category list and any version-specific thresholds at **owasp.org**. The classes below extend the original OWASP-2021-era checks with 2026-critical disciplines (SSRF, IDOR/BOLA/BFLA, modern auth, CI/CD supply-chain, LLM/agent attack surface). Keep all existing checks; these are additive.

## Authentication Requirements

### Auth Middleware on All Non-Public Routes

Every route except explicitly whitelisted public routes must enforce authentication:

```php
// Laravel routes/web.php
Route::middleware(['auth'])->group(function () {
    Route::get('/dashboard', DashboardController::class);
    Route::resource('posts', PostController::class);
});

// Public routes (no auth required)
Route::get('/', HomeController::class);
Route::get('/blog', BlogController::class);
Route::post('/register', RegisterController::class);
```

**Audit check:** Grep for route definitions without middleware or with `web` middleware only. Routes serving user/admin content MUST have `auth` middleware.

### Session Configuration

Sessions must be configured securely:

```php
// config/session.php
'secure' => env('SESSION_SECURE_COOKIES', true), // HTTPS only in production
'http_only' => true,                             // No JavaScript access
'same_site' => 'lax',                            // CSRF protection
'encrypt' => true,                               // Encrypt session data
```

**Audit check:** Session config in production must have `secure: true`, `http_only: true`, `same_site: lax|strict`.

### CSRF Protection

All POST/PATCH/DELETE endpoints must validate CSRF tokens:

```php
// Automatically protected by VerifyCsrfToken middleware
Route::post('/posts', [PostController::class, 'store']); // Protected

// If disabling CSRF (rare), explicitly exempt — Laravel 11+ (target: Laravel 13):
// there is no app/Http/Middleware/VerifyCsrfToken.php to extend by default;
// exceptions are declared in bootstrap/app.php instead.
->withMiddleware(function (Middleware $middleware) {
    $middleware->validateCsrfTokens(except: [
        'webhook/stripe/*', // Only signature-verified external webhooks
    ]);
})
```

**Audit check (version-dependent, do NOT flag the wrong era):** On **Laravel 11+**, verify CSRF exceptions via `$middleware->validateCsrfTokens(except: [...])` in `bootstrap/app.php` — do not flag a missing `app/Http/Middleware/VerifyCsrfToken.php`; a fresh Laravel 13 skeleton doesn't ship one. On **Laravel <=10** (legacy), the exception lived in `App\Http\Middleware\VerifyCsrfToken::$except`. Either way, the only sanctioned exemption is a webhook endpoint that verifies a signature instead (CLAUDE.md § Security Defaults: never disable CSRF without webhook signature verification) — verify the signature check exists and document it.

## Authorization Requirements

### Policies for Every Resource Route

Every resource (Post, User, Team, etc.) must have a Policy:

```php
// app/Policies/PostPolicy.php
class PostPolicy
{
    public function view(User $user, Post $post): bool
    {
        return $user->can('view_posts') && $post->team_id === $user->team_id;
    }

    public function update(User $user, Post $post): bool
    {
        return $user->id === $post->author_id;
    }

    public function delete(User $user, Post $post): bool
    {
        return $user->id === $post->author_id || $user->isAdmin();
    }
}
```

**Policy registration — version-dependent (do NOT flag the wrong era):**

```php
// Laravel 11+ (target: Laravel 13): policies are AUTO-DISCOVERED.
// `App\Policies\PostPolicy` is resolved for `App\Models\Post` by naming convention.
// There is NO AuthServiceProvider by default. Only explicit registration in a
// service provider's boot() is needed when the policy name/namespace breaks convention:
Gate::policy(Post::class, CustomPostPolicy::class); // edge case only

// Laravel <=10 (legacy): registered the $policies array (or Gate::policy)
// in app/Providers/AuthServiceProvider.php.
```

**Audit check (policy registration):** Detect the Laravel major version first (`composer.json` `laravel/framework` constraint, or `php artisan --version`). On **Laravel 11+**, do NOT flag a missing `app/Providers/AuthServiceProvider.php` or missing `Gate::policy(...)` — auto-discovery is the default. Confirm each policy by either (a) convention-matched file `app/Policies/{Model}Policy.php`, or (b) an explicit `Gate::policy(...)` / `enforceMorphMap`-style registration for non-conventional names. Only on **Laravel <=10** require the `AuthServiceProvider::$policies` registration. Flagging missing AuthServiceProvider on Laravel 11+ is a false positive.

**In controllers:** Use `Gate::authorize()`, never inline permission logic:

```php
// GOOD: Policy-based
public function show(Post $post)
{
    Gate::authorize('view', $post);
    return view('posts.show', compact('post'));
}

// BAD: Inline permission check (hard to test, easy to miss)
public function show(Post $post)
{
    if (auth()->user()->id !== $post->author_id) {
        abort(403);
    }
    return view('posts.show', compact('post'));
}
```

Not `$this->authorize()` — since Laravel 11 the base `Illuminate\Routing\Controller` no longer includes the `AuthorizesRequests` trait (confirmed against two production projects: neither project's `app/Http/Controllers/Controller.php` has it by default, and one re-adds it explicitly while the other does not — a controller relying on `$this->authorize()` throws `BadMethodCallException` unless a project has opted back in). `_v-security.md § Authorization Baseline` is the canonical owner of this rule; this file mirrors it rather than conflicting with it.

**Audit check:** Every resource controller's show/update/delete must call `Gate::authorize()` (or `$this->authorize()` ONLY if the project's base controller has re-added `AuthorizesRequests` — confirm before flagging either as missing). Search for missing authorization calls.

### IDOR / Broken Object-Level Authorization (BOLA) — own discipline

(OWASP API #1 BOLA + #5 BFLA — verify at owasp.org.) Authorization is not just "is this route behind `auth`" — it is "does THIS actor own THIS specific record." The most common real-world breach is an authenticated user reading or mutating another tenant/user's object by changing an ID in the URL or payload.

```php
// BAD: route-level auth passes, but no per-record ownership check.
// User A can GET /invoices/999 (User B's invoice) by guessing the ID.
public function show(Invoice $invoice)        // implicit binding, no scoping
{
    return new InvoiceResource($invoice);     // IDOR — no ownership verification
}

// GOOD: scope the lookup to the actor, OR authorize the resolved record.
public function show(Invoice $invoice)
{
    Gate::authorize('view', $invoice);        // policy checks $invoice->team_id
    return new InvoiceResource($invoice);
}

// GOOD (defense-in-depth): bind only within the actor's scope so a foreign
// ID 404s instead of leaking. Scoped route binding or an explicit where():
// `currentTeam` here is a project-level relation (e.g. Jetstream's HasTeams,
// or an equivalent hand-rolled one) — not a stock Eloquent/Auth API. Swap in
// whatever this project's actual tenant-scoping relation/column is.
$invoice = auth()->user()->currentTeam->invoices()->findOrFail($id);
```

**Object-level (BOLA/IDOR) audit checklist:**
- [ ] Enumerate every endpoint that accepts an object ID (route param, query string, JSON body) — these are the IDOR surface.
- [ ] For each, verify a per-record ownership/tenant check (`authorize()` on the resolved model, scoped relationship lookup, or global scope) — NOT just route `auth` middleware.
- [ ] Adversarial test: **"fetch resource with actor B's token."** Authenticate as user/tenant A, request A's object ID → 200; request B's object ID → MUST be 403/404, never 200.
- [ ] Sequential/guessable IDs (auto-increment PKs) escalate the risk — prefer UUIDs/ULIDs for externally-exposed identifiers, but UUIDs are NOT a substitute for the ownership check.
- [ ] Mass-assignment + IDOR combo: `update(['team_id' => ...])` must never let an actor re-parent a record into another tenant.

### BFLA — Broken Function-Level Authorization

(OWASP API #5 — verify at owasp.org.) Object-level checks can pass while *function-level* (action/role) checks are missing: a regular user reaching an admin-only function (e.g. `DELETE /accounts/{id}`, `POST /admin/payouts`) because the route is guarded by `auth` but not by role/ability.

**Function-level (BFLA) audit checklist:**
- [ ] Every privileged action (admin endpoints, role-changing mutations, destructive/bulk operations, financial actions) enforces a role/ability check, not just authentication.
- [ ] Adversarial test: call each admin/privileged endpoint with a **low-privilege actor's token** → MUST be 403.
- [ ] Hidden/undocumented methods (e.g. an extra HTTP verb on a resource route, a debug endpoint) are still authorized.
- [ ] Authorization is enforced server-side; client-side hiding of a button/menu item is UX, never the control.

## SSRF — Server-Side Request Forgery

(OWASP Top 10 A10:2021 + current list — verify at owasp.org.) Any feature where a **user-controlled URL reaches an outbound fetch** is an SSRF surface: webhooks, "import from URL", OG-image/link-preview fetchers, avatar-by-URL, PDF/screenshot renderers, RSS/feed importers, and AI "analyze this URL" tools. An attacker supplies a URL pointing at internal infrastructure or the cloud metadata endpoint to exfiltrate credentials or pivot.

```php
// BAD: user-controlled URL fetched directly. Attacker sends
// http://169.254.169.254/latest/meta-data/iam/security-credentials/...
$response = Http::get($request->input('image_url'));

// GOOD: validate scheme, resolve+block private/link-local/metadata ranges,
// enforce an egress allowlist, and disable redirects (or re-validate each hop).
$url = $request->validated()['image_url'];
abort_unless(SafeUrl::isAllowed($url), 422, 'URL not permitted');
$response = Http::withOptions(['allow_redirects' => false])
    ->timeout(5)
    ->get($url);
```

**SSRF audit checklist:**
- [ ] Inventory every outbound fetch fed by user input (`Http::get/post`, `file_get_contents($url)`, cURL, image/PDF/OG fetchers, webhook target URLs).
- [ ] Scheme allowlist: only `https` (and `http` if truly required) — reject `file://`, `gopher://`, `dict://`, `ftp://`.
- [ ] **Block link-local and cloud-metadata IPs**: `169.254.0.0/16` (incl. AWS/GCP/Azure metadata `169.254.169.254`), `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `::1`, `fc00::/7`, `fe80::/10`, and `0.0.0.0`.
- [ ] Resolve the hostname and validate the **resolved IP** (DNS-rebinding-aware): re-check after resolution, not just the literal string; ideally pin the validated IP for the actual request.
- [ ] Enforce an **egress allowlist** of permitted hosts/domains where the feature allows it (webhooks to known partners, avatar CDNs).
- [ ] Disable or bound redirects — a `200 https://allowed.example` can `302` to `169.254.169.254`; re-validate every hop or set `allow_redirects => false`.
- [ ] Apply timeouts and response-size caps; never reflect the raw upstream response/error to the user (blind-SSRF / info-leak).

**Audit grep:** search for outbound fetches taking request/user data: `Http::`, `file_get_contents`, `curl_`, `Guzzle`, `fetch(` (Node), with a URL sourced from `$request`/input/DB. Flag any without scheme+IP validation or an allowlist.

## Modern Authentication

(OWASP Top 10 A07:2021 Identification & Authentication Failures — verify at owasp.org.) Beyond password hashing and rate limiting, audit for current-era auth primitives.

| Check | Requirement | Severity |
|-------|-------------|----------|
| Passkeys / WebAuthn | If passwordless/2FA is offered, WebAuthn is present and hardened: verify RP ID + origin, enforce user verification, store/validate the signature counter (clone detection), reject `none` attestation where attestation matters | HIGH |
| MFA on privileged accounts | Admin / billing-owner accounts require a second factor (TOTP or passkey); SMS-only is a weak fallback | HIGH |
| OAuth2 PKCE | All OAuth2 authorization-code flows (esp. public/SPA/mobile clients) use **PKCE** (`code_challenge`/`code_verifier`, S256); the implicit grant is NOT used | HIGH |
| OAuth2 state / redirect_uri | `state` param validated (CSRF on the callback); `redirect_uri` is exact-match allowlisted, no open redirect | HIGH |
| Refresh-token rotation | Refresh tokens are **rotated** on every use, not long-lived static tokens | HIGH |
| Refresh-token reuse detection | A replayed (already-rotated) refresh token revokes the whole token family — detects theft | HIGH |
| Session fixation | Session ID regenerated on login/privilege change (`session()->regenerate()`) | MEDIUM |

**Audit check:** Detect the auth mechanism (Sanctum/Passport/Fortify/Socialite, custom WebAuthn). For OAuth2 client flows verify PKCE params; for token APIs verify rotation + reuse detection on the refresh path; for WebAuthn verify counter validation and origin/RP-ID binding.

## Input Validation

### FormRequest for Every Write Endpoint

Every POST/PATCH/DELETE endpoint must have a dedicated FormRequest:

```php
// app/Http/Requests/StorePostRequest.php
class StorePostRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true; // Already checked by controller's authorize()
    }

    public function rules(): array
    {
        return [
            'title' => 'required|string|max:255',
            'content' => 'required|string|max:10000',
            'published_at' => 'nullable|date|after:today',
        ];
    }
}

// app/Http/Controllers/PostController.php
public function store(StorePostRequest $request)
{
    // $request->validated() is guaranteed valid by FormRequest
    $post = auth()->user()->posts()->create($request->validated());
    return redirect()->route('posts.show', $post);
}
```

**NO raw $request->input():** Never use `$request->input()` directly — use `$request->validated()` only.

```php
// GOOD
$user = User::create($request->validated());

// BAD: Bypasses validation
$user = User::create($request->all());
$user = User::create($request->input());
```

**Audit check:** Every write endpoint must have a FormRequest. Search for controllers with `$request->input()` or `$request->all()` (data not validated).

## Data Protection

### No Mass Assignment Vulnerabilities

Models must explicitly define `$fillable` or `$guarded`:

```php
class User extends Model
{
    // Explicit whitelist (preferred)
    protected $fillable = ['name', 'email', 'password'];

    // OR explicit blacklist
    protected $guarded = ['role', 'admin_flag', 'verified_at'];
}
```

**Audit check:** Every model must have `$fillable` or `$guarded`. No empty `$guarded = []` without `$fillable`.

### No Raw SQL with User Input

Never interpolate user input into raw SQL:

```php
// GOOD: Parameterized query
User::whereRaw('email = ?', [$userEmail])->first();

// GOOD: Query builder (preferred)
User::where('email', $userEmail)->first();

// BAD: SQL injection vulnerability
DB::select("SELECT * FROM users WHERE email = '$email'");
```

**Audit check:** Search for `DB::raw()`, `DB::select()`, `DB::statement()` with string concatenation (not array bindings).

### PII Encryption at Rest

Sensitive fields (SSN, phone, payment details) must be encrypted:

```php
class User extends Model
{
    protected $casts = [
        'ssn' => 'encrypted',
        'phone' => 'encrypted',
    ];
}
```

**Audit check:** Check `$casts` in models with sensitive data. Verify `ENCRYPTION_KEY` is set in `.env`.

## API Security

### Rate Limiting on All API Routes

Every API endpoint must have rate limiting:

```php
// routes/api.php
Route::middleware(['api', 'throttle:60,1'])->group(function () {
    Route::apiResource('posts', PostController::class);
    Route::apiResource('users', UserController::class);
});

// Auth routes: stricter limits — ALL FOUR auth surfaces per CLAUDE.md § Security
// Defaults (login, register, password reset, email verification)
Route::middleware(['throttle:5,1'])->group(function () {
    Route::post('/login', LoginController::class);
    Route::post('/register', RegisterController::class);
    Route::post('/forgot-password', PasswordResetLinkController::class);
    Route::post('/email/verification-notification', EmailVerificationNotificationController::class);
});
```

**Audit check:** API routes must have `throttle:X,Y` middleware. Auth routes (login, register, password reset, email verification — the full CLAUDE.md list) ≤10 per minute.

### API Token Scoping

API tokens must be scoped to specific abilities:

```php
// app/Models/ApiToken.php
$user->createToken(
    'api-token',
    abilities: ['read-posts', 'write-posts'] // NOT ['*']
)->plainTextToken;
```

**In policies:**

```php
// app/Policies/PostPolicy.php
public function create(User $user): bool
{
    // Token users need explicit ability
    if ($user->tokenCan('write-posts')) {
        return true;
    }
    return $user->role === 'admin';
}
```

**Audit check:** API token creation must use `abilities` array (not wildcard). Check gate/policy logic validates `tokenCan()`.

### No Sensitive Data in URLs

Never pass PII or tokens in URL query parameters:

```php
// BAD: Password reset token in URL logged in proxy/browser history
redirect("/password-reset?token=$token");

// GOOD: Token in POST body or signed URL
$url = URL::signedRoute('password.reset', ['token' => $token]);
```

**Audit check:** Search for redirect/route calls with sensitive parameters (password, token, email, apikey, ssn).

## Secrets Management

### Secrets in .env Only

All secrets must be in `.env`, never hardcoded:

```env
# .env
DATABASE_PASSWORD=xyz123
STRIPE_SECRET_KEY=sk_live_...
MAIL_PASSWORD=email_password

# code: safe to read from config
'database' => [
    'password' => env('DATABASE_PASSWORD'),
],
```

**Audit check:** Grep config files for hardcoded secrets (not using `env()`). Whether `.env` is gitignored is per-project policy — see § .gitignore Policy below.

### .gitignore Policy (project-conditional)

Default posture when the project's CLAUDE.md is silent:

```
.env
.env.local
*.key
config/secrets.php
```

**Audit check:** `.env*` tracking is per-project policy (CLAUDE.md § Security Defaults: `.env*` files may be committed per project policy). If the project's stated policy is gitignored `.env` (or policy is silent), verify the entries above and check git history for accidental commits. If the project policy explicitly allows committed `.env*`, a tracked `.env` is NOT a finding — do not flag it (v-build's staging rules already treat it as expected and safe).

### No Secrets in Git History

Use `git log -p` to scan for leaked secrets:

```bash
# Exclude the safe env()/config() idiom (e.g. `env('DB_PASSWORD')`) so
# routine env-var reads don't drown out real leaked literals.
git log -p | grep -i "password\|key\|secret\|token" | grep -viE "\.env|config\(|\benv\(" | head -10
```

**Audit check:** If secrets found in git, rotate them immediately.

## Headers

### HSTS (HTTP Strict Transport Security)

Force HTTPS:

```php
// app/Http/Middleware/HttpsRedirect.php
// `app()` helper, not `$this->app` — a plain middleware class has no `$app`
// property unless one is constructor-injected and assigned explicitly.
// Default-safe inversion (framework-pitfalls.md Class 2 — env-keyed
// half-guard): allow-list local/testing rather than single-out 'production',
// so preview/staging/demo inherit the header automatically instead of
// silently shipping without it.
if (! app()->environment(['local', 'testing'])) {
    $response->header('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload');
}
```

**Audit check:** Verify `Strict-Transport-Security` header present on every non-local/testing environment (`~/.claude/skills/references/framework-pitfalls.md § Class 2 — Env-keyed half-guard` — flag a guard keyed only to `environment('production')`, since it silently excludes preview/staging).

### X-Content-Type-Options

Prevent MIME sniffing:

```php
// app/Http/Middleware/SecurityHeaders.php
$response->header('X-Content-Type-Options', 'nosniff');
```

**Audit check:** Verify header sent. Prevent browsers from guessing content type.

### X-Frame-Options

Prevent clickjacking:

```php
$response->header('X-Frame-Options', 'DENY'); // Never in iframe
// OR
$response->header('X-Frame-Options', 'SAMEORIGIN'); // Same-origin only
```

**Audit check:** Verify header present.

### Content-Security-Policy (if applicable)

Restrict script execution:

```php
$response->header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline' cdn.example.com; style-src 'self' 'unsafe-inline'");
```

**Audit check:** If CSP enabled, verify no overly-permissive directives (no `*`).

## Monitoring & Alerting

### Failed Login Attempts

Log and alert on repeated failures:

```php
// app/Http/Controllers/LoginController.php
public function authenticate(LoginRequest $request)
{
    // Not $request->credentials() — that method doesn't exist on Request,
    // FormRequest, or Breeze's generated LoginRequest (which builds the
    // array inline: $this->only('email', 'password')). Auth::attempt()
    // takes a plain credentials array.
    if (!Auth::attempt($request->only('email', 'password'))) {
        Log::warning('Failed login attempt', [
            'email' => $request->email,
            'ip' => $request->ip(),
            'user_agent' => $request->userAgent(),
        ]);

        // Alert if >5 failures from same IP
        $recentFailures = Cache::get("login_failures.{$request->ip()}", 0);
        if ($recentFailures > 5) {
            Notification::route('mail', config('admin.email'))
                ->notify(new SuspiciousActivityAlert($request->ip()));
        }

        return back()->withErrors(['email' => 'Invalid credentials']);
    }

    Cache::forget("login_failures.{$request->ip()}");
    return redirect()->intended('/dashboard');
}
```

**Audit check:** Verify failed login logging exists. Check for alerting thresholds (>5 per hour).

### Suspicious Activity Detection

Monitor for data exfiltration patterns:

```php
// app/Jobs/DetectSuspiciousActivity.php
// Alert on: bulk exports, unusual data access patterns, rapid account creation
```

**Audit check:** Search for monitoring/alerting hooks in critical operations (admin actions, bulk exports, data access).

## CI/CD Supply-Chain Security

(OWASP Top 10 A08:2021 Software & Data Integrity Failures + CI/CD-SEC — verify at owasp.org.) The build pipeline is part of the attack surface. A malicious or compromised GitHub Action runs with repo secrets and can exfiltrate them or tamper with artifacts. Scan `.github/workflows/` (and any other CI config).

```yaml
# BAD: third-party action pinned to a moving tag — the tag can be repointed
# to malicious code after you've reviewed it.
- uses: some-org/some-action@v3

# GOOD: pin to a full commit SHA (immutable), with the version in a comment.
- uses: some-org/some-action@8f4b7c2e0a... # v3.1.0
```

| Check | Pattern | Severity |
|-------|---------|----------|
| Unpinned third-party action SHAs | `uses: org/action@v1` / `@main` / `@<branch>` instead of a full 40-char commit SHA (first-party `actions/*` by tag is lower risk but SHA-pinning is best practice) | HIGH |
| `pull_request_target` misuse | `on: pull_request_target` that then **checks out and runs PR-author code** (`actions/checkout` with the PR ref, then build/test) — runs untrusted code WITH secrets and write token | CRITICAL |
| Secret exfiltration patterns | Steps that pipe `${{ secrets.* }}` / env to `curl`, `nc`, an external webhook, or base64+network; `printenv`/`env` dumped to logs; secrets passed to untrusted actions | CRITICAL |
| Over-broad `GITHUB_TOKEN` permissions | Missing top-level `permissions:` block (defaults to broad write) — should be least-privilege `permissions: { contents: read }` and elevated only per-job | HIGH |
| `script injection` via untrusted input | `${{ github.event.pull_request.title }}` / issue body / branch name interpolated directly into a `run:` shell step (command injection) | HIGH |
| Self-hosted runner on public repo | Untrusted forks running on a self-hosted runner | HIGH |

**Audit grep:**
```bash
# Unpinned action refs (flag anything not pinned to a 40-hex SHA)
grep -rnE 'uses:\s*[^@]+@(v?[0-9]|main|master|latest|[a-z-]+)\b' .github/workflows/ 2>/dev/null

# pull_request_target — inspect each for PR-code checkout
grep -rn "pull_request_target" .github/workflows/ 2>/dev/null

# Secret-to-network / secret-in-log exfiltration smells
grep -rnE 'secrets\.|printenv|env\b' .github/workflows/ 2>/dev/null | grep -iE 'curl|wget|nc |http|base64'

# Missing least-privilege permissions block
grep -rL "permissions:" .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null
```

**Audit check:** Every workflow pins third-party actions to a commit SHA, declares least-privilege `permissions:`, and never runs untrusted PR code with secrets. `pull_request_target` workflows that check out PR code are CRITICAL until proven safe.

## LLM / Agent Attack Surface

(OWASP **LLM** Top 10 — verify at owasp.org. Extends the direct-prompt-injection check in the AI/LLM integration domain.) When the app calls an LLM or runs an agent/tool loop, three classes beyond direct prompt injection must be audited:

| Class | What it is | Audit check | Severity |
|-------|------------|-------------|----------|
| **Direct prompt injection** (existing) | User text overrides the system prompt / instructions | User input concatenated into prompts without delimiting/guardrails; system prompt not isolated; output not validated before display/action | HIGH |
| **Indirect prompt injection** | Malicious instructions hidden in **retrieved/external content** the model ingests — RAG documents, fetched web pages, emails, PDFs, tool results, user-uploaded files. The attacker doesn't talk to the model; they plant instructions where the model will read them | Treat all retrieved/tool-returned content as **untrusted data, not instructions** — fence it, never let retrieved content carry privileged directives; verify the system prompt re-asserts trust boundaries after each retrieval; consider an injection classifier on retrieved chunks | HIGH |
| **Excessive agency / tool abuse** | The agent has broader tool scopes/permissions than the task needs, so a successful injection causes real damage (send email, delete data, spend money, call internal APIs) | Inventory every tool the agent can call; enforce **least-privilege tool scopes** (read-only where possible); require human-in-the-loop confirmation for irreversible/financial/destructive tool calls; rate-limit and audit-log tool invocations; never give one agent both untrusted-content ingestion AND high-privilege tools without a gate | HIGH |

**Audit checklist (LLM/agent):**
- [ ] Retrieved content (RAG, fetched URLs, file uploads, tool outputs) is fenced as data and cannot inject instructions (indirect prompt injection).
- [ ] System prompt / trust boundary is re-asserted and not overridable by ingested content.
- [ ] Each tool the agent can invoke is scoped to least privilege; destructive/financial/irreversible tools gate on explicit confirmation.
- [ ] Tool inputs derived from model output are validated server-side (the model is an untrusted input source to your own APIs).
- [ ] SSRF rules (above) apply to any agent tool that fetches a URL the model produced.
- [ ] Tool invocations are rate-limited and audit-logged (`user_id`, tool, args, result) for abuse detection.

## Verification Checklist

Run this audit checklist against the codebase:

- [ ] All non-public routes have `auth` middleware
- [ ] Session config: `secure: true`, `http_only: true`, `same_site: lax`
- [ ] CSRF middleware enabled for all POST/PATCH/DELETE
- [ ] Every resource has a Policy with authorize() calls (Laravel 11+ auto-discovery recognized — no AuthServiceProvider required)
- [ ] **IDOR/BOLA:** every object-ID endpoint verifies per-record ownership; "fetch with actor B's token" returns 403/404
- [ ] **BFLA:** every privileged/admin/destructive action enforces a role/ability check, not just auth
- [ ] **SSRF:** every user-controlled-URL fetch validates scheme + resolved IP, blocks 169.254.169.254 & private ranges, enforces egress allowlist, bounds redirects
- [ ] **Modern auth:** OAuth2 flows use PKCE + state; refresh tokens rotate with reuse detection; WebAuthn (if present) validates counter + origin/RP-ID
- [ ] Every write endpoint has a FormRequest (no $request->input() or $request->all())
- [ ] Models have $fillable or $guarded (no empty $guarded)
- [ ] No raw SQL with user input (all parameterized)
- [ ] Sensitive data encrypted in database
- [ ] All API routes throttled (60 req/min or less, auth ≤10)
- [ ] API tokens scoped (not `['*']`)
- [ ] No sensitive data in URL parameters
- [ ] All secrets in `.env*` (never hardcoded in source); `.env` tracking matches the project's stated policy (default when silent: gitignored)
- [ ] No hardcoded credentials in config files
- [ ] **CI/CD:** `.github/workflows/` actions pinned to commit SHAs, least-privilege `permissions:`, no `pull_request_target` running untrusted PR code with secrets, no secret-exfil patterns
- [ ] **LLM/agent (if applicable):** retrieved content fenced against indirect prompt injection; agent tools least-privilege; destructive tool calls gated
- [ ] HSTS, X-Content-Type-Options, X-Frame-Options headers present
- [ ] Failed login logging and alerting configured
