# v-audit-floors — Per-skill minimum-findings calibration

_Last reviewed: 2026-07-06 (theme-consistency sweep B: security/performance/UI-states alignment; prev sweep A: SEO/AEO + growth-motion + copy/voice)._

Audit skills (`v-audit-admin`, `v-audit-analytics`, `v-audit-growth`,
`v-audit-messaging`, `v-audit-sales-pricing`, `v-audit-seo`) declare
their per-dim floor tables here and enforce Gate 2 from
`~/.claude/skills/references/v-audit-gates.md` against them at runtime.

**`v-audit-code` is the one exception, historical-only (read before
using its table below).** `v-audit-code` is a flexible-framework
audit (`v-audit-code/references/rating-framework.md`: "no mandated
category list or scale") plus prose lenses
(`v-audit-code/references/audit-lenses.md`). It does not run a
per-dim numbered floor table or Gate 2's mandatory re-task loop — the
`## v-audit-code floors` table below is **inherited calibration data
from the retired `v-ui-audit`** (2026-07-06), kept here as a reference
point for "roughly how many findings a thorough UX/a11y pass on a
mature project tends to surface," not as an active enforcement
mechanism. `v-audit-code`'s actual compliance-floor enforcement for
accessibility and security-UI findings is a prose rule in
`v-audit-code/references/deep-ux-audit.md` § "Compliance floors
(non-demotable in deep-UX mode)" — full severity, never auto-demoted —
not a numeric floor + re-task gate.

A floor is the **minimum number of findings a dim must produce**
on a project at a given stage to be considered fully covered.
Returns below floor trigger Gate 2's mandatory re-task path.

## Stage definitions

| Stage | Signals |
|---|---|
| **mature** | Live revenue, ≥500 commits, paid users in production, >3 months old |
| **growth** | Live with users but pre-revenue or early revenue, 100-500 commits |
| **early** | Pre-launch / early access, <100 commits, <3 months old |

The orchestrator detects stage in Phase 1 (per each skill's
detection logic) and selects the floor column accordingly.
**Mature signals dominate:** any strong mature signal — live
revenue, paid users in production, or a production deploy —
selects `mature` (or `growth`) regardless of repo-shape hints; a
low commit count alone (squashed history, a fresh monorepo
subtree, a recent migration) must NEVER pull a revenue-bearing,
deployed product down to `early`. **Select `early` only when the
greenfield picture is unambiguous** — a CLAUDE.md that declares
the product pre-launch, OR the combination of no production
deploy AND no paid users — AND no contradicting mature signal is
present. Default to `mature` (most demanding) when signals are
mixed or absent. Rationale: `early` floors demand FEWER findings,
so mis-selecting `early` on a live product under-audits it while
mis-selecting `mature` on a day-0 product over-manufactures — the
asymmetry above fails safe in both directions and applies to
every audit skill that reads this file.

## Data-sufficiency override (evidence surface, not project age)

Stage above measures how far along the *project* is. It does not measure how much
*evidence* exists to audit against, and those diverge badly on small live sites.

**Rule: a site below the analytics noise floor uses the `early` column regardless of
age, commit count, or revenue.** Detect it as:

```bash
# clicks/day over the most recent 30 days of whatever first-party data exists
DAILY_CLICKS=$(awk -F, 'NR>1{c+=$2; n++} END{if(n)printf "%.1f", c/n}' \
  .seo/gsc-export-*/Chart.csv 2>/dev/null | tail -1)
SUBNOISE=$(awk -v d="${DAILY_CLICKS:-0}" 'BEGIN{print (d>0 && d<10) ? 1 : 0}')
```

`SUBNOISE=1` → use `early`, and set `confidence: low` on every finding whose evidence
is a traffic, CTR, or position delta.

**Why this is a correctness fix, not a convenience.** A multi-year-old site at
a handful of visitors/day satisfies `mature` on every listed signal — age, commits, live users —
so it draws the most demanding floors against the thinnest possible evidence surface.
Gate 2 then mandates a re-task when returns fall below floor, which pressures
subagents to manufacture findings the data cannot support. Floors exist to catch lazy
audits, not to extract a fixed yield from a site that has no measurable behaviour.

Corollary: **an honest under-floor return is a valid result** when `SUBNOISE=1`. Record
`floor_waived: "subnoise"` with the measured `DAILY_CLICKS` rather than re-tasking.

## How to use this file

1. Each audit skill adds a floor table for its dimensions. Use
   the schema below.
2. Floors are calibrated from past audit observations on similar
   projects (e.g., past audits of a mature project informed the
   `v-audit-code` deep-UX floors, inherited from the retired
   `v-ui-audit`).
3. When a floor is wrong (consistently too high or too low across
   audits), update this file (not the skill body).
4. Update the floor only when a pattern emerges (≥3 audits show
   the floor is mis-calibrated). Single-audit anomalies should be
   handled by Gate 2's auto-justify path, not by lowering the
   floor.

## Floor table schema

```
| Dim # | Dim name | Mature floor | Growth floor | Early floor | Notes |
|---|---|---|---|---|---|
| 1 | {name} | N | N | N | optional clarification |
```

Cell conventions:
- `N` (a number) — minimum findings required at that stage
- `—` — dim is **permanently skipped** at this skill's calibration
  (e.g., v-audit-code Dim 9 "Print/PDF" per operator preference)
- `n/a` — dim is **stage-skipped** (i.e., the dim's relevant
  surface doesn't exist at this stage; falls back to qualitative
  Gate 2 enforcement)

Heavy-priority dims should have higher floors than default-priority
dims at the same stage.

---

## v-audit-code floors (historical calibration, not enforced)

**This table is not live Gate 2 enforcement.** It is `v-ui-audit`'s
last-calibrated per-dim floor table, renamed in place when `v-ui-audit`
retired into `/v-audit-code` (2026-07-06) so the numbers weren't lost.
`/v-audit-code` itself runs no per-dim numbered checklist, no Gate 2
re-task loop, and no dedicated per-dim subagent topology — its deep
UX/a11y mode is the prose lenses in `audit-lenses.md` plus the
deepenings in `references/deep-ux-audit.md`, scored against whatever
framework the operator defines per `rating-framework.md`. Read the
numbers below as "what past `v-ui-audit` runs typically surfaced per
theme," useful for sanity-checking whether a `v-audit-code` deep-UX
pass came back thin — not as a floor the skill mechanically checks
against or re-tasks on. See
`skills/v-audit-code/references/deep-ux-audit.md` for the current
skill body and its own (prose) "Compliance floors" statement.

| Dim # | Dim name | Mature | Growth | Early | Priority |
|---|---|---|---|---|---|
| 1 | Visual hierarchy & layout | 15 | 10 | 6 | HEAVY |
| 2 | Brand voice & in-product microcopy | 15 | 10 | 6 | HEAVY |
| 3 | Activation funnel | 10 | 6 | 3 | default |
| 4 | Empty states & first-run | 6 | 4 | 2 | default |
| 5 | Accessibility (WCAG 2.2 AA) | 6 | 4 | 2 | COMPLIANCE (non-demotable) |
| 6 | Mobile responsiveness | 4 | 3 | 2 | default |
| 7 | Dark mode | 3 | 2 | 1 | default |
| 8 | Performance & web vitals | 5 | 4 | 2 | default |
| 9 | Print / PDF | — | — | — | SKIPPED per operator |
| 10 | SEO (meta, OG, JSON-LD, hreflang) | 12 | 8 | 4 | HEAVY |
| 11 | Visual system | 12 | 8 | 5 | HEAVY |
| 12 | Brand identity | 8 | 5 | 3 | HEAVY |
| 13 | Documentation / help / trust | 4 | 3 | 2 | default |
| 14 | i18n readiness | — | — | — | SKIPPED per operator |
| 15 | Security & data handling | 3 | 2 | 1 | COMPLIANCE (non-demotable) |

**COMPLIANCE priority (Dims 5, 15) — historical framing, carried
forward as a live PROSE rule, not this numeric table.** The retired
`v-ui-audit` ran Dim 5 (a11y, WCAG 2.2 AA) and Dim 15 (security) as
non-demotable compliance floors via dedicated per-dim subagents (F =
accessibility, G = security) and a numbered Gate 2/7 re-task-then-
demote sequence. `/v-audit-code` does not reimplement that
subagent topology or those numbered gates. What carries forward is
the *principle*, restated as prose in
`skills/v-audit-code/references/deep-ux-audit.md` § "Compliance
floors (non-demotable in deep-UX mode)": WCAG 2.2 AA accessibility and
Security-UI findings are reported at full severity and never
auto-demoted for being adjacent to craft findings. The only demotion
path is the same as before in spirit — an explicit, logged
operator internal-only-tool declaration — but there is no "forms-
baseline 2/2/2" numeric fallback or 6-subagent topology to revert to;
`/v-audit-code` simply runs the applicable lens (`audit-lenses.md`'s
"Security & trust boundaries", and `deep-ux-audit.md` § 1 for a11y) at
whatever depth the operator's depth tier (Quick/Standard/Thorough)
calls for.

---

## v-audit-admin floors

Maps to the 6 audit domains in v-audit-admin/SKILL.md.

| Dim # | Domain | Mature | Growth | Early | Priority | Notes |
|---|---|---|---|---|---|---|
| 1 | Functional Completeness (ADM-PM) | 8 | 5 | 3 | HEAVY | Missing CRUD, bulk ops, export, admin-specific pages, relationship management |
| 2 | Visual Craft & Consistency (ADM-DES) | 6 | 4 | — | default | Thorough mode only; structural uniformity, spacing, dark mode tokens |
| 3 | Usability & Interaction (ADM-UX) | 6 | 4 | — | default | Thorough mode only; loading/error states, confirmations, keyboard, mobile |
| 4 | Edge Cases & Robustness (ADM-QA) | 5 | 3 | — | default | Thorough mode only; empty states, long-text overflow, form validation, file upload |
| 5 | Audit Trail & Security (ADM-OPS) | 6 | 4 | 2 | HEAVY | Action audit logging, RBAC granularity, rate limiting, queue health, tenant isolation |
| 6 | AI-Built Blind Spots (ADM-AI) | 5 | 3 | 2 | HEAVY | Structural uniformity (>70% identical), happy-path only, binary permissions, no operational tooling, missing pages |

**Quick mode runs only Domains 1, 5, 6** — floor for Quick mode
= ⌈sum of those rows × 0.7⌉ (round up). Concretely:
- Mature: ⌈(8+6+5)×0.7⌉ = ⌈13.3⌉ = **14 findings**
- Growth: ⌈(5+4+3)×0.7⌉ = ⌈8.4⌉ = **9 findings**
- Early: ⌈(3+2+2)×0.7⌉ = ⌈4.9⌉ = **5 findings**

**Why Domains 2/3/4 are `—` at Early stage:** these dims
(visual craft, usability, edge cases) are Thorough-mode-only and
their value compounds with shipped surface area. A mature admin
panel has many pages where structural inconsistency, broken
interactions, or unhandled empty states become real costs; an
early prototype has 3 pages and the findings would all be "build
this out" — not actionable as craft findings. The `—` marker
tells Gate 2 to skip floor enforcement for those dims at Early
stage, falling back to the qualitative "is the dim relevant?"
check.

**Quick-vs-Thorough mode floor relationship:** Quick mode's
aggregate floor (14/9/5) is computed from Domains 1+5+6 only.
Thorough mode applies per-dim floors across all 6 domains. The
per-dim approach is stricter (more dims = more chances to
under-cover), which is correct: Thorough mode promises depth.

**Calibration note:** v-audit-admin's value is heavily
concentrated in Domain 6 (AI-Built Blind Spots) for the
operator's solo-AI workflow. If Domain 6 returns below floor on
a mature project, that's a stronger signal than Domain 2/3
underperformance — the AI-built-blind-spots pattern surfaces
exactly the failures most likely to ship to production. Re-task
Domain 6 below-floor returns before any other dim.

---

## v-audit-seo floors

Maps to the 9 SEO audit dimensions in v-audit-seo/SKILL.md (§ The 9 SEO Audit Dimensions).

| Dim # | Dimension | Mature | Growth | Early | Priority | Notes |
|---|---|---|---|---|---|---|
| 1 | Technical SEO | 6 | 4 | 2 | HEAVY | Crawlability, indexability, CWV static correlates only (runtime CWV metrics are out of scope for a static audit — never fabricate numbers), redirects, orphan pages. At least half of floor-count findings must come from crawlability/indexability/rendering/orphan-pages/mobile — Discover-eligibility (added 2026-08-11) and non-Google-indexing checks are additive, not substitutive |
| 2 | On-Page SEO | 6 | 4 | 2 | HEAVY | Title tags, meta descriptions, heading hierarchy, alt text, internal linking, URL structure |
| 3 | Content Quality & Gaps | 5 | 3 | 2 | HEAVY | Content inventory, gap detection, cannibalization, orphan content, freshness, thin content |
| 4 | Keyword Research & Intent | 4 | 3 | 2 | default | Seed keywords, SERP analysis, intent classification, volume, difficulty |
| 5 | SERP Analysis | 3 | 2 | 1 | default | Competitor ranking patterns, featured snippets, content-type distribution |
| 6 | Content Strategy | 4 | 3 | 2 | default | Topic clustering, publishing calendar, programmatic SEO |
| 7 | Structured Data & AI Readiness | 5 | 3 | 2 | HEAVY | Schema detection + validation, GEO, AI crawler accessibility, citability |
| 8 | Off-Site Growth & Link Earning | 3 | 2 | 1 | default | Backlink profile, competitor link gaps, citable asset strategy |
| 9 | Alternative-Page Opportunities | 3 | 2 | 1 | default | Missing comparison/alternatives pages vs competitors, hand-off to /v-content-create --type=comparison. Early-access-tier floor halving applies to dims 3, 4, 6, 9 (SKILL.md § Entry Point); true greenfield instead skips/reframes those dims, it does not just halve their floors |

**Heavy-priority dims** (1, 2, 3, 7) drive the audit's value for
the operator's organic-acquisition focus. A mature-stage v-audit-seo
run that doesn't hit heavy-dim floors should re-task before
synthesizing the prompt pack.

**Calibration note:** floors are calibrated for English-only B2B
SaaS sites with ~50-200 indexable pages. Sites with 1000+ pages
(programmatic SEO, ecosystem landings) should expect 1.5× the
floors as a minimum.

**Tier-2 (default-priority) dims — calibration confidence:**
Dims 4 (Keywords), 5 (SERP), 6 (Strategy), 8 (Off-Site) were
spot-checked during the floor-calibration pass. Their floors
(4/3/2 for Keywords + Strategy; 3/2/1 for SERP + Off-Site) reflect
the natural finding density of those dims — Keywords and Strategy
cover broader surface area and produce more findings than SERP
analysis or Off-Site link-gap analysis. Re-calibrate per the rule
at the top of this file (≥3 audits showing consistent over- or
under-shoot before changing).

**Dim 3 Early floor raised from 1 → 2.** Within v-audit-seo
specifically, Dim 3 (Content Quality & Gaps, HEAVY) and Dim 4
(Keyword Research, default) have comparable surface area on
mature B2B SaaS sites. Dim 3 producing only 1 finding at Early
stage while Dim 4 produces 2 was an internal inconsistency. Note
that priority class encodes **importance**, not **finding
volume** — high-importance dims with small surface area
(e.g., v-audit-code Dim 12 Brand identity HEAVY at mature 8) can
legitimately produce fewer findings than high-volume default
dims (e.g., v-audit-code Dim 3 Activation funnel default at
mature 10). Calibrators should set floors by expected finding
density, not by priority alone.

---

## Provisional floors (other audit skills)

The audit skills below haven't yet been calibrated from past
audits, so floors are **provisional** rather than per-dim. Gate 2
applies these as a fallback so it has teeth even before
calibration: if any dim returns below the provisional floor, the
mandatory-re-task path fires.

The provisional floors are deliberately conservative (low) — they
catch obvious under-coverage without over-flagging legitimately
strong dims. Once a skill is calibrated, promote the provisional
table to a first-iteration `## v-audit-X floors (first iteration)`
section sibling of `## v-audit-code floors` (see v-audit-messaging
and v-audit-sales-pricing for the pattern). v-audit-analytics and
v-audit-growth are scheduled for first-iteration calibration in a
subsequent round.

### Provisional default

| Priority | Mature | Growth | Early |
|---|---|---|---|
| HEAVY | 5 | 3 | 2 |
| default | 3 | 2 | 1 |
| LIGHT | 2 | 1 | 1 |

### v-audit-analytics (provisional)

| Dim # | Dimension | Priority | Provisional floor |
|---|---|---|---|
| 1 | Event Taxonomy & Naming | HEAVY | mature 5 / growth 3 / early 2 |
| 2 | Schema Integrity & Properties | HEAVY | mature 5 / growth 3 / early 2 |
| 3 | Funnel Definition Correctness | HEAVY | mature 5 / growth 3 / early 2 |
| 4 | KPI Formula Validation | default | mature 3 / growth 2 / early 1 |
| 5 | Dashboard Assertions | default | mature 3 / growth 2 / early 1 |
| 6 | Instrumentation Coverage | HEAVY | mature 5 / growth 3 / early 2 |

### v-audit-growth (provisional)

| Dim # | Dimension | Priority | Provisional floor |
|---|---|---|---|
| 1 | Activation | HEAVY | mature 5 / growth 3 / early 2 |
| 2 | Retention | HEAVY | mature 5 / growth 3 / early 2 |
| 3 | Feedback Loops | default | mature 3 / growth 2 / early 1 |
| 4 | CRO | HEAVY | mature 5 / growth 3 / early 2 |
| 5 | Cancellation & Win-Back | default | mature 3 / growth 2 / early 1 |

---

## v-check floors (provisional)

Maps to the 12 v-check audit domains in v-check/SKILL.md.
Calibrated as **provisional** — promote to first-iteration after
≥3 mature-stage audits per the recalibration rule at the top of
this file.

| Dim # | Domain | Mature | Growth | Early | Priority | Notes |
|---|---|---|---|---|---|---|
| 1 | Security | 5 | 3 | 2 | HEAVY | Always P0; auth gaps, injection, XSS, CSRF, secrets, CORS, CSP |
| 2 | Performance | 5 | 3 | 2 | HEAVY | N+1 queries, lazy loading violations, unbounded queries, bundle size |
| 3 | Test Coverage | 5 | 3 | 2 | HEAVY | Pass rate, coverage %, missing test files, critical paths |
| 4 | UX & Copy | 3 | 2 | 1 | default | Empty states, loading states, error messages, dark mode |
| 5 | Tech Debt | 5 | 3 | 2 | HEAVY | TODOs, dead code, TypeScript `any`, config drift. AI-built code surfaces tech debt at higher density than human code; calibrated up from default per the operator's solo-AI workflow (precedent: v-audit-admin Domain 6 AI-Built Blind Spots). |
| 6 | Accessibility | 3 | 2 | 1 | default | WCAG 2.2 AA: aria-labels, keyboard nav, contrast, focus |
| 7 | SEO (triage) | 1 | 1 | 1 | LIGHT | Triage-only — surface checks only; floor of 1 reflects the contract that v-check produces a single triage pointer (or zero) for SEO findings. Full SEO depth owned by `/v-audit-seo`. |
| 8 | AI/LLM Integration | 5 | 3 | 2 | HEAVY | API key safety, cost tracking, rate limiting, PII |
| 9 | Feature Completeness | 2 | 1 | 1 | LIGHT | Full-mode only; backend / frontend pattern coverage |
| 10 | Parallel Deep Analysis | n/a | n/a | n/a | — | Process domain (agent dispatch); not a finding-producing dim |
| 11 | Observability & Monitoring | 3 | 2 | 1 | default | Structured logging, error tracking, performance monitoring, alerting |
| 12 | Config Validation (.env*) | 5 | 3 | 2 | HEAVY | `.env*` mismatches with `.env.example`, missing required env vars, wrong values |

**Heavy-priority dims** (1, 2, 3, 5, 8, 12) carry P0 / P1 risk and drive
v-check's pre-launch and pre-merge value. Domain 5 (Tech Debt) is
HEAVY rather than default for the operator's solo-AI workflow —
AI-built code accumulates tech debt at higher density than
human-written code (precedent: v-audit-admin Domain 6). A mature-stage v-check run
that doesn't clear heavy-dim floors should re-task before
synthesizing the report.

**Scoped mode skips:** SEO (7), Feature Completeness (9), and
Parallel Deep Analysis (10) — Gate 2 enforcement automatically
applies the `n/a` semantics for skipped dims in scoped runs.

**Calibration note:** these floors assume Laravel + React + TS + Tailwind 4
SaaS at the operator's typical project stage (~50-200 source files,
single-developer, Cashier-based billing). Larger projects (1000+
files, multi-team) should expect 1.5× the floors as a minimum.
Re-calibrate per the rule at the top of this file (≥3 audits showing
consistent over- or under-shoot before changing).

