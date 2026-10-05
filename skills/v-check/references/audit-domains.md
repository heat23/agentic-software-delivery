# Audit Domain Reference — v-check

_Last reviewed: 2026-07-06 (theme-consistency sweep B: security/performance/UI-states alignment)_

Detailed detection patterns, grep commands, and checklists for each audit domain.
Read this file when executing audit domains 1-11.

---

## Audit Domains

### 1. SECURITY (Always P0 Priority)

**Tracks OWASP Top 10 (current) + OWASP LLM Top 10 — verify category list at owasp.org.** Full policy + adversarial test steps in `references/v-security-baseline.md`.

| Check | Pattern | Risk |
|-------|---------|------|
| Missing auth | Controllers with no authorization call — match `Gate::authorize(`, `$this->authorize(`, `->can(`, or a `can:` route middleware. **Do NOT grep for `$this->authorize` alone:** Laravel 11+ dropped `AuthorizesRequests` from the base controller, so correct modern code uses `Gate::authorize()` and a single-idiom grep flags it as missing (false-positive HIGH on correct code). See `v-security-baseline.md` § Authorization, which owns the nuanced rule. | HIGH |
| **IDOR / BOLA** (object-level authz) | Object-ID endpoint without per-record ownership check; "fetch with actor B's token" returns 200 | CRITICAL |
| **BFLA** (function-level authz) | Privileged/admin/destructive action guarded by `auth` only, no role/ability check | CRITICAL |
| **SSRF** | User-controlled URL reaching outbound fetch without scheme+IP validation / egress allowlist (blocks 169.254.169.254 & private ranges) | CRITICAL |
| **Modern auth gaps** | OAuth2 without PKCE/state; refresh tokens not rotated / no reuse detection; WebAuthn without counter+origin validation | HIGH |
| Rate limiting gaps | Auth routes without throttle | HIGH |
| Mass assignment | Models without `$fillable`/`$guarded` | HIGH |
| SQL injection | `whereRaw` without bindings | CRITICAL |
| XSS vectors | `{!! !!}` without `Purify::clean`, or `dangerouslySetInnerHTML` without `DOMPurify.sanitize()` + explicit allowlist — canon-sanctioned sanitized usage (CLAUDE.md § Security Defaults) is NOT a finding | HIGH |
| CSRF disabled | Routes in `$except` without webhook sig | HIGH |
| File upload risks | Missing MIME/size/extension validation server-side (client `accept` attr is UX, not validation) | MEDIUM |
| Secrets exposed | Hardcoded keys in source; tracked `.env` ONLY where project policy forbids it (CLAUDE.md § Security Defaults: `.env*` may be committed per project policy) | CRITICAL |
| **CI/CD supply-chain** | `.github/workflows/` unpinned action SHAs, `pull_request_target` running PR code, secret-exfil patterns | HIGH–CRITICAL |
| **LLM/agent attack surface** | Indirect prompt injection via retrieved content; over-broad agent tool scopes (excessive agency) — see Domain 8 | HIGH |
| Dependency vulns | `composer audit && npm audit` | VARIES |
| Rate limit + login | IP limits without clear on login | HIGH |

**Key grep patterns:**

> **BSD/macOS grep note:** macOS's `grep` is "BSD grep, GNU compatible" and DOES honor `\|` as alternation in default (BRE) mode (a GNU-compatible extension) — `grep "a\|b"` is not a silent false "clean" on this platform. Still prefer `grep -E "a|b"` (ERE) for portability/readability: all multi-alternative patterns below use `-E`, so there is no behavior change either way.

