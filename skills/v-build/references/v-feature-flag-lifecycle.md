# Feature Flag Lifecycle Reference (GAP-FF)

_Last reviewed: 2026-08-02 (fabricated-API sweep: all Pennant calls — `Feature::active/define/purge/deactivate`, `Lottery::odds()`, the "no `Feature::percentage()`" and "`deactivate()` is scope-local, not global" claims — verified against `laravel/pennant` in a project's vendor tree and confirmed real; annotated `hasRole()` as a non-Laravel/non-Pennant assumption (role package or project-local, not a framework built-in) so it doesn't read as a Pennant API)_

**Scope:** Full feature flag operational workflow from creation through removal, using Laravel Pennant. Written for a **solo operator**: there is no on-call rotation, no product manager, no security team — the person implementing the flag is also the one who monitors it and flips the kill switch.

**Gap:** v-check requires feature flags for apps with paying users (section 1.8b) and defines a brief lifecycle, but no skill owns the operational workflow, monitoring, and cleanup strategy.

---

## 1. Flag Creation & Naming

### Naming Convention

Use hierarchical naming: `feature.module.name`

- `feature.checkout.one-click-pay` — new checkout feature
- `feature.dashboard.ai-insights` — dashboard AI widget
- `ops.rate-limit.burst-protection` — operations flag for rate limiting
- `experiment.pricing.annual-discount` — pricing experiment
- `permission.admin.audit-logs` — permission-based flag

**Components:**
- **Type prefix** (`feature`, `ops`, `experiment`, `permission`)
- **Module** (checkout, dashboard, admin, etc.)
- **Name** (what the flag does)

**Why:** Hierarchical names are easy to search, group by type, and understand at a glance.

### Flag Types

| Type | Purpose | Lifecycle |
|------|---------|-----------|
| `feature` | User-facing feature rollout | Create → enable team → beta → 50% → 100% → remove after 2 weeks stable |
| `experiment` | A/B test or experiment | Create → enable cohort → measure → analyze → remove when complete |
| `ops` | Operational control (rate limit, cache behavior) | Create → enable when needed → may be permanent if it becomes a configuration |
| `permission` | Role-based access (admin-only, beta-tester-only) | Create → manage via permission system → may be permanent |

---

## 2. Gradual Rollout Stages

### Stage 1: Team-Only (Internal Testing)

**When:** After code review, before external exposure.

**Configuration:**
```php
// Example: Laravel Pennant. `Feature::active(...)` is the real Pennant call;
// `hasRole('team')` is NOT a Laravel or Pennant built-in — it assumes a role
// system the project has installed (e.g. spatie/laravel-permission) or a
// project-local trait/column. Swap it for whatever the project actually uses
// to check team/internal membership.
if (Feature::active('feature.checkout.one-click-pay') && auth()->user()->hasRole('team')) {
    // Show one-click pay to internal team only
}
```

**Duration:** 1–3 days.

**Verification:**
- [ ] Feature works in staging.
- [ ] QA has tested the feature with team members.
- [ ] No UI glitches, no error logs.
- [ ] Metrics collection is working (see section 3).

### Stage 2: Beta Percentage (Early Adopters)

**When:** Feature is stable; ready for limited external exposure.

**Configuration:** Pennant has no `Feature::percentage()` — define the flag with a `Lottery` for probabilistic rollout, then check it per-scope. In a service provider (or a dedicated definitions file):
```php
use Illuminate\Support\Lottery;

Feature::define('feature.checkout.one-click-pay', fn () => Lottery::odds(5, 100)); // ~5% of scopes
```
```php
// At the call site — resolves once per scope (user) and is then persisted/cached
if (Feature::active('feature.checkout.one-click-pay')) {
    // this user is in the 5% cohort
}
```

**Duration:** 3–7 days.

**Targets:** 5% → 25% → 50% (widen by redefining the `Lottery::odds(...)` and running `Feature::purge('feature.checkout.one-click-pay')` so stored resolutions are recomputed at the new odds).

**Verification at each step:**
- [ ] Error rate (flag-on cohort) ≤ error rate (flag-off cohort).
- [ ] No spike in support tickets or complaints.
- [ ] Performance metrics stable (latency, CPU, database load).
- [ ] Key feature metrics trending as expected.

### Stage 3: 50% Rollout

**When:** Beta phase is successful; feature is ready for half the user base.

**Configuration:** Widen the lottery odds in the definition, then purge stored resolutions so existing users are re-bucketed:
```php
Feature::define('feature.checkout.one-click-pay', fn () => Lottery::odds(50, 100)); // ~50%
// then: php artisan tinker >>> Feature::purge('feature.checkout.one-click-pay')
```
```php
if (Feature::active('feature.checkout.one-click-pay')) {
    // this user is now in the 50% cohort
}
```