---

## v-bug-hunt floors (provisional)

Maps to the 8 v-bug-hunt dimensions in v-bug-hunt/SKILL.md.
Calibrated as **provisional** — promote to first-iteration after
≥3 mature-stage audits per the recalibration rule at the top of
this file.

Floors here are **per-target-subsystem**, not per-codebase. A bug-hunt
run targets a single subsystem (auth, onboarding, async pipeline, etc.).
Floor expectations are calibrated to "what a hostile QA pass on this
subsystem should reveal." Zero-findings outcomes are valid (per the
anti-reward-hacking clause in the skill) but require per-dim
justification at Gate 2.

| Dim # | Dimension | Mature | Growth | Early | Priority | Notes |
|---|---|---|---|---|---|---|
| 1 | Critical Flows | 2 | 1 | 1 | HEAVY | Flow-trace per target; any AI-built target should surface at least 1 hostile-path issue at mature stage |
| 2 | Forms & Validation | 2 | 1 | 1 | HEAVY | Frontend/backend validation drift is endemic in AI-generated code; floors reflect that |
| 3 | API / Inertia Contract | 2 | 1 | 1 | HEAVY | Inertia prop-drift and null/undefined access are the single most common AI-generated defect family |
| 4 | Auth, Session & RBAC | 1 | 1 | 1 | HEAVY | Thorough-only; not all targets have auth surface. Floor of 1 reflects mandatory check for at least one auth-adjacent finding when target touches auth |
| 5 | Async & State | 2 | 1 | 1 | HEAVY | Race conditions + retry idempotency; floors apply when target dispatches jobs or has optimistic UI |
| 6 | Error Surfaces | 3 | 2 | 1 | HEAVY | Swallowed exceptions and generic toasts are the highest-density finding type for AI-generated full-stack apps; floor calibrated up |
| 7 | Data Integrity | 1 | 1 | 1 | default | Floor of 1; many targets are read-only or have no multi-table writes. n/a when target has no DB writes |
| 8 | Production Surface | 2 | 1 | 1 | HEAVY | env() leaks, debug code, hardcoded secrets — common AI defects, calibrated up |

