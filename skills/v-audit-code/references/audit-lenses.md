# Audit lenses

Thinking lenses, not a checklist to tick. Apply the ones that fit, weight them by the real operating scenario, combine or split them, and add dimensions you think matter. Everything here stays inside the in-app boundary (no new vendors/services, no runbook/infra review). Justify your framework.

## Contents
- Security & trust boundaries
- Dependency & supply-chain hygiene
- CI/CD & committed-config correctness
- Architecture & data integrity
- Reliability, concurrency & failure handling
- Cost & abuse: metered outbound calls
- Performance & scalability
- In-app operational behavior
- Observability from within the app
- Testing & quality gates
- UX, UI craft & content quality
- Feature completeness & scope discipline
- Code quality & maintainability
- The modernization lens (era-current)

_Last reviewed: 2026-08-12 (audit-of-the-auditor pass: deepened Dependency & supply-chain hygiene from a one-sentence lens to detection + severity table — the 2026-08-02 sweep had upgraded its neighbors but skipped it; added a CI/CD & committed-config correctness lens for the GitHub-Actions-poisoning surface the family boundary already scopes in but no lens covered. Prev 2026-08-02: added the Cost & abuse lens — AI-era coverage sweep; zero prior coverage of metered-call cost/abuse controls across the audit family. Same-day follow-up: SME coverage-gap sweep added auth-endpoint rate limiting to Security & trust boundaries, webhook/event-replay idempotency + money/decimal handling to Architecture & data integrity, a concrete missing-index detection method to Performance & scalability, and expanded Observability from a one-sentence lens to a full grep-backed check with severity table — all were one-line "consider X" gaps or entirely absent)._

---