```bash
# Authorization gaps
grep -rnE "public function store|public function update|public function destroy" app/Http/Controllers --include="*.php" | head -20
grep -rnE "this->authorize|Gate::allows|can\(" app/Http/Controllers --include="*.php" | wc -l

# IDOR / BOLA — object-ID lookups WITHOUT ownership scoping or authorize().
# Flag implicit route-model-binding / find() that isn't followed by authorize() or a scoped relationship.
grep -rnE "::find\(|::findOrFail\(|Route::(get|put|patch|delete).*\{" app/Http/Controllers routes/ --include="*.php" | head -20
grep -rnE "->authorize\(|->where\((['\"])(team_id|tenant_id|organization_id|user_id)|currentTeam->|auth\(\)->user\(\)->" app/Http/Controllers --include="*.php" | wc -l
# Low ownership-check count vs many ID endpoints => likely IDOR. Adversarial: re-fetch with actor B's token (see v-security-baseline.md § IDOR / Broken Object-Level Authorization).

# BFLA — privileged/destructive actions without a role/ability gate (auth alone is insufficient)
grep -rnE "destroy|forceDelete|->delete\(|refund|impersonate|admin" app/Http/Controllers --include="*.php" | head -20
grep -rnE "->hasRole\(|->can\(|abort_unless|authorize\(|middleware\(['\"]role|middleware\(['\"]can" app/Http/Controllers routes/ --include="*.php" | wc -l

# SSRF — user-controlled URL reaching an outbound fetch (webhooks, import-from-URL, OG/avatar fetchers)
grep -rnE "Http::(get|post|head)\(|file_get_contents\(|curl_exec|GuzzleHttp" app/ --include="*.php" -n | head -20
# For each hit, confirm the URL is request/user-derived AND validated (scheme + resolved IP + allowlist). Cross-check against:
grep -rnE "169\.254\.169\.254|isPrivate|FILTER_FLAG_NO_PRIV_RANGE|allow_redirects|allowlist|allowed_hosts" app/ config/ --include="*.php" | head -10
# Any user-URL fetch with NO such guard = P0_CRITICAL SSRF. See v-security-baseline.md § SSRF.

# Modern auth — OAuth2 PKCE, refresh-token rotation/reuse, WebAuthn
grep -rnE "code_challenge|code_verifier|PKCE|pkce" app/ config/ --include="*.php" | head -5   # PKCE present?
grep -rnE "refresh_token|refreshToken|token.*rotat|reuse" app/ --include="*.php" | head -10
grep -rnE "webauthn|WebAuthn|publicKeyCredential|signature.*counter|attestation" app/ config/ composer.json --include="*.php" 2>/dev/null | head -5

# SQL injection
grep -rnE "whereRaw|selectRaw|DB::raw" app/ --include="*.php" | grep -vE "bindings|\?"

# XSS
grep -rnE "dangerouslySetInnerHTML|\{!! " resources/ --include="*.tsx" --include="*.blade.php"

# Secrets. Exclude the safe env()/config() idiom too (e.g. env('DB_PASSWORD'))
# — without \benv\(, that idiom false-positives as a "leaked" secret.
git grep -iE "api.key|secret|password" -- "*.php" "*.ts" "*.tsx" | grep -vE "\.env|config\(|\benv\("

# CORS misconfiguration
grep -rnE "allowed_origins|allowedOrigins|Access-Control-Allow-Origin" config/ app/ --include="*.php" | grep -i "\*"

# Content Security Policy (CSP)
grep -rnE "Content-Security-Policy|content_security_policy|csp" config/ app/Http/Middleware/ --include="*.php" | head -5
# If no results: CSP status is not confirmed from grep alone — mark as not_verified and note it may be configured at the web server or CDN layer

# API route auth middleware
grep -rnE "Route::middleware.*auth:sanctum|->middleware.*auth:sanctum" routes/api.php | head -10
grep -rn "Route::" routes/api.php | grep -vE "middleware|//|group" | head -10
# Unprotected API routes without auth middleware = P0_CRITICAL

# CI/CD supply-chain — scan .github/workflows/ (see v-security-baseline.md § CI/CD Supply-Chain Security)
grep -rnE 'uses:\s*[^@]+@(v?[0-9]|main|master|latest|[a-z-]+)\b' .github/workflows/ 2>/dev/null | head -20   # unpinned action refs (not 40-hex SHA)
grep -rn "pull_request_target" .github/workflows/ 2>/dev/null                                                # inspect each for untrusted PR-code checkout
grep -rnE 'secrets\.|printenv|env\b' .github/workflows/ 2>/dev/null | grep -iE 'curl|wget|nc |http|base64'   # secret-exfil smells
grep -rL "permissions:" .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null                         # missing least-privilege permissions block
```

