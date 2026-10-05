# Audit Workflow Routing Reference

## Quick Decision Guide

Unsure which audit to run? Use this:
- "Is my code ready?" → `/v-check` (code-focused, 11 domains)
- "Is my product ready to launch?" / "ship it" → `/v-audit-orchestrator` — **the canonical launch/ship routing owner**; its [Bundle] pre-launch path dispatches the 7-skill audit ecosystem and auto-consolidates. (/v SKILL.md and `v-classification-routing.md` both cite this owner; do not route ship/launch to `/v-check`.)
- "How's my growth funnel?" → `/v-audit-growth` (4 owned growth dimensions) + companion specialist audits
- Need a specific deep-dive → use the specialized audit (`/v-audit-seo`, `/v-audit-analytics`, `/v-audit-messaging`, `/v-audit-sales-pricing`, `/v-audit-admin`)
- Operator doesn't know which audit they want, or asks to be routed/advised across the whole audit family, or wants a bundled multi-skill sweep (pre-launch, pre-merge gate) with auto-consolidation → `/v-audit-orchestrator` (single consolidated question, dispatches + consolidates on the operator's behalf)

## Audit Classification Routing

| User Says | Route To |
|-----------|----------|
| "audit", "check", "review", "scan" | `/v-check` |
| "audit but not sure which", "advise me on what to audit", "help me pick an audit", "audit family", "which audit should I run" | `/v-audit-orchestrator` (Advise-me path or single-question menu) |
| "pre-launch sweep", "pre-launch readiness bundle", "run everything before I ship" | `/v-audit-orchestrator` ([Bundle] pre-launch options — dispatches + auto-consolidates) |
| "pre-merge gate", "gate before merge/commit" | `/v-audit-orchestrator` ([Bundle] Pre-merge gate — v-pre-flight + v-verify-done) or `/v-pre-flight` directly if only the deterministic gates are wanted |
| "full audit", "production readiness" | `/v-audit-orchestrator` ([Bundle] — the canonical owner dispatches all 7 audit skills + consolidates). `/v-audit-full` is DEPRECATED. |
| "quick audit", "quick check", "sanity check" | `/v-check` (Quick depth) |
| "launch readiness", "pre-launch", "ready to ship" | `/v-audit-orchestrator` ([Bundle] pre-launch — canonical owner; dispatches the 7-skill ecosystem + consolidates) |
| "growth audit", "funnel review" | `/v-audit-growth` (standalone, 4 dimensions) |
| "sales audit", "pricing audit", "pricing review", "sales ops", "dunning", "CRM", "pricing strategy", "value metric", "pricing model", "pricing psychology", "expansion revenue" (auditing EXISTING pricing/sales-ops) | `/v-audit-sales-pricing`. **Designing pricing that does not yet exist** ("design/set initial pricing", "pricing tiers", "willingness to pay", "price anchoring", "packaging") → `/v-pricing-design` (design skill, not an audit — per `v-classification-routing.md`). |
| "analytics audit", "analytics QA", "event audit", "KPI check", "instrumentation", "metrics audit", "dashboard audit" | `/v-audit-analytics` |
| "messaging audit", "positioning review", "copy audit", "value prop", "homepage copy", "messaging consistency" | `/v-audit-messaging` |
| "SEO audit", "content strategy", "content gap analysis", "keyword research", "organic traffic", "content calendar" | `/v-audit-seo` |
| "blog", "write article", "SEO content", "email sequence", "welcome email", "onboarding emails", "drip campaign", "lifecycle emails", "dunning emails" | `/v-content-create` (Mode 1 or 2) |
| "comparison page", "vs page", "X vs Y", "{competitor} alternative", "alternatives to {competitor}", "{competitor} pricing/review" (a specific named competitor) | `/v-content-create --type=comparison` (the former standalone `/v-comparison-page` skill was merged back into `/v-content-create` as this brief type 2026-07-05; requires a named competitor). Generic feature-comparison content with no named competitor → `/v-content-create` (default `article` type). |
| "refresh article", "update content", "stale article", "content refresh", "update old blog" | `/v-content-create` (Mode 4: Content Refresh) |
| "admin audit", "admin panel review", "admin UX", "admin completeness" | `/v-audit-admin` |
| "UI audit", "UX audit", "design audit", "comprehensive UI/UX audit", "visual audit", "pixel-perfect audit", "does this look AI-generated", "portfolio-quality review", "brand/visual-system audit", "accessibility audit", "WCAG audit", "dark mode audit" | `/v-audit-code` (it absorbed `/v-ui-audit` on 2026-07-06 — deep UX/a11y/brand specialist; see `references/deep-ux-audit.md` — deeper on UI than `/v-check`'s single UX/a11y domain) |
| "interactive showcase", "interactive demos", "calculators", "visualizations", "blog widgets" | `/v-interactive-showcase` |
| "CRO", "conversion optimization", "signup conversion", "form friction", "checkout optimization" | `/v-audit-growth` (includes CRO dimension) |
| "what should I build next", "feature gaps", "competitive gaps", "what are competitors doing", "feature prioritization", "increase engagement", "grow adoption", "next features", "product strategy", "feature discovery" | `/v-discover-features` |
| "privacy policy", "terms of service", "legal docs", "cookie policy", "DPA", "GDPR", "CCPA", "legal pages", "terms and conditions", "compliance docs" | `/v-legal-docs-generate` |
| "turn findings into prompts" | Any audit skill (prompt generation is built into all of them) |

## The 7 Specialist Audit Skills

| Skill | Domain | Dimensions |
|-------|--------|------------|
| `/v-check` | Security, performance, test coverage, UX/a11y, tech debt, AI/LLM, observability, feature completeness | 11 |
| `/v-audit-admin` | Admin panel completeness, visual craft, usability, edge cases, security, AI blind spots | 6 |
| `/v-audit-analytics` | Event taxonomy, schema integrity, funnels, KPIs, dashboards, coverage | 6 |
| `/v-audit-seo` | Technical SEO, on-page, content, keywords, SERP, strategy, structured data, off-site | 8 |
| `/v-audit-messaging` | Homepage, pricing, features, onboarding, email, differentiation, consistency | 7 |
| `/v-audit-sales-pricing` | ICP, leads, outreach, CRM, pricing, checkout, dunning, competitive, strategy | 10 |
| `/v-audit-growth` | Activation, retention, feedback, CRO | 4 |

**Deeper-tier UI/UX + refactor specialist (not part of the ecosystem-runner 7-set):**
`/v-audit-code` — absorbed `/v-ui-audit` (2026-07-06) and `/v-refactor`
(2026-07-06). It's a flexible-framework audit (`references/rating-framework.md`
— no mandated category list) plus prose lenses, not a numbered-dim
checklist. Its always-on core lenses (`references/audit-lenses.md`)
already cover visual hierarchy, brand voice/microcopy, empty/loading/error
states, mobile responsiveness, and dark-mode theme integrity as part of
the "UX, UI craft & content quality" lens, plus security & trust
boundaries in full via its own dedicated lens (not a UI-mode-only
"baseline" — the same lens every `v-audit-code` pass applies). The
on-demand deep UX/a11y mode (`references/deep-ux-audit.md`, loaded for a
deep UX/accessibility/brand ask) deepens beyond that core lens with:
WCAG 2.2 AA compliance-floor depth, structural anti-AI-tells,
pixel-perfect measurement thresholds, conversion/forms/funnel UX depth,
brand-identity depth, SEO-UI depth, visual-system consistency depth,
i18n depth, and frontend performance / Core Web Vitals (the one area
the core Performance lens only touches in passing, being
backend-focused). A separate code-quality/modernization mode
(`references/refactor-modernization.md`) covers the former `/v-refactor`
analysis incl. the DEBT_TREND register. Route here when the ask is
specifically about design quality, pixel-perfection, "looks AI-generated",
accessibility compliance, visual-system consistency, or structural
refactor/modernization — `/v-check` only skims UX/a11y as 1 of its 11
domains.

## Implementing Audit Findings

**Targeted audit / verification / investigation** ("did X work?", "make sure Y is correct", "is this bug present?", a single-surface check): when it finds an actionable defect, **fix it end-to-end in the SAME session** — do NOT stop and ask. Per SKILL.md *Autonomous End-to-End Completion*, the discovered defect routes exactly like a directly-reported bug (classify → worktree → TDD → fix → pre-flight → agent review → verify-done → merge-back). Stopping at "want me to fix?" is an incomplete session.

**Broad multi-domain audit** (`/v-check` + the 7 specialist skills produce a multi-finding `AUDIT_REPORT_*.md`): the report IS the deliverable. Because auto-fixing dozens of cross-cutting findings in one session is a different task (scale management), implement via `/v-build AUDIT_REPORT_*.md` (the report is under `.v/artifacts/`; v-build's disk-scan dual-searches root as a legacy fallback) or by copy-pasting individual prompt files from the skill's `v-*-prompts/` directory into parallel sessions. Even here, present the report + that trigger — never a blocking "want me to fix?" yes/no gate.
