# Audit Domain Reference (Extended) — v-check

_Last reviewed: 2026-07-06 (theme-consistency sweep B: security/performance/UI-states alignment; prev sweep A: SEO/AEO + growth-motion + copy/voice)._

Continued from `audit-domains.md`. Covers domains 6-12.

---

## 6. ACCESSIBILITY (WCAG 2.2 AA)

| Check | Pattern | Priority |
|-------|---------|----------|
| Missing aria-labels | Buttons/icons without accessible text | P1 |
| Keyboard navigation | Click handlers on non-interactive elements (`div`, `span`) | P1 |
| Color contrast | Body text below 4.5:1; large text (≥24px, or ≥18.66px bold) and UI elements below 3:1 — definitions per `_v-design.md § Color Contrast Requirements` | P1 |
| Focus indicators | Interactive elements without visible focus ring | P1 |
| Form labels | Inputs without associated `<label>` or `aria-label` | P1 |
| Image alt text | `<img>` without `alt` attribute | P2 |
| Skip links | No skip-to-content link for keyboard users | P2 |
| ARIA roles | Click handlers on `div`/`span` without `role="button"` | P1 |

**Key grep patterns:**

> **Multi-line JSX warning:** A `<button>`/`<input>`/`<img>` element frequently opens on one line and its `aria-label`/`alt`/text content lands on a LATER line. A single-line `grep "<button" | grep -v "aria-label|...|>.*<"` therefore false-flags well-labeled multi-line elements (the label is simply on another line) AND misses violations where the opening tag and attributes are split. Use ripgrep multiline (`rg -U`) or `grep -A3 -B1` context, then read the element. Where a reliable text match isn't possible, **dispatch a fork-safe `claude -p` subprocess (Domain 10, via `v-dispatch-subagent.sh` — NOT the Agent tool, which fails silently from this skill's `context: fork`) for an AST/JSX-aware accessibility pass** — do NOT report a broken single-line grep as a finding.

```bash
# Buttons/icons without accessible text — MULTILINE-AWARE.
# Single-line grep -v "aria-label|...|>.*<" is broken on multi-line buttons.
rg -nU -g '*.tsx' -g '*.jsx' '<button(\s|>)[\s\S]*?</button>' resources/js 2>/dev/null | rg -v 'aria-label|aria-labelledby|>[^<]*\w' || true
# Fallback with context (inspect each block; the label may be on an adjacent line):
grep -rnE -A3 -B1 "<button" resources/js --include="*.tsx" | grep -vE "aria-label|aria-labelledby|>[^<]*[A-Za-z]"
# If the result is noisy, treat as a candidate list and confirm via a Domain 10 claude -p AST-aware pass — not as final findings.

# Click handlers on non-interactive elements (line-local — grep is reliable)
grep -rn "onClick" resources/js --include="*.tsx" | grep -E "div|span" | grep -v "role="

# Images without alt text — check the element, not just the opening line (alt= may be on a later line)
grep -rnE -A2 "<img" resources/js --include="*.tsx" | grep -v "alt="

# Inputs without labels — MULTILINE-AWARE (label/aria-label often on a separate line)
grep -rnE -A3 "<input|<select|<textarea" resources/js --include="*.tsx" | grep -vE "aria-label|id=.*label|aria-labelledby"
# Verify candidates in a Domain 10 claude -p AST-aware pass — associated <label htmlFor> elsewhere in the file won't show in this window.

# Missing focus styles (utility classes — line-local, grep is reliable)
grep -rnE "outline-none|outline-0" resources/js --include="*.tsx" | grep -vE "focus-visible|focus:|ring-"
```

## 7. SEO (If Public-Facing)

**Quick-check gates (always run in v-check):**

```bash
# Essential SEO surface checks
grep -rnE "title|description|og:" resources/views --include="*.blade.php"
grep -rnE "<Head|<title|meta" resources/js/Pages --include="*.tsx"
test -f public/sitemap.xml && echo "sitemap.xml exists" || echo "MISSING: sitemap.xml"
test -f public/robots.txt && echo "robots.txt exists" || echo "MISSING: robots.txt"
grep -rn "canonical" resources/views --include="*.blade.php"
grep -rnE "application/ld\+json|schema.org" resources/views --include="*.blade.php"
grep -rnE "noindex|nofollow" resources/views --include="*.blade.php"
```