**Duration:** 1–2 days.

**Verification:** Same as Stage 2.

### Stage 4: 100% Rollout

**When:** 50% phase is stable; feature is approved for all users.

**Configuration:**
```php
if (Feature::active('feature.checkout.one-click-pay')) {
    // All users see one-click pay
}
```

**Duration:** Until removal (see Stage 5).

**Verification:**
- [ ] Error rate stable.
- [ ] No performance degradation.
- [ ] Feature fully integrated into product.

### Stage 5: Flag Removal

**When:** Feature has been at 100% for 2+ weeks without issues.

**Actions:**
1. Remove the feature flag guard from code (unwrap the feature).
2. Remove the flag definition from the flag database/config.
3. Remove any flag-related analytics or metrics.
4. Deploy the code change.

**Example cleanup:**
```php
// Before (with flag)
if (Feature::active('feature.checkout.one-click-pay')) {
    $checkout = new OneClickCheckout();
    return $checkout->process();
}
return $checkout->processLegacy();

// After (flag removed)
$checkout = new OneClickCheckout();
return $checkout->process();
```

**Duration:** Instant (deploy the cleanup PR).

**Verification:**
- [ ] Code review confirms all flag references are removed.
- [ ] Tests still pass.
- [ ] No errors in logs post-deploy.

---

## 3. Monitoring During Rollout

### Error Rate Comparison

**Track:** Error rate in flag-on cohort vs. flag-off cohort.

**Setup:**
```javascript
// Frontend example: send flag state with every error
Sentry.captureException(error, {
  tags: {
    flag_one_click_pay: isFeatureEnabled('feature.checkout.one-click-pay'),
  },
});
```

**Monitoring query (Sentry, Datadog, or similar):**
```
SELECT error_rate BY tags.flag_one_click_pay
WHERE feature_name = 'checkout'
AND time > now() - 1h
```

**Threshold:** If flag-on error rate > flag-off error rate × 1.5 (or > 2× baseline), **kill switch** the flag.

### Key Metrics to Watch

1. **Conversion/success rate:** Does the feature achieve its goal?
   - Example: one-click checkout should increase conversion by X%.
   - Track: orders_one_click / total_orders.

2. **Latency:** Is the feature slow?
   - Track: p50, p95, p99 response time.
   - Alert if latency > baseline × 1.2.

3. **Database load:** Does the feature cause database spike?
   - Track: queries per second, slow query count.
   - Alert if QPS increases by > 20%.

4. **Customer support load:** Are support tickets up?
   - Track: new support tickets mentioning the feature.
   - Manual check (not automated).

5. **User engagement:** Are users actually using it?
   - Track: feature_used / users_in_cohort.
   - If engagement is near 0%, consider killing the feature (it may not be visible or not valued).

### Alerting Rules

| Metric | Threshold | Action |
|--------|-----------|--------|
| Flag-on error rate > flag-off × 1.5 | Automatic | Kill switch (go to Stage 0) |
| Latency p99 > baseline × 1.2 | Automatic | Kill switch |
| Database QPS > +20% from baseline | Manual review | Investigate, consider kill switch |
| Customer complaints about feature | Manual | Investigate, consider kill switch |

---

## 4. Kill Switch Protocol

### When to Flip the Flag Off

- Error rate spike detected (automatic alert).
- Customer complaints or support surge.
- Performance degradation (latency spike, DB overload).
- Security issue discovered (disable until patch is deployed).
- Business decision to pause rollout (change in strategy).

### What Triggers It (solo operator — you wear every hat)

- **Error spike or performance issue:** automated alert flips it, or you flip it the moment you see the alert.
- **Customer complaints / support surge:** treat a cluster of reports on the flagged feature as a flip trigger.
- **Security issue:** flip immediately, then patch — availability of the rest of the app beats one broken feature.
- **Business/strategy decision:** your call; no sign-off loop to wait on. Prefer wiring the automated triggers so a flip does not depend on you being awake.

### How Fast Must It Take Effect

- **Best case:** < 1 minute (flag state is cached for up to 60 seconds; restart app or clear cache to force immediate change).
- **Acceptable:** < 5 minutes (flag system polls every 5 minutes or on deploy).
- **Last resort:** Deploy a code change (if flag system is unavailable; > 15 minutes, requires a full deploy).

