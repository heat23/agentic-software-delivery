# Audit family map

_Last reviewed: 2026-07-06 (theme-consistency sweep B: v-audit-growth corrected to 5 dims)_

> **Purpose:** the canonical "which audit skill for which intent"
> reference. Loaded on-demand by v-audit-orchestrator and as the
> operator's go-to documentation when they've forgotten which
> specialist audit covers what.

The audit family has 13 skills + 1 consolidator (v-edge-hunt merged
into v-bug-hunt as a `boundaries` lens 2026-07-05, reducing the count
by one; `/v-ui-audit` retired 2026-07-06, absorbed into `/v-audit-code`
— its comprehensive UX/a11y depth now lives in
`skills/v-audit-code/references/deep-ux-audit.md` as a deepening of
that skill's flexible-lens framework (`references/rating-framework.md`
— no fixed dim count), reducing the count by one more). Each has a
specific specialty; they're not interchangeable. This map is the
single page that distinguishes them.

---

## Decision matrix — what to run when

| Operator intent | Skill / bundle | Output |
|---|---|---|
| "Is this product ready to send strangers to?" | `v-prelaunch-readiness` | Punch list of MUST-FIX surfaces |
| "Does this output look professionally crafted vs AI-built default?" | `v-anti-template-gauntlet` | PASS / CONDITIONAL_PASS / BLOCK verdict |
| "Audit my entire codebase for issues" | `v-check` (broad) | Findings across security / perf / tests / UX / tech debt / observability / config validation |
| "I just implemented a feature — verify before merging" | `v-pre-flight` + `v-verify-done` | Quality gates + convention checks |
| "How's our SEO + content?" | `v-audit-seo` | 9-dim SEO audit (technical, on-page, content, keywords, SERP, strategy, schema, off-site, alt-page opportunities) |
| "How's our messaging across surfaces?" | `v-audit-messaging` | 7-dim messaging audit (positioning, copy, voice, FAQ) |
| "How's our pricing model + checkout + dunning?" | `v-audit-sales-pricing` | 10-dim revenue-ops audit (ICP, lead scoring, outreach, CRM, pricing model, checkout, dunning, etc.) |
| "How's our activation funnel + retention?" | `v-audit-growth` | 5-dim growth audit (activation, retention, feedback, CRO, cancellation/win-back) |
| "How's our analytics instrumentation?" | `v-audit-analytics` | 6-dim analytics audit (event taxonomy, schema, funnels, KPIs, dashboards, coverage) |
| "How's our admin panel?" | `v-audit-admin` | 6-dim admin audit (CRUD completeness, ops, audit trail, AI-built blind spots) |
| "Adversarial bug hunt on one flow/subsystem" | `v-bug-hunt` (`bugs` lens, default) | Full-stack findings (race conditions, broken UX, critical-path defects) + prompt pack |
| "Boundary/edge-case sweep on one domain" | `v-bug-hunt --lens=boundaries` | Empty/max/DST/currency/unicode/pagination/state-machine/concurrency/entitlement findings + prompt pack (formerly `v-edge-hunt`, merged in 2026-07-05) |
| "Is this repo production-ready and 2026-current? / Comprehensive product review (deepest single audit)" | `v-audit-code` | Whole-repo risk triage + modernization findings + fix packs (standalone, not bundled) — also the deep UX/a11y/brand/copy/conversion/lifecycle owner via its flexible-lens framework (`references/audit-lenses.md`) plus the `references/deep-ux-audit.md` deepening (absorbed `v-ui-audit` 2026-07-06, retired) |
| "I ran multiple audits — give me a unified view" | `v-audit-consolidate` | Single de-duplicated report + merged prompt pack |

---

## Bundle recipes

Pre-built bundles for common workflows.

### Pre-launch readiness sweep (recommended for solo SaaS launches)

**Skills:** `v-prelaunch-readiness` + `v-anti-template-gauntlet` + auto-consolidate.

**When:** sending strangers to the product (HN post, PH submission, paid ads, cold outreach).

**Output:** unified consolidated report covering surface presence/correctness AND output quality, plus one merged prompt pack.

**Why this combo:** prelaunch-readiness checks "do the surfaces work?" (hero, signup, pricing, demo, docs, OG, dark mode, mobile). Gauntlet checks "do the surfaces look professionally crafted?" Together they cover the pre-launch product gate.

### Pre-launch full sweep

