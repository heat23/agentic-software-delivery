# Admin Audit Checklists & Detection Patterns

Referenced by `v-audit-admin/SKILL.md`. Load this file when executing discovery passes and audit domains.

_Last reviewed: 2026-08-02 (SME coverage-gap fix: the Domain 4 admin-controller authorization check was rewritten from presence-only to detect instance-less `authorize()`/`can()` calls — the classic IDOR/BOLA a class-reference second argument passes cleanly; the Tenant Isolation section below was rewritten from two unscored greps into a full enumerate-every-model plus bypass-path plus worked-test scored checklist, the single most damaging failure class for AI-built multi-tenant SaaS)._

---

## Discovery Patterns

### Pass 1: Route Scan

```bash
# Laravel: List admin routes via artisan (preferred)
php artisan route:list --json 2>/dev/null | jq -r '.[] | select(.uri | test("^admin|^dashboard|^manage|^backoffice|^internal")) | "\(.method) \(.uri) → \(.action)"'

# Fallback: grep route files
grep -rn "Route::" routes/web.php routes/admin.php 2>/dev/null | grep -iE "admin|dashboard|manage|backoffice|internal" | head -40

# Detect admin prefix
grep -rn "prefix.*admin\|prefix.*dashboard\|prefix.*manage\|prefix.*backoffice" routes/ --include="*.php" | head -5

# Detect admin middleware group
grep -rn "middleware.*admin\|middleware.*is_admin\|middleware.*role:admin\|middleware.*can:admin" routes/ --include="*.php" | head -10

# Map routes to controllers
grep -rn "Route::resource\|Route::apiResource\|Route::get\|Route::post\|Route::put\|Route::delete\|Route::patch" routes/ --include="*.php" | grep -iE "admin|dashboard|manage" | head -30

# Detect Inertia pages for admin
grep -rn "Inertia::render\|inertia(" app/Http/Controllers/ --include="*.php" | grep -iE "Admin|Dashboard|Manage" | head -20

# Framework-agnostic: find admin-like directories
ls -d resources/js/Pages/Admin* resources/js/Pages/admin* resources/views/admin* src/pages/admin* src/app/admin* app/admin* pages/admin* 2>/dev/null
```

### Route Classification

Classify each route by its HTTP method and URI pattern:

| Pattern | Classification |
|---------|---------------|
| `GET /admin/{resource}` | index |
| `GET /admin/{resource}/create` | create |
| `POST /admin/{resource}` | store |
| `GET /admin/{resource}/{id}` | show |
| `GET /admin/{resource}/{id}/edit` | edit |
| `PUT/PATCH /admin/{resource}/{id}` | update |
| `DELETE /admin/{resource}/{id}` | destroy |
| Other | custom |

### Pass 2: Model Scan

```bash
# Laravel: List all Eloquent models
ls app/Models/*.php 2>/dev/null | xargs -I{} basename {} .php | sort

# Check SoftDeletes usage
grep -rn "SoftDeletes" app/Models --include="*.php" -l

# Cross-reference: for each model, check if admin routes exist
for model in $(ls app/Models/*.php 2>/dev/null | xargs -I{} basename {} .php); do
  # Convert ModelName to a kebab route segment (e.g., BlogPost -> blog-post).
  # NOTE: do NOT use `sed 's/.../-\L\1/'` — the `\L` lowercase escape is GNU-only and on
  # macOS/BSD sed emits a LITERAL "l" (BlogPost -> lblog-lpost), which made every model
  # false-positive as NO_ADMIN_CRUD. Portable form: insert a space before each capital,
  # lowercase via tr, then hyphenate.
  segment=$(echo "$model" | sed 's/\([A-Z]\)/ \1/g' | tr '[:upper:]' '[:lower:]' | sed 's/^ //; s/ /-/g')
  # Naive "${segment}s" mispluralizes irregulars (company->companys, category->categorys,
  # box->boxs). Instead derive a SEARCH STEM by dropping a trailing y/s and substring-match
  # the route list — the stem is shared by both the singular and the correct plural
  # (compan/categor/statu/box all match companies/categories/statuses/boxes). Fall back to the
  # full singular segment too so single-word models still match, and Str::plural irregulars
  # (Person->people) that share no stem are caught by the controller-import fallback below.
  stem=$(echo "$segment" | sed 's/y$//; s/s$//')
  found=$(php artisan route:list --json 2>/dev/null | jq -r ".[].uri" \
    | grep -iE "admin|dashboard|manage" | grep -iE "$stem|$segment" | head -1)
  if [ -z "$found" ]; then
    echo "NO_ADMIN_CRUD: $model  # verify against the controller-import fallback before flagging (irregular plurals like Person->people share no stem)"
  else
    echo "HAS_ADMIN: $model -> $found"
  fi
done

# Fallback: grep for model references in admin controllers
grep -rn "use App\\\\Models\\\\" app/Http/Controllers/Admin/ --include="*.php" 2>/dev/null | sed 's/.*Models\\\\//' | sed 's/;.*//' | sort -u

# Django: List models
grep -rn "class.*models.Model" */models.py 2>/dev/null | head -20

# Rails: List models
ls app/models/*.rb 2>/dev/null | xargs -I{} basename {} .rb | sort
```

### Pass 3: Page Scan (Thorough: full; Standard: fingerprint-only)

**Standard mode (Pass 3-lite):** skip the feature-detection loop below — run only the fingerprint computation from Domain 6 § Shared-Shell Breaks so Domain 2 has shell-conformance data. Feature Inventory Matrix feature columns stay `?`.

```bash
# Find all admin page components
find resources/js/Pages/Admin -name "*.tsx" -o -name "*.jsx" -o -name "*.vue" 2>/dev/null | sort

# For each page, detect structural features
for page in $(find resources/js/Pages/Admin -name "*.tsx" 2>/dev/null); do
  echo "=== $page ==="
  # Tables
  grep -c "<Table\|<table\|DataTable\|<thead\|columns=" "$page" 2>/dev/null && echo "  HAS_TABLE"
  # Forms
  grep -c "<form\|useForm\|<Form\|handleSubmit" "$page" 2>/dev/null && echo "  HAS_FORM"
  # Search
  grep -c "search\|Search\|onSearch\|searchQuery\|filterText" "$page" 2>/dev/null && echo "  HAS_SEARCH"
  # Filters
  grep -c "filter\|Filter\|filterBy\|activeFilter" "$page" 2>/dev/null && echo "  HAS_FILTER"
  # Bulk operations
  grep -c "selectAll\|selectedIds\|bulkAction\|selectedRows\|checkbox" "$page" 2>/dev/null && echo "  HAS_BULK"
  # Export
  grep -c "export\|Export\|download\|Download\|csv\|CSV" "$page" 2>/dev/null && echo "  HAS_EXPORT"
  # Pagination
  grep -c "paginate\|Pagination\|nextPage\|prevPage\|per_page\|links" "$page" 2>/dev/null && echo "  HAS_PAGINATION"
  # Empty states
  grep -c "empty\|Empty\|no.*found\|No.*found\|length === 0" "$page" 2>/dev/null && echo "  HAS_EMPTY_STATE"
  # Loading states
  grep -c "loading\|Loading\|skeleton\|Skeleton\|spinner\|Spinner\|isLoading" "$page" 2>/dev/null && echo "  HAS_LOADING"
  # Error boundaries
  grep -c "ErrorBoundary\|error\|Error\|catch\|fallback" "$page" 2>/dev/null && echo "  HAS_ERROR_HANDLING"
  # Confirmation dialogs
  grep -c "confirm\|Confirm\|AlertDialog\|Modal.*delete\|ConfirmDialog" "$page" 2>/dev/null && echo "  HAS_CONFIRMATION"
done
```