| Check | Pattern | Impact |
|-------|---------|--------|
| Unique title + description per public page | Every public route has `<title>` and `<meta name="description">` | HIGH |
| sitemap.xml exists | Auto-generated or manually maintained | HIGH |
| robots.txt configured | Allows crawling of public pages, blocks admin/API | MEDIUM |
| Canonical URLs on all pages | `<link rel="canonical">` prevents duplicate content | HIGH |
| No accidental `noindex` on public pages | No `noindex` on pages that should be indexed | HIGH |
| HTTPS enforced | HTTP redirects to HTTPS, HSTS header set | HIGH |
| JSON-LD structured data on homepage | At minimum `Organization` schema | HIGH |
| OpenGraph + Twitter Card tags | `og:title`, `og:description`, `og:image` on public pages | MEDIUM |

### Core Web Vitals (CWV) — runtime-only, NOT statically analyzable

**Honest scope note:** v-check is a static/grep audit and **cannot measure Core Web Vitals from source code**. There are no LCP/INP/CLS thresholds to grep for — these are field/lab metrics produced by a real page load. Do **not** emit a CWV finding with a fabricated number.

Instead, emit a single pointer finding:

> **Run Lighthouse or PageSpeed Insights (PSI)** against the public pages and report against the current Google "good" thresholds — number source: `~/.claude/skills/references/seo-volatile-knowledge-2026.md` § Core Web Vitals (verify against web.dev/vitals if that file is stale):
> - **LCP** (Largest Contentful Paint) ≤ **2.5s**
> - **INP** (Interaction to Next Paint) ≤ **200ms** — **INP replaced FID as a Core Web Vital in March 2024; do NOT report FID.**
> - **CLS** (Cumulative Layout Shift) ≤ **0.1**

Optional static *correlates* (signals that may hurt CWV, but are NOT a CWV measurement — report them as performance hints, not CWV scores): unoptimized/unsized `<img>` (CLS/LCP risk), render-blocking scripts, missing `loading="lazy"`, large JS bundles (see Domain 2 bundle-size check), no `font-display: swap`.

**For comprehensive SEO audit:** Invoke `/v-audit-seo` (canonical for all SEO depth beyond these quick checks). The specialist audit covers 9 dimensions: technical SEO, on-page optimization, content quality and gaps, keyword research and intent, SERP analysis, content strategy, structured data / AI-search readiness, off-site growth / link earning, and alternative-page opportunities. (Dimension list lockstep with `v-audit-seo/SKILL.md` § The 9 SEO Audit Dimensions — update together.)

Do not duplicate SEO analysis here. Report the quick-check findings above and recommend `/v-audit-seo` when deeper analysis is needed.

## 8. AI/LLM INTEGRATION (If AI Features Detected)

**Auto-skip if no AI/LLM code detected.** Run the detection grep first — if no matches, skip this domain entirely and do not report it as N/A in the output. Only proceed if AI/LLM usage is positively detected:

```bash
# Detect AI/LLM usage. Terms are word-bounded against LETTER neighbors
# only (not underscore/digit) so snake_case identifiers like
# `llm_call`/`call_llm`/`openai_request` still match, while an
# unrelated English word that merely CONTAINS the substring (e.g.
# "hallmark" contains "llm", "Mumbai_office" contains "ai_") does not.
grep -rnE "(^|[^a-zA-Z])(openai|anthropic|claude|gpt|llm|ai_)([^a-zA-Z]|$)|\bAiService\b|\bLlmService\b" app/ config/ --include="*.php" -l 2>/dev/null
grep -rnE "(^|[^a-zA-Z])(openai|anthropic|langchain)([^a-zA-Z]|$)|@ai-sdk" package.json 2>/dev/null
```

