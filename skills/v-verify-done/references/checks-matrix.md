# v-verify-done checks matrix

_Last reviewed: 2026-08-02 — added § Architecture-Test Codification (Pest `arch()`), recommending the highest-value PHP conventions be encoded as un-skippable suite assertions with the existing greps demoted to a backstop, not removed._

> **Persona for this reference:** senior code-review engineer
> with experience auditing AI-generated implementations across
> Laravel, Next.js, React, and Python codebases. Loaded
> on-demand by v-verify-done to drive the convention-check pass
> on changed files.

The matrix below is the canonical list of checks v-verify-done
runs against changed files. Each row specifies (a) what's checked,
(b) when it triggers, and (c) the method (grep / agent dispatch /
file existence check / live tool invocation).

The matrix is **stack-aware**: universal checks apply to every
project; framework-specific subsections only apply when that
stack is detected. v-verify-done's Convention Discovery step
(see SKILL.md § Convention Discovery) determines which subsections
load.

When adding a new check, prefer adding to this reference rather
than inline in the skill body. Convention drift catches accumulate
fast; a centralized matrix is easier to keep current.

---

## Checks Matrix

### Universal Checks (all frameworks)

| Check | Triggers When | Method |
|-------|--------------|--------|
| TODO/FIXME/HACK | Any file changed | Grep changed files |
| Hardcoded secrets | Any file changed | Grep for `sk_live_`, `sk-ant-` (Anthropic), `AKIA`, `ghp_`, `github_pat_` (fine-grained GitHub PAT), `whsec_` (Stripe webhook signing secret), `Bearer `, other API-key patterns. Exclude `.env*` files (secrets there are policy-allowed per CLAUDE.md) and test fixtures. |
| Debug statements | Any source file changed | Grep `console.log`, `print(`, `dd(`, `binding.pry`, `debugger`, `dbg!` per language |
| Missing test file | New source file created | Check corresponding test file exists AND references at least one symbol from the source file |
| `any` types | `.ts`/`.tsx` changed | Grep `: any`, `as any` (TypeScript projects only). Complements pre-flight's `tsc --noEmit` which only catches `any` if `noImplicitAny` is enabled. |
| DOMPurify compliance | `.tsx`/`.jsx` with `dangerouslySetInnerHTML` | Grep + verify sanitize call wraps content |

### Laravel/PHP Checks

| Check | Triggers When | Method |
|-------|--------------|--------|
| Lazy loading patterns | `.php` in Controllers/Services/Jobs | Agent or grep for `->relation` without `load` |
| Route middleware | `routes/` changed | Agent or `php artisan route:list` |
| Inertia contracts | Controller or Page `.tsx` changed | Agent or grep `Inertia::render` |
| **Inertia prop shape** | Controller or Page `.tsx` changed | See Inertia Prop Shape Verification below |
| Model factories | New model in `app/Models/` | Check factory file exists |
| Migration safety | New file in `database/migrations/` | Agent or grep for non-nullable columns |
| Ziggy freshness | Route files changed | Compare timestamps |
| Mock routes | New route added | Check `resources/js/test/setup.ts` mockRoutes |
| Mockery identity traps | Test `.php` with Mockery + Eloquent args | Grep `->with($` — flag without `Mockery::on()` |
| Queue::fake + side-effect assertions | Test `.php` with `Queue::fake()` | Grep for Queue::fake in same test as assertDatabaseHas |
| Factory FK drift | Test `.php` creating factories | Grep for factory `create()` missing scope FK |
| **Page `<Head>` tags** | New `.tsx` page component in `Pages/` | Grep for `<Head>` with `title` — see SEO Meta Tags check below |
| **Doc freshness** | New routes added | Check if `docs/api/` or `openapi.yaml` was updated — see Doc Freshness check below |
| **Billing/pricing cross-check** | Billing files changed | Check pricing page copy — see Billing Cross-Check below |
| **Inertia error-path contract** | Controller `.php` changed | For each new/changed `withErrors([...])`, `ValidationException::withMessages([...])`, or `with('<channel>', ...)` in the diff: see Inertia Error-Path Contract below |

### Framework Currency (Laravel 13 / Tailwind v4) — HIGH priority

The operator's CLAUDE.md names these as THE codegen risks: an LLM trained on older
majors silently emits pre-Laravel-11 / pre-Tailwind-v4 idioms that are wrong for this
stack. Flag any of the following found in **changed** files.

