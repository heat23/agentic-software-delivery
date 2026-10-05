# Status page decision and setup

_Last reviewed: 2026-08-02 (stripped stale "deferred — Batch 2" marker now that `v-launch-week-ops.md` is written; prev 2026-07-05 ecosystem review sweep)._

> **Persona for this reference:** senior solo-SaaS launch
> operator. Loaded by `v-launch-channels` Step 8 (pre-publish
> gates) and by `v-prelaunch-readiness` Phase 5 (Observability
> hooks) when no status page exists.
>
> **Last verified:** 2026-05-10. Hosted-status-page vendors
> shift pricing and feature sets on 12-month cycles; verify
> before adopting.

A status page does ONE thing: when the product is partially or
fully down, it answers the "is it down or is it me?" question
without funneling that question into the support inbox during
the worst possible moment. For a solo operator, this is
inbox-flood-prevention more than uptime-bragging.

---

## When you need this

| Stage | Status page need |
|---|---|
| Pre-launch (no customers yet) | Skip. No traffic, no incidents. |
| Launch + first 30 customers | **Set up, even minimal.** First incident is when you'll regret not having one. |
| 30–100 customers | Required if any B2B procurement asks; common Q on enterprise security questionnaires |
| 100+ customers | Required, ideally with subscription mechanism + automated incident updates |

The default for a solo SaaS at launch: spend 30 minutes setting
up a basic status page. The cost of doing it later, mid-incident,
is far higher.

---

## Decision: DIY vs hosted

| Option | When to use | Pros | Cons |
|---|---|---|---|
| **Static HTML at status.yourproduct.com** | Truly minimal need; pre-revenue; you mostly need a place to redirect "is it down?" inbox traffic | Free; full control; trivial to update with a commit | No automated checks; you have to manually update during incidents — easy to forget mid-firefight |
| **Hosted: Statuspage / BetterStack / Instatus / Cachet** | You want automated component health + subscription notifications | Auto-checks; subscriber-base captures customer emails; incident history | Recurring subscription fee; another vendor relationship; overkill at <20 customers |
| **Open-source self-host: Cachet / Uptime Kuma** | You want hosted-like features without vendor dependency; have a server to run it on | Free; powerful (Uptime Kuma is excellent) | One more thing to keep running; if your status page goes down with your product, it's useless |

**Default for solo SaaS at launch:** static HTML at
`status.yourproduct.com` for the first 30 days, then evaluate
based on actual incident frequency. If you have >2 incidents in
the first 30 days, upgrade to hosted.

---

## Tool examples (last-verified 2026-05-10 — verify before adopting)

**Hosted:**
- BetterStack (incl. Better Uptime — combines uptime monitoring + status page)
- Statuspage by Atlassian (heavyweight; B2B-procurement-friendly)
- Instatus (lightweight; reasonable price point)
- StatusGator (status-page aggregator; different category — not for hosting your own)

**Self-host:**
- Uptime Kuma (open source; recommended over Cachet — actively maintained)
- Cachet (older; less active maintenance)

---

## Minimum viable status page (≤30 minutes)

Even at the static-HTML tier:

### 1. Subdomain setup

`status.yourproduct.com` (CNAME to a static host or status page
provider). If you're on Vercel/Netlify/Cloudflare Pages, this is
a one-page sub-deployment.

### 2. Page structure

Three sections:

```
[Logo]                                    [Subscribe to updates]

Current status: All Systems Operational

Components:
  - Web App:        [Operational]
  - API:            [Operational]
  - Database:       [Operational]
  - Authentication: [Operational]

Recent incidents:
  No incidents in the last 7 days.

[Footer: link back to product, link to support]
```

### 3. Incident posting template

When an incident happens, the operator updates the page (or
hosted system) with:

```
[Investigating] <timestamp> UTC
We're investigating reports of slow response times on the API.
We'll update within 15 minutes.

[Identified] <timestamp> UTC
Identified: database connection pool exhaustion. Scaling up.

[Monitoring] <timestamp> UTC
Pool scaled. Monitoring response times for 30 minutes before
declaring resolved.

[Resolved] <timestamp> UTC
Resolved. Total user impact: <N> minutes of degraded API
response times. Postmortem to follow within 48 hours.
```

Communicate every 15-20 minutes during an active incident even
if the status hasn't changed. "We're still investigating" is
better than silence.

### 4. Subscribe mechanism (hosted-tier feature)

If using a hosted provider, enable subscriber sign-up. Capture
email addresses for incident broadcasts. **This list is also
your post-incident retro distribution list — overlap is real.**

If staying on static HTML: skip subscriptions; rely on Twitter /
LinkedIn for incident broadcasts (acknowledged tradeoff).

---

## What goes in the pre-launch checklist

Phase 5 (Observability) of `v-prelaunch-readiness` should also
confirm:
- [ ] Status page exists at `status.yourproduct.com` (or
      decision documented to defer until 30+ customers)
- [ ] Operator knows where the status page edit interface lives
      (so it can be updated in <2 minutes during an incident)
- [ ] Incident posting template saved somewhere accessible
      (this reference, an internal runbook, a Slack canvas) so
      the operator doesn't waste 10 minutes drafting wording at
      3am during a firefight

---

## Cross-references

- Pre-launch readiness Phase 5 (Observability): `~/.claude/skills/v-prelaunch-readiness/SKILL.md`
- Launch-week real-time operations playbook: `~/.claude/skills/references/v-launch-week-ops.md`
- Incident postmortem skill: `engineering:incident-response`