#### Supply Chain Security
| Check | Pattern | Severity |
|-------|---------|----------|
| Typosquatting risk | Packages with names similar to popular packages but slightly misspelled | HIGH |
| Package health | Dependencies with 0 commits in 12+ months (abandoned) | MEDIUM |
| Maintainer changes | Packages with recent maintainer transfers (possible takeover) | HIGH |
| Lockfile integrity | `package-lock.json` / `composer.lock` committed and up-to-date | HIGH |
| Install scripts | Packages with `postinstall` scripts that execute arbitrary code | MEDIUM |

**Detection for non-registry sources:**
```bash
npm ls --json | jq '.dependencies | to_entries[] | select(.value.resolved | test("^https://registry.npmjs.org") | not)'
```

### 1b. SaaS-SPECIFIC SECURITY (P0-P1)

These checks apply when the application has multi-tenant features, billing, or team management.

#### Tenant Data Isolation

```bash
# Find models with team/tenant scoping
grep -rnE "team_id|tenant_id|organization_id|workspace_id" app/Models --include="*.php" | head -10

# Find controllers querying without tenant scope
grep -rnE "::all\(\)|::get\(\)|::paginate\(" app/Http/Controllers --include="*.php" | head -10

# Check for global scopes that enforce tenant isolation
grep -rnE "addGlobalScope|booted.*static.*fn" app/Models --include="*.php" | head -10
```

| Check | Pattern | Risk |
|-------|---------|------|
| Unscoped queries on tenant-owned models | `Model::all()` or `Model::get()` without `where('team_id', ...)` | **CRITICAL** — data leakage across tenants |
| Missing global scope on tenant models | Models with `team_id` column but no global scope or query scope applied | **HIGH** — easy to forget scoping in new queries |
| Direct ID lookups without ownership check (IDOR/BOLA) | `Model::find($id)` without verifying the record belongs to current team. **This is the IDOR/BOLA discipline — run the full object-level + function-level (BFLA) checklist and adversarial "fetch with actor B's token" test in `references/v-security-baseline.md` § IDOR/BOLA + BFLA**, not just this one line. | **CRITICAL** — IDOR / cross-tenant access |
| API responses including tenant_id | JSON resources exposing internal `team_id` or `organization_id` | **MEDIUM** — information disclosure |

#### Race Conditions

```bash
# Find subscription/billing state changes without locking
grep -rnE "->update\(|->save\(\)" app/Services --include="*.php" -B3 | grep -E "subscription|billing|plan|credit" | head -10

# Check for DB::transaction usage around multi-step mutations
grep -rn "DB::transaction" app/Services app/Http/Controllers --include="*.php" | wc -l

# Find form submissions without idempotency protection
grep -rn "public function store" app/Http/Controllers --include="*.php" | wc -l
```

| Check | Pattern | Risk |
|-------|---------|------|
| Subscription state change without DB lock | `$subscription->update(['status' => ...])` without `lockForUpdate()` or transaction | **HIGH** — double-charge on concurrent requests (pattern-match evidence → `confidence: medium`; `/v-bug-hunt` deliberately caps unreproduced race findings at P3 — its repro-capable pass is the escalation path, not a contradiction) |
| Multi-step mutation without transaction | Create + update + notify without `DB::transaction()` | **HIGH** — partial state on failure |
| Payment form without idempotency key | Stripe charge/subscription creation without idempotency | **HIGH** — double-charge on retry/double-click |
| Webhook handler without deduplication | Webhook endpoint processes same event ID multiple times | **HIGH** — duplicate side effects; **CRITICAL** for billing/payment webhooks (duplicate charge/refund/entitlement grant). Per `[[v-core-severity]]` severity is absolute — a prior lower rating (e.g. from an earlier audit) never suppresses re-raising this at its true severity. |

#### Missing Database Indexes