| Check | Triggers When | Method | Finding |
|-------|--------------|--------|---------|
| `Kernel.php`-era config | `.php` changed OR a new `app/Http/Kernel.php` / `app/Console/Kernel.php` | Grep changed diff for `app/Http/Kernel.php`, `app/Console/Kernel.php`, `$routeMiddleware`, `$middlewareGroups`, `protected $commands` | `FND-L13-001 | high | Laravel 13 registers middleware/routes/exceptions/schedule in `bootstrap/app.php`, not `Kernel.php`. Move this to `bootstrap/app.php`.` |
| SoftDeletes mandate | `.php` model changed | Grep for `use SoftDeletes;` / `SoftDeletes::class` | `FND-L13-002 | medium | Global rule is HARD deletes (SoftDeletes caused silent data-restoration bugs). Remove `SoftDeletes` unless project CLAUDE.md whitelists this model (e.g. `Site`).` |
| `@tailwind` directives | `.css` changed | Grep for `@tailwind base|components|utilities` | `FND-TW4-001 | high | Tailwind v4 uses `@import "tailwindcss";`, not the three `@tailwind` directives. Replace.` |
| `tailwind.config.js` usage | new/changed `tailwind.config.{js,ts,cjs}` | File-exists + grep for a non-trivial `theme`/`content` block | `FND-TW4-002 | high | Tailwind v4 config lives in CSS (`@theme { ... }`), not `tailwind.config.js`. Migrate the config into the stylesheet.` |

```bash
# Live detection over the session's changed files (worktree-aware $ALL_CHANGED from SKILL.md)
for f in $ALL_CHANGED; do
  case "$f" in
    *.php)
      # New/changed Kernel.php is itself the smell — checked by path, since grepping a
      # file's own content for its own path string never matches.
      case "$f" in
        app/Http/Kernel.php|app/Console/Kernel.php) echo "FND-L13-001 (Kernel.php-era) in $f" ;;
      esac
      grep -qE '\$routeMiddleware|\$middlewareGroups' "$f" 2>/dev/null \
        && echo "FND-L13-001 (Kernel.php-era) in $f"
      # Match both the FQCN import and the in-class trait use; a bare 'SoftDeletes' token
      # in a changed model is the smell (avoids fragile backslash-escaping of the namespace).
      grep -qE '\bSoftDeletes\b' "$f" 2>/dev/null \
        && echo "FND-L13-002 (SoftDeletes) in $f"
      ;;
    *.css)
      grep -qE '@tailwind[[:space:]]+(base|components|utilities)' "$f" 2>/dev/null \
        && echo "FND-TW4-001 (@tailwind directive) in $f"
      ;;
    tailwind.config.js|tailwind.config.ts|tailwind.config.cjs|*/tailwind.config.*)
      grep -qE '(theme|content)[[:space:]]*:' "$f" 2>/dev/null \
        && echo "FND-TW4-002 (tailwind.config.js) in $f"
      ;;
  esac
done
```

Also flag a bare `app/Http/Kernel.php` file appearing in the changeset at all — a new Kernel.php in a Laravel 13 project is itself the smell.

### Architecture-Test Codification (Pest `arch()`)

Every check in this matrix is a grep that only runs when a skill invoking v-verify-done happens to fire — a convention violation shipped by a session that never ran `/v-verify-done` sails through untouched. Pest's [architecture testing](https://pestphp.com/docs/arch-testing) (`arch()`) encodes a dependency/usage-shaped convention as a real suite assertion that runs on every `php artisan test` / `./vendor/bin/pest` invocation, regardless of which skill (or no skill) triggered it — CI, a pre-flight run, a plain TDD loop, all of them.

**Recommendation:** for the highest-value PHP/Laravel conventions in this matrix, encode an `arch()` test ONCE in `tests/Arch/` (or the project's existing arch-test location) rather than relying on the grep catching it every time. Once the arch test exists, **demote the matching grep row above to a backstop** — it still runs (catches a violation the moment it's written, before the next `php artisan test` even executes), but the arch test is now the authoritative, un-skippable enforcement. Do NOT remove the grep: the two checks catch the same defect at different points in the loop (grep = as you write it, this session; arch test = every future session, even ones that never invoke v-verify-done).