**Skills:** `v-prelaunch-readiness` + `v-anti-template-gauntlet` + `v-audit-seo` + `v-audit-messaging` + `v-check` + auto-consolidate.

**When:** comprehensive pre-launch readiness; when you want everything in one pass.

**Output:** consolidated report from 5 audits.

**Caveat:** runs 5 specialists in sequence; expect 30-60 minutes total. For most launches, the basic sweep above is enough.

### Pre-merge gate

**Skills:** `v-pre-flight` + `v-verify-done`.

**When:** finished implementing a feature; verifying before commit/merge.

**Output:** `PRE_FLIGHT_REPORT_*.md` (executable gates) + `VERIFY_DONE_REPORT_*.md` (convention checks).

**Why this combo:** pre-flight runs deterministic CI-style gates (tests/build/lint/types/security audits). verify-done runs judgment-call convention checks (lazy loading, DOMPurify, types, AI-test anti-patterns). Different question types; both should pass before merging.

### Code-quality audit

**Skills:** `v-check` (alone — it's broad enough).

**When:** quarterly audit of the codebase; before a major refactor; investigating tech debt.

**Output:** `AUDIT_REPORT_*.md` with findings across 12 domains (security, performance, tests, UX, tech debt, accessibility, SEO triage, AI/LLM integration, feature completeness, agent dispatch, observability, config validation).

### Specialist-only audits

**Skills:** any single `v-audit-{specialist}` invocation.

**When:** you know exactly which domain to audit; no need for a multi-skill bundle.

**Output:** specialist's report + prompt pack.

---

## Skill cards (1-line description + when to use + when NOT to use)

### `v-prelaunch-readiness`

- **Domain:** pre-launch product surfaces (hero, signup, pricing, demo, docs, OG, dark mode, mobile)
- **SME persona:** senior solo-SaaS launch operator (first-100-customers experience)
- **Use when:** sending traffic to the product for the first time
- **Don't use when:** product is already launched and has revenue (use `v-audit-code` for comprehensive post-traction audit — absorbed `v-ui-audit`'s depth 2026-07-06)

### `v-anti-template-gauntlet`

- **Domain:** AI/template tells across copy + visual + brand
- **SME persona:** senior product designer (non-AI-built craft signals)
- **Use when:** pre-ship gate; verifying output looks crafted, not template-default
- **Don't use when:** auditing surface presence (use `v-prelaunch-readiness`); auditing comprehensive UX (use `v-audit-code` — absorbed `v-ui-audit`'s depth 2026-07-06)

### `v-check`

- **Domain:** broad codebase audit (12 domains: security, perf, tests, UX, tech debt, a11y, SEO triage, AI/LLM, feature completeness, agent dispatch, observability, config validation)
- **SME persona:** senior code reviewer + security engineer
- **Use when:** codebase audit; pre-merge for substantial features; quarterly tech-debt review
- **Don't use when:** specialist audit needed (use the specific `v-audit-{specialist}` skill)

### `v-audit-seo`

- **Domain:** 9-dim SEO audit (technical, on-page, content, keywords, SERP, strategy, schema/AI-readiness, off-site, alt-page opportunities)
- **SME persona:** senior SEO + GEO strategist (AI-Overview transition)
- **Use when:** organic-discovery audit; before/during content scaling
- **Don't use when:** pre-launch with no published content (use stage=greenfield mode for foundation-focused audit)

### `v-audit-messaging`

- **Domain:** 7-dim messaging audit (homepage, pricing copy, features, onboarding, emails, differentiation, cross-surface consistency)
- **SME persona:** senior brand & messaging strategist
- **Use when:** positioning / copy / value-prop audit
- **Don't use when:** auditing pricing MODEL (use `v-audit-sales-pricing`); auditing pricing PAGE COPY only is in scope here

### `v-audit-sales-pricing`

- **Domain:** 10-dim revenue-ops audit across 3 tracks (Sales Pipeline 1-5, Pricing & RevOps 6-9, Pricing Strategy 10)
- **SME persona:** senior RevOps + pricing strategy partner
- **Use when:** revenue-ops audit; pricing-model review; checkout/dunning review
- **Don't use when:** pricing-page COPY only (use `v-audit-messaging`); designing INITIAL pricing (use `v-pricing-design`)

### `v-audit-growth`

