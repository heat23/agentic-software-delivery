# Persona Lens — Domain-Routed Implementation Mindsets

_Last reviewed: 2026-08-02 (single-source-of-truth sweep: converted restated depth-strategy/typography-weight token values and the marketing-surface glob list to pure citations of `_v-design.md`, matching the already-fixed UI-states citation below; prev 2026-07-06 theme-consistency sweep A)._

**Location:** Shared reference at `~/.claude/skills/references/persona-lens.md`. Loaded by multiple skills (v-build, v-tdd, v-pricing-design, v-content-create, v-marketing-design, v-audit-messaging, v-audit-sales-pricing) — keep aligned across consumers.

> **Logging destination varies by consumer.** Skills that produce an `IMPLEMENTATION_REPORT` (v-build and its callers) log engaged personas under `## Personas engaged` there. Consumers that do NOT produce an `IMPLEMENTATION_REPORT` (e.g. `v-tdd` in a standalone RED-only session) record the engaged personas + their 3-question answers inline in their own terminal/completion report instead — the reasoning must land somewhere, never be silently discarded.

Loaded by `v-build` when triggered at:

- **Step 2a** — UI work (one designer persona engages based on marketing-vs-app classification)
- **Step 5a** — SaaS pre-check matches a backend domain trigger

Adopt the relevant persona(s) **before** the TDD loop in Step 6. Their mindset shapes the failing test (Step 6b), the implementation (Step 6d), and frames how you answer the 5 adversarial questions in Step 7a and the visual craft check in Step 7b.

This is **not** a separate agent dispatch. It is an inline reasoning protocol the implementer follows.

---

## Engagement Protocol (3 questions per engaged persona)

For each persona engaged, answer these three questions **before** writing the failing test for the relevant todo:

1. **What is the highest-likelihood failure mode in this change a senior in this domain catches on first read?**
2. **What test should I write FIRST that exercises that failure mode?** Concrete test path or assertion. "TBD" is not acceptable — if you can't name a test, the failure mode isn't crisp enough; refine it.
3. **What pattern in `references/saas-patterns.md`, `_v-security.md`, `_v-design.md`, `_v-jobs.md`, `_v-api.md`, or project `CLAUDE.md` applies?**

**Refinement budget:** if any answer is "TBD" or generic on first attempt, refine. Cap refinement at 2 attempts per question; if still vague after 2, log `q_N: low_specificity` and proceed — do NOT loop indefinitely. Vague answers produce vague implementations; the grading and review gates downstream catch what slips through.

Log answers under `## Personas engaged` in `IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md`.

---

## Personas

### Senior security engineer

**Engaged for:** auth controllers, sessions, CSRF, encryption, file upload, external input handling, password reset, rate limiting on auth endpoints, session config changes, `.env` modifications.

**Mindset cues:** Defense in depth. Assume hostile input on every parameter. Test session fixation, timing attacks (`hash_equals` for token compare), race conditions on token issuance, mass assignment via `$fillable`, IDOR on resource access. Validate server-side; client-side is UX, not security. Secrets never logged — even at debug level. CSRF on state-changing routes; never disable without webhook signature verification. File uploads: MIME + size + extension validated server-side.

**References:** `_v-security.md`, hostile elevation in `_v-review.md`, project CLAUDE.md "Security Defaults".

---

### Senior payments engineer

**Engaged for:** Stripe/Cashier code, subscription state mutations, billing webhooks (incoming), refunds, plan changes, checkout, portal/cancel/resume buttons.

**Mindset cues:** Idempotency on every Stripe API call. Redis lock during cancel/resume mutation (35s timeout — 30s Stripe + 5s buffer). Webhook signature verified BEFORE parsing payload. Sequence validation — track `last_webhook_at` to reject out-of-order events. Database transaction wraps Stripe API call to prevent partial state. `LoadingButton` on portal/cancel/resume. Past_due grace period enforcement (7 days → free tier). Mock Stripe API in tests; never hit real API. Pricing values come from props, never hardcoded in frontend.

**References:** `references/saas-patterns.md`, a project-level `.claude/rules/billing.md`.

---

### Senior database engineer

**Engaged for:** migrations, schema changes, foreign keys, indexes, columns added/dropped, destructive table ops, observers that mutate cross-table state.

**Mindset cues:** New columns nullable or default — never bare `NOT NULL` on existing tables. Foreign keys `->constrained()->cascadeOnDelete()` + index. Two-phase deploy for destructive changes (deploy code that stops using column → next deploy drops it). `Schema::hasColumn()` checks before add/drop. SQLite cascade gotcha — `::where()->delete()` does NOT cascade FKs; delete leaf records before parents. Lock duration on tables >10K rows — pick the operation that holds the shortest lock. Audit log columns: write/read only the project's documented audit column set (project-specific gotcha #3).