**Scope note:** `arch()` inspects PHP dependency/usage graphs and function calls — it has no equivalent for the TypeScript checks in this matrix (`any`-type ban, DOMPurify compliance). Those remain grep-only; a custom ESLint rule would be the analogous un-skippable mechanism for JS/TS, but building one is a separate, not-yet-scoped lever, not a Pest `arch()` gap.

**Worked examples, mapped to matrix rows above:**

1. **SoftDeletes mandate** (Framework Currency table, `FND-L13-002`) — dependency-shaped, an ideal `arch()` fit:
   ```php
   arch('models must not use SoftDeletes')
       ->expect('App\Models')
       ->not->toUse('Illuminate\Database\Eloquent\SoftDeletes');
   ```

2. **Debug statements** (Universal Checks table) — function-call-shaped, also a strong fit:
   ```php
   arch('no debug statements in shipped code')
       ->expect(['dd', 'dump', 'ray', 'var_dump'])
       ->not->toBeUsed();
   ```

3. **Controllers stay in their lane** (not yet its own matrix row — illustrative extension, not a demoted existing check; add a matrix row first if this drifts in practice):
   ```php
   arch('controllers extend the base Controller')
       ->expect('App\Http\Controllers')
       ->toExtend('App\Http\Controllers\Controller');
   ```

**Verify the exact `arch()` method names against the project's installed Pest version before relying on them** — the same fabricated-API caution that applies to any less-common library API (`v-tdd/SKILL.md` § Test Convention Discovery's Tier-3 library-doc lookup applies here too). `toUse()`/`not->toBeUsed()`/`toExtend()` are core, stable Pest architecture-testing methods, but a project pinned to an older Pest minor may not have every method this file assumes.

### Next.js/React Checks

| Check | Triggers When | Method |
|-------|--------------|--------|
| Missing `use client` directive | `.tsx` with hooks in app/ directory | Grep for useState/useEffect without `'use client'` at top |
| Image optimization | `<img>` in `.tsx`/`.jsx` | Grep for `<img` — should use `next/image` or framework equivalent |
| Missing loading/error boundaries | New page in `app/` | Check for `loading.tsx` and `error.tsx` siblings |
| Unhandled async in Server Components | `.tsx` in `app/` without `'use client'` | Check async functions have error handling |
| Missing metadata export | New page route | Check for `generateMetadata` or `metadata` export |

### Django/FastAPI (Python) Checks

| Check | Triggers When | Method |
|-------|--------------|--------|
| Missing migration | New/changed model file | `python manage.py makemigrations --check --dry-run` |
| N+1 query patterns | View/serializer changed | Grep for queryset without `select_related`/`prefetch_related` |
| Missing permission class | New view | Check for `permission_classes` on API views |
| Raw SQL injection | Any `.py` changed | Grep for `raw(` or `.execute(` without parameterized queries |
| Missing type hints | New Python functions | Grep for `def ` without `->` return type annotation |

### Rails (Ruby) Checks

| Check | Triggers When | Method |
|-------|--------------|--------|
| Missing migration | New/changed model | Check for pending migrations |
| N+1 queries | Controller/view changed | Grep for `.each` on associations without `includes` |
| Missing strong params | Controller changed | Check for `permit` on params |
| Missing factory | New model | Check factory file exists in `spec/factories/` |
| Missing validation | New model | Check for `validates` presence |

### Rust Checks

| Check | Triggers When | Method |
|-------|--------------|--------|
| Unwrap in production code | `.rs` changed (not tests) | Grep for `.unwrap()` outside test modules |
| Missing error handling | `.rs` changed | Grep for `todo!()` or `unimplemented!()` |
| Unsafe blocks | `.rs` changed | Grep for `unsafe {` — flag for review |

### Go Checks

| Check | Triggers When | Method |
|-------|--------------|--------|
| Unchecked errors | `.go` changed | Grep for patterns ignoring returned errors |
| Missing error wrapping | `.go` changed | Grep for `return err` without `fmt.Errorf` wrapping |
| Context not propagated | `.go` changed | Grep for functions accepting context but not passing it down |

### Inertia Prop Shape Verification (Laravel + Inertia)