```bash
# Find foreign key columns that may lack indexes
grep -rnE "foreignId|foreign\(" database/migrations --include="*.php" | head -10
grep -rn "->index()" database/migrations --include="*.php" | wc -l

# Check for tenant scoping columns
grep -rnE "team_id|tenant_id|organization_id" database/migrations --include="*.php" | grep -vE "index|foreign" | head -10

# Find status/state columns commonly used in WHERE clauses
grep -rnE "'status'|'state'|'type'" database/migrations --include="*.php" | grep -v "index" | head -10
```

| Check | Pattern | Risk |
|-------|---------|------|
| Missing index on tenant_id/team_id | `$table->foreignId('team_id')` without `->index()` or explicit index migration | **HIGH** — every tenant-scoped query is a full table scan |
| Missing index on status/state columns | Columns used in dashboard filters without index | **MEDIUM** — slow dashboard queries at scale |
| Missing composite index on common query patterns | Queries filtering on (team_id, status) or (team_id, created_at) without composite index | **MEDIUM** — inefficient even with individual indexes |
| Foreign keys without index | `$table->foreignId(...)` without `constrained()` (which adds index) or explicit `->index()` | **MEDIUM** — slow JOIN queries |

### 2. PERFORMANCE

#### 2.1 Lazy Loading Violations (Laravel-Specific, CRITICAL Priority)

**What:** Eloquent relationships accessed without eager loading cause N+1 queries and throw `LazyLoadingViolationException` in apps with `Model::preventLazyLoading()` enabled.

**Detection:**
```bash
# Check if lazy loading prevention is enabled
grep -rn "preventLazyLoading" app/Providers --include="*.php"

# Check for relationships accessed inside loops (common N+1 pattern)
grep -rnE "->each\(|foreach" app/ --include="*.php" -A5 | grep -E "\->[a-zA-Z]+" | head -10

# Count load/with usage (low vs total model calls = risk)
echo "Eager loads:"; grep -rnE "->load\b|->loadMissing\b|->with\(" app/ --include="*.php" | wc -l
```

**Pattern to flag:**
```php
// BAD - lazy loading violation if preventLazyLoading enabled
$user->posts;                    // relationship access without eager load
foreach ($orders as $order) {
    $order->items->count();      // N+1: fires query per iteration
}

// GOOD - eager load before accessing
$user->loadMissing('posts');
$user->posts;                    // safe

$orders->load('items');
foreach ($orders as $order) {
    $order->items->count();      // safe: no extra query
}
```

**Check project CLAUDE.md** for project-specific relationships requiring eager loading (e.g., billing library nested relationships like `items.subscription`). Apply those patterns when scanning.

**Add to audit output as P0 if found.**

### 2.2 General N+1 Queries and Performance

| Check | Pattern | Impact |
|-------|---------|--------|
| N+1 queries | `->get()` in loop without `->with()` | HIGH |
| Missing indexes | FK columns without index | MEDIUM |
| Unbounded queries | No LIMIT on large tables | HIGH |
| Sync external calls | HTTP in request cycle | HIGH |
| Large payloads | >100KB JSON responses | MEDIUM |
| Bundle size | Exceeds the project-configured budget (`package.json`/`vite.config.js` — per v-pre-flight, never fabricate a default); if no budget is configured, >500KB is a `confidence: low` heuristic flag only | MEDIUM |
| Missing pagination | Lists without paginate() | MEDIUM |
| No caching | Repeated identical queries without Cache | MEDIUM |
| Missing HTTP cache | No Cache-Control/ETag headers on static responses | MEDIUM |
| Eager loading gaps | Nested relationship chains without nested `with()` | HIGH |
| **Lazy loading violations (CRITICAL)** | **Eloquent methods called without eager loading relationships** | **CRITICAL** |