## Security & trust boundaries
Authn/authz as implemented (session/token/credential hygiene, MFA logic, authorization enforcement and defense-in-depth, IDOR), secret handling and encryption in the code, input/output trust boundaries, injection / SSRF / unsafe deserialization, mass-assignment, privilege and blast radius. Sensitive data in logs or error output (passwords, tokens, API keys, card data at any log level — the CLAUDE.md § Security Defaults never-log list; sanctioned failed-login email logging per v-check's `v-security-baseline.md` § Monitoring & Alerting is NOT a finding, but minimize other incidental PII) and internal details leaking to user-facing responses (stack traces, SQL, raw exceptions). Include the *current* threat surface the code itself must withstand: any AI/LLM in the request path and its prompt-injection/abuse surface, unsafe handling of untrusted data, and cheap-to-plan-for future-proofing (e.g. crypto agility). Judge what the code does, not the perimeter around it.

**Auth-endpoint rate limiting** (a house rule — `CLAUDE.md § Security Defaults`: "Rate limit all auth endpoints (login, register, password reset, email verification)"). The only rate-limit grep elsewhere in this skill family is filtered to admin routes (`~/.claude/skills/v-audit-admin/references/admin-audit-checklists.md § Rate Limiting`) and structurally cannot see the public login/register/password-reset/verification routes a credential-stuffing attack actually targets — check them here.

Enumerate auth routes, then confirm each carries `throttle:` middleware or a named `RateLimiter::for()` limiter:
```
# 1. Enumerate auth-shaped routes
grep -nE "Route::(post|get|put|patch)\(" routes/*.php 2>/dev/null | grep -iE "login|register|password|verif|logout|forgot"

# 2. Which of those carry throttle: inline on the same route/chain?
grep -nE "Route::(post|get|put|patch)\(" routes/*.php 2>/dev/null | grep -iE "login|register|password|verif|logout|forgot" | grep "throttle:"

# 3. Named limiters registered instead (Fortify/Jetstream ship 'login' + 'two-factor' by default)
grep -rnE "RateLimiter::for\(['\"][a-zA-Z_-]+['\"]" app/Providers --include="*.php" 2>/dev/null
```
A route from step 1 absent from step 2's output, with no matching named limiter in step 3, is unthrottled. Routes declared inside a `Route::middleware(['throttle:...'])->group()` block don't repeat `throttle:` on each inner line — open the enclosing group before flagging a false positive. A managed auth provider (Fortify, Breeze, Jetstream, or a third-party IdP) that ships its own default limiters satisfies this check — confirm the provider's config didn't disable them rather than re-flagging routes it owns.

**Severity table**

| Finding | Severity |
|---|---|
| Login route with no `throttle:` middleware and no matching named limiter | P1 |
| Registration route unthrottled (scripted/bot account creation) | P1 |
| Password-reset request route unthrottled (enumeration + spam) | P1 |
| Email-verification resend route unthrottled | P2 |
| Throttle/limiter present but the rate is effectively unlimited (e.g. `throttle:1000,1`) | P2 |
| All auth routes throttled, but no test asserts the 429 fires on the Nth attempt (a limiter is silently removable in a future refactor with nothing failing) | P2 |

**AI/LLM feature security** (concrete surface, when the repo has an AI/LLM in the request path — the security twin of the Cost & abuse lens). The prompt-injection clause above is a name-check; this is the worked treatment. Detection: locate LLM call sites (`grep -rniE 'openai|anthropic|->chat|completions|messages\.create|generateText|invokeModel'`), then trace what reaches the prompt and what the model's output is allowed to do.

| Finding | Severity |
|---|---|
| Untrusted content (user input, fetched web pages, UGC, uploaded docs) concatenated into a system prompt or tool-instruction context with no delimiting/sanitization — direct prompt-injection surface | P1 |
| LLM output used to drive a privileged action (SQL, shell, file write, HTTP request, `eval`) without a validation/allowlist gate between model and effect — injection escalates to code/data execution | P0 |
| Tool/function-calling exposed to the model with no per-tool authorization scoping (the model can call a tool that acts outside the requesting user's own permissions) | P1 |
| Secrets/API keys/system-prompt internals reachable in model context that is then reflected to users (prompt-leak exposes them) | P1 |
| AI-generated HTML/markdown rendered without sanitization (`dangerouslySetInnerHTML` / raw render) — stored-XSS via model output | P1 |
| LLM feature in the request path with no test covering an injection/adversarial input (the guardrail is silently removable) | P2 |

## Dependency & supply-chain hygiene (in-repo only)
Dependency freshness and known-vulnerability posture via the project's *own* audit tooling, lockfile integrity, and whether the repo's "green gates" actually prove what they claim (a gate that auto-skips isn't a pass). No external services.

Detection (run the project's own tooling, capture full output — never truncate a verdict):
```bash
# Known-vuln posture via the repo's own auditors (capture, read counts from the file)
composer audit --format=plain > /tmp/dep-composer.txt 2>&1 || true    # PHP
npm audit --audit-level=high > /tmp/dep-npm.txt 2>&1 || true          # JS (or pnpm/yarn audit)
# Lockfile present AND committed for every manifest (a manifest with no lockfile = unpinned build)
for m in composer.json package.json; do ls "$m" >/dev/null 2>&1 && \
  { ls "${m%.json}.lock" package-lock.json pnpm-lock.yaml yarn.lock 2>/dev/null | head -1 || echo "NO LOCKFILE for $m"; }; done
# Security-sensitive deps on floating ranges (^/~/*) rather than pinned
grep -nE '"(.*(auth|jwt|crypto|bcrypt|password|oauth|saml|stripe|webhook).*)":\s*"[\^~*]' package.json composer.json 2>/dev/null
```

| Signal | Severity |
|---|---|
| The project's own audit tool reports a known-exploited / critical CVE in a shipped (non-dev) dependency | P0 |
| A production manifest has no committed lockfile (builds are unpinned; "works on my machine" supply-chain drift) | P1 |
| Known high-severity CVE in a shipped dependency with a compatible fixed version available | P1 |
| Security-sensitive dependency (auth/crypto/payments) pinned to a floating `^`/`~`/`*` range rather than an exact version | P2 |
| Dependency major-version lag past end-of-life / no-longer-security-patched, with no tracking issue | P2 |
| `composer audit`/`npm audit` never runs in the project's own gate suite (nothing would catch a new CVE) | P2 |

## CI/CD & committed-config correctness (in-repo only)
The correctness of pipeline/config files **already committed to the repo** — NOT the CI platform, runners, or infra (those are off-stack per `_v-audit.md` § In-App Actionability Boundary; committed workflow YAML is the in-app twin, explicitly in scope). GitHub Actions poisoning is one of the more common real-world 2024–2026 supply-chain incident classes, and the surface lives entirely in files the repo owns.

Detection:
```bash
# Third-party actions pinned by moving tag (@v4, @main) rather than a full commit SHA
grep -rnE 'uses:\s+[^@]+@(v?[0-9]+|main|master|latest)\s*$' .github/workflows/ 2>/dev/null
# The dangerous-by-default trigger + untrusted checkout combination
grep -rlE 'pull_request_target' .github/workflows/ 2>/dev/null
# Over-broad token scope
grep -rnE 'permissions:\s*write-all|contents:\s*write' .github/workflows/ 2>/dev/null
```

| Signal | Severity |
|---|---|
| `pull_request_target` workflow that checks out and executes the PR head (`actions/checkout` with `ref: ...head.sha` / runs untrusted code with secrets in scope) | P0 |
| Third-party action referenced by moving tag (`@v4`, `@main`) instead of a pinned commit SHA — upstream compromise executes in your pipeline with your secrets | P1 |
| `permissions: write-all` (or unrestricted default token) where the job only needs read | P1 |
| Secret passed to a step that runs untrusted/third-party code, or echoed where it can land in logs | P1 |
| No top-level `permissions:` block at all (inherits the repo/org default, often broader than needed) | P2 |

## Architecture & data integrity
Correctness of the core mutation/transaction model, idempotency, rollback and compensating actions, consistency across whatever the app talks to, and whether the architecture is coherent and evolvable — or accreted. Look hard at the seams between subsystems. Schema-change safety where migrations exist: destructive changes staged in two phases (stop-using before drop), new columns on live tables nullable-or-defaulted, foreign keys constrained and indexed.

**Webhook / event-replay idempotency.** Signature-verification *presence* is a Security-lens concern (`_v-api.md § Webhooks`) — this lens checks the sibling failure: a verified webhook that still double-processes. Payment/billing providers retry failed deliveries for days on at-least-once delivery semantics; a handler that re-applies side effects on a retried `invoice.paid` double-credits an account.

Locate webhook handlers, then require a stored/checked event ID *before* any side effect runs:
```
# Locate webhook handlers
grep -rlniE "webhook" app/Http/Controllers routes --include="*.php" 2>/dev/null

# For each handler found, check for a dedup guard: a stored/checked provider event ID
# (webhook_events table, firstOrCreate on the event id, a DB unique constraint on the
# event-id column) or the framework's own duplicate handling — open the file and confirm
# the guard runs BEFORE the side-effect call, not merely somewhere in the method.
grep -nE "event(->|\.)id|processed_event|WebhookEvent::|firstOrCreate\(.*event|->unique\(.*event" <handler-file>
```
A handler with zero hits from the second grep processes every delivery as new — flag it even if signature verification passes cleanly. Cross-reference `_v-api.md § Idempotency` for the dedup shape (insert-and-catch-unique-violation, not select-then-insert — a prior read cannot close the replay race).

| Finding | Severity |
|---|---|
| Webhook handler with signature verification but no event-ID dedup at all — side effects run on every delivery | P1 |
| Dedup check present but reads-then-writes (an `exists()`/`where()` check followed by a separate insert) instead of a DB-level unique constraint — two near-simultaneous retries still race past it | P2 |
| Dedup present and DB-constrained, but exercised by no test | P2 |

**Money & decimal handling.** Only display-unit formatting is checked elsewhere in this family — nothing verifies the underlying storage or arithmetic type. `float`/`double` cannot represent most decimal currency values exactly (binary floating point); accumulated rounding error compounds across a ledger.

```
# Migrations: money-bearing columns typed float/double instead of integer-cents or decimal
grep -nE "\$table->(float|double)\(" database/migrations/*.php 2>/dev/null

# Models: money-bearing attribute cast to a PHP float, discarding a decimal column's precision
grep -rnE "'(amount|price|total|balance|cost|fee|tax)[a-zA-Z_]*'[[:space:]]*=>[[:space:]]*'float'" app/Models --include="*.php" 2>/dev/null

# Service-layer arithmetic on money-named variables with float operators
grep -rnE "\$(amount|price|total|balance|cost|fee|tax|subtotal|discount|refund|charge)[a-zA-Z_]*[[:space:]]*[*/+-]" app/Services app/Actions app/Http/Controllers --include="*.php" 2>/dev/null \
  | grep -viE "_cents|Money::|intval\(|\(int\)"
```
The service-layer grep is a proxy, not proof — read each hit; a `_cents`-suffixed variable, an `intval()`/`(int)` cast, or a dedicated Money/value-object wrapper (e.g. `brick/money`) is the expected mitigation and clears the finding.

| Finding | Severity |
|---|---|
| Money-bearing migration column typed `float`/`double` | P1 |
| Money-bearing model attribute cast to `'float'` in `$casts` | P1 |
| Money-named variable used in float arithmetic (`*`, `/`) with no integer-cents suffix, cast, or Money wrapper | P1 |

## Reliability, concurrency & failure handling
Race conditions, locking, retries/backoff, timeouts, poison-message and partial-failure behavior, graceful degradation — in the app's own code paths. Ask "what happens when this call half-succeeds?"

## Cost & abuse: metered outbound calls
Any call the app makes to a paid/metered external service — model/inference APIs, SMS/email/push providers billed per-send, third-party enrichment or search APIs, usage-billed compute — is a financial blast-radius surface the same way an auth boundary is a data blast-radius surface. An unthrottled call site isn't a performance nit: it's the single call site that turns a retry storm, a scraping bot, or one authenticated user issuing thousands of requests into a five-figure overnight bill. This lens governs *who can spend how much* (a cost/reliability control) — it does not cover *who is allowed to call the endpoint at all*; that's the Security lens's authn/authz domain, out of scope for this pass.

**Locate the call sites first.**
```
grep -rniE "Http::(post|get|send)\(|->post\(|->send\(|withToken\(|bearerToken\(" app/Jobs app/Services app/Actions 2>/dev/null
grep -rniE "openai|anthropic|cohere|replicate|huggingface|bedrock|vertexai|twilio|sendgrid|postmark|resend|nexmo|vonage|plivo|stripe" -r app/ 2>/dev/null
grep -rln "ShouldQueue" app/Jobs 2>/dev/null | xargs grep -LiE "RateLimiter|throttle|Cache::.*lock|spend|budget" 2>/dev/null
```
Every model-call job is by definition a metered outbound call site and inherits this lens whole — cross-reference `~/.claude/skills/_v-jobs.md § Model-Call Jobs` for what the job itself must implement; this lens is the audit-side check that it actually did.

**Four independent controls must be true at every metered call site.** Missing any one is its own finding — they don't substitute for each other:
1. A per-user or per-tenant rate or spend cap, enforced *before* the call is dispatched (a global-only cap lets one abusive account exhaust the shared budget for everyone).
2. A bounded retry ceiling with backoff — never an unbounded loop or a retry-until-success pattern.
3. An explicit timeout, shorter than the queue worker timeout.
4. A kill-switch (a config flag that zeroes the call path without a deploy) or a budget alert that fires before the cap is silently reached, not only after.

**Severity table**

| Finding | Severity |
|---|---|
| Metered call site with no rate/spend cap at all (any user can trigger unlimited billable calls) | P0 |
| Metered call site with an unbounded retry (no `$tries` ceiling, `while(true)` retry, or retry-until-success loop) | P0 |
| Metered call site with no timeout (default/infinite) | P1 |
| Rate/spend cap exists but is global only, not per-user/per-tenant | P1 |
| No kill-switch and no budget alert (cap exists but nothing pages before or at the ceiling) | P1 |
| Retry logic doesn't distinguish retryable transport failures from non-retryable content/validation rejections (retries a deterministic failure N times) | P2 |
| Cap/timeout/retry present but exercised by no test | P2 |

**Grep patterns to find violations:**
```
# Unbounded retry loops
grep -rniE "while\s*\(\s*true\s*\)|->retry\(\s*(-1|PHP_INT_MAX)" app/

# HTTP client calls with no explicit timeout
grep -rniE "Http::(post|get)\(" app/ | grep -v "timeout("

# Metered-provider jobs/services with no rate limiter or spend tracking nearby
grep -rlniE "openai|anthropic|stripe|twilio|sendgrid" app/Jobs app/Services 2>/dev/null \
  | xargs grep -LiE "RateLimiter::(for|attempt)|spend|budget|Cache::(increment|lock)" 2>/dev/null
```
A metered call site guarded only by the HTTP client's built-in `retry()` helper with no bound passed, or a `$tries` set arbitrarily high with linear (non-backoff) delay, is functionally the unbounded case — treat it the same as no retry ceiling at all. Cost-model reasoning (how the cap number itself is derived — worst-case cost per user before ship) is owned by `~/.claude/skills/references/ai-feature-engineering.md § Cost model`; this lens verifies the control exists and fires, not how the number was chosen.

## Performance & scalability
Query patterns (N+1s, unbounded result sets, missing indexes implied by the queries), caching of expensive work, pagination on every list that can grow, job/queue behavior under volume, frontend payload weight and render cost where a UI exists. Judge against the real scale: an internal tool with ten users doesn't need the same answer as a public API — but an unbounded query is a defect at any scale, it just has a different fuse length.

**Missing-index detection — concrete proxy** (not "check for missing indexes"). Extract every column driving a `where`/`whereIn`/`orderBy` on a hot path (controllers, jobs — paths that run per-request or per-job, not one-off console commands), then confirm each has a matching index in the schema:
```
# 1. Columns referenced in where()/whereIn()/orderBy() on hot paths (both ->chained and ::static entry points)
grep -rhoE "(->|::)(where|whereIn|orderBy)\(['\"][a-zA-Z_]+['\"]" app/Http/Controllers app/Jobs --include="*.php" 2>/dev/null \
  | grep -oE "['\"][a-zA-Z_]+['\"]" | tr -d "'\"" | sort -u

# 2. For each column from step 1, confirm a matching ->index()/composite index/unique() exists
for col in <columns from step 1>; do
  grep -qE "index\(.*['\"]?$col['\"]?|unique\(.*['\"]?$col['\"]?" database/migrations/*.php \
    && echo "INDEXED: $col" || echo "POSSIBLY_MISSING_INDEX: $col"
done
```
Treat `POSSIBLY_MISSING_INDEX` as a lead, not a verdict — a column always queried alongside another already-indexed column (covered by a composite index) is fine; open the migration and confirm before flagging. Where the project's own test suite can run one, recommend an `EXPLAIN`/`EXPLAIN ANALYZE` review on the hot-path query rather than asserting the finding from grep output alone — the grep proves the column is unindexed, not that it's slow at the project's actual row counts.

## In-app operational behavior
The correctness and safety of operational *code* that ships in the repo: scheduled tasks, health/self-check commands, backup/restore/verification logic, in-app alerting/notification code. Is it correct, safe, and complete on its own terms? (Not the surrounding runbooks/infra.) Include shipped-config hygiene: debug flags that must be off in production, permissive CORS, unsafe defaults, and whether the example/env-template config would produce a safe deployment as written.

## Observability from within the app
Quality and coherence of the signals the app itself emits and the in-app logic that acts on them: structured logging, in-app health surfacing, self-diagnostics. Would an incident be *detectable and diagnosable* from what the app produces? (The transport/backend for those signals is out of scope.)

**Structured-logging context fields** (a house rule — `CLAUDE.md § Production Standards`: every error/warning-level log carries `user_id`, `action`, `duration_ms`, `ip` at minimum). Presence of a `Log::` call is not the check — context-free logging at error/warning level is functionally indistinguishable from no logging once there's an incident to diagnose.
```
# 1. Every error/warning/critical-level log call site
grep -rnE "Log::(error|warning|critical|alert|emergency)\(" app/ --include="*.php" 2>/dev/null

# 2. The failure shape this check exists to catch: a log call with no context array at all.
#    Laravel's structured-logging convention passes context as a second array argument; a
#    bare Log::error($e->getMessage()) carries nothing to correlate the incident to a user,
#    action, or request. Absence of a literal `[` on the call line is the proxy for "no array
#    argument was passed" — reliable for single-line calls, needs eyes-on for multi-line ones.
grep -rnE "Log::(error|warning|critical|alert|emergency)\(" app/ --include="*.php" 2>/dev/null | grep -v "\["
```
A step-2 hit is the concrete finding: an error/warning/critical log with zero context. A step-1-minus-step-2 hit still needs eyes-on — open it and confirm `user_id` and `action` (or their equivalents: `auth()->id()`, a request-tracing ID) are actual keys in the array, not just that some array was passed.

**No secrets in log statements** (CLAUDE.md § Security Defaults — never log passwords, tokens, API keys, or card numbers, even at debug level):
```
grep -rniE "Log::(info|debug|error|warning|notice)\(.*\b(password|token|secret|api[_-]?key|card[_-]?number|cvv)\b" app/ --include="*.php" 2>/dev/null
```
A hit is a finding regardless of log level — `debug` output ships to the same aggregated log store as `error` in most setups, so log-level scope is not a mitigation.

**Sensitive code paths with zero logging** — money, auth-decision, and admin-mutation call sites that log nothing at all are undiagnosable by construction, not merely under-contexted:
```
for f in $(grep -rlE "refund|charge|subscription|->authorize\(|Gate::authorize" app/Http/Controllers app/Services --include="*.php" 2>/dev/null); do
  grep -q "Log::" "$f" || echo "NO_LOGGING_IN_SENSITIVE_FILE: $f"
done
```

**Severity table**

| Finding | Severity |
|---|---|
| Password/token/secret/API-key/card-number pattern inside any log statement, at any level | P0 |
| Money/auth-decision/admin-mutation file with zero `Log::` calls anywhere | P1 |
| Error/warning/critical log with zero context (no array argument at all) | P1 |
| Context array present but missing `user_id` and/or `action` keys | P2 |

## Testing & quality gates
Coverage that asserts **independent expected values**, not tests that bless the implementation (no seeding inputs at the same broken path the code reads; exercise the real persisted path). Partial-failure / rollback / idempotency coverage. N-independent performance assertions (prove no-N+1 across two Ns, not a single fixed N). Determinism/flakiness (freeze time, no engine-specific tie-breaks). Whether recorded gate evidence is real and current (base = HEAD, audits forced not skipped, zero baseline exclusions). Consider whether in-repo 2026-grade techniques (mutation testing, property-based testing, fuzzing, contract tests) would add real assurance.

## UX, UI craft & content quality
Hold user-facing surfaces to a real bar, not just "it works." Low-friction, scannable hierarchy — can the user grab what matters at a glance? Does it feel like careful designers touched it (type, spacing, color, and the empty / loading / error states) *without* over-design (gradient soup, gratuitous animation, novelty over usefulness)? Restraint is craft. **Match the bar to the real audience**: a consumer/multi-user surface should be engaging and polished; an internal tool with a few operators should optimize for productivity, clarity, and low cognitive load — well-designed and fast, not flashy. Judge the **words** too: are labels, buttons, errors, empty states, and confirmations plain, specific, human, and confident — or vague, robotic filler? And the safety basics: destructive/irreversible actions guarded, state honest, footguns designed out, accessible. **Theme integrity:** if the app ships or claims dark mode, check it's real coverage, not a stray unstyled surface — hardcoded light-only colors, low-contrast text, or a toggle that half-applies across routes/components. **Low-contrast text specifically:** whether text reads as legible against its rendered background is UNVERIFIABLE-STATICALLY (no browser/pixel-sampling tool is provisioned — do not claim you visually inspected contrast). Static proxy: where a literal foreground/background pair is discoverable in source (inline hex/rgb styles, Tailwind arbitrary-value classes like `text-[#...]` paired with a `bg-[#...]` on the same or an ancestor element, or a pair of CSS custom properties resolved from the theme file), compute the WCAG relative-luminance contrast ratio between the two colors and flag any pair under 4.5:1 (body text) or 3:1 (large text — ≥24px, or ≥18.66px bold, per `_v-design.md § Color Contrast Requirements`) as a real, statically-checkable finding. Where colors are semantic/token-based rather than literal (e.g. `text-muted-foreground` on `bg-card`), grep the theme/token definition file for the two tokens' resolved values in BOTH light and dark mode and run the same ratio check per mode — a token pair that clears contrast in light mode but not dark (or vice versa) is exactly the "toggle half-applies" failure this check exists to catch. **Mobile / viewport responsiveness:** does the layout hold up below desktop width — breakpoints/media queries or a responsive utility scheme (e.g. Tailwind `sm:`/`md:`/`lg:` prefixes) present on key surfaces, no fixed-width containers or off-canvas overflow at narrow viewports, tap targets sized for touch. Actually rendering at each breakpoint is UNVERIFIABLE-STATICALLY (no browser tool provisioned) — do not claim you resized a viewport. Static proxy: grep for responsive utility classes / `@media` rules on the surfaces you're judging; a page with zero responsive styling anywhere is a real finding independent of any live check. **Motion and "feels fast":** whether animation/transition timing actually reads as intentional (vs. janky or gratuitous) and whether the UI subjectively "feels fast" are UNVERIFIABLE-STATICALLY — no browser/runtime tool is provisioned, so do not claim you watched it animate or timed an interaction. Static proxies: grep for `transition`/`animation` utility classes and a `prefers-reduced-motion` handling path (motion present with no reduced-motion fallback is a real, statically-checkable finding); for perceived performance, grep for skeleton/loading-state components instead of blank screens, optimistic-update patterns where a mutation is safe to assume, and any interaction wrapped in nothing but a bare spinner-then-pop-in — presence/absence of these patterns is the static proxy for "feels fast," not a live timing observation.

## Feature completeness & scope discipline
Is the shipped surface coherent and honest? Are immature parts fenced off (feature-flagged, not half-exposed)? Is anything half-built that adds risk?

## Code quality & maintainability
Clarity, single-source-of-truth (no duplicated constants/logic), dead/duplicated code, and how a competent new maintainer would fare on day one.

## The modernization lens (era-current, first-class — but in-app)
Step back from line-level review and challenge the premises *within the app's own walls*. Is the framework usage, language-level features, architectural patterns, security model, and in-app operational/testing approach current for the era — or dated idioms solving the problem the old way? What would a cutting-edge *in-app* version look like, and is that shift worth it for this scenario, or is boring-and-proven the right call? Be concrete about trade-offs. Reward pragmatism: call out **both** dated choices and needless over-engineering. Constraint: every idea must be achievable inside this codebase with its existing stack and no new vendors/services. If a "modern" practice inherently requires stepping outside that boundary, it's out of scope — one sentence of context at most, never a recommendation or a scoring ding.