- **Domain:** 5-dim growth audit (activation, retention, feedback loops, CRO, cancellation/win-back)
- **SME persona:** senior growth strategist
- **Use when:** activation rate stalled; retention curve flat; CRO review
- **Don't use when:** designing INITIAL activation funnel (use `v-activation-funnel-design`); pricing review (use `v-audit-sales-pricing`)

### `v-audit-analytics`

- **Domain:** 6-dim analytics audit (event taxonomy, schema integrity, funnels, KPIs, dashboards, coverage)
- **SME persona:** senior analytics engineer
- **Use when:** instrumentation audit; debugging "why are funnel numbers wrong"
- **Don't use when:** designing initial event taxonomy (no skill exists yet for this; use the audit's findings to design)

### `v-audit-admin`

- **Domain:** 6-dim admin-panel audit (functional completeness, visual craft, usability, edge cases, audit trail, AI-built blind spots)
- **SME persona:** senior product/design/UX/QA/ops review team
- **Use when:** admin panel exists and needs review
- **Don't use when:** no admin panel (skill auto-detects and exits gracefully)

### `v-pre-flight`

- **Domain:** executable quality gates (tests/build/lint/types/security audits)
- **SME persona:** senior CI/release engineer
- **Use when:** post-implementation, pre-merge
- **Don't use when:** auditing code quality broadly (use `v-check`); convention checks (use `v-verify-done`)

### `v-verify-done`

- **Domain:** convention checks (lazy loading, DOMPurify, types, factory integrity, AI-test anti-patterns)
- **SME persona:** senior code reviewer
- **Use when:** post-implementation, pre-merge (alongside pre-flight)
- **Don't use when:** executable gates (use `v-pre-flight`); broad codebase audit (use `v-check`)

### `v-bug-hunt` (`bugs` lens — default)

- **Domain:** adversarial full-stack bug hunt on one target subsystem/flow (race conditions, broken UX, critical-path defects)
- **SME persona:** senior adversarial QA engineer
- **Use when:** a specific flow (auth, checkout, onboarding) needs a hostile pass beyond normal review
- **Don't use when:** you want a full-codebase sweep (use `v-check`); boundary/edge-value defects specifically (use `v-bug-hunt --lens=boundaries`)

### `v-bug-hunt --lens=boundaries` (formerly `v-edge-hunt`, merged 2026-07-05)

- **Domain:** boundary-condition sweep on one domain (empty/max-value, DST, currency, unicode, pagination, state-machine, concurrency, entitlement) — same skill as above, different lens
- **SME persona:** senior adversarial QA engineer (edge-case specialist)
- **Use when:** a specific domain (billing, dates, pagination) needs boundary-value coverage
- **Don't use when:** broader behavioral/UX defects (use the default `bugs` lens); multi-domain code health (use `v-check`)

### `v-audit-code`