| Check | Pattern | Priority |
|-------|---------|----------|
| API keys in env (not code) | Hardcoded API keys | P0 |
| Cost tracking | Token usage logging | P1 |
| Rate limiting on AI endpoints | Throttle middleware on AI routes | P1 |
| Input sanitization | User input cleaned before prompts | P1 |
| Output filtering | AI responses validated/filtered | P1 |
| Timeout handling | AI calls have timeouts | P1 |
| Fallback on failure | Graceful degradation when AI unavailable | P2 |
| PII detection | User data filtered from prompts | P1 |
| **Indirect prompt injection** | Retrieved/external content (RAG, fetched pages, uploads, tool output) ingested as instructions, not fenced as data | P0 |
| **Excessive agency / tool abuse** | Agent tools scoped broader than needed; destructive/financial tools without confirmation gate | P0 |

> Tracks the **OWASP LLM Top 10** — verify the current category list at owasp.org. See `references/v-security-baseline.md` § LLM / Agent Attack Surface for the full discipline.

### Prompt Injection Detection (direct)
- User input concatenated directly into LLM prompts without sanitization
- Missing input validation before AI API calls
- No output filtering/guardrails on LLM responses displayed to users
- System prompts exposed in client-side code or API responses

### Indirect Prompt Injection (via retrieved/external content)
The attacker doesn't talk to the model — they plant instructions where the model will read them:
- RAG documents, fetched web pages, emails, PDFs, and user-uploaded files ingested without treating their content as untrusted **data** (not instructions)
- Tool/function-call results fed back into the prompt without fencing — a malicious tool output can hijack the agent
- System prompt / trust boundary not re-asserted after retrieval, so injected text in a chunk can override it
- No injection classifier or content-provenance separation between trusted instructions and retrieved content

### Excessive Agency / Tool Abuse (over-broad tool scopes)
- Agent granted tool scopes broader than the task requires (write/delete/spend when read-only would do)
- Destructive, financial, or irreversible tool calls execute without human-in-the-loop confirmation
- One agent both ingests untrusted content AND holds high-privilege tools, with no gate between them
- Tool inputs derived from model output not validated server-side (the model is an untrusted input source to your own APIs)
- Tool invocations not rate-limited or audit-logged (`user_id`, tool, args, result), so abuse is undetectable

### SSRF via AI Integrations
- Unvalidated URLs passed to AI services (e.g., "analyze this URL" features)
- User-controlled URLs in webhook configurations without allowlist
- AI-generated URLs followed without validation (apply the full SSRF discipline in `references/v-security-baseline.md` § SSRF — block 169.254.169.254 + private ranges, enforce egress allowlist)

### Token & Secret Leakage
- API keys in error messages or stack traces
- LLM API keys in client-side bundles (check build output)
- Tokens logged at debug level that could appear in production logs
- AI service responses cached with sensitive context

## 9. FEATURE COMPLETENESS (If SaaS/App)

Context-dependent checks. First detect what the app is, then flag missing expected features. Skip items that don't apply to the project scope.

### 9a. Detect App Type

```bash
# What kind of app is this?
ls app/Models/*.php 2>/dev/null | xargs -I{} basename {} .php | sort
php artisan route:list --json 2>/dev/null | jq -r '.[].uri' | head -30
ls resources/js/Pages/**/*.tsx 2>/dev/null | head -20

# Team/multi-tenant?
grep -rnE "team|tenant|organization|workspace" app/Models/ --include="*.php" -l

# Billing?
grep -rnE "Billable|cashier|stripe" app/Models/ --include="*.php" -l
test -f config/cashier.php && echo "Cashier configured"
```

### 9b. Backend Patterns

| Check | Detection | Priority |
|-------|-----------|----------|
| DB transactions on mutations | `DB::transaction` in store/update/destroy methods | P1 |
| Undeclared `SoftDeletes` usage | `SoftDeletes` trait present on a model with NO matching exception in project CLAUDE.md | P2 |
| Activity/audit logging | `Activity` model or `spatie/laravel-activitylog` | P2 |
| Search implementation | Scout, `LIKE` queries, or full-text indexes | P1 |
| Security headers | CSP, HSTS, X-Frame-Options middleware | P1 |
| Webhook signature verification | `$request->header('Stripe-Signature')` or equivalent | P1 |