**Heavy-priority dims** (1, 2, 3, 4, 5, 6, 8) carry P0 / P1 risk.
Dim 7 (Data Integrity) is default-priority because data-integrity
defects are catastrophic but the floor is necessarily lower —
many subsystems don't write to multiple tables.

**Stage-skipped dims:** If the target subsystem genuinely lacks
the dim's surface (no auth in target → Dim 4 = `n/a`; no DB writes
in target → Dim 7 = `n/a`), Gate 2 falls back to qualitative
enforcement. Skill MUST mark the dim as stage-skipped in the
audit metadata with a one-sentence justification, not silently
pass.

**Calibration note:** floors assume the operator's standard stack
(Laravel 13 + React + Inertia + Tailwind v4) and that the target
subsystem is non-trivial (4+ files, at least one user-facing flow).
For tiny subsystems (1-2 files, no UI), expect zero-findings outcomes
to dominate — the anti-reward-hacking clause is load-bearing here.

---

## v-bug-hunt `boundaries` lens floors (provisional)

Maps to the 9 EHUNT-* dimensions in
`v-bug-hunt/references/boundaries-lens.md` (the former v-edge-hunt
skill, merged into v-bug-hunt as a `boundaries` lens 2026-07-05 —
this table previously covered only 8 dimensions and was missing
EHUNT-ENTITLEMENT, added to the source skill before the merge; that
gap is corrected here). Calibrated as **provisional** — promote to
first-iteration after ≥3 mature-stage audits per the recalibration
rule at the top of this file.