### Structural Fingerprint (Shell-Consistency Detection)

Layout consistency across admin pages is REQUIRED (spec §1: sidebar, search, theme toggle, notifications, profile identical on every page — content area is the only thing that changes). The fingerprint detects pages that DIVERGE from the shared shell, not uniformity.

```bash
# For each admin index page, extract layout structure
for page in $(find resources/js/Pages/Admin -name "Index.tsx" -o -name "index.tsx" -o -name "List.tsx" 2>/dev/null); do
  # Extract JSX structure (simplified — look for top-level layout components)
  echo "=== $(basename $(dirname $page))/$(basename $page) ==="
  grep -E "^\s*<(div|section|Card|Panel|Container|Layout|Table|Header|Page)" "$page" | head -15
done

# Identify the dominant (shared) shell pattern, then list the pages that do NOT match it
# Pages off the dominant shell (different sidebar/header wiring, off-spec components) = ADM-AI finding
```

---

## Domain 1: Functional Completeness (PM)

ID Prefix: `ADM-PM-`

### Missing CRUD Checks

**Exemption class (apply BEFORE flagging — check every model against this list first):** a model with
no admin CRUD is only a finding when it's a **user-facing domain model** an operator would plausibly
need to view/create/edit/delete from the back office. The following model shapes are EXEMPT — do not
emit a missing-CRUD finding for them (this prevents the report flooding with noise on every pivot table):

| Exempt shape | Why | Detection heuristic |
|---|---|---|
| Pivot / join table | No standalone identity — managed through its parent's relationship UI, not directly | Model name is `*_pivot`, has only foreign keys + timestamps, or is registered as a Many-to-Many pivot class |
| Read-only / lookup / reference table | Static or admin-seeded reference data (statuses, categories, currencies, country lists) with no create/edit workflow by design | Migration has no corresponding form/mutation route anywhere in the codebase, or model docblock/comment says "seeded"/"reference" |
| System / framework model | Not a business domain concept — queue jobs, cache entries, sessions, password resets, personal access tokens | Model lives in a framework/package namespace, or is one of Laravel's built-ins (`FailedJob`, `PersonalAccessToken`, `Session`) |
| Internal/log/audit-trail model | Written by the system, never edited by a human — the admin UI is a read-only viewer at most, never a CRUD form | Model is append-only (activity log, webhook log, audit entries) with no human mutation path |
| Denormalized/cache/derived model | Materialized from other tables; editing it directly would be overwritten by the next recompute | Model is populated by a job/observer from another model, not from user input |

Only after a model fails ALL of the above exemptions does it qualify for a missing-CRUD finding below.
When in doubt (ambiguous model), downgrade to `confidence: "low"` rather than skip — do not silently omit
a genuinely user-facing gap, but do not manufacture noise on data-plumbing models either.

For each model identified in Pass 2 that is NOT exempt and lacks admin CRUD:

| Check | Severity | Evidence |
|-------|----------|----------|
| Model has no admin index route | P1 | Route list output |
| Model has no admin create/store route | P1 | Route list output |
| Model has no admin edit/update route | P1 | Route list output |
| Model has no admin delete route | P1 | Route list output |
| SoftDeleted model has no restore route | P1 | `grep SoftDeletes` + route list |

### Bulk Operations

```bash
# Check for bulk selection UI
grep -rn "selectAll\|selectedIds\|bulkAction\|selectedRows\|bulk" resources/js/Pages/Admin --include="*.tsx" | head -10

# Check for bulk action endpoints
grep -rn "bulk\|batch\|mass" routes/ --include="*.php" | grep -iE "admin|dashboard" | head -10

# Check for bulk delete
grep -rn "bulkDelete\|massDelete\|deleteSelected\|destroyMany" app/Http/Controllers/Admin --include="*.php" 2>/dev/null | head -5
```

| Check | Severity | Condition |
|-------|----------|-----------|
| No bulk operations on any list view | P1 | >10 items possible in any resource |
| Bulk delete without confirmation | P0 | Destructive operation unconfirmed |
| No select-all across pages | P2 | Pagination present but select limited to current page |

### Data Export

```bash
# Check for export functionality
grep -rn "export\|Export\|download\|Download\|csv\|CSV\|xlsx\|pdf" resources/js/Pages/Admin --include="*.tsx" | head -10
grep -rn "export\|download\|csv\|StreamedResponse\|BinaryFileResponse" app/Http/Controllers/Admin --include="*.php" 2>/dev/null | head -10
```

| Check | Severity |
|-------|----------|
| No export on any data table | P1 |
| Export without date/filter range | P2 |

### Admin-Specific Pages (AI Never Builds)

These are the 11 pages AI rarely generates but every production admin needs. Check for each:

```bash
# 1. Audit/Activity Log
grep -rn "activity\|audit\|ActivityLog\|AuditLog\|action_log" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -3
grep -rn "activity\|audit_log\|action_log" routes/ --include="*.php" | grep -iE "admin" | head -3
composer show spatie/laravel-activitylog 2>/dev/null && echo "ACTIVITY_LOG_INSTALLED"

# 2. System Health / Dashboard
grep -rn "health\|Health\|system.*status\|SystemHealth\|ServerStatus" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -3

# 3. Failed Jobs Monitor
grep -rn "failed.*job\|FailedJob\|failed_jobs" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -3
grep -rn "failed.*job\|failed-jobs" routes/ --include="*.php" | grep -iE "admin" | head -3

# 4. Session Manager
grep -rn "session\|Session\|active.*session\|UserSession" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -3

# 5. Feature Flags
grep -rn "feature.*flag\|FeatureFlag\|pennant\|feature_flag" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -3

# 6. Cache Management
grep -rn "cache\|Cache\|flush.*cache\|clear.*cache\|CacheManager" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -3

# 7. User Impersonation
grep -rn "impersonat\|Impersonat\|login.*as\|loginAs\|act.*as" app/ routes/ --include="*.php" | head -5

# 8. Data Export Center (centralized)
grep -rn "export.*center\|ExportCenter\|bulk.*export\|DataExport" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -3

# 9. Scheduled Task Monitor
grep -rn "schedule\|Schedule\|cron\|ScheduledTask" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -3

# 10. Notification Center (admin-sent)
grep -rn "notification.*center\|NotificationCenter\|send.*notification\|broadcast\|announcement" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -3

# 11. Billing / Subscription Support (view sub, refund, retry failed payment, comp/credit)
#     The #1 founder-admin surface: when a customer emails "I was double-charged" / "my card failed" /
#     "please refund", the operator needs an in-admin way to act WITHOUT opening the Stripe dashboard.
grep -rn "refund\|Refund\|issueRefund\|creditNote\|comp\|credit\|retryPayment\|retryInvoice\|manage.*subscription\|SubscriptionManage\|billing.*admin\|adminBilling" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -5
grep -rn "refund\|creditNote\|retryPayment\|retryInvoice\|swapAndInvoice\|->refund(" app/Http/Controllers/Admin --include="*.php" 2>/dev/null | head -5
grep -rn "refund\|subscription\|invoice\|dunning" routes/ --include="*.php" | grep -iE "admin|dashboard" | head -5
```