**Key grep patterns:**
```bash
# N+1 detection
grep -rn "->get()" app/Http/Controllers --include="*.php" -B5 | grep -v "with("

# External calls in request
grep -rnE "Http::get|Http::post|file_get_contents" app/Http/Controllers --include="*.php"

# Unbounded queries
grep -rnE "->all\(\)|->get\(\)" app/ --include="*.php" | grep -vE "paginate|take|limit"

# Missing cache on repeated queries
grep -rnE "->get\(\)|->first\(\)|->find\(" app/Http/Controllers --include="*.php" | grep -vE "Cache|cache|remember"

# Eager loading gaps (nested relationships)
grep -rn "->with(" app/ --include="*.php" | grep -v "\."

# CRITICAL: Cashier methods without proper eager loading (verify required relationships are loaded)
grep -rnE "->cancel\(\)|->resume\(\)|->swap\(\)" app/ --include="*.php" -B3 | grep -v "->load("

# CRITICAL: Check for Model::preventLazyLoading()
grep -rn "preventLazyLoading" app/Providers --include="*.php"
```

### 3. TEST COVERAGE

When "Test coverage deep dive" is selected, this becomes the primary domain — run all subsections thoroughly. For other audit types, run 3a and 3b only.

#### 3a. Baseline & Coverage Metrics

```bash
# Run test suite
php artisan test 2>&1 | tail -20
npm test -- --run 2>&1 | tail -20

# Coverage metrics
php artisan test --coverage 2>/dev/null | tail -30
npm run test:coverage 2>/dev/null | tail -30

# Count tests
php artisan test --list 2>/dev/null | wc -l
ls tests/Feature tests/Unit 2>/dev/null
```

| Check | Target | Priority |
|-------|--------|----------|
| All tests pass | 0 failures | P0 |
| Backend line coverage | >= 80% | P1 |
| Frontend line coverage | >= 80% | P1 |
| Auth/payment coverage | 100% | P0 |

#### 3b. Missing Test Files

Critical user flows (authentication, authorization, payments, and data mutation) should have test coverage. Use the file scan below to identify likely gaps, then prioritize by user impact instead of strict file-to-file correspondence:

```bash
# Controllers without test files
for f in app/Http/Controllers/*.php; do
  name=$(basename "$f" .php)
  if [ "$name" != "Controller" ]; then
    found=$(find tests -name "*${name}*" 2>/dev/null | head -1)
    [ -z "$found" ] && echo "UNTESTED: $f"
  fi
done

# Services without test files
for f in app/Services/*.php; do
  name=$(basename "$f" .php)
  found=$(find tests -name "*${name}*" 2>/dev/null | head -1)
  [ -z "$found" ] && echo "UNTESTED: $f"
done

# React pages without test files
for f in resources/js/Pages/**/*.tsx; do
  name=$(basename "$f" .tsx)
  found=$(find resources/js -name "*${name}*.test.*" 2>/dev/null | head -1)
  [ -z "$found" ] && echo "UNTESTED: $f"
done
```

#### 3c. Scenario Coverage Analysis (Deep Dive)

For each controller/service, read the test file and check for scenario coverage:

| Scenario Type | What to Look For | Priority |
|---------------|-----------------|----------|
| **Happy path** | Success case for each public method/endpoint | P0 |
| **Authentication** | Unauthenticated user gets 401/redirect | P0 |
| **Authorization** | Wrong user/role gets 403 | P0 |
| **Validation** | Invalid input returns 422 with correct errors | P1 |
| **Not found** | Missing resource returns 404 | P1 |
| **Boundary values** | Empty strings, zero, max length, null | P1 |
| **Edge cases** | Duplicate submissions, concurrent operations, expired tokens | P2 |
| **Error recovery** | External service failure handled gracefully | P1 |

```bash
# Check for auth tests
grep -rnE "assertUnauthorized|assertRedirect.*login|401|assertStatus\(401\)" tests/ --include="*.php" | wc -l

# Check for authorization tests
grep -rnE "assertForbidden|403|assertStatus\(403\)" tests/ --include="*.php" | wc -l

# Check for validation tests
grep -rnE "assertSessionHasErrors|assertInvalid|422|assertStatus\(422\)" tests/ --include="*.php" | wc -l

# Check for 404 tests
grep -rnE "assertNotFound|404|assertStatus\(404\)" tests/ --include="*.php" | wc -l

# Check assertion density (low assertion count = weak tests)
total_tests=$(grep -rnE "it\(|test\(" tests/ --include="*.php" | wc -l)
total_asserts=$(grep -rnE "assert|expect\(" tests/ --include="*.php" | wc -l)
echo "Tests: $total_tests, Assertions: $total_asserts, Ratio: $(( total_asserts / (total_tests > 0 ? total_tests : 1) ))"
```