Floors here are **per-target-subsystem**, not per-codebase. A
boundaries-lens run targets a single subsystem and probes boundary
values the happy path already passed. Floors are deliberately
conservative: many boundary dimensions are n/a for a given target (no
billing surface → EHUNT-MONEY n/a; no state machine → EHUNT-STATE
n/a). Zero-findings outcomes are valid (per the anti-reward-hacking
clause in the reference file) but require per-dim justification at
Gate 2.

| Dim | Dimension | Mature | Growth | Early | Notes |
|---|---|---|---|---|---|
| 1 | EHUNT-EMPTY (empty/null/zero) | 2 | 1 | 1 | Empty-state and null-deref bugs are endemic in AI-generated code; floor calibrated up |
| 2 | EHUNT-LIMIT (max/overflow) | 1 | 1 | 1 | Applies when target has length/size/count limits |
| 3 | EHUNT-TIME (date/DST/leap/tz) | 1 | 1 | 1 | n/a when target has no date/time logic |
| 4 | EHUNT-MONEY (currency/Cashier proration) | 1 | 1 | 1 | n/a when target has no billing surface; high-risk when present |
| 5 | EHUNT-UNICODE (unicode/emoji/RTL/multibyte) | 1 | 1 | 1 | n/a when target has no free-text user input |
| 6 | EHUNT-QUANTITY (pagination/sorting/pluralization) | 1 | 1 | 1 | n/a when target has no lists/pagination |
| 7 | EHUNT-STATE (state machine/invalid transitions) | 1 | 1 | 1 | n/a when target has no status/state field |
| 8 | EHUNT-CONCURRENT (race/idempotency) | 1 | 1 | 1 | n/a when target has no concurrent writes/jobs/webhooks |
| 9 | EHUNT-ENTITLEMENT (plan-limit/seat-cap/quota/feature-gate) | 1 | 1 | 1 | n/a when target has no metered/entitlement surface; core business-model surface when present |