**Preparation:**
- Set up a Slack bot or dashboard shortcut to flip flags instantly (test before launch).
- Document the kill switch. Pennant has no global percentage switch — a true global off is
  achieved by **redefining the feature to `false` and purging stored resolutions** (deploy or
  hot-patch the definition), not by `Feature::deactivate(...)` (which only deactivates the
  default/current scope):
  ```text
  # Global kill switch (Laravel Pennant): redefine to false, then clear stored values
  # In a service provider / definitions file (deploy this):
  Feature::define('feature.checkout.one-click-pay', fn () => false);
  # Then flush persisted resolutions so no cached "active" survives:
  php artisan tinker
  >>> Feature::purge('feature.checkout.one-click-pay')
  ```
  `Feature::deactivate('feature.checkout.one-click-pay')` is the right tool only for turning the
  flag off for **one specific scope** (e.g. a single abusive tenant), not the whole fleet.
- Verify it took effect yourself (check logs, test with a test account).

---

## 5. Flag Cleanup & Stale Flag Management

### 2-Week Stable Period Before Removal

- **Feature at 100% for 2+ weeks** without issues or rollbacks = safe to remove.
- **Why 2 weeks?** Covers a full business cycle (weekday + weekend traffic patterns).
- **Track:** Add a `created_at` and `enabled_at_100_percent` timestamp to each flag.

### Finding Stale Flags

**Query the flag table:**
```sql
SELECT name, created_at, last_updated_at, enabled_percentage, status
FROM feature_flags
WHERE status = 'active'
  AND DATE_ADD(last_updated_at, INTERVAL 30 DAY) < NOW();
```

**Stale flags to investigate:**
- Flags that haven't been updated in 30+ days.
- Flags that are still at partial rollout (e.g., stuck at 25% for 3 months).
- Flags with no recent metric activity.

**Cleanup action:**
1. If 100% for 2+ weeks: Remove the flag code (see Stage 5 cleanup).
2. If stuck at partial rollout: Escalate to product manager (why is it still partial?).
3. If unused (no users in flag-on cohort): Kill switch immediately or remove.

### Removing Flag Code Without Breaking

**Pattern:**

1. **Phase 1:** Wrap the feature in the flag guard (already done).
   ```php
   if (Feature::active('feature.checkout.one-click-pay')) {
       // new feature
   } else {
       // old feature
   }
   ```

2. **Phase 2 (after 2 weeks):** Unwrap the feature (assume flag is always true).
   ```php
   // old feature code removed, new feature code runs for everyone
   // but flag is still in database (just never checked anymore)
   ```

3. **Phase 3 (1 week later, safe cleanup):** Remove flag from database.
   ```php
   // Flag is definitely not checked in code anymore; remove from database
   ```

**Why the delay?** If code deploy fails or has to roll back, having the flag in the database for 1 week allows you to re-enable it without code changes.

---

## 6. Anti-Patterns

### Nested Flags (Avoid)

**Bad:**
```php
if (Feature::active('feature.checkout.one-click-pay')) {
    if (Feature::active('feature.checkout.express-shipping')) {
        // one-click pay + express shipping (both must be enabled)
    }
}
```

**Why bad:** Debugging is hard. If express shipping is off, you don't know if one-click pay works. Creates invisible dependencies.

**Good:**
```php
if (Feature::active('feature.checkout.one-click-with-express')) {
    // both features bundled as one flag
}
```

---

### Flags That Never Get Cleaned Up (Avoid)

**Bad:**
```php
if (Feature::active('legacy.old-checkout-flow')) {
    // Been at 100% for 2 years, flag guard is still here
    // No one remembers why
}
```

**Why bad:** Accumulates technical debt. Code becomes unreadable. Flag system gets slower.

**Good:**
```php
// Flag removed after 2 weeks at 100%. Code is now clean.
// If we need to rollback, we deploy a new version with the flag; we don't revive the old one.
```

---

### Using Flags for Permanent Configuration (Avoid)

**Bad:**
```php
if (Feature::active('feature.enable_advanced_analytics')) {
    // This is really a permanent config, but we put it in the flag system
}
```

**Why bad:** Flags are meant to be temporary. A permanent config should be in environment variables or a config file.

**Good:**
```php
// In .env or config file
ADVANCED_ANALYTICS_ENABLED=true

// In code
if (config('analytics.advanced_enabled')) {
    // ...
}
```

---

## Glossary

- **Cohort:** A group of users (e.g., those with the flag on vs. off).
- **Rollout:** Gradually increasing the percentage of users who see a feature.
- **Kill switch:** Instantly disabling a feature by setting the flag to inactive.
- **Percentage-based:** A flag that's enabled for X% of users (deterministic hash of user ID).
- **Idempotent removal:** Removing a flag doesn't break code that checks for it (flag system returns false if flag is unknown).