#### 3d. Critical Path Verification

These flows MUST have end-to-end test coverage before go-live:

| Critical Path | Tests Must Cover |
|--------------|-----------------|
| Registration | Success, duplicate email, invalid input, email verification |
| Login | Success, wrong password, non-existent user, rate limiting |
| Password reset | Request, token valid, token expired, token invalid |
| Payment flow | Subscribe, webhook received, subscription cancelled, failed payment |
| Data mutations | Create, update, delete + authorization for each |

```bash
# Verify auth flow coverage
grep -rnE "register|login|password.*reset|verify.*email" tests/Feature --include="*.php" -l

# Verify payment flow coverage (if applicable)
grep -rnE "subscribe|webhook|payment|invoice" tests/Feature --include="*.php" -l

# Verify CRUD coverage for each model
for model in $(ls app/Models/*.php 2>/dev/null | xargs -I{} basename {} .php); do
  count=$(grep -rin "$model" tests/ --include="*.php" -l 2>/dev/null | wc -l)
  echo "$model: $count test files"
done
```

#### 3e. Frontend Test Quality

```bash
# React components with test files
find resources/js -name "*.test.tsx" -o -name "*.test.ts" 2>/dev/null | wc -l

# Check for user interaction testing (not just render tests)
grep -rnE "userEvent|fireEvent|click|type|keyboard" resources/js --include="*.test.tsx" | wc -l

# Check for render-only tests (weak coverage)
grep -rn "render(" resources/js --include="*.test.tsx" -l | while read f; do
  interactions=$(grep -cE "userEvent|fireEvent|click|type" "$f" 2>/dev/null)
  [ "$interactions" -eq 0 ] && echo "RENDER-ONLY: $f"
done
```

| Check | Pattern | Priority |
|-------|---------|----------|
| User interactions tested | `userEvent.click`, `fireEvent.change` present | P1 |
| Form submission tested | Submit + validation + success/error states | P1 |
| Loading/error states tested | Assertions on loading spinners, error messages | P2 |
| Render-only tests flagged | Tests that only call `render()` with no interactions | P2 |

### 4. UX & COPY

| Check | Pattern | Impact |
|-------|---------|--------|
| Empty states | Tables without empty message | MEDIUM |
| Loading states | No skeleton/spinner | MEDIUM |
| Error messages | Generic "Error occurred" | MEDIUM |
| Copy accuracy | UI text doesn't match behavior | HIGH |
| Theme-token contrast | Colors not resolving to canonical tokens (light value must come from `[data-theme="light"]`) | MEDIUM |
| Form data loss | Links in forms cause data loss | HIGH |

**Key grep patterns:**
```bash
# Missing empty states — MULTILINE-AWARE.
# A single-line `grep ... | grep -v "Empty|empty|No "` is BROKEN: the `.length === 0`
# conditional and its empty-state JSX (<EmptyState/>, "No items found") almost always
# live on DIFFERENT lines, so the line-scoped grep -v can never see the message and
# false-flags every list. Use ripgrep multiline (-U) to inspect the surrounding block,
# or grep -A6 context, then read the block. If neither is available, dispatch a claude -p subprocess (v-dispatch-subagent.sh)
# for an AST/JSX-aware check (Domain 10) — do NOT present a single-line grep as evidence.
rg -nU -g '*.tsx' -g '*.jsx' '\.length\s*===?\s*0' resources/js 2>/dev/null | head -20   # locate length-0 conditionals (rg has NO built-in tsx type — use -g globs)
# For each hit, inspect the surrounding render block for an empty-state branch:
grep -rnE -A6 '\.length\s*===?\s*0' resources/js --include="*.tsx" | grep -iE "Empty|No .*(found|yet|results|items)|nothing" || echo "REVIEW: list(s) with .length===0 but no empty-state copy in the next 6 lines — verify in an Agent/AST pass"

# Hardcoded status colors not resolving to canonical tokens (single-class, line-local — grep is reliable here;
# flag regardless of dark: twins — theming is html[data-theme] token switching, not per-element variants)
grep -rnE "text-(green|red|amber|blue)-[567]00" resources/js --include="*.tsx"

# Generic error messages (string literals — line-local, grep is reliable)
grep -rnE '"Error"|"Something went wrong"|"An error occurred"' resources/js --include="*.tsx"
```