**Stage-skipped dims:** boundary dimensions are frequently n/a for a
given target subsystem. When the target genuinely lacks a dim's
surface, Gate 2 falls back to qualitative enforcement: the skill
MUST mark the dim as stage-skipped in the audit metadata with a
one-sentence justification, not silently pass.

**Calibration note:** floors assume the operator's standard stack
(Laravel 13 + React + Inertia + Tailwind v4) and a non-trivial target
subsystem. Numeric floors above are intentionally low — boundary-case
findings are target-dependent, and the anti-reward-hacking clause is
load-bearing here. Promote to a first-iteration table once ≥3 mature
boundaries-lens audits provide calibration data.

---

## v-audit-messaging floors (first iteration)

Maps to the 7 messaging audit dimensions in
v-audit-messaging/SKILL.md. Calibrated as first-iteration —
refine after ≥3 mature-stage audits per the recalibration rule
at the top of this file.

| Dim # | Dimension | Mature | Growth | Early | Priority | Notes |
|---|---|---|---|---|---|---|
| 1 | Homepage & Value Proposition | 5 | 3 | 2 | HEAVY | 5-second test, specificity, proof above fold, primary + secondary CTAs, objection handling |
| 2 | Pricing Page Messaging | 5 | 3 | 2 | HEAVY | Tier-name clarity, value-metric explanation, plan differentiation, contextual social proof, who-picks-which guidance |
| 3 | Feature & Product Pages | 3 | 2 | 1 | default | Benefits framing, persona targeting, screenshot freshness, comparison-page honesty |
| 4 | Onboarding & In-App Copy | 5 | 3 | 2 | HEAVY | Welcome reinforces value-prop, empty-state guidance, upgrade-prompt value framing, error-message actionability |
| 5 | Email & Notification Copy | 5 | 3 | 2 | HEAVY | Welcome email value-prop, lifecycle sequence existence, subject-line specificity, transactional brand quality |
| 6 | Differentiation & Competitive Positioning | 5 | 3 | 2 | HEAVY | Defensible unique angle, competitor-claim accuracy (WebSearch verified), positioning-statement so-what test |
| 7 | Cross-Surface Consistency | 3 | 2 | 1 | default | Same product story everywhere; synthesis dim — see degraded-mode note below |

