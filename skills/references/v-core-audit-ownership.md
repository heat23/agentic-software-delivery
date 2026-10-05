# Audit Domain Ownership Table

_Last reviewed: 2026-08-02 (single-source-of-truth fix: AI-Search/GEO row claimed "dim 7-8" — v-audit-seo's own dimension table shows GEO lives entirely in dim 7, dim 8 is off-site/link-earning, unrelated to GEO; corrected. Prior: 2026-07-06 theme-consistency sweep B)_

Single source of truth for which skill owns which audit domain. When multiple skills touch the same area, this table designates the canonical owner. Non-owning skills MUST delegate to the canonical owner or cross-reference its output — they must NOT re-implement the same analysis independently.

## Ownership Table

| Domain | Canonical Owner | Cross-References / Delegates | Notes |
|--------|----------------|------------------------------|-------|
| Technical SEO (crawlability, CWV, sitemaps, canonicals) | `/v-audit-seo` dim 1-2 | v-check domain 7 → lightweight triage only (see Triage Rule below) | v-check flags SEO issues, recommends `/v-audit-seo` for depth |
| On-Page SEO (content quality, keywords, SERP) | `/v-audit-seo` dim 3-6 | — | Canonical owner (v-audit-growth no longer covers SEO) |
| AI-Search / GEO | `/v-audit-seo` dim 7 | v-check domain 7 → skip, reference v-audit-seo | Dim 7 (Structured Data & AI Readiness — schema, GEO, AI-crawler accessibility, citability) is where GEO lives entirely. Dim 8 (Off-Site Growth & Link Earning — backlinks) is a distinct domain, not GEO. Re-verified 2026-08-02 against `v-audit-seo/SKILL.md` § The 9 SEO Audit Dimensions; previously mis-stated here as dim 7-8. |
| Pricing & Monetization | `/v-audit-sales-pricing` | — | Canonical owner (v-audit-growth no longer covers pricing) |
| Analytics Instrumentation | `/v-audit-analytics` | — | Canonical owner (v-audit-growth no longer covers analytics) |
| Messaging & Positioning | `/v-audit-messaging` | — | Canonical owner (v-audit-growth no longer covers messaging) |
| Activation & Onboarding | `/v-audit-growth` dim 1 | — (no overlap) | Canonical owner |
| Retention & Lifecycle | `/v-audit-growth` dim 2 | — (no overlap) | Canonical owner |
| Customer Feedback Loop | `/v-audit-growth` dim 3 | — (no overlap) | Canonical owner |
| CRO / Conversion | `/v-audit-growth` dim 4 | — (no overlap) | Canonical owner |
| Cancellation / Offboarding / Win-Back | `/v-audit-growth` dim 5 | dedup fence vs `/v-audit-sales-pricing` dim 8 (dunning/churn mechanics) per v-audit-growth SKILL.md | Canonical owner |
| Admin Panel | `/v-audit-admin` | — (no overlap) | Canonical owner |
| Security | `/v-check` domain 1 | — (no overlap) | Canonical owner |
| Performance | `/v-check` domain 2 | — (no overlap) | Canonical owner |
| Test Coverage | `/v-check` domain 3 | — (no overlap) | Canonical owner |
| UX / Accessibility | `/v-check` domains 4, 6 | — (no overlap) | Canonical owner |
| Tech Debt | `/v-check` domain 5 | — (no overlap) | Canonical owner |
| AI/LLM Integration | `/v-check` domain 8 | — (no overlap) | Canonical owner |
| Observability | `/v-check` domain 11 | — (no overlap) | Canonical owner |
| Agent Dispatch / Deep Analysis | `/v-check` domain 10 | — (no overlap) | Canonical owner; skipped in scoped mode (requires full-codebase context) |
| Feature Completeness | `/v-check` domain 9 | — (no overlap) | Canonical owner |

## Delegation Rules

### Triage Rule (v-check domain 7)

In standalone mode, v-check domain 7 runs a **lightweight SEO triage** — surface-level checks for missing meta tags, broken structured data, and static CWV-risk correlates (unsized images, render-blocking scripts — CWV itself is runtime-only per v-check's Domain 7 contract; never report a fabricated CWV measurement or "regression"). It produces triage-level findings (no implementation guidance) and appends: "For full SEO analysis, run `/v-audit-seo`." It does NOT produce findings with SEO-prefixed IDs, priority rankings, or implementation plans — those belong to the canonical owner.

In scoped mode, domain 7 is already skipped (requires full-codebase context).

### Scope Narrowing Rule (v-audit-growth)

v-audit-growth has been narrowed from 8 dimensions to 5 owned dimensions only: Activation (dim 1), Retention (dim 2), Feedback (dim 3), CRO (dim 4), Cancellation/Win-Back (dim 5). The former dimensions for Analytics, Landing Page, SEO, and Pricing have been **removed** — their canonical owners provide complete coverage:

- Analytics → `/v-audit-analytics`
- Landing Page & Positioning → `/v-audit-messaging`
- SEO & Content → `/v-audit-seo`
- Pricing & Billing → `/v-audit-sales-pricing`

v-audit-growth includes a "Companion Audit Guidance" section that directs users to these specialist skills for complete funnel coverage.

### v-audit-full Deprecation Note

v-audit-full has been **deprecated**. Its orchestration role is now handled by the ecosystem review runner, which runs all 7 specialist audit skills directly. The Track 3 Dispatch Rule is no longer applicable.

### Routing Rule (orchestrator `/v`)

The `/v` orchestrator uses this table for audit routing decisions:

| User intent | Route to |
|-------------|----------|
| "audit my SEO" / "content strategy" / "keyword research" | `/v-audit-seo` |
| "audit my pricing" / "pricing review" / "monetization" | `/v-audit-sales-pricing` |
| "audit my analytics" / "instrumentation" / "event tracking" | `/v-audit-analytics` |
| "audit my messaging" / "positioning review" | `/v-audit-messaging` |
| "audit my admin panel" | `/v-audit-admin` |
| "growth audit" / "funnel review" | `/v-audit-growth` |
| "launch" / "ship" / "go-live" / "pre-launch sweep" / "what do I run before launch" | `/v-audit-orchestrator` — **canonical launch/ship audit router** (owns the bundle recipes). The non-interactive fleet automation path is the ecosystem review runner; the orchestrator is the operator-facing entry point. |
| "full audit" / "production readiness" | `/v-audit-orchestrator` (interactive bundle) or the ecosystem review runner (non-interactive, all 7 audit skills). `/v-audit-full` is DEPRECATED. |
| "audit" / "check" / "review" (generic) | `/v-check` |

This table supplements `references/v-audit-routing.md` — it resolves ambiguity when the routing table has multiple possible targets.

## Conflict Resolution

If a future skill needs to cover a domain already owned:

1. **Narrow its scope** to a sub-domain not covered by the owner (e.g., "checkout UX" as a focused slice, not "full pricing audit").
2. **Or replace the owner** by updating this table and migrating the domain logic. The old owner must remove its coverage of that domain.

Never have two skills independently producing implementation-ready findings for the same domain.

## Synthesis Lens Rule

**Cross-reference prior canonical output:** When multiple audit skills run on the same project within a **7 days** window, the consolidator (v-audit-consolidate) merges findings. Audits older than 7 days are considered stale and excluded from synthesis. Re-run them before consolidating.