```bash
# DB transactions
grep -rnE "DB::transaction|DB::beginTransaction" app/Http/Controllers app/Services --include="*.php" | wc -l
grep -rnE "public function store|public function update|public function destroy" app/Http/Controllers --include="*.php" | wc -l

# Undeclared SoftDeletes usage — global default is hard deletes (SoftDeletes caused silent data
# restoration bugs). Any hit here is a P2 UNLESS the project's CLAUDE.md names that specific model
# as an explicit exception (e.g. one named soft-deletable model) — cross-check before flagging.
grep -rn "SoftDeletes" app/Models --include="*.php" -l

# Activity logging
composer show spatie/laravel-activitylog 2>/dev/null && echo "INSTALLED"
grep -rnE "activity\(\)|log\(" app/ --include="*.php" | grep -v "Log::" | head -5

# Search
grep -rnE "Searchable|Scout|LIKE|MATCH.*AGAINST" app/ --include="*.php" | head -5

# Security headers
grep -rnE "Content-Security-Policy|X-Frame-Options|Strict-Transport" app/Http/Middleware --include="*.php"
```

### 9c. Frontend Patterns

| Check | Detection | Priority |
|-------|-----------|----------|
| Bulk operations | Checkbox select + batch action buttons | P1 |
| Data export | CSV/PDF download routes or buttons | P1 |
| Data import | File upload + validation UI | P2 |
| Data tables with sort/filter | Column headers with sort, filter inputs | P1 |
| Confirmation on destructive actions | Confirm dialog before delete/cancel | P1 |
| Toast/notification system | Sonner, react-hot-toast, or custom | P1 |
| Command palette | Cmd+K / Ctrl+K handler | P2 |

```bash
# Bulk operations
grep -rnE "selectAll|selectedIds|bulkAction|bulk" resources/js --include="*.tsx" | head -5

# Export
grep -rnE "export|download|csv|pdf" routes/web.php routes/api.php --include="*.php" | grep -ivE "import|component"
grep -rnE "Export|Download|CSV" resources/js --include="*.tsx" | head -5

# Data tables
grep -rnE "sortBy|orderBy|filterBy|<Table|DataTable" resources/js --include="*.tsx" | head -5

# Confirmation dialogs — a native confirm( hit counts as PRESENCE only: native browser
# confirm() is itself a craft finding (anti-template gauntlet: "native browser dialog
# instead of styled modal", MEDIUM). Don't list it in VERIFIED_GOOD without that caveat.
grep -rnE "AlertDialog|confirm\(|Confirmation|ConfirmDialog" resources/js --include="*.tsx" | head -5

# Toast system
grep -rnE "toast|Sonner|react-hot-toast|Toaster" resources/js --include="*.tsx" | head -3

# Command palette
grep -rnE "cmdk|CommandDialog|Cmd\+K|command-palette" resources/js --include="*.tsx" | head -3
```

### 9d. Team/Multi-User Patterns (If Team Model Detected)

Only check if team/organization/workspace model exists:

| Check | Detection | Priority |
|-------|-----------|----------|
| Team invitations | Invite model or invitation routes | P1 |
| Role-based team access | Team roles/permissions | P1 |
| Team-scoped queries | `where('team_id', ...)` or global scope | P0 |
| Team switching | UI to switch between teams | P1 |

```bash
# Only run if team model exists
if ls app/Models/ 2>/dev/null | grep -qiE "team|organization|workspace"; then
  grep -rnE "invitation|invite" app/ routes/ --include="*.php" | head -5
  grep -rnE "team_id|organization_id|workspace_id" app/ --include="*.php" | wc -l
  grep -rnE "role|permission" app/ --include="*.php" | grep -i "team" | head -5
fi
```

### 9e. Billing Patterns (If Stripe/Cashier Detected)

Only check if Cashier/Stripe is configured:

| Check | Detection | Priority |
|-------|-----------|----------|
| Trial period handling | `onTrial()` checks in UI and backend | P1 |
| Plan upgrade/downgrade | Swap subscription routes | P1 |
| Failed payment recovery | `pastDue()` checks, dunning UI | P1 |
| Invoice access | Invoice download route | P2 |
| Cancellation flow | Cancel + resume routes, confirmation UI | P1 |