**Heavy-priority dims** (1, 2, 4, 5, 6) drive the audit's value
for the operator's solo-SaaS positioning focus. Dimension 7
(Cross-Surface Consistency) cannot be reliably calibrated — it's
a synthesis dim whose finding count is bounded by upstream
dimensions; it operates in degraded mode when ≤3 of dims 1-6 ran.

**Calibration note:** floors are conservative first-iteration
estimates. The single most common Gate 2 trigger here will be
Dim 5 (Email) under-coverage on early-stage products that haven't
built lifecycle sequences yet — this is the correct behavior.
The fix is to BUILD the lifecycle sequence, not lower the floor.

---

## v-audit-sales-pricing floors (first iteration)

Maps to the 10 sales-pricing audit dimensions in
v-audit-sales-pricing/SKILL.md across three tracks: Sales Pipeline
(Dims 1–5), Pricing & RevOps (Dims 6–9), Pricing Strategy (Dim 10).
Calibrated as first-iteration.

**Heavy-priority dims** (1, 6, 7, 8, 10) drive the audit's value.
Dim 10 is the only strategic-judgment-heavy dim but still uses
`--model sonnet` like Dims 1–9 (sonnet-max policy — the former opus
tier was retired 2026-07-07; opus is rejected at the dispatch gate); a
mature-stage audit that doesn't clear Dim 10's floor should
re-task with the strategic-fitness checklist before synthesizing
the prompt pack.