> **Note (multi-line JSX):** empty-state, loading-state, and accessibility checks operate on JSX that spans multiple lines. Line-scoped `grep`/`grep -v` pipelines produce both false negatives (missed violations across lines) and false positives (well-handled cases the `grep -v` couldn't see). Prefer `rg -U`/`rg --multiline` or `grep -A/-B` context, and when a reliable text match isn't possible, **dispatch a fork-safe `claude -p` subprocess (Domain 10, via `v-dispatch-subagent.sh`) for an AST-aware pass** rather than reporting a broken single-line grep as evidence.

#### Visual Craft (per _v-design.md)

| Check | Detection | Severity |
|-------|-----------|----------|
| Cards off the 3-tier spec system | Cards not on panel → card → nested tiering (`var(--surface)` / `var(--surface-elevated)` / top-border detail) | MEDIUM |
| Token compliance | Hardcoded hex/non-semantic classes in app UI — BLOCK-level per `_v-design.md § Visual Craft Gate` Check 1 (exemptions: print and shared-report pages advisory; a QR-code settings page's `bg-white` grandfathered) | HIGH |
| Off-mechanism theming | `.dark`/`dark:`-class strategy or `prefers-color-scheme`-only switching instead of `html[data-theme]` — BLOCK-level per `_v-design.md § Visual Craft Gate` Check 2 | HIGH |
| Non-canonical elevation | `shadow-xl`/`2xl`, heavy 2px+ borders, ad-hoc shadows — spec pairs 1px `var(--border)` with `--shadow`/`--shadow-lg` (advisory in canon) | MEDIUM |
| Typography hierarchy | Size-only headings; weights off the fixed 400/500/600/700 scale, no weight/tracking variation | MEDIUM |
| Glassmorphism in app UI | `backdrop-filter` in Pages/ or Components/ | MEDIUM |
| Arbitrary z-index | `z-[...]` values outside the layer system (`_v-design.md § Z-Index Layer Definitions`; grep: `grep -rn 'z-\[' --include="*.tsx" \| grep -v 'z-\[10\]\|z-\[20\]\|z-\[30\]\|z-\[40\]\|z-\[50\]\|z-\[60\]\|z-\[100\]\|z-\[200\]'` — 100/200 are the canonical sidebar/hamburger values) | MEDIUM |

### 5. TECH DEBT

| Check | Pattern | Impact |
|-------|---------|--------|
| TODO comments | `// TODO`, `// FIXME` | VARIES |
| Dead code | Unused functions/classes | LOW |
| Inconsistent patterns | Mixed approaches | MEDIUM |
| Missing types | `any` in TypeScript | MEDIUM |
| Config drift | Hardcoded values | HIGH |

**Key grep patterns:**
```bash
# TODOs
grep -rnE "TODO|FIXME|HACK|XXX" app/ resources/js --include="*.php" --include="*.tsx" | wc -l

# TypeScript any
grep -rnE ": any|as any" resources/js --include="*.tsx" --include="*.ts" | wc -l

# Config drift
grep -rnE "14.day|14-day" resources/js --include="*.tsx" | grep -v "{trialDays"
grep -rnE '\$[0-9]+' resources/js --include="*.tsx" | grep -vE "config|props"
```

---

**Continued:** Read `audit-domains-extended.md` for domains 6-11 (Accessibility, SEO, AI/LLM Integration, Feature Completeness, Parallel Deep Analysis, Observability & Monitoring).


---