| Page | Severity | When Required |
|------|----------|---------------|
| Audit/Activity Log | P0 | Always — admin actions must be traceable |
| Billing / Subscription Support | P1 | When the product charges money (Stripe/Cashier/Paddle present) — the operator must be able to view a customer's subscription, issue a refund, retry a failed payment, and comp/credit an account from admin, not only the Stripe dashboard. Missing = every billing support request forces a context-switch to Stripe and leaves no in-app audit trail. Escalate to **P0** when the operator has paying customers AND there is no other admin-side billing action surface at all |
| System Health Dashboard | P1 | Always — admins need system status at a glance |
| Failed Jobs Monitor | P1 | When queues are used |
| Session Manager | P2 | When multi-session security matters |
| Feature Flags | P2 | When >3 features or gradual rollout needed |
| Cache Management | P2 | When caching is used |
| User Impersonation | P2 | When supporting users requires context |
| Data Export Center | P2 | When multiple resources need export |
| Scheduled Task Monitor | P2 | When scheduled tasks exist |
| Notification Center | P2 | When admin-to-user communication needed |

**Billing/Subscription Support — what the surface must cover** (each absent capability, when the product
charges money, is its own sub-finding under `ADM-PM-`; use Cashier's real APIs, not fabricated ones):
- **View subscription state** — current plan, status (active/past_due/canceled/on grace period), renewal date, read via `$user->subscription('default')` (method) or the `subscriptions` relation (there is NO bare `subscription` relation).
- **Issue a refund** — refund a charge/invoice from admin (`$user->refund($paymentIntentId)` / a Cashier refund path), with a reason field captured to the audit log.
- **Retry a failed payment** — re-attempt the latest failed invoice from admin (do not silently wait for the provider's retry schedule).
- **Comp / credit an account** — apply a balance credit or move the customer onto a comped plan (`$subscription->swapAndInvoice($priceId)` is a REAL Cashier method for an immediate plan change with proration invoice — pass a real price id; never call it "fabricated").
- **Chargeback / dispute visibility** — Cashier has no built-in dispute-management UI; disputes arrive as Stripe webhook events (`charge.dispute.created`, `.updated`, `.closed`). The admin surface must, at minimum: (a) listen for and persist these events (do not let them silently no-op through an unhandled webhook route), (b) surface an open-dispute list with the evidence-submission deadline visible to the operator — card-network evidence windows run roughly 7-21 days from the dispute notification and are easy to miss without an in-app reminder, and (c) link out to the Stripe Dashboard's evidence-submission flow (evidence itself is filed in Stripe, not reinvented in-app). **P1** if the product takes payments and there is no dispute-webhook handler at all (a dispute that never reaches the app is discovered only when Stripe auto-debits the loss); **P2** if disputes are logged but the deadline is not surfaced anywhere an operator would see it in time.
- Every billing action here MUST write to the activity/audit log (Domain 5) with before/after state and the acting admin — money-moving admin actions are the highest-value audit-trail entries.

**User Impersonation — what the surface must cover** (feature *presence* alone is not sufficient — an
unlogged, unbounded, or silent impersonation capability is itself a P0 finding regardless of the P2 row
above; each absent capability is its own sub-finding under `ADM-PM-`):
- **Impersonation-specific audit logging** — a dedicated log entry distinguishable from generic admin
  actions, capturing WHO (impersonating admin), WHOM (impersonated user), and START/END timestamps for the
  session. A generic "admin action" log line that doesn't name the impersonated user or bound the session is
  not sufficient. **P0** if impersonation exists with no audit trail at all — an admin able to act as any
  user with zero record is the single highest-risk admin capability in the panel.
- **Session scoping / time-limited** — the impersonation session auto-expires (does not persist indefinitely
  across browser sessions or survive a token refresh unbounded). **P1** if impersonation never expires.
- **Non-chainable** — an admin already impersonating a user cannot impersonate a second user from within
  that session (must explicitly return to their own admin session first). **P1** if impersonation can chain.
- **Bannered** — a persistent, unmissable UI indicator visible throughout the impersonated session (e.g. a
  fixed banner: "You are impersonating {user} — Return to admin") with a one-click exit. **P1** if
  impersonation has no visible indicator — silent impersonation is a common AI-tell and a real trust risk:
  the admin has no reminder they're acting inside someone else's account.

### Relationship Management

```bash
# Check for related resource management in admin pages
# e.g., managing a user's posts, an order's items
grep -rn "Tab\|tab\|TabPanel\|related\|hasMany\|belongsTo" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -10

# Check for inline editing of related resources
grep -rn "InlineEdit\|inlineEdit\|editInPlace\|contentEditable" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -5
```

### Workflow Dead Ends

```bash
# Check for action buttons that lead nowhere (no form action, no link)
grep -rn "onClick.*undefined\|onClick.*null\|href=\"#\"\|to=\"#\"" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -10

# Check for forms without submit handlers
grep -rn "<form" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | grep -v "onSubmit\|handleSubmit\|action="
```

---

## Domain 2: Visual Craft & Consistency (Designer)

ID Prefix: `ADM-DES-`

Runs in **Standard and Thorough modes** (inline in Standard, subagent in Thorough). References `_v-design.md` for the canonical token set (§ Design System Application Order) and the Spec-Deviation Detection Table. In Standard mode, shell-conformance uses the Pass 3-lite fingerprints; all other Domain 2 checks read the page files directly.

### Shared-Shell Conformance

```bash
# Compare layout structures across admin pages
# Count unique layout patterns — ONE dominant shell is correct (spec §1);
# the finding is pages whose structure DIVERGES from the dominant shell
for page in $(find resources/js/Pages/Admin -name "*.tsx" 2>/dev/null); do
  structure=$(grep -E "^\s*<(div|section|Card|Panel|Layout|Page)" "$page")
  echo "$structure" | md5 2>/dev/null || echo "$structure" | md5sum | cut -d' ' -f1
done | sort | uniq -c | sort -rn

# Off-spec card patterns (cards should sit on the 3-tier system: panel → card → nested)
grep -rn "Card\|card" resources/js/Pages/Admin --include="*.tsx" | head -20
```

### Visual Hierarchy in Tables

```bash
# Check for status badges with semantic colors
grep -rn "badge\|Badge\|status\|Status\|pill\|Pill" resources/js/Pages/Admin --include="*.tsx" | head -10

# Check for avatar/icon usage in tables
grep -rn "Avatar\|avatar\|thumbnail\|icon.*user\|UserIcon" resources/js/Pages/Admin --include="*.tsx" | head -10
```

### Checks

**Cross-domain dedup note:** the first row below (shell breaks) is the SAME check Domain 6 § Shared-Shell
Breaks runs with a more precise fingerprint script. When Domain 6 also runs (Standard/Thorough), Domain 6 is
canonical for this finding — do not independently author a second `ADM-DES-` finding for a page Domain 6
already flagged as `ADM-AI-`; cross-reference it by file path instead.

| Check | Severity | Detection |
|-------|----------|-----------|
| Pages break the shared admin shell (different sidebar, different header patterns, off-spec components) | P1 | Fingerprint divergence from the dominant shell |
| Spacing off the fixed scale (values not on xs–2xl: 4/8/12–14/20–24/28–32/36–40px) | P2 | Grep padding/gap classes against the canonical scale |
| No visual hierarchy in tables (all columns same weight) | P2 | Page scan — no bold/semibold on primary column |
| Placeholder content left in (`Lorem`, `Example`, `Test`) | P1 | Grep placeholder text |
| Icon inconsistency (icon fonts, sprites, or mixed libraries — spec mandates inline Lucide-compatible SVG) | P2 | Grep icon imports — multiple sources or non-SVG |
| Typography — size-only hierarchy, weights off the fixed 400/500/600/700 scale | P2 | Per `_v-design.md` |
| Canonical theme tokens missing | P1 | Hardcoded colors not resolving to canonical tokens (light value must come from `[data-theme="light"]`) per `_v-design.md` |
| Status badges off the fixed semantic set | P2 | Badge colors not `--critical`/`--high`/`--medium`/`--resolved`/`--info` (dim bg + full-color text) |
| Spec deviations detected | P2 | Per `_v-design.md` Spec-Deviation Detection Table |

```bash
# Placeholder content
grep -rn "Lorem\|lorem\|Example\|example@\|test@\|placeholder\|TODO\|FIXME" resources/js/Pages/Admin --include="*.tsx" | head -10

# Mixed icon libraries
grep -rn "import.*Icon\|import.*icon\|from.*icons\|from.*heroicons\|from.*lucide\|from.*phosphor" resources/js/Pages/Admin --include="*.tsx" | sed 's/.*from/from/' | sort -u

# Spacing inconsistency
# NOTE: do NOT isolate the class token with a `sed 's/.*:\(...\).*/\1/'` anchored on grep -n's
# leading `path:line:` colon — the token sits mid-string inside a className attribute, never
# immediately after that colon, so the substitution never matches and every line passes through
# unchanged (verified: the old pattern no-ops on every real hit, silently defeating the frequency
# count). Use `grep -oE` to extract just the matching token instead.
grep -rn "p-[0-9]\|px-[0-9]\|py-[0-9]\|gap-[0-9]" resources/js/Pages/Admin --include="*.tsx" | grep -oE "(px|py|gap|p)-[0-9]+" | sort | uniq -c | sort -rn | head -10
```

---

## Domain 3: Usability & Interaction (UX Developer)

ID Prefix: `ADM-UX-`

Runs in **Thorough mode only**.

### Checks

| Check | Severity | Detection |
|-------|----------|-----------|
| No loading states on data tables | P1 | Missing `isLoading`/`skeleton` in index pages |
| No error boundaries around admin sections | P1 | Missing `ErrorBoundary` wrapper |
| Delete without confirmation dialog | P0 | `destroy`/`delete` handler without `confirm`/`AlertDialog` |
| Form dirty-state not tracked (data loss on navigation) | P1 | Missing `isDirty`/`beforeunload`/`useBlocker` |
| Search without debounce | P2 | `onChange` handler calling API without debounce/throttle |
| Filter state not persisted in URL | P2 | Filters reset on page refresh |
| No keyboard navigation for power users | P2 | No `onKeyDown`/keyboard shortcut handlers |
| Poor mobile responsiveness | P2 | No responsive classes on admin layout |
| Pagination lacks per-page selector | P2 | Pagination without `perPage` option |

```bash
# Loading states on index pages
for page in $(find resources/js/Pages/Admin -name "Index.tsx" -o -name "index.tsx" 2>/dev/null); do
  has_loading=$(grep -c "loading\|Loading\|skeleton\|Skeleton\|isLoading" "$page")
  [ "$has_loading" -eq 0 ] && echo "NO_LOADING: $page"
done

# Error boundaries
grep -rn "ErrorBoundary\|errorBoundary\|error.*boundary" resources/js/Pages/Admin --include="*.tsx" | head -5

# Delete without confirmation — file-level check (NOT a per-line grep -v).
# A per-line `grep ... | grep -v "confirm|Confirm|AlertDialog|Modal|dialog"` false-positives any
# component where the delete call and its AlertDialog wrapper sit on different lines (the common
# React shape: an <AlertDialog> wraps a trigger button whose action fires a separate
# `handleDelete`/`router.delete(...)` call elsewhere in the file) — the delete-call line alone
# never contains "confirm"/"AlertDialog" and gets flagged even though the delete IS confirmed
# (verified: live-fired against an AlertDialog-wrapped delete, false-positive confirmed). Decide at
# the FILE level instead, same pattern as § File upload validation above: flag a page/component
# only if it references delete/destroy/remove AND contains no confirmation guard anywhere in the file.
for page in $(find resources/js/Pages/Admin -name "*.tsx" 2>/dev/null); do
  has_delete=$(grep -cE "delete|destroy|remove" "$page")
  has_confirm=$(grep -cE "confirm|Confirm|AlertDialog|Modal|dialog" "$page")
  if [ "$has_delete" -gt 0 ] && [ "$has_confirm" -eq 0 ]; then
    echo "DELETE_NO_CONFIRM: $page (references delete/destroy/remove, no confirmation guard in file)"
  fi
done

# Form dirty state
grep -rn "isDirty\|beforeunload\|useBlocker\|unsavedChanges\|hasChanges" resources/js/Pages/Admin --include="*.tsx" | head -5

# Search debounce
grep -rn "debounce\|Debounce\|useDebouncedValue\|useDebounce\|throttle" resources/js/Pages/Admin --include="*.tsx" | head -5

# URL filter persistence
grep -rn "useSearchParams\|router\.get.*preserveState\|queryString\|URLSearchParams" resources/js/Pages/Admin --include="*.tsx" | head -5
```

---

## Domain 4: Edge Cases & Robustness (QA Engineer)

ID Prefix: `ADM-QA-`

Runs in **Thorough mode only**.

### Checks

| Check | Severity | Detection |
|-------|----------|-----------|
| Empty states missing on list views | P1 | No empty/zero-length check in index pages |
| Long text overflow not handled | P2 | No `truncate`/`line-clamp`/`overflow-hidden` on text columns |
| Form validation client-side only (no server validation) | P1 | `useForm` without corresponding FormRequest |
| No server-side validation at all | P0 | Controller stores data without validation |
| Permission boundaries not tested | P1 | Admin routes without authorization checks |
| Instance-less `authorize()`/`can()` call — authorizes against a bare `Model::class` reference instead of the route-bound instance, for an ability that requires one (`view`/`update`/`delete`/`restore`/`forceDelete`) | **P0** | The call passes the presence-only check below cleanly while authorizing the wrong subject — any authenticated user can pass it for ANY record ID (classic IDOR/BOLA). See the instance-less authorize detector in the bash block below |
| File upload without type/size/extension validation (server-side) | P1 | No server-side `mimes:`/`extensions:`/`max:` rules in the FormRequest/controller — a client-side `accept` attribute alone is UX, not validation (CLAUDE.md § Security Defaults) |
| Error recovery missing (failed saves show nothing) | P1 | No error handling on form submission |
| Concurrent editing not handled | P2 | No optimistic locking or last-write-wins warning |

```bash
# Empty states
for page in $(find resources/js/Pages/Admin -name "Index.tsx" -o -name "index.tsx" 2>/dev/null); do
  has_empty=$(grep -c "length === 0\|\.length == 0\|empty\|Empty\|no.*found\|No.*found" "$page")
  [ "$has_empty" -eq 0 ] && echo "NO_EMPTY_STATE: $page"
done

# Long text overflow
grep -rn "truncate\|line-clamp\|overflow-hidden\|text-ellipsis\|whitespace-nowrap" resources/js/Pages/Admin --include="*.tsx" | head -10

# Server-side validation (FormRequest usage)
for controller in $(find app/Http/Controllers/Admin -name "*.php" 2>/dev/null); do
  has_request=$(grep -c "Request \$request\|FormRequest" "$controller")
  has_store=$(grep -c "public function store\|public function update" "$controller")
  if [ "$has_store" -gt 0 ] && [ "$has_request" -eq 0 ]; then
    echo "NO_FORM_REQUEST: $controller"
  fi
done

# Authorization checks in admin controllers — PRESENCE ONLY. This catches a controller with
# literally zero auth calls, but it does NOT catch the classic IDOR/BOLA shape below: a
# controller calling $this->authorize('update', Model::class) — the CLASS, not the request's
# own route-bound $model — passes this check cleanly while authorizing the wrong subject.
for controller in $(find app/Http/Controllers/Admin -name "*.php" 2>/dev/null); do
  has_auth=$(grep -c "authorize\|Gate::\|can(\|Policy\|middleware.*can:" "$controller")
  [ "$has_auth" -eq 0 ] && echo "NO_AUTH_CHECK: $controller"
done

# INSTANCE-LESS AUTHORIZE CHECK — the actual IDOR/BOLA detector. Captures the authorize()/
# can() call's SECOND argument and flags any call passing a class name / ::class literal
# instead of a variable bound to the route-model-bound resource. `$this->authorize('update',
# Invoice::class)` / `Gate::authorize('update', Invoice::class)` / `->can('update',
# Invoice::class)` all pass the presence check above while authorizing against the class —
# any authenticated user can pass this call for ANY record ID.
#
# `viewAny`/`create`/`index`/`list` are excluded: by Laravel Policy convention these methods
# take only $user, no model instance, so a class reference there is correct, not a finding.
# Every other ability (`view`, `update`, `delete`, `restore`, `forceDelete`, or a custom
# ability name) authorized against a bare class is a P0/P1 finding in its own right.
for controller in $(find app/Http/Controllers/Admin -name "*.php" 2>/dev/null); do
  hits=$(grep -noE "(->authorize\(|Gate::authorize\(|\$this->authorize\(|->can\()[[:space:]]*['\"][A-Za-z_]+['\"][[:space:]]*,[[:space:]]*[A-Za-z_\\][A-Za-z0-9_\\]*::class" "$controller" \
    | grep -viE "'(viewAny|create|index|list)'")
  if [ -n "$hits" ]; then
    echo "INSTANCE_LESS_AUTHORIZE (IDOR/BOLA risk): $controller"
    echo "$hits" | sed 's/^/  /'
  fi
done

# Sanity check: the correct shape — authorize()/can() called with an instance variable
# ($model, not Model::class) as the second argument. A controller with instance-less hits
# above AND zero hits here has no correctly-scoped authorize call anywhere in the file.
grep -rnoE "(->authorize\(|Gate::authorize\(|\$this->authorize\(|->can\()[[:space:]]*['\"][A-Za-z_]+['\"][[:space:]]*,[[:space:]]*\$[a-zA-Z_][a-zA-Z0-9_]*" app/Http/Controllers/Admin --include="*.php" 2>/dev/null

# File upload validation — file-level check (NOT a per-line grep -v).
# The old `grep ... | grep -v "validate|mimes|max:"` was a per-LINE filter: a controller that
# validates on one line (`$request->validate([...'mimes:jpg,png|max:2048'])`) and reads the file
# on the next still surfaced the file-read line as "unvalidated" — a false positive on properly
# guarded uploads. Decide at the FILE level instead: flag a controller only if it handles an
# upload AND contains no upload-validation anywhere in the file.
for controller in $(find app/Http/Controllers/Admin -name "*.php" 2>/dev/null); do
  handles_upload=$(grep -cE -e "->file\(|UploadedFile|->store\(|->storeAs\(|hasFile\(" "$controller")
  has_upload_validation=$(grep -cE -e "mimes:|mimetypes:|max:[0-9]|->validate\(|FormRequest|'file'|image" "$controller")
  if [ "$handles_upload" -gt 0 ] && [ "$has_upload_validation" -eq 0 ]; then
    echo "UPLOAD_NO_VALIDATION: $controller (handles uploads, no mimes/size/file validation in file)"
  fi
done
# (If a controller delegates validation to a FormRequest, the `FormRequest` token above matches its
# type-hinted param; still open the flagged file to confirm before emitting the P1 finding.)
```

---

## Domain 5: Audit Trail & Security (Operations)

ID Prefix: `ADM-OPS-`

### Audit Logging

```bash
# Check for activity logging package
composer show spatie/laravel-activitylog 2>/dev/null && echo "SPATIE_ACTIVITY_LOG=installed"

# Check for custom audit logging
grep -rn "audit\|activity\|action_log\|AuditLog\|ActivityLog" app/ --include="*.php" | grep -v "vendor\|test" | head -10

# Check if models use LogsActivity trait
grep -rn "LogsActivity\|Auditable\|HasActivity" app/Models --include="*.php" -l

# Check for before/after value capture
grep -rn "getOriginal\|getDirty\|getChanges\|old_values\|new_values\|before\|after" app/ --include="*.php" | grep -i "audit\|log\|activity" | head -5

# Check for activity log viewer in admin
grep -rn "activity\|ActivityLog\|AuditLog\|audit.*log" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -5
```

| Check | Severity |
|-------|----------|
| No audit logging on admin actions (create/update/delete) | P0 |
| Logging exists but no before/after value capture | P1 |
| Logging exists but no admin UI to view logs | P1 |
| No user attribution on log entries | P1 |

### Permission Granularity

```bash
# Check permission system
grep -rn "Permission\|permission\|spatie.*permission\|bouncer\|Gate::define" app/ config/ --include="*.php" | head -10
composer show spatie/laravel-permission 2>/dev/null && echo "SPATIE_PERMISSIONS=installed"

# Binary admin check (too coarse)
grep -rn "is_admin\|isAdmin\|->admin\|role.*admin" app/Http/Middleware --include="*.php" | head -5
```

| Check | Severity |
|-------|----------|
| Binary admin/non-admin only (no granular permissions) | P1 |
| No role-based access control | P1 |
| Admin middleware is just `is_admin` boolean check | P1 |

### Rate Limiting

```bash
# Check for rate limiting on admin routes
grep -rn "throttle\|RateLimiter" routes/ --include="*.php" | grep -iE "admin" | head -5
```

**Scope note:** this grep is filtered to admin routes only — it cannot see whether the product's
public login/register/password-reset/email-verification routes are throttled, which is where a
credential-stuffing attack actually lands. That broader check lives in
`~/.claude/skills/v-audit-code/references/audit-lenses.md § Security & trust boundaries`
("Auth-endpoint rate limiting"); run it too on any audit that includes the public auth surface.

### Session Management

```bash
# Session management for admins
grep -rn "session\|Session\|logoutOtherDevices\|active.*session" app/ --include="*.php" | head -5
```

### 2FA Enforcement (Admin Accounts)

Admin accounts are the highest-value credential in the product — a single compromised admin login
exposes every customer's data and every money-moving action. 2FA on admin accounts is the single
cheapest defense against credential-stuffing / phishing takeover of that account.

```bash
# Is 2FA available at all? (Fortify/Jetstream ship two-factor; Breeze does NOT)
grep -rn "two_factor\|twoFactor\|TwoFactor\|two-factor\|2fa\|totp\|TOTP\|google2fa\|authenticator" \
  app/ config/ routes/ --include="*.php" 2>/dev/null | grep -v "vendor\|test" | head -10
composer show laravel/fortify 2>/dev/null && echo "FORTIFY=installed (ships 2FA scaffolding)"
grep -rn "features.*two-factor\|Features::twoFactorAuthentication" config/fortify.php config/jetstream.php 2>/dev/null | head -3

# Is the two_factor_* column set present on the users table? (migration evidence)
grep -rn "two_factor_secret\|two_factor_recovery_codes\|two_factor_confirmed_at" database/migrations --include="*.php" 2>/dev/null | head -3

# Is 2FA ENFORCED (not merely offered) for admin accounts? Look for middleware / gate that
# blocks admin access until 2FA is confirmed.
grep -rn "two_factor_confirmed_at\|hasEnabledTwoFactor\|RequireTwoFactor\|EnsureTwoFactor\|forceTwoFactor" \
  app/Http/Middleware app/ routes/ --include="*.php" 2>/dev/null | head -5
```

| Check | Severity | Condition |
|-------|----------|-----------|
| No 2FA capability exists anywhere (no Fortify/Jetstream 2FA, no TOTP, no `two_factor_*` columns) | P1 | Product has an admin panel — admin credential has no second factor available at all |
| 2FA available to users but NOT enforced for admin accounts (admins can log in with password only) | P1 | 2FA scaffolding present but no middleware/gate requires confirmed 2FA before admin access |
| 2FA enforced for admins but no recovery-code / reset flow (lockout risk) | P2 | Enforcement present, `two_factor_recovery_codes` unused or no admin-reset path |
| 2FA fully enforced for admins with recovery flow | VERIFIED_GOOD | Note in `VERIFIED_GOOD`, not a finding |

Do not flag "2FA missing" when the product intentionally uses SSO/IdP-enforced MFA for admin access
(e.g., all admins authenticate through an SSO provider that enforces MFA upstream) — detect an SSO
guard (`socialite`, `saml`, `oidc`, an `sso` guard in `config/auth.php`) and downgrade to
`confidence: "low"` advisory, recommending confirmation that the IdP enforces MFA.

### Failed Job Monitoring

```bash
# Failed job monitoring in admin
grep -rn "failed.*job\|FailedJob\|failed_jobs" app/Http/Controllers/Admin --include="*.php" 2>/dev/null | head -3
test -f config/horizon.php && echo "HORIZON=configured"
```

### Queue Health

```bash
# Queue monitoring
grep -rn "queue\|Queue\|horizon\|Horizon" resources/js/Pages/Admin --include="*.tsx" 2>/dev/null | head -5
```

### Tenant Isolation (if multi-tenant)

The single most damaging failure class for AI-built SaaS: one tenant reading or writing another
tenant's data. Two greps for the string `team_id` cannot distinguish "this file mentions tenancy"
from "every query path touching this model is actually scoped" — score it like the Audit Logging
and Permission Granularity checks above, don't sample it.

**Detect multi-tenancy first** — skip this entire subsection if neither matches (the product is single-tenant):
```bash
grep -rlE "team_id|tenant_id|organization_id|workspace_id" database/migrations --include="*.php" 2>/dev/null | head -5
grep -rlE "BelongsToTenant|BelongsToTeam|HasTenant|TenantScope" app/Models app/Traits 2>/dev/null | head -5
```

**Enumerate EVERY tenant-owned model — do not sample.** A model is tenant-owned if it references a
tenant FK (`team_id`/`tenant_id`/`organization_id`/`workspace_id`) anywhere in its file (fillable,
casts, relation, or scope definition). For each one, confirm a global scope or tenant trait is
actually applied:
```bash
for model in $(ls app/Models/*.php 2>/dev/null); do
  is_tenant_owned=$(grep -cE "team_id|tenant_id|organization_id|workspace_id" "$model")
  has_scope=$(grep -cE "BelongsToTenant|BelongsToTeam|HasTenant|TenantScope|addGlobalScope|static function booted\(\)" "$model")
  if [ "$is_tenant_owned" -gt 0 ] && [ "$has_scope" -eq 0 ]; then
    echo "UNSCOPED_TENANT_MODEL: $model (has a tenant FK, no global scope / tenant trait detected — open the file to confirm)"
  fi
done
```

**Find query paths that bypass the model's global scope entirely** — a scope defined on the model
does nothing for a query that never goes through Eloquent, or that explicitly opts out:
```bash
grep -rnE "::query\(\)|DB::table\(|DB::select\(|DB::statement\(|withoutGlobalScope|withoutGlobalScopes" \
  app/Http/Controllers app/Services app/Actions app/Jobs --include="*.php" 2>/dev/null
```
Every hit needs eyes-on: a raw `DB::table()`/`DB::statement()`/`::query()` call touching a
tenant-owned table needs its own manual tenant `where()` clause in the same method — confirm one
exists. A `withoutGlobalScope()`/`withoutGlobalScopes()` call needs an explicit, narrow
justification (a genuine cross-tenant admin/system operation) — anything else is a live bypass,
not an exception.

**Worked cross-tenant-ID-substitution test recipe** — the only artifact that actually proves
isolation rather than asserting it. Adapt to the project's factories/test framework (Pest shown);
run this shape against every tenant-owned resource's show/update/delete admin route, not just one:
```php
it('cannot access another tenant\'s resource by ID substitution', function () {
    $tenantA = Team::factory()->create();
    $tenantB = Team::factory()->create();
    $userA = User::factory()->for($tenantA)->create();
    $resourceB = Invoice::factory()->for($tenantB)->create(); // belongs to the OTHER tenant

    actingAs($userA)
        ->get("/admin/invoices/{$resourceB->id}")
        ->assertNotFound(); // or assertForbidden() — never a 200 carrying tenant B's data
});
```

| Check | Severity |
|-------|----------|
| Tenant-owned model with no global scope / tenant trait applied at all | P0 |
| Raw `DB::table()`/`DB::statement()`/`::query()` path on a tenant-owned table with no manual tenant `where()` clause | P0 |
| `withoutGlobalScope()`/`withoutGlobalScopes()` call on a tenant-owned model outside an explicitly justified admin/system context | P0 |
| Global scope present on every tenant-owned model, but no automated cross-tenant-ID-substitution test exists for any resource | P1 |
| Tenant scoping enforced only in the controller layer (manual `where('team_id', ...)` per-controller) rather than the model's global scope, so a new controller/job added later silently bypasses it by omission | P1 |
| Global scope applied on every tenant-owned model, cross-tenant-substitution test present and passing | VERIFIED_GOOD |

---

## Domain 6: AI-Built Blind Spots (Cross-cutting)

ID Prefix: `ADM-AI-`

This domain flags patterns that AI code generators consistently produce but that are inadequate for production admin panels.

**Quick mode limitations:** In Quick mode, Pass 3 (page scan) does not run, so structural fingerprinting and form fingerprint comparison are unavailable. Quick mode Domain 6 checks are limited to:
- Happy-path only detection (controller grep — no page scan needed)
- Binary permissions detection (middleware grep)
- Missing operational tooling (route-level check against canonical page list)
- Placeholder content (grep — does not require page structure analysis)
- SoftDeletes without restore (model + route cross-reference from Pass 1+2)

Shared-shell divergence detection requires Standard or Thorough mode (fingerprints from Pass 3 / Pass 3-lite); form layout comparison requires Thorough mode (full Pass 3 feature detection).

### Shared-Shell Breaks (Pages Off the Mandated Shell) — Standard + Thorough

Layout consistency across admin pages is REQUIRED (spec §1). The finding is INVERTED from the legacy uniformity check: flag pages that BREAK the shared shell (different sidebar, different header patterns, off-spec components), not pages that share it.

```bash
# Compare page structures against the dominant (shared) shell
TOTAL_PAGES=0
FINGERPRINTS=""
for page in $(find resources/js/Pages/Admin -name "*.tsx" 2>/dev/null); do
  TOTAL_PAGES=$((TOTAL_PAGES + 1))
  structure=$(grep -E "^\s*<(div|section|Card|Panel|Layout|Page|Table|Form)" "$page")
  fp=$(echo "$structure" | md5 2>/dev/null || echo "$structure" | md5sum | cut -d' ' -f1)
  FINGERPRINTS="$FINGERPRINTS $fp:$page"
done

if [ "$TOTAL_PAGES" -gt 0 ]; then
  DOMINANT_FP=$(echo "$FINGERPRINTS" | tr ' ' '\n' | cut -d: -f1 | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  DOMINANT_COUNT=$(echo "$FINGERPRINTS" | tr ' ' '\n' | cut -d: -f1 | grep -c "^$DOMINANT_FP")
  CONSISTENCY_PCT=$((DOMINANT_COUNT * 100 / TOTAL_PAGES))
  echo "SHELL_CONSISTENCY: $CONSISTENCY_PCT% ($DOMINANT_COUNT of $TOTAL_PAGES pages on the dominant shell)"
  # Every page NOT on the dominant shell is a potential shell break — list and inspect each
  echo "$FINGERPRINTS" | tr ' ' '\n' | grep -v "^$DOMINANT_FP:" | cut -d: -f2- | sed 's/^/SHELL_BREAK_CANDIDATE: /'
fi
# Read each candidate: divergence that changes the sidebar/header/nav shell = P1;
# divergence that is legitimate content-area variation (the spec allows only the content area to change) = not a finding
```

**Cross-domain dedup note:** this is the SAME underlying check as Domain 2 § Checks "Pages break the shared
admin shell" (`ADM-DES-`) — Domain 2's row is the coarser page-scan version of this fingerprint script. When
both Domain 2 and Domain 6 run in the same audit (Standard/Thorough), Domain 6's fingerprint script is
canonical for shell-break findings; Domain 2 must NOT independently re-emit an `ADM-DES-` finding for a page
already flagged here as `ADM-AI-` — cross-reference the existing Domain 6 finding by file path instead of
authoring a second one. This is a same-domain-family duplicate risk the generic fingerprint dedup in
`_v-review.md` § Finding Deduplication Protocol may not catch on its own if the two domains categorize the
same page under different `category` slugs (`visual-craft` vs `ai-blind-spot`) — do not rely on it alone here.

### Happy-Path Only

```bash
# Check for error handling in admin controllers
for controller in $(find app/Http/Controllers/Admin -name "*.php" 2>/dev/null); do
  has_try=$(grep -c "try\|catch\|rescue" "$controller")
  has_error=$(grep -c "abort\|throw\|Exception\|error" "$controller")
  total_methods=$(grep -c "public function" "$controller")
  if [ "$total_methods" -gt 2 ] && [ "$has_try" -eq 0 ] && [ "$has_error" -eq 0 ]; then
    echo "HAPPY_PATH_ONLY: $controller (${total_methods} methods, 0 error handling)"
  fi
done
```

### Complete Checklist

| Check | Severity | Detection |
|-------|----------|-----------|
| Pages break the shared admin shell (different sidebar, different header patterns, off-spec components) | P1 | Fingerprint divergence from the dominant shell |
| No error handling in admin controllers (happy-path only) | P1 | No try/catch, no abort, no throw |
| Binary permissions (admin=yes/no, no roles) | P1 | `is_admin` boolean check only |
| No operational tooling (no system health, no job monitor) | P1 | Missing pages from canonical list |
| No ⌘K command palette (spec §6.2 mandates the search overlay on dashboard products) | P2 (P1 only on multi-admin-seat products) | No search overlay / `Cmd+K`/`Ctrl+K` handler / sidebar search trigger |
| No workflow shortcuts (no quick actions, no keyboard shortcuts beyond ⌘K) | P2 | No `onKeyDown` shortcut handlers, no quick actions |
| Placeholder content still present | P1 | `Lorem`, `Example`, `test@`, `placeholder` |
| Missing pages AI never builds (see Domain 1 list) | P1 | Cross-reference with the 11-page canonical list (incl. Billing / Subscription Support) |
| SoftDeletes models without restore UI | P1 | `SoftDeletes` trait but no restore route/button |
| No data integrity tools (no orphan detection, no consistency checks) | P2 | No data repair/cleanup utilities |
| Forms off the shared form pattern (inconsistent wrapper/label/error placement across pages) | P2 | Form fingerprint divergence |

---

## Subagent Prompts (Thorough Mode — Domains 2-4)

These prompts are briefing-file content for Thorough-mode parallel dispatch only — write each (with discovery results substituted) to a file and dispatch via `v-dispatch-subagent.sh --mode capture` as an independent `claude -p` subprocess (NEVER the Agent tool: this skill runs `context: fork` and nested Agent dispatch fails silently). In Standard mode, Domain 2 runs inline in the main context using its § Domain 2 checklist above — do not dispatch subprocesses in Standard.

**Severity vocabulary (mandatory mapping — the subagents below emit `critical | high | medium | low`; the SKILL body, scoring, and every other domain checklist use `P0 | P1 | P2 | P3`).** These are the SAME scale under the canonical mapping in `[[v-core-severity]]` (`~/.claude/skills/references/v-core-severity.md` § Cross-vocabulary mapping): **critical = P0, high = P1, medium = P2, low = P3.** At merge time (SKILL Step 2, § dedup), normalize every subagent `severity` to its `P#` equivalent via this mapping BEFORE scoring or ranking, so the consolidated report speaks one vocabulary. A single P0 (critical) forces the failing domain verdict regardless of the 0-10 score, per `[[v-core-severity]]` § Scoring discipline.

### Domain 2 Subagent: Visual Craft & Consistency

```
You are a Designer reviewing an admin panel for visual craft and consistency.

**Context:**
- Admin pages are located at: [discovery results — admin page paths]
- Design tokens source: canonical set per _v-design.md § Design System Application Order [+ .interface-design/system.md overlay]
- Total admin pages: [count]

**Your task:** Audit the admin panel's visual design using these checks:
1. Shared-shell conformance — spec §1 MANDATES an identical sidebar/header shell on every page; flag pages that BREAK the shared shell (different sidebar, different header patterns, off-spec components), never pages for sharing it
2. Spacing conformance — are padding/margin values on the fixed scale (xs 4 / sm 8 / md 12–14 / lg 20–24 / xl 28–32 / 2xl 36–40 px)?
3. Visual hierarchy in tables — do primary columns stand out? Are status badges on the fixed semantic set (--critical/--high/--medium/--resolved/--info)?
4. Placeholder content — any Lorem ipsum, example@, test data left in?
5. Icon consistency — inline Lucide-compatible SVG only (no icon fonts, no sprites, no mixed libraries)?
6. Typography hierarchy — weight + tracking variation on the fixed 400/500/600/700 scale, not just size?
7. Canonical theme-token compliance — colors resolve to canonical tokens; theming via html[data-theme] only (no .dark classes, no per-element dark: strategy) — per _v-design.md governance
8. Spec-deviation detection — per _v-design.md Spec-Deviation Detection Table

For each finding, use the format:
  id: ADM-DES-NNN
  file: [path:line]
  type: ux
  severity: [critical | high | medium | low]
  confidence: [high | medium | low]
  issue: [description]
  evidence: [code snippet]
  fix: [specific change]
  verification: [how to verify]

Report ALL findings at every severity level.
```

### Domain 3 Subagent: Usability & Interaction

```
You are a UX Developer reviewing an admin panel for usability and interaction quality.

**Context:**
- Admin pages: [discovery results]
- Routes: [route list]
- Page features detected: [from Pass 3]

**Your task:** Audit admin panel usability:
1. Loading states — every data-fetching page must show loading state
2. Error boundaries — admin sections should fail gracefully
3. Confirmation dialogs — destructive actions (delete, bulk delete, cancel) need confirmation
4. Form dirty-state — unsaved changes should warn on navigation
5. Search debouncing — search inputs must not fire on every keystroke
6. Filter persistence — filter/search state should survive page refresh (URL params)
7. Keyboard navigation — power user shortcuts for common admin actions
8. Mobile responsiveness — admin layout usable on tablet minimum
9. Pagination UX — per-page selector, total count, current page indicator

For each finding, use the same format as Domain 2 with id: ADM-UX-NNN.
Use the full severity range: [critical | high | medium | low].
Report ALL findings at every severity level.
```

### Domain 4 Subagent: Edge Cases & Robustness

```
You are a QA Engineer reviewing an admin panel for edge cases and robustness.

**Context:**
- Admin controllers: [discovery results]
- Admin pages: [discovery results]
- Models with admin CRUD: [from Pass 2]

**Your task:** Audit admin panel edge case handling:
1. Empty states — every list view must handle zero items gracefully
2. Long text overflow — text columns must handle long content (truncate, tooltip, wrap)
3. Form validation — both client-side and server-side (FormRequest classes)
4. No server validation = P0 (controller accepts unvalidated input)
5. Permission boundaries — admin routes must have authorization beyond just "is admin". Flag any `authorize()`/`can()` call whose second argument is a bare class reference (`Model::class`) rather than the route-bound instance, for an ability that requires one (`view`/`update`/`delete`/`restore`/`forceDelete`) — that authorizes against the class, not the record being mutated, and is IDOR/BOLA, not authorization (P0)
6. File upload edge cases — type validation, size limits, multiple files
7. Error recovery — failed form submissions show meaningful error messages
8. Concurrent editing — at minimum, last-write-wins with a warning

For each finding, use the same format as Domain 2 with id: ADM-QA-NNN.
Use the full severity range: [critical | high | medium | low].
Report ALL findings at every severity level.
```

---

## Framework-Agnostic Fallbacks

If the project is not Laravel + Inertia/React, adapt discovery patterns:

### Django
```bash
# Admin registration
grep -rn "admin.site.register\|ModelAdmin" */admin.py 2>/dev/null
# Custom admin views
grep -rn "AdminSite\|get_urls" */admin.py 2>/dev/null
# Models
grep -rn "class.*models.Model" */models.py 2>/dev/null
```

### Rails
```bash
# Admin controllers
ls app/controllers/admin/ 2>/dev/null
# ActiveAdmin or Administrate
grep -rn "ActiveAdmin\|Administrate" Gemfile 2>/dev/null
# Models
ls app/models/*.rb 2>/dev/null
```

### Next.js
```bash
# Admin pages
ls -R src/app/admin/ pages/admin/ 2>/dev/null
# API routes for admin
ls -R src/app/api/admin/ pages/api/admin/ 2>/dev/null
# Admin middleware
grep -rn "isAdmin\|admin\|authorize" middleware.ts src/middleware.ts 2>/dev/null
```

### Express / Node.js
```bash
# Admin routes
grep -rn "router.*admin\|app.*admin" routes/ src/routes/ 2>/dev/null
# Admin middleware
grep -rn "isAdmin\|adminAuth\|requireAdmin" middleware/ src/middleware/ 2>/dev/null
```

### Generic (Any Framework)
```bash
# Find admin-like directories
find . -type d -name "admin" -o -name "Admin" -o -name "backoffice" -o -name "dashboard" 2>/dev/null | grep -v node_modules | grep -v vendor

# Find admin-like files
find . -type f \( -name "*admin*" -o -name "*Admin*" \) -not -path "*/node_modules/*" -not -path "*/vendor/*" 2>/dev/null | head -20

# Find auth/permission middleware
grep -rn "isAdmin\|is_admin\|admin.*middleware\|requireAdmin\|admin.*guard" . --include="*.py" --include="*.rb" --include="*.ts" --include="*.js" --include="*.php" 2>/dev/null | grep -v node_modules | grep -v vendor | head -10
```