```bash
# Only run if Cashier installed
if test -f config/cashier.php; then
  grep -rnE "onTrial|trialEndsAt" app/ resources/js --include="*.php" --include="*.tsx" | head -5
  grep -rnE "swap|changePlan|upgrade|downgrade" app/ routes/ --include="*.php" | head -5
  grep -rnE "pastDue|hasIncompletePayment|dunning" app/ --include="*.php" | head -5
  grep -rnE "invoice|downloadInvoice" routes/ --include="*.php" | head -3
  grep -rnE "cancel|resume" routes/ --include="*.php" | grep -i "subscri" | head -5
fi
```

---

## 10. PARALLEL DEEP ANALYSIS (Agent-Assisted)

If an agents directory exists, dispatch parallel Agent subagents for deeper code-level analysis that supplements grep-based detection. Skip in Quick mode.

**Agent directory lookup order** (project-level takes precedence):
1. `.claude/agents/` (project-level, relative to repo root)
2. `~/.claude/agents/` (global, user home directory)

**Detection:**
```bash
ls .claude/agents/*.md 2>/dev/null || ls ~/.claude/agents/*.md 2>/dev/null && echo "AGENTS_AVAILABLE=true"
```

Follow the Agent Dispatch Protocol in `_v-review.md` from the active skill tree for agent selection and worktree-isolated review behavior. For audit context:

1. **Discover available agents:** List all `.md` files in the agents directory. Do not assume specific agent names exist — dispatch whatever agents are found.
2. **Select by relevance:** Match agent names/descriptions to the audit type and changed file types. For example, an agent mentioning "eager loading" is relevant for performance audits on PHP files.
3. **Always add `codex-adversarial-reviewer`** when `codex-adversarial-reviewer.md` exists in either agents directory — dispatch is mandatory; if Codex CLI is unavailable, record `agent_dispatch: skipped, reason: cli_unavailable` and invoke `superpowers:requesting-code-review` via Skill tool per `_v-review.md`. Elevate to hostile adversarial focus for Security or Full audit with auth, payments, file upload, data deletion, encryption, or external-input risk.

Merge agent findings into the appropriate P0/P1/P2 sections of the audit report.

**If neither agents directory exists:** Skip this section entirely. The grep-based analysis in domains 1-9 is sufficient.

### Domain 11 — Observability & Monitoring

**Structured Logging**
| Check | Pattern | Severity |
|-------|---------|----------|
| No raw console.log in production code | `grep -rnE "console\.log|console\.debug" --include="*.ts" --include="*.tsx" app/ \| grep -vE "test|spec"` | MEDIUM |
| Structured log format (JSON or key-value) | Logger configured with structured output, not string concatenation | MEDIUM |
| Request context in logs | Every log entry includes request_id, user_id where available | MEDIUM |
| No sensitive data in logs | Passwords, tokens, API keys, credit cards never logged even at debug level (canonical list: CLAUDE.md § Security Defaults). Emails are NOT on the never-log list — required failed-login logging (v-security-baseline § Monitoring & Alerting) legitimately logs the attempted email; still minimize incidental PII (advisory, not CRITICAL) | CRITICAL |

**Error Tracking** (in-repo only, per `_v-audit.md` § In-App Actionability Boundary — absence of an external error-tracking service is NEVER a finding; adding one is off-stack)
| Check | Pattern | Severity |
|-------|-------|----------|
| Error-tracking SDK already in the stack is wired correctly | IF an error-tracking dependency already exists in composer.json/package.json: initialized, DSN via `.env`, not hardcoded. If none exists: skip — do not recommend adding one | MEDIUM |
| Error boundaries in React | Top-level and route-level error boundaries present | MEDIUM |
| Unhandled rejection handler | Global handler for unhandled promise rejections | MEDIUM |

**Performance Monitoring** (in-repo only, per `_v-audit.md` § In-App Actionability Boundary — "alerts" below means in-app notification code/admin surfaces, never an external paging or APM service)
| Check | Pattern | Severity |
|-------|---------|----------|
| Request timing instrumentation | In-repo middleware (or an APM SDK already in the stack) tracking response times | MEDIUM |
| Database query monitoring | Slow query logging configured (>1s threshold) | MEDIUM |
| External API call tracking | Timeouts, retries, and latency tracked for third-party calls | MEDIUM |
| Queue job monitoring | In-app failed-job notifications/admin surface wired, job duration tracked | MEDIUM |