For each `Inertia::render('PageName', [...props])` found in changed PHP files:
1. Extract the page component name and the prop keys passed in the PHP array
2. Read the corresponding `.tsx` file's `PageProps` (or equivalent) type definition
3. Compare keys:
   - **Key in TypeScript type but absent from controller props** → `medium` finding: `FND-PROP-001: PageProps.{key} defined in {Page}.tsx but not passed from {Controller}.php — potential undefined at runtime`
   - **Key in controller props but absent from TypeScript type** → `low` finding: `FND-PROP-002: '{key}' passed from {Controller}.php but not in PageProps type — dead data`

```bash
# Find Inertia::render calls in changed PHP files
grep -n 'Inertia::render' $CHANGED_PHP_FILES 2>/dev/null
# For each match, extract page name and read the corresponding .tsx PageProps
```

This is a grep+read check, not a runtime check. Skip if the project doesn't use Inertia (no `Inertia::render` in changed files).

### SEO Meta Tags for New Pages (Laravel/Inertia)

For new `.tsx` page components (files in `Pages/` that are rendered by `Inertia::render`), check for `<Head>` component usage with at least `title` prop:

```bash
# Find new page files (created this session, in Pages/ directory)
# For each, grep for <Head> component usage
grep -l '<Head' $NEW_PAGE_FILES 2>/dev/null
```

If a new page component lacks `<Head>` with `title`: flag as `medium` finding: `FND-SEO-001: New page {Page}.tsx missing <Head> component with title/description — page will have no SEO meta tags`.

### Doc Freshness Check (Universal)

If the changeset adds new routes (grep for `Route::` in changed PHP files, or new files in `routes/` or `pages/api/`), check if documentation was also updated:

```bash
# Check if any doc files were modified alongside new routes (worktree-aware — use merge-base, not HEAD)
MERGE_BASE=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo "HEAD~10")
git diff --name-only "$MERGE_BASE"..HEAD -- 'docs/' 'openapi.yaml' 'openapi.json' 2>/dev/null
```

If new routes were added but no doc files were modified: flag as `medium` finding: `FND-DOCS-001: New routes added without API doc update — consider running /v-docs`.

This is advisory, not blocking — it makes doc drift visible without requiring docs for every change.

### Billing/Pricing Cross-Check (Universal)

If changed files include billing/subscription keywords (`Cashier`, `stripe`, `subscription`, `price_`, `plan_`):

```bash
# Detect billing-related changes
grep -rlE '(Cashier|stripe|subscription|price_|plan_)' $CHANGED_FILES 2>/dev/null

# If found, scan for pricing page component (use proper grouping for find -o)
find . \( -path '*/Pages/*' -o -path '*/components/*' -o -path '*/pages/*' \) -print 2>/dev/null | grep -iE '(Pricing|Plans|Billing)\.(tsx|jsx|vue)' | head -3
```

If billing logic was changed AND a pricing page component exists: flag as `medium` finding: `FND-BILLING-001: Billing logic changed — verify pricing page copy matches new pricing structure`.

### Inertia Error-Path Contract (Laravel + Inertia)

Four controller-to-UI patterns must hold; deviations are findings. All checks are diff-based — they only fire on lines this session ADDED, not on pre-existing code. Pre-existing tech debt is surfaced separately via the W54-AUDIT inventory artifact.

#### 1. Orphaned `withErrors` key (FND-ERR-001, medium)

Extract NET added keys from the diff (added minus removed, to dodge MOVE-only changes):

```bash
ADDED_KEYS=$(git diff --no-color "$MERGE_BASE"..HEAD -- '*.php' \
  | grep -E "^\+" \
  | grep -oE "(withErrors|ValidationException::withMessages)\(\s*\[\s*['\"][a-zA-Z_]+['\"]" \
  | grep -oE "['\"][a-zA-Z_]+['\"]" \
  | tr -d "'\"" \
  | sort -u)

REMOVED_KEYS=$(git diff --no-color "$MERGE_BASE"..HEAD -- '*.php' \
  | grep -E "^-" \
  | grep -oE "(withErrors|ValidationException::withMessages)\(\s*\[\s*['\"][a-zA-Z_]+['\"]" \
  | grep -oE "['\"][a-zA-Z_]+['\"]" \
  | tr -d "'\"" \
  | sort -u)

NET_ADDED=$(comm -23 <(echo "$ADDED_KEYS") <(echo "$REMOVED_KEYS"))
```

For each key `<K>` in `NET_ADDED`, search the React tree for a consumer:

```bash
grep -rln "errors\.<K>\b" resources/js/Pages resources/js/Components 2>/dev/null
# Wildcard renderer fallback (also accepted)
grep -rln "Object\.\(values\|entries\)(errors)" resources/js/Pages resources/js/Components 2>/dev/null
```

If `errors.<K>` has no specific consumer AND no wildcard renderer is reachable, emit:

> `FND-ERR-001 | medium | confidence: medium | <Controller>.php:<line> writes errors.<K> with no UI consumer. Either add <InputError message={errors.<K>} /> to the form, or switch to back()->with('error', ...) for action-level errors. (See resources/js/CLAUDE.md → Error display contract.)`

Confidence stays `medium` because wildcard renderers and dynamic keys defeat exact greps. The grep matches both `withErrors([...])` and `ValidationException::withMessages([...])` literal-array forms; it does NOT match the validator-object form `withErrors($validator)` (acceptable false-negative, validator keys flow from Form Request rules).

#### 2. Anti-pattern `with('flash', ...)` (FND-ERR-002, medium)

```bash
git diff --no-color "$MERGE_BASE"..HEAD -- '*.php' \
  | grep -E "^\+.*->with\(\s*['\"]flash['\"]"
```

If matched, emit:

> `FND-ERR-002 | medium | confidence: high | <Controller>.php:<line> uses ->with('flash', $array) which the HandleInertiaRequests middleware does NOT extract — the payload is silently dropped. Replace with ->with('error', '<msg>') or ->with('success', '<msg>'). (See resources/js/CLAUDE.md → Error display contract → ANTI-PATTERN.)`

This finding is `medium` (not `high`) so it doesn't block completion — operators may want to commit and clean up incrementally. Confidence stays `high` because the pattern is mechanically detectable; no false positives.

#### 3. Custom channel without middleware resolver (FND-ERR-004, medium)

For each new `->with('<channel>', ...)` callsite where `<channel>` is NOT in {`success`, `error`, `warning`, `info`, `flash`}:

```bash
NEW_CHANNELS=$(git diff --no-color "$MERGE_BASE"..HEAD -- '*.php' \
  | grep -E "^\+" \
  | grep -oE "->with\(\s*['\"][a-zA-Z_]+['\"]" \
  | grep -oE "['\"][a-zA-Z_]+['\"]" \
  | tr -d "'\"" \
  | sort -u \
  | grep -vE "^(success|error|warning|info|flash)$")

# For each, check if the middleware has a resolver
for ch in $NEW_CHANNELS; do
  if ! grep -qE "['\"]${ch}['\"]\s*=>\s*fn" app/Http/Middleware/HandleInertiaRequests.php 2>/dev/null; then
    echo "FND-ERR-004: '${ch}' no resolver"
  fi
done
```

If matched, emit:

> `FND-ERR-004 | medium | confidence: medium | <Controller>.php:<line> uses ->with('<channel>', ...) but HandleInertiaRequests::share() has no 'flash.<channel>' resolver. Frontend will see flash.<channel> as undefined. Add 'flash.<channel>' => fn () => $request->session()->get('<channel>') to the share() flash array, OR switch to a canonical channel. Production precedent: a custom flash channel was missing its resolver and silently broke a usage-tracking event — see W54 manifest.`

Confidence is `medium` because some custom channels are intentional non-Inertia session data (e.g., `with('redirect_url')` for OAuth flows that read session in the next request). Manual review required.

#### Skip conditions

Skip the entire error-path block when:
- Project is not Laravel + Inertia (no `Inertia::render` and no `app/Http/Controllers/`).
- The diff has zero changed `*.php` files.
- The diff has zero `withErrors\(` or `->with\(` callsites added.
- The controller method returns `JsonResponse` or `response()->json(...)` instead of `RedirectResponse` (those are fetch-consumed, no Inertia error contract applies).

### Hook Warning Normalization

After all checks complete, scan for hook warnings from this session (filter by session ID to exclude stale markers from prior sessions):

```bash
# Only include markers from the current session (8-char session ID prefix)
ls ${TMPDIR:-/tmp}/claude-hooks/*${CLAUDE_SESSION_ID:0:8}* 2>/dev/null | head -20
```

If current-session hook marker files exist, include them as `low` severity findings in the report under a `## Hook Advisories` section. This ensures ephemeral hook warnings are captured in the durable audit artifact rather than existing only in session context.