| Dim # | Dimension | Track | Mature | Growth | Early | Priority | Notes |
|---|---|---|---|---|---|---|---|
| 1 | ICP & Segmentation | T1 Pipeline | 5 | 3 | 2 | HEAVY | Documented persona, anti-personas, segmentation in user model + analytics |
| 2 | Lead Scoring & Qualification | T1 Pipeline | 3 | 2 | 1 | default | Scoring model existence, MQL/SQL definitions, behavioral + firmographic signals |
| 3 | Outreach Sequences | T1 Pipeline | 3 | 2 | 1 | default | MOTION-GATED (note below table). Cold/warm/inbound coverage, follow-up cadence, trial-ending urgency, multi-channel diversity |
| 4 | CRM State Machine | T1 Pipeline | 3 | 2 | 1 | default | Lifecycle stages defined, transition rules explicit, stage-history tracked, hygiene flags |
| 5 | Sales Enablement Content | T1 Pipeline | 3 | 2 | 1 | default | MOTION-GATED (note below table). Battle cards, objection handling, demo script, case studies, ROI calculator, comparison pages |
| 6 | Pricing Model & Packaging | T2 RevOps | 5 | 3 | 2 | HEAVY | Value-metric alignment, tier differentiation, code-level entitlements, annual vs monthly, enterprise tier |
| 7 | Checkout & Conversion Path | T2 RevOps | 5 | 3 | 2 | HEAVY | Click count to payment, trust signals, trial→paid smoothness, social proof on pricing page, error recovery |
| 8 | Dunning & Payment Recovery | T2 RevOps | 5 | 3 | 2 | HEAVY | Failed-payment detection, retry schedule, in-app banner, grace period, escalating dunning sequence |
| 9 | Competitive Pricing Intelligence | T2 RevOps | 3 | 2 | 1 | default | Top 3 competitor pricing documented, value anchoring, comparison page, defensibility |
| 10 | Pricing Strategy & Model Fitness | T3 Strategy | 5 | 3 | 2 | HEAVY | Value metric fitness, model-type fit matrix, pricing psychology (≥3 of 6 tactics), expansion architecture, experimentation readiness |