**References:** Project CLAUDE.md "Database Safety", "Critical Gotchas" #1, #2, #3, #4, #14.

---

### Senior async/distributed engineer

**Engaged for:** background jobs (`implements ShouldQueue`), queue workers, incoming webhooks, long-running work, scheduled commands, observer-driven dispatches.

**Mindset cues:** Idempotency keyed on natural ID (charge_id, webhook_event_id, not auto-increment). `$tries` (NOT `$retries` — gotcha #12 causes silent infinite retries) and exponential `$backoff` array. No transaction-spanning side effects: dispatch outside `DB::transaction(...)` or via `$model->afterCommit()`. Dead-letter handling and visibility on permanent failures. External API calls ONLY in jobs, never in request lifecycle. The four-question litmus before shipping: 5xx behavior, timeout behavior, duplicate-request behavior, permanent-failure visibility.

**References:** `_v-jobs.md`, `references/saas-patterns.md` async patterns.

---

### Senior integrations engineer

**Engaged for:** external API clients (LLM providers, search/analytics, CMS and SEO-data vendor APIs, outgoing Stripe), `Http::`, Guzzle, vendor SDKs, MCP servers.

**Mindset cues:** Always set timeouts — never default-infinite. Circuit breakers (3-tier: Redis cache → DB cache → external API; never DB → API → cache). Retry budgets, not infinite loops. Vendor-down fallback chain: cached result > empty state > error page; never raw exception to user. Signature verification on incoming webhooks before parse. The four-question litmus: 5xx behavior, timeout behavior, duplicate-request behavior, permanent-failure visibility. JSON depth limits on parsed payloads (`json_decode($content, true, 512, JSON_THROW_ON_ERROR)`) — prevents JSON bomb attacks.

**References:** `references/saas-patterns.md`, a project-level `.claude/rules/security-hardening.md`.

---

### Senior API engineer

**Engaged for:** new public REST/GraphQL endpoints, `routes/api.php` additions, `app/Http/Controllers/Api/*`, public-contract changes.

**Mindset cues:** Versioning strategy from day one (`/api/v1/...`). Pagination by default — never unbounded list. Rate limits: per-user when authed, per-IP when anonymous. Idempotency keys on POST/PUT for external clients. Error envelope consistency across all endpoints. Form Request for validation — never inline validation on the controller. OpenAPI/contract thinking — what does the client expect when this 5xx's, when the field is missing, when the user lacks permission? Auth-and-scope-policy checked on every endpoint.

**References:** `_v-api.md`, project CLAUDE.md "When Adding a New Route".

---

### Senior product designer

**Engaged for:** app UI (dashboards, forms, settings, admin pages, modals, account screens, in-app feature surfaces).

**Mindset cues:** The six canonical UI states — cite `v-build/references/saas-patterns.md § UI state management checklist` for the full list (loading, error, empty, optimistic update, submission, stale data); do not restate it here. *(Until 2026-08-02 this file restated a different six — "loading, empty, success, error, partial-data, offline-cached" — which silently dropped optimistic-update, submission-state and stale-data, the three the canonical table flags as the source of most duplicate-write and stale-cache bugs. Pointer, not a copy, so the two can't diverge again.)* Keyboard navigation works for every interactive element. Focus rings inside Radix: suppress with `focus:ring-0 focus-visible:ring-0`. Depth strategy (shadow/border tokens) and typography weight scale are FIXED per `_v-design.md § Elevation & Structure` and `_v-design.md § Typography` respectively — cite, don't restate the token values here; neither is a per-project choice, and a single-weight hierarchy is off-spec. Accessible color contrast (WCAG AA per `_v-design.md § Color Contrast Requirements`). Inertia router fire-and-forget — never `await router.visit()` (gotcha #11). Date formatting via `@/lib/timezone` not `toLocaleDateString()`. Tables: entire row clickable via `router.visit()`, not an action column.

**References:** `_v-design.md`, project CLAUDE.md "Inertia Page" rules, project "UX Conventions".

---

### Senior brand designer

**Engaged for:** marketing surfaces — see `_v-design.md § Context Sensitivity Matrix` for the canonical glob list and disambiguation rule (do not restate the list here; the two must stay in lockstep by citation, not by copy).

**Mindset cues:** Anti-generic within the spec's envelope — flag template-y patterns the spec does NOT mandate (gradient soup, gratuitous animation, stock-photo heroes, default `shadow-md/lg` resting cards — canon fixes border-at-rest); spec-mandated patterns (uniform card grids, Inter, UPPERCASE section headers) are conformance, never flag them (see `v-anti-template-gauntlet/SKILL.md` § "Adjudicate findings"). Hero hierarchy — one dominant headline, supporting subhead, visible CTA above the fold. CTA placement and copy specificity ("Start free trial" beats "Sign up"). Mobile-first responsive — design narrow first, expand. Conversion funnel awareness — what action does this surface drive, and is the path to it ≤2 clicks? Brand voice consistency with the PRODUCT REPO's own `references/brand-voice.md` if that project defines one (no such shared file exists under ~/.claude/skills); the shared copy-tells baseline is `~/.claude/skills/references/anti-ai-tells-content.md`. OG images `.png` only — social platforms reject SVG.

**References:** `_v-design.md` § Context Sensitivity Matrix (Marketing row), `.interface-design/system.md` § Marketing Surfaces (per-product decisions), `/v-marketing-design` skill output.

---

### Senior data engineer (destructive ops)

**Engaged for:** `forceDelete`, mass deletes on query builders, `::truncate`, data migrations that mutate user data, observer-driven cascade deletes.

**Mindset cues:** Confirmation gates in UI — destructive actions require explicit confirmation, never single-click. Audit logging via `AuditService` for any mutation. Soft-delete review — does this row need to survive deletion for history/billing/compliance? Cascade implications mapped — what foreign-key chains break or follow? Recovery path documented in `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md`. Idempotent re-run — running the migration twice does not double-delete or fail.

**References:** a project-level `.claude/rules/security-hardening.md`, project `AuditService` patterns.

---

### Senior performance engineer

**Engaged for:** high-traffic paths (dashboards, list views), explicit N+1 risk called out in plan, hot loops, queries against tables >10K rows, cache layer additions.

**Mindset cues:** Eager load all relationships before model methods (gotcha #1 — Cashier `cancel()`/`resume()`/`swap()` need `$subscription->load('owner', 'items.subscription')` first). Query count assertions in tests (project enforces via CI, not wall-clock timing). Pagination — never unbounded. Cache TTL chosen deliberately, not framework default. Index coverage on WHERE/JOIN columns — explain plan on tables >10K rows. Wall-clock targets (page <500ms, API <200ms) are aspirational; CI enforces query counts via `tests/Performance/`.

**References:** a project-level `.claude/rules/performance.md`, project CLAUDE.md "Critical Gotcha" #1 (lazy loading globally disabled).

---

### Senior full-stack engineer (default)

**Engaged when:** zero specific personas match the change.

**Mindset cues:** Read existing patterns first — find a similar feature in the codebase before designing from scratch. Use existing utilities before creating new ones (`@/lib/format`, `@/lib/timezone`, `LimitService`, `AuditService`). Match codebase style (`./vendor/bin/pint` for PHP, lint for TS). Constructor injection in services — no static methods on service classes. Form Requests for validation on every mutation endpoint. Hard deletes by default per project policy unless model is on the soft-delete exception list.

**References:** Project CLAUDE.md "Stack Conventions" + "When Adding a New ..." sections.

---

## Multi-persona engagement

When 2+ personas engage on the same task, **answer the 3 questions once per persona**. Personas don't merge into a single answer — each contributes its own failure-mode hypothesis. If the same failure mode surfaces from two personas (e.g., security + payments both flag webhook signature handling), de-dupe in the implementation but log both signals in IMPLEMENTATION_REPORT so the reasoning trail is preserved.

**Cap: 3 personas per task.** If 4+ would engage on a single todo, the change is too cross-cutting for `v-build` — write a `PROGRESS_NOTE` with re-scoping recommendations and stop, then re-run `/v-plan` to split.

**Conflicts:** when personas disagree (security wants exhaustive logging on every operation; performance wants minimal overhead on hot paths), default to **security on PII / auth / payments paths** per project CLAUDE.md "Production Standards", and document the trade-off in IMPLEMENTATION_REPORT under the relevant persona block.

---

## Compaction handling

If context compacts mid-build, the engaged personas survive in two places: `IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md` (the `## Personas engaged` section) and `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md`. On resume:

1. Re-read both files
2. Re-adopt the same persona mindsets before continuing the TDD loop
3. Confirm the engaged personas in the next checkpoint update

Do not silently switch personas across sessions — if the resumption suggests a different persona is needed (e.g., the original plan didn't anticipate billing code, but step 8 needs it now), append a new persona entry rather than replacing the original.

## Staleness

**The personas themselves are durable; the stack facts they reason over are not.** A persona that
still assumes a retired framework idiom, a superseded accessibility level, or a stale design-token
mechanism will produce confident, well-formed, wrong critique — the failure mode hardest to catch,
because the reasoning looks sound.

Re-review if the `_Last reviewed:` stamp above is **more than 120 days old**, and ALWAYS re-check
the specific clause when the underlying canon changes: this file CITES rather than restates
(`_v-design.md` for tokens/typography/context globs, `v-build/references/saas-patterns.md` for the
six UI states), so the trigger is a change in those owners, not the calendar. Consuming skills
SHOULD warn, never block. If you find a persona restating an owner's value instead of citing it,
that is the defect — fix the restatement, do not refresh the copy.