- **Domain:** whole-repo production-readiness + 2026-modernization pass (security, data integrity, reliability, dated patterns) — **retired `v-ui-audit`'s ownership (2026-07-06)**, so this skill is now also the deep UX/a11y/brand/copy/conversion/lifecycle owner via its flexible-lens framework (`skills/v-audit-code/references/audit-lenses.md`) deepened by `skills/v-audit-code/references/deep-ux-audit.md` (no fixed dim count — see `rating-framework.md`); the shared anti-AI-tells COPY catalog stays in `skills/references/anti-ai-tells-content.md`
- **SME persona:** senior production-readiness auditor + modernization architect (also covers the cross-functional designer + brand designer + frontend-engineer lens for the absorbed deep-UX mode)
- **Use when:** a standalone whole-repo risk/modernization pass is wanted; post-traction comprehensive UX review; quarterly product health check (formerly `v-ui-audit`'s use case)
- **Don't use when:** single-PR/diff review (use `/code-review`); operational launch gate (use `/v-check`); pre-launch triaged view (output is comprehensive, not triaged — use `v-prelaunch-readiness`). Standalone only — not part of any orchestrator bundle sequence.

### `v-audit-consolidate`

- **Domain:** meta — consolidates outputs of N≥2 audits into one
- **SME persona:** senior data-pipeline engineer (deduplicates heterogeneous outputs)
- **Use when:** ran 2+ audits; want one consolidated view + merged prompt pack
- **Don't use when:** single audit ran (no consolidation needed); 0 audits ran (run audits first)

---

## Cross-skill overlap notes

These overlaps are intentional but worth knowing:

| Pair | Where they overlap | How to handle |
|---|---|---|
| `v-audit-messaging` + `v-audit-sales-pricing` | Pricing page (messaging audits COPY; sales-pricing audits MODEL/STRUCTURE) | Run both for complete pricing-page review |
| `v-prelaunch-readiness` + `v-anti-template-gauntlet` | Pre-ship gates (prelaunch checks PRESENCE; gauntlet checks QUALITY) | Run both — that's the recommended pre-launch bundle |
| `v-pre-flight` + `v-verify-done` | Post-implementation gates (pre-flight DETERMINISTIC; verify-done JUDGMENT) | Run both — that's the pre-merge gate |
| `v-check` + specialist `v-audit-*` | Domain X coverage (v-check has TRIAGE-level coverage; specialist has CANONICAL coverage) | Run v-check broadly; run specialist when v-check flags depth needed |
| `v-audit-code` (deep-UX mode) + `v-prelaunch-readiness` | UI quality (polish's deep-UX mode is COMPREHENSIVE, absorbed from retired `v-ui-audit` 2026-07-06; prelaunch is TRIAGED) | Pre-launch: prelaunch only. Post-traction: v-audit-code. |

---

## Design vs audit split

Some design skills exist alongside audit skills. They're complementary, not interchangeable:

| Audit skill | Design skill (pre-revenue) | Use the design skill when |
|---|---|---|
| `v-audit-sales-pricing` | `v-pricing-design` | Designing INITIAL pricing for a pre-revenue product |
| `v-audit-growth` (Dim 1: Activation) | `v-activation-funnel-design` | Designing activation funnel from scratch (pre-launch) |
| (no audit equivalent) | `v-beta-program` | Designing beta program for first 30-50 users |
| `v-marketing-design` (visual decisions) | `v-illustration-system` | Designing static visual identity (hero illustrations, custom icons, branded data viz) |

The design skills produce design docs + implementation prompt packs. The audit skills evaluate existing implementation. Don't mix them — design first, build, then audit.

---

## Portfolio & ops skills (adjacent to this family, NOT product audits)

These two skills are report-only like the audit family but operate at a different altitude —
across the operator's whole project portfolio, or against a live production deployment, rather
than auditing one project's codebase. They are NOT part of the audit-family bundle recipes above
and are not invoked by `/v-audit-orchestrator`.

| Operator intent | Skill | Output |
|---|---|---|
| "What should I work on next across all my projects?" | `v-next` | Ranked cross-project next-action list (stale audits, unresolved findings, stranded worktrees, CI health) — recommends skills, never dispatches them |
| "Is production actually healthy right now?" | `v-prod-triage` | Runtime health triage (error clustering, queue/failed-jobs, scheduler drift, smoke check, opt-in backup-restore drill) |

### `v-next`

- **Domain:** portfolio-wide cadence — reads ground truth (audit mtimes, unresolved findings,
  worktree/branch state, CI status) across multiple projects and ranks what's overdue
- **SME persona:** portfolio-operations lead
- **Use when:** periodic "what's overdue" check-ins; no specific task in mind yet
- **Don't use when:** auditing one project in depth (use the relevant `v-audit-*` specialist);
  auditing the `/v` system itself (use `v-self-audit`)

### `v-prod-triage`

- **Domain:** production runtime health — error clustering, queue/failed-jobs backlog,
  scheduled-task drift, post-deploy smoke check, opt-in backup-restore integrity drill
- **SME persona:** senior SRE / production-reliability engineer
- **Use when:** periodic prod health check-ins, post-deploy verification, or disaster-recovery
  readiness checks
- **Don't use when:** pre-deploy static gates (use `v-pre-flight`); adversarially exercising a
  specific subsystem's behavior (use `v-bug-hunt`); static codebase health (use `v-check`)

---

## Cross-references

- Audit consolidator: `~/.claude/skills/v-audit-consolidate/SKILL.md`
- Severity vocabulary mapping: `~/.claude/skills/v-audit-consolidate/references/severity-mapping.md`
- Per-skill floor calibration: `~/.claude/skills/references/v-audit-floors.md`
- Audit-family verification gates: `~/.claude/skills/references/v-audit-gates.md`
- Audit-family output conventions: `~/.claude/skills/references/v-audit-output-conventions.md`
- Skill-template canonical structure: `~/.claude/skills/v-audit-orchestrator/references/v-audit-skill-template.md`