**Motion-gated floors (Dims 3 and 5):** per
`~/.claude/skills/references/v-core-solo-motion.md` the default motion is
zero-outreach (`OUTBOUND_OK=0`). In that mode these dims audit ONLY their
passive/self-serve scope (Dim 3: lifecycle, trial-ending, and
behavior-triggered sequences to existing signups; Dim 5: comparison pages,
case studies, ROI calculators — NOT battle cards, demo scripts, pitch
decks, or objection docs), and `"status": "correctly absent —
zero-outreach motion"` entries COUNT toward the floor as coverage. A floor
miss on the gated scope must NEVER be resolved by re-tasking the subagent
toward outbound findings — that re-task prompt inherits the motion gate,
and manufacturing an outbound finding to clear a floor is the P0 described
in v-core-solo-motion.md § Note for reviewers. The floor NUMBER (3/2/1) is
the same in both modes — what changes is how it is satisfied: at
`OUTBOUND_OK=0`, passive-scope findings + correctly-absent statuses satisfy
it; at `OUTBOUND_OK=1`, the full outbound checklist applies and
correctly-absent no longer substitutes for outbound coverage.

**Calibration note:** these floors assume a SaaS with at least
the basic shape of a sales motion (some pricing page, some
onboarding flow). Pre-launch products with no pricing page yet
should hit Gate 2 auto-justify on Dims 6–9 (the surfaces don't
exist yet) — this is correct behavior; the audit produces a
"build these surfaces first" recommendation rather than fabricating
findings on missing artifacts.

---

## How to add floors for a new skill

1. Run the skill on 3+ representative projects (mature stage
   preferred).
2. Record the actual finding counts per dim per project.
3. The floor for each dim = the **30th percentile** of the
   recorded counts (i.e., 70% of audits should clear floor; 30%
   may legitimately produce fewer findings, justifiable via Gate
   2's auto-justify path).
4. Add the table to this file.
5. Update the skill's body to reference this file:
   *"This skill's floors are defined in
   `~/.claude/skills/references/v-audit-floors.md`."*

When the skill's dim definitions change (new dim added, dim
renamed, dim merged), update the floor table immediately to
prevent silent drift.

## Cross-reference with v-audit-gates.md

The calibration table in `v-audit-gates.md` is the runtime
lookup index used by Gate 2 enforcement for the 6 skills that
actually run Gate 2. It lists each audit skill, its HEAVY dims,
its representative default-priority floor, its LIGHT/skip dims,
and the **exact `## Section header`** to match in this file. As
of this calibration round:

- v-audit-admin, v-audit-seo: calibrated (live Gate 2 enforcement)
- v-audit-messaging, v-audit-sales-pricing: first-iteration (live Gate 2 enforcement)
- v-audit-analytics, v-audit-growth: provisional (live Gate 2 enforcement)
- v-audit-code: **not Gate-2-enforced** — its `## v-audit-code floors`
  table above is historical `v-ui-audit` calibration data, listed in
  `v-audit-gates.md`'s table for cross-reference only, not as a skill
  that runs the re-task loop.

When this file changes, mirror the change in v-audit-gates.md:

- "Heavy dims" column → enumerate this file's rows where
  Priority = HEAVY
- "Default floor (mature)" column → the Mature-stage floor from
  this file's default-priority rows (representative number; not
  a sum)
- "Light/skip dims" column → enumerate this file's rows where
  Priority = LIGHT or `—` permanent skip
- "Floor table" column → exact `## Section header` to match
  here, e.g., `## v-audit-messaging floors (first iteration)`

The "Floor table" column is what makes Gate 2's lookup
deterministic — Gate 2 scans v-audit-floors.md for the literal
header string. **Match the header byte-for-byte, including any
parenthetical suffix.** Sections currently use suffixes like
`(first iteration)` and `(provisional)` that are part of the
literal header — Gate 2 will not strip them. If you rename a
section here (including adding/removing a suffix), update
v-audit-gates.md in the same commit or Gate 2 silently falls
over to qualitative mode for that skill.
