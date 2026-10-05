# Pest Browser Test Skeleton (Authenticated Inertia/Laravel Flows)

_Last reviewed: 2026-08-03 (adversarial review: the plugin's own installer view
(`vendor/pestphp/pest/resources/views/installers/plugin-browser.php`, confirmed present in a
local vendor tree) states `visit()` also requires the Playwright npm package + downloaded
browser binaries, not just the composer plugin — the Detection block checked composer.json only,
which could false-positive PEST_BROWSER=true with no working runtime; added a Playwright
runtime check and a not-yet-usable branch. Prev 2026-08-02 (fabricated-API sweep: settled the
"not verified against a live install" caveat — the plugin isn't installed in any local repo,
but `visit()`/`assertPathIs()`/`assertSee()`/`click()`/`fill()` were cross-checked against the
official Pest browser-testing docs and confirmed real; added detail on the `actingAs()` GitHub
issue #1496 history so the authentication claim is evidence-backed rather than asserted)_

> Loaded by v-tdd **only when the test target is an authenticated Inertia/Laravel
> flow AND the project has Pest browser testing available** (per Detection below).
> Not loaded for plain PHP/Pest feature tests (those use the PHP Controller Test
> Skeleton in the skill body) or for React/Vitest component targets (those use
> `react-test-skeleton.md`). This lane sits alongside — never replaces — the raw
> Playwright lane `v-workflow-verifier` owns at /v Step 3.5, and the standalone
> Playwright gate `v-pre-flight` runs at Gate 11.5, for cross-framework flows or
> pixel-level visual-diff needs.

## Why this lane exists

A raw Playwright spec for an authenticated flow has to re-implement login as a
browser interaction: fill the login form, submit, wait for redirect, THEN start
testing the actual flow under test. Pest's browser testing plugin shares the
Laravel test session with the browser, so a Pest browser test can call
`actingAs($user)` exactly like an ordinary Pest feature test and the browser
request arrives already authenticated — no re-implemented login fixture, no
extra brittle setup step per spec. Use this lane for any RED-phase test that
needs REAL browser rendering (client-side JS execution, real navigation, a
visual/async state a jsdom/Vitest render can't produce) on an authenticated
Inertia page. For flows that don't need a real browser, prefer the ordinary
PHP Controller Test Skeleton (`$this->actingAs($user)->get(...)`) — it's
faster, and this lane is unnecessary overhead for it.

## Detection

**Capability-based — never gate this on a version string.**

```bash
# Plugin installed (composer.json require-dev) OR an existing spec directory —
# either is sufficient signal the project has this lane available.
grep -q '"pestphp/pest-plugin-browser"' composer.json 2>/dev/null && echo "PEST_BROWSER=true"
{ test -d tests/Browser && find tests/Browser -name '*.php' 2>/dev/null | grep -q .; } && echo "PEST_BROWSER_SPECS=true"

# The plugin's own installer (`vendor/pestphp/pest/resources/views/installers/plugin-browser.php`)
# states `visit()` ALSO needs the Playwright npm package + downloaded browser binaries — a
# composer-only check can false-positive (plugin required, but Playwright never installed, which
# surfaces as a browser-launch error at test-run time, not a missing-implementation RED). Check
# both sides before trusting PEST_BROWSER=true from the composer signal alone:
{ grep -q '"@playwright/test"\|"playwright"' package.json 2>/dev/null && test -x node_modules/.bin/playwright; } && echo "PLAYWRIGHT_RUNTIME=true"
```

If NEITHER `PEST_BROWSER`/`PEST_BROWSER_SPECS` fires, this skeleton does not apply — fall back to
the PHP Controller Test Skeleton (real-browser assertions aren't available), or note to the
operator that `composer require pestphp/pest-plugin-browser --dev` (plus
`npm install playwright@latest && npx playwright install`) would unlock this lane for a target
that genuinely needs real-browser rendering. If `PEST_BROWSER=true` fires from the composer
signal alone (no existing specs yet) and `PLAYWRIGHT_RUNTIME` does NOT fire, treat the lane as
**not yet usable** — note both missing install steps to the operator rather than scaffolding a
test that will fail on browser launch, which the Fail-loud RED gate would otherwise misread as a
setup error.

**API-surface caveat (avoid fabricating method names):** the browser-testing
plugin is newer and less stable than Pest core, and is not installed in any
current local repo (the two repos checked run `pestphp/pest` ^4.0 +
`pestphp/pest-plugin-laravel`, but neither `composer.json` requires
`pestphp/pest-plugin-browser` — confirmed by grepping both), so there is no
local vendor tree to check method names against. The methods used in the
skeleton below (`visit()`, `assertPathIs()`, `assertSee()`, `click()`,
`fill()`) were cross-checked against the official Pest browser-testing docs
(pestphp.com/docs/browser-testing, retrieved 2026-08-02) and confirmed to
exist with this shape — `fill()` in particular is a real, distinct method
from `type()` (both exist; `fill()` sets a field's value directly, `type()`
simulates keystrokes). That external-docs check is weaker evidence than a
local vendor tree, so before writing assertions BEYOND the basic shape below,
use the Tier-3 library-doc lookup already established in `v-tdd/SKILL.md` §
Test Convention Discovery (`mcp__plugin_context7_context7__resolve-library-id`
/ `get-library-docs` for `pestphp/pest-plugin-browser`) to confirm exact
method names against the project's actually-installed version, OR read 1-2
existing specs under `tests/Browser/` if the project already has them. Do not
guess a fluent method name that "sounds right" — that is exactly the
fabricated-API failure mode `v-skill-reviewer`'s F26 lens exists to catch.

## Location

`tests/Browser/{FlowName}Test.php`

## Scenarios

- `it('redirects unauthenticated users to login')` — visit the protected route
  logged out → land on the login page
- `it('lets an authenticated user complete the flow')` — `actingAs($user)`,
  visit, interact, assert the success state renders
- `it('shows a validation error inline')` — submit invalid input, assert the
  error text renders in the DOM (not just an HTTP 422 — this lane exists
  precisely because a real browser render is observable here)
- `it('shows a loading state during an async action')` — real-browser-only
  assertion; a jsdom render can't reliably show an in-flight network state
- One boundary/edge scenario relevant to the flow (per the skill body's
  Mandatory Boundary Tests rule — still applies to browser tests)

## Skeleton

```php
use App\Models\User;

it('redirects unauthenticated users to login', function () {
    $page = visit('/dashboard');

    $page->assertPathIs('/login');
});

it('lets an authenticated user complete the flow', function () {
    $user = User::factory()->create();

    $page = actingAs($user)->visit('/dashboard');

    $page->assertSee('Dashboard')
        ->click('New Project')
        ->fill('name', 'Test Project')
        ->click('Create')
        ->assertSee('Test Project created');
});

it('shows a validation error inline', function () {
    $user = User::factory()->create();

    $page = actingAs($user)->visit('/dashboard');

    $page->click('New Project')
        ->click('Create')                  // submit with the name field empty
        ->assertSee('The name field is required');
});
```

`actingAs()` here is the SAME Laravel test helper used in ordinary Pest feature
tests (`v-testing-patterns.md` § HTTP Testing) — because browser tests run in
the same application instance/process as the rest of the test, `actingAs()`'s
`setUser()` call on the guard is visible to the browser request too, which is
the whole point of this lane over raw Playwright. This was a live source of
confusion in the plugin's early releases (`pestphp/pest` issue #1496, opened
Sep 2025): several reporters initially saw `actingAs()` fail to authenticate
the browser session, but the issue was closed after a maintainer reproduced a
clean install and found it worked correctly — the reporters' failures traced
to project-specific custom auth logic (relying on the `Login` event, which
`actingAs()` does NOT fire — only feature-test-style `setUser()`; or an
absolute route URL resolving to a different host than the test server) rather
than a plugin defect. If a project's auth flow depends on the `Login` event or
custom session state beyond the guard's user, verify `actingAs()` alone is
sufficient before relying on it in a RED-phase test — otherwise this exact
call shape is confirmed to work. Verify against the installed plugin version
per the API-surface caveat above if anything here doesn't hold.

## Composition with the rest of v-tdd

- Boundary-test rule (skill body § Mandatory Boundary Tests) still applies —
  a numeric-parameter flow tested here still needs a manually-computed
  boundary case.
- Test budget cap (skill body § Test budget + prioritization) still applies —
  browser tests are slower than feature tests; don't burn the 8-test session
  cap on browser coverage a feature test would answer just as well.
- `browser_only_states` / `verify_by: browser` entries from a
  `SUCCESS_CRITERIA_*.md` artifact (skill body § Workflow scope check) are
  the canonical trigger for reaching for this lane instead of the plain PHP
  skeleton — those states were already routed away from v-tdd's default PHP
  skeleton because they need real-browser rendering; this file is where they
  land when the project has the capability, instead of falling through to
  `v-workflow-verifier`'s raw Playwright lane by default.
