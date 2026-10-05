# v-* Incident Response & Production Hotfix Guide

_Last reviewed: 2026-08-03 (deferred-findings closure: added explicit no-staging fallbacks for the diagnosis "reproduce in staging" step and the deploy "canary/staged rollout (if available)" step — both now say what to do instead of relying on the tier existing, cross-referencing `v-migration-lifecycle.md`'s seeded-copy convention)_

**Purpose:** Triage, diagnosis, and minimal-scope fix workflow for production incidents in the v-* skill ecosystem. This complements the plan→build→test→polish→audit→ship pipeline by providing the _off-cycle_ path when things break in production.

**Audience:** a **solo operator**. There is no on-call rotation, no separate team to notify, no incident commander — "notify" means "your alerting reaches you" (PagerDuty/push/email/SMS), and every decision below is yours. The severity tiers still matter because they set how much ceremony to skip, not who to escalate to.

**Scope:** This is a reference guide. The `/v` router and `v-build` own actual execution; this guides decision-making.

---

## 1. Triage: Severity Classification & Initial Response

### Severity Levels

| Level | Criteria | Alert Urgency | Fix Target | Ceremony |
|-------|----------|-------------|-----------|----------|
| **P0** | Site/core service down; data loss risk; auth broken | Drop everything now (push/SMS-grade alert) | <15 min diagnosis; <1 hour fix+deploy | Skip TDD, skip full test suite; minimal-scope only |
| **P1** | Major feature broken; widespread user impact; data integrity at risk | Act within 15 min | <1 hour diagnosis; <4 hour fix+deploy | TDD optional; focused integration tests mandatory |
| **P2** | Feature partially broken; small user subset affected; workaround exists | Act within the hour | <4 hour diagnosis; <24 hour fix | TDD enforced; full test suite before deploy |
| **P3** | Cosmetic/minor UX issue; no functional impact; single user or rare edge case | Log it, handle on next cycle | <1 week | Standard ceremony; full audit before ship |

### Initial Triage Checklist

- [ ] Is the service responding? (HTTP 200, basic health checks pass)
- [ ] How many users affected? (all, by region, by feature, single user)
- [ ] Is data being lost or corrupted? (check recent writes to database, queue backlog, logs for errors)
- [ ] Can users work around it? (is there a fallback, can they retry, does business continue)
- [ ] Did we deploy in the last 4 hours? (most likely culprit)

---

## 2. Diagnosis: Structured Debugging Steps

### Diagnosis Sequence (Do in Order)

1. **Check Infrastructure Health**
   - Database: connections available? replication lag? disk space?
   - Memory/CPU: any process at 100%? OOM kills in last 10 min?
   - Network: high latency? packet loss to dependency services?
   - Queue (if present): backlog size? consumers running?
   - Caching layer: evictions? high miss rate?

2. **Check Logs (Last 5-10 Minutes)**
   - Error logs: stack traces, 5xx responses, timeout patterns
   - Application logs: request rate, latency p95/p99, trace IDs for failed requests
   - Database logs: slow queries, connection exhaustion, lock waits
   - Third-party logs: API error rates, webhook delivery failures

3. **Reproduce the Issue**
   - What's the minimal repro? (specific endpoint, user action, data state)
   - Is it consistent or intermittent?
   - Does it happen in staging? (if yes, easier to debug; if no, environment-specific)
   - **No staging tier at all?** Don't skip this step — reproduce against a local copy seeded with
     production-like data volume instead (same convention as `v-migration-lifecycle.md § No Staging Tier`:
     seed to at least 10x the affected table's current production row count). A repro that only
     manifests under real production data volume/skew is real signal; treat "couldn't reproduce at
     all, anywhere" differently from "couldn't reproduce because nothing was seeded" — the second is
     an untested step, not a clean environment-specific signal.
   - Can you trigger it on demand? (if yes, root cause is likely deterministic)

4. **Isolate the Root Cause**
   - Recent code changes: what shipped in the last deploy? (check git log --oneline -20)
   - Configuration changes: new feature flags, env vars, secrets rotated?
   - Dependency updates: new library versions, API contract changes?
   - Data state: unusual data volume, new field, deleted record causing cascade failures?

5. **Identify Root Cause (Common SaaS Failure Modes)**
   - **Database connection pool exhausted:** Max connections set too low; connection leaks from unfinished transactions
   - **Queue backlog:** Consumers can't keep up; messages not being acked; poison pill message blocking queue
   - **Memory leak:** Process memory growing over time; cached objects not being GC'd; circular references
   - **Third-party API timeout:** Dependency service slow; your retry logic amplifying load; fallback not triggered
   - **Cache stampede:** Cache key expired; all requests regenerating the same expensive compute; write throughput overloaded
   - **N+1 queries:** Loop loading related data one-by-one instead of batch; recent code change removed eager-load
   - **Infinite loop or recursion:** New business logic calling itself; cyclic data structure traversal
   - **Missing index:** Query scanning whole table; recent code change added new WHERE clause without index

---

## 3. Hotfix: Minimal-Scope Fix Principles

### Fix-First Principles

- **Fix the symptom first, root cause later:** P0/P1 hotfixes prioritize _availability_ over _correctness_. If the fix is 5 lines, ship it. Root cause investigation happens in postmortem.
- **Minimal scope:** Only touch the code path that's broken. Don't refactor nearby code, don't fix tech debt in the same commit, don't add new features.
- **Feature flag as kill switch:** If the fix is risky, wrap it in a feature flag. Operators can toggle without redeploying.

### Skip-Ceremony Rules (When You Can Abbreviate Steps)

| Step | P0 | P1 | P2 | P3 |
|------|----|----|----|----|
| Full TDD (red→green→refactor) | ✗ write test only | ✗ focused test only | ✓ | ✓ |
| Full test suite run before deploy | ✗ run affected suite only | ✗ run affected suite only | ✓ | ✓ |
| `/v-check` or full audit | ✗ skip | ✗ skip | skip during hotfix | ✓ before ship |
| Code review | ✗ async after deploy if stable | ✗ async after deploy | ✓ before deploy | ✓ before deploy |
| v-polish (UI changes) | ✗ ship, iterate after | ✗ skip DESIGN_TOKENS check | ✓ | ✓ |

### Mandatory Minimums (Can NEVER Skip)

- [ ] **Test the fix:** Write or run ONE test that would fail before the fix and pass after. This proves the fix works.
- [ ] **Don't break existing tests:** Run the affected test suite. If existing tests are now failing (that weren't failing before), fix them or revert.
- [ ] **Sanity check the change:** Read the diff yourself. Does it make logical sense? Did you introduce a typo, wrong variable, off-by-one error?
- [ ] **Log the fix:** Add a one-line comment with the issue ID/ticket number so future readers know why this code exists.

---

## 4. Verification: Targeted Verification for Hotfixes

### Hotfix Verification (P0/P1 Only)

- [ ] **Affected path only:** Run tests for the specific feature/endpoint that was broken. Don't run the full suite (takes too long).
- [ ] **Smoke test checklist:**
  - [ ] Can users access the feature? (HTTP 200, no error page)
  - [ ] Does the fix work as expected? (run your minimal repro manually)
  - [ ] Did we break anything else? (run related features; check error rates in logs)
  - [ ] Is performance acceptable? (no new slowness, queue backlog not growing)
  - [ ] Are we logging the right information? (can ops/support see what happened)

### Verification Artifact (Mandatory)

Create a lightweight verification note in your implementation report:
```
## Verification
- Affected test suite: [test file or command to run]
- Smoke test: [manual step or curl command to verify]
- Logs checked: [where to find evidence fix worked]
- Rollback trigger: [metric or error that would trigger rollback]
```

---

## 5. Deploy: Hotfix Deployment & Rollback Triggers

### Deployment Checklist

- [ ] **Feature flag set to OFF during deploy:** If the fix is gated by a flag, deploy with it OFF. Turn it ON only after confirming logs/metrics look good.
- [ ] **Canary or staged rollout (if available):** Deploy to 1% of traffic first. Watch error rates for 5 minutes. If clean, expand to 100%.
  - **No canary/staged-rollout capability (typical solo Forge/Vapor setup):** don't silently skip the
    caution this buys you — deploy straight to 100% but treat the first 5 minutes post-deploy as the
    canary window: watch the Rollback Triggers below with your dashboards already open (not "check
    back in a bit"), and have the rollback command typed and ready to run, not looked up after the
    fact. This is higher-risk than a real canary, not equivalent to it — note that in the postmortem
    if it's ever the reason a bad deploy reached 100% of traffic before detection.
- [ ] **Rollback plan ready:** Know how to revert in <5 minutes (git revert, database rollback, feature flag toggle, etc.).
- [ ] **Watch it yourself:** you are the operator — keep logs and the error dashboard open through the deploy and across the rollback window after.

### Zero-Downtime Considerations

- **Database migrations:** Can't be done zero-downtime for P0. Ship code that's compatible with old schema. Run migration in separate deploy after code is stable.
- **API contract changes:** If response format changes, old clients break. Ship code that accepts _both_ old and new request formats. Migrate clients separately.
- **Cache invalidation:** If you're changing cached data structure, invalidate cache or version the key. Don't leave stale data.

### Rollback Triggers

Rollback automatically if any of these occur within 5 minutes of deploy:
- Error rate spikes >2x baseline
- Latency p95 increases >100ms
- Database connection errors
- Queue backlog growing
- OOM kills or process crashes
- Customer reports of new errors

---

## 6. Postmortem: Lightweight Post-Incident Template

Run this async, within 24 hours of resolution (not during the crisis).

```markdown
## Incident Postmortem: [Service] [Brief Description]

**Duration:** [Start time] to [End time] ([X minutes downtime])
**Severity:** P0 | P1 | P2

### Timeline
- [HH:MM] Customer report / error alert fired
- [HH:MM] Acknowledged (alert reached me)
- [HH:MM] Root cause identified: [specific finding]
- [HH:MM] Hotfix deployed
- [HH:MM] Verified fix working
- [HH:MM] Declared resolved

### Root Cause
[One sentence: what broke and why]
- Was this deterministic (always fails) or probabilistic (fails sometimes)?
- Did it require a specific data state or external condition?

### What We Broke
- Affected component/feature: [e.g., "user authentication", "checkout flow"]
- User impact: [how many users, what could they not do]
- Data impact: [any data lost/corrupted, or just availability?]

### What Caught It
- How did we discover the problem? (customer report, alert, proactive check)
- How long until we detected it? (seconds, minutes, hours)
- Could we have detected it earlier? (missing alert, monitoring gap)

### What Prevented Earlier Detection
- Was there a test that would have caught this? (if yes, why didn't we run it?)
- Was there monitoring that should have fired? (if no, why not?)
- Do we have visibility into this component? (logs, metrics, tracing)

### Action Items
- [ ] [Action]. Due: [Date]
- [ ] Example: Add integration test for queue consumer health. Due: 2026-04-05.
- [ ] Example: Add latency alert for checkout endpoint. Due: 2026-04-03.
- [ ] Example: Document safe database migration procedure. Due: 2026-04-10.

### Lessons Learned
- What do we do differently next time?
- Did our tools/processes help or hurt? (e.g., "feature flags let us deploy safely", "we lacked prod-like staging")
```

### Postmortem Rules

- **Blame-free:** Focus on systems, not the moment. "We lacked monitoring" not "I forgot to test."
- **Ship improvements:** Action items must have due dates. Track them alongside your normal backlog.
- **Learn once:** If this failure mode appears again in future postmortems, it means the action item wasn't shipped or didn't work.

---

## Quick Reference: When to Use What

| Scenario | First Step | Route |
|----------|-----------|-------|
| Feature is completely down | Triage (§1) → Diagnosis (§2) | P0: Skip ceremony, minimal fix. Deploy with feature flag OFF. |
| Specific user action fails | Triage → Diagnosis → Reproduce | P1/P2: Test the fix before deploy. |
| Data inconsistency detected | Diagnosis → Check logs for corruption | P0 if ongoing; P1 if historical. Verify before committing data restore. |
| Third-party service is slow | Diagnosis → Check dependency logs | Implement circuit breaker / fallback. Don't retry aggressively. |
| Memory/CPU spike after deploy | Diagnosis → Rollback (don't wait for fix) | Revert code immediately. Investigate in staging. |
| Intermittent failures | Diagnosis → Check logs for timing patterns | Look for race conditions, cache stampedes, retry loops. |

---

## Integration with `/v` Router & `v-build`

This reference is read by `v-build` when the raw prompt indicates a production incident or hotfix. The skill checks this reference for triage/diagnosis guidance and uses it to decide which ceremony steps to skip or abbreviate. The actual code execution happens in `v-build` with the hotfix principles from this guide applied to task execution.

See `v-build` SKILL.md step 4b (Incident/hotfix context) for how this reference is invoked.