**Alerting** (in-repo only, per `_v-audit.md` § In-App Actionability Boundary — external paging/uptime services are off-stack; never flag their absence)
| Check | Pattern | Severity |
|-------|-------|----------|
| In-app alert code correctness | Where the repo already implements alerting/notifications (failed-job mail, exception notifications via the app's existing mailer/channels), it is wired and correct | MEDIUM |
| Health/self-check endpoint | An in-app health route (`/up`, `/health`, or artisan health command) exists and exercises critical dependencies (DB, cache, queue) | MEDIUM |
| Alert fatigue mitigation | In-app notifications grouped/deduplicated/throttled, not firing per-occurrence | MEDIUM |

**Analytics Instrumentation Triage** (existence only — `/v-audit-analytics` is the canonical owner of all analytics analysis per `~/.claude/skills/references/v-core-audit-ownership.md`; do NOT emit taxonomy/naming/funnel findings here)
| Check | Pattern | Severity |
|-------|-------|----------|
| Product analytics events exist at all | Run the detection grep below. Zero product events on a launched product, or flow-level presence gaps (a signup/checkout flow with no events at all — presence at flow level only, NO per-event coverage analysis, which is v-audit-analytics Dim 3/6 territory), is a triage finding: report it and recommend `/v-audit-analytics` | MEDIUM |

```bash
# Analytics instrumentation existence (triage only)
grep -rnE "track\(|posthog\.capture\(|mixpanel\.track\(|analytics\.|gtag\(|plausible\(" \
  --include='*.ts' --include='*.tsx' --include='*.php' app/ resources/ src/ 2>/dev/null | head -5
```

---

## Depth Modifiers

### Thorough Mode
- Read ALL files in each category
- Cross-reference findings
- Include edge case analysis
- Full dependency audit

### Standard Mode
- Sample files from each category
- Focus on common patterns
- Basic dependency check

### Quick Mode
- Grep-based detection only
- P0 issues only
- Skip P2 entirely
- No file reading except for evidence

---

## Audit Order

Always audit in this order (security first — matches SKILL.md § Audit Order):

1. **Security** - Vulnerabilities that could expose data
2. **Performance** - Slowness or scaling problems
3. **Test Coverage** - Missing safety nets
4. **UX** - User-facing issues
5. **Tech Debt** - Maintainability concerns
6. **Accessibility** - WCAG 2.2 AA compliance
7. **SEO** - Search visibility (if applicable)
8. **AI/LLM Integration** - API key safety, cost tracking, rate limiting, PII (if AI features detected)
9. **Feature Completeness** - Missing expected functionality (if SaaS/app, includes data integrity checks)
10. **Parallel Deep Analysis** - Agent-assisted review (Thorough/Standard modes only)
11. **Observability & Monitoring** - Logging, error tracking, alerting
12. **Config Validation (.env\*)** - `.env*` mismatches with `.env.example`, missing required env vars, wrong values, stale vars

---

## Already-Configured Detection

Before recommending infrastructure changes, CHECK FIRST:

```bash
# Redis/Horizon
grep -E "QUEUE_CONNECTION|CACHE_STORE" .env
test -f config/horizon.php && echo "Horizon configured"

# Circuit breakers
grep -rn "CircuitBreaker" app/Services --include="*.php"

# Rate limiting
grep -rn "RateLimiter::for" app/Providers --include="*.php"
```

**Report as verified, not missing.**


---

## Domain 12: Config Validation (.env*) — added 2026-04-29

> **Persona:** senior DevOps / release engineer focused on the
> config-validation subset that catches "I forgot to set this
> env var" / "the value is wrong for this environment" issues.
> Migrated from the retired `/v-ship` skill (retired 2026-04-29);
> operational-readiness checks (monitoring, payments, runtime HSTS
> deployment verification, backups) are NOT in scope — static HSTS
> header checks remain in Domain 1 (see § What's NOT in Domain 12).

### What Domain 12 audits

The `.env*` config layer is one of the highest-leverage audit
surfaces — env-var mistakes silently break production and are
hard to detect via runtime testing (the config seems to load
fine; the wrong value just produces wrong behavior).

| Sub-check | Method | Severity |
|---|---|---|
| **Missing required env vars** | Compare `.env.example` against deployed env (`.env`, `.env.production` if present); flag vars in `.example` but not in actual env | P0 (broken app) |
| **Stale env vars** | Vars in `.env` but no longer in `.env.example` AND not referenced in code (`grep` codebase) — likely leftover from removed features | P2 (cleanup) |
| **Wrong values for production** | `APP_DEBUG=true`, `APP_ENV=local`, dev database URLs, localhost references, fake API keys (`sk_test_*` in production env) | P0 (broken or unsafe) |
| **Hardcoded secrets that should be env-vars** | Grep for `sk_live_`, `AKIA`, `ghp_`, JWT-shaped tokens, password-like strings in source code (NOT in `.env*`) | P0 (security) |
| **Secrets in tracked files vs project policy** | `.env.example` is always safe to track. For `.env` and variants, commit policy is per-project (CLAUDE.md § Security Defaults: `.env*` may be committed per project policy — v-build treats a policy-sanctioned tracked `.env` as expected and safe). Flag a tracked `.env` as P0 ONLY when the project's stated policy does not allow it; when policy is silent, the default expectation is gitignored | P0 (leak risk — policy-conditional) |

### Detection commands

```bash
# 1. Compare .env.example to .env (find missing vars)
if [ -f .env.example ] && [ -f .env ]; then
  diff <(grep -E '^[A-Z]' .env.example | cut -d'=' -f1 | sort)        <(grep -E '^[A-Z]' .env | cut -d'=' -f1 | sort) | head -20
fi

# 2. Find vars in .env not in .env.example (potentially stale)
if [ -f .env.example ] && [ -f .env ]; then
  comm -23 <(grep -E '^[A-Z]' .env | cut -d'=' -f1 | sort)            <(grep -E '^[A-Z]' .env.example | cut -d'=' -f1 | sort) | head -10
fi

# 3. Detect wrong values in any production-shaped env
for f in .env .env.production .env.staging; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  grep -E '^(APP_DEBUG|APP_ENV)=' "$f" | head -5
  grep -E 'localhost|127\.0\.0\.1|sk_test_|pk_test_|MAIL_HOST=mailhog|QUEUE_CONNECTION=sync' "$f" | head -10
done

# 4. Hardcoded secrets in source (should be in .env)
grep -rn -E '(sk_live_[a-zA-Z0-9]+|AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36}|Bearer [a-zA-Z0-9_\-\.]{30,})'   --include='*.php' --include='*.ts' --include='*.tsx' --include='*.js'   --exclude-dir=node_modules --exclude-dir=vendor 2>/dev/null | head -10

# 5. .gitignore safety check — POLICY-CONDITIONAL (CLAUDE.md § Security Defaults:
# `.env*` may be committed per project policy). A hit below is a P0 only when the
# project's CLAUDE.md does NOT explicitly allow tracked `.env*`; check policy first.
if ! grep -qE '^\.env$|^\.env\*' .gitignore 2>/dev/null; then
  echo "NOTE: .env not in .gitignore — check project commit policy before flagging"
fi
git ls-files | grep -E '^\.env$|^\.env\.production$|^\.env\.staging$' | head -5
```

### What's NOT in Domain 12 (out of scope for this audit)

The following were in the retired `v-ship` skill (retired 2026-04-29) but are intentionally NOT in v-check:
- Monitoring setup (Sentry / DataDog / etc. configuration)
- Payment provider config (Stripe webhook URLs, signing secrets verification — these ARE in scope as missing-env-var detection, but provider-specific config flow is not)
- HSTS verification + security headers (these ARE in Domain 1 Security; Domain 12 is just env-var subset)
- Backup configuration
- Queue worker automation (cron / supervisor)
- First-72h watchlist generation
- Post-launch automation setup

These will return as a separate skill when the operator's projects have a meaningful operational surface area.
