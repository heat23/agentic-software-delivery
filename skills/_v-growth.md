# V Growth

Shared growth trigger matrix and required fields for product-facing `v-*` skills.

**Motion constraint (applies to every skill following this file):** all growth
recommendations are bound by the zero-outreach gate in
`~/.claude/skills/references/v-core-solo-motion.md` — passive/asset-based acquisition only;
outbound findings require an explicit `motion:` opt-in in the project CLAUDE.md. That file
is the single source of truth; do not restate its rules here.

<!-- runtime -->
## Runtime-Critical Quality Bar

These growth rules are runtime-critical and must survive any future
runtime-derivative extraction. Growth work touches onboarding, messaging,
pricing, lifecycle surfaces, and other public-facing product moments that must
stay useful, professional, and conversion-focused.

- All growth surfaces conform to the shared SaaS design system
  (`_v-design.md` + `references/design-system-spec.md`): shared tokens,
  typography, and the marketing page layout — canonical section order and
  structure live in `design-system-spec.md § Marketing Page Structure`; cite
  it, do not re-derive the list here. Product identity lives in the
  sanctioned degrees of freedom — accent, category colors, branding, copy,
  and the hero display font — never in off-spec visual systems.
- Treat onboarding flow requirements, CTA clarity, empty-state guidance, and
  public-facing copy quality as part of the product quality bar, not optional
  marketing polish. Copy must be product-specific and concrete — generic
  filler copy on a spec-conformant layout is still a regression.
- If a runtime derivative cannot preserve these standards without examples or
  concrete surface lists, keep the examples and surface lists.
<!-- end-runtime -->

## Growth Audit Entry Point

For growth-funnel assessment, use `/v-audit-growth`. It runs 5 parallel audits covering the owned growth dimensions: activation, retention, feedback, CRO, and cancellation/win-back. It produces a scored JSON report with implementation prompts in `.v-prompt-packs/v-audit-growth-<MM-DD>/`.

For complete funnel coverage, run the companion specialist audits alongside `/v-audit-growth`:

| Funnel Gap | Specialist Audit |
|------------|-----------------|
| Analytics & Instrumentation | `/v-audit-analytics` (6 dimensions: event taxonomy, schema, funnels, KPIs, dashboards, coverage) |
| Landing Page & Positioning | `/v-audit-messaging` (7 surfaces: homepage, pricing, features, onboarding, emails, differentiation, consistency) |
| SEO & Content | `/v-audit-seo` (9 dimensions: technical, on-page, content, keywords, SERP, strategy, structured data, off-site, alternative-page opportunities) |
| Pricing & Billing | `/v-audit-sales-pricing` (10 dimensions: ICP, leads, outreach, CRM, enablement, pricing, checkout, dunning, competitive, strategy — the outreach/enablement dims are motion-gated per `references/v-core-solo-motion.md`; zero-outreach default scores them "correctly absent") |

The ecosystem review runner runs ALL 7 audit skills by default, providing complete coverage.

For content creation, use `/v-content-create` (articles with visuals, email sequences). Optionally integrates with Ahrefs MCP for real keyword data.

## Growth Hook

Use a growth hook only when the change matches one or more trigger categories:
- modifies a CTA on a landing page, pricing page, signup page, or checkout page
- changes an onboarding step, empty-state CTA, or first-success flow
- touches pricing, billing, paywalls, checkout, upgrade, downgrade, cancel, or entitlement logic
- changes a landing page, signup page, or acquisition funnel surface
- adds or changes lifecycle emails, notifications, referral, invite, or sharing flows

When a trigger category matches:
- define the target metric
- define the activation or conversion event
- define the instrumentation needed
- define the post-launch readout date or trigger

If no trigger category matches, `target_metric: none` is valid.

## Growth Hook JSON Schema

When a growth hook is required, include this structure in findings and plan documents:

```json
{
  "growth_hook": {
    "target_metric": "activation_rate | conversion_rate | retention_d7 | mrr | ...",
    "success_event": "event_name that proves success",
    "instrumentation": "what analytics event(s) to track",
    "readout_trigger": "date or condition to review results"
  }
}
```

**Implementation status:** The `readout_trigger` field is defined but no skill currently consumes it automatically. Growth hooks are recorded in audit and plan documents for human review. A future `v-growth-readout` skill could close this loop by reading growth hook artifacts and generating follow-up actions when readout conditions are met. Until then, treat `readout_trigger` as a reminder for the operator, not an automated system.

## Funnel Stage Reference

| Stage | Dimension | Key Metrics |
|-------|-----------|-------------|
| Acquisition | Landing page, SEO, content, AI search surfaces | Visitor → signup rate, organic traffic, AI referral traffic (from AI Overviews, Perplexity, ChatGPT, etc.) |
| Activation | Onboarding, first-success | Signup → activated rate, time-to-value |
| Conversion | CRO, form optimization, CTA effectiveness | Form completion rate, signup → activation %, upgrade conversion % |
| Monetization | Pricing, billing, checkout | Trial → paid rate, ARPU, failed payment recovery |
| Retention | Lifecycle, re-engagement | D7/D30 retention, churn rate, DAU/MAU |
| Measurement | Analytics, feedback | Event coverage, funnel visibility, feedback volume |
