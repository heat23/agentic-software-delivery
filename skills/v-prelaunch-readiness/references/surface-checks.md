# v-prelaunch-readiness surface checks

_Last reviewed: 2026-07-06 (theme-consistency sweep B: security/performance/UI-states alignment; prev sweep A: SEO/AEO + growth-motion + copy/voice)._

> **Persona for this reference:** senior product launch engineer
> with experience auditing solo-SaaS pre-launch surfaces (hero,
> signup, pricing, demo, docs, OG/social, dark mode, mobile)
> against the "first-100-customers ready" bar. Loaded on-demand
> by v-prelaunch-readiness Step 1.

Tier vocabulary in these checks (MUST-FIX / SHOULD-FIX / NICE-TO-HAVE) maps to canonical
P0 / P1 / P3 per `~/.claude/skills/references/v-core-severity.md` (mapping stated in
SKILL.md § Step 2: Consolidate findings).

The 8 surface checks below are dispatched as parallel **fork-safe
`claude -p` subprocesses** (model: sonnet) via
`~/.claude/skills/v/references/v-dispatch-subagent.sh --model sonnet
--mode capture` — **NOT the Agent tool**, which fails silently from
this skill's `context: fork` (see SKILL.md § Step 1). Each subprocess
receives project context + the surface scope and returns a JSON
payload with findings and verdict.

The skill's body owns the workflow (orchestration, consolidation,
launch-window stringency); this reference owns the per-surface
prompts.

**Boundary with `/v-anti-template-gauntlet`:** these surface
checks focus on **content presence and correctness** (is the hero
specific? is the signup form ≤6 fields? does the demo link
resolve?). They do NOT check **output quality / template tells**
(default Tailwind palette, generic gradients, AI-tell copy). Run
the gauntlet alongside this skill for output-quality coverage.

---

## Surface 1: Hero & 5-Second Test

```
Subject: Pre-launch hero readiness check

Read: homepage / landing page source file (Welcome.tsx, Home.tsx, page.tsx — auto-detect)

Assess:
- 5-second test: can a visitor identify WHO it's for, WHAT it does, WHY it's better in <5 seconds?
- Specificity: is the value prop concrete ("Cut invoice processing from 4hrs to 10min") or generic ("Save time")?
- Primary CTA visible above fold WITHOUT scrolling on 1366×768 desktop and 375×812 mobile
- Proof element above fold (customer count / logo bar / specific testimonial) — note: pre-launch products may legitimately lack this; downgrade severity but flag as opportunity
- Secondary CTA (Watch demo / See how it works / Read case study) for visitors not ready to commit
- Hero text uses specific numbers / outcomes, not abstract benefits
- No "Welcome to {ProductName}" — that's not a value prop

**Note:** AI/template tells in hero copy (banned-word density, hedging openers, generic gradients, default Tailwind palette, etc.) are NOT checked here. Run `/v-anti-template-gauntlet` for those; this surface check focuses on missing/incorrect content, not output quality.

Output JSON:
{
  "surface": "hero",
  "findings": [
    {"id": "HERO-001", "severity": "must|should|nice", "title": "...", "evidence": "file:line", "fix": "1-sentence fix"}
  ],
  "five_second_pass": true|false,
  "five_second_summary": "what a stranger would think the product does after 5 seconds, verbatim"
}
```

## Surface 2: Signup Flow

```
Subject: Pre-launch signup flow readiness check

Read: signup form source + signup controller + post-signup redirect destination

Assess:
- Signup form has ≤6 fields (target: 4 — name, email, password, optional company)
- Email validation is server-side AND inline client-side (not just submit-then-error)
- Password requirements are visible BEFORE submit attempt (not error-then-correct)
- Post-signup redirect is to a value moment (dashboard with first action prompt, NOT empty state with no guidance)
- Email verification flow exists OR is intentionally deferred to first-action gate
- Welcome email triggers within 2 minutes of signup
- Signup error states show specific messages (not "Something went wrong")
- Form submits without JS (progressive enhancement) OR fails gracefully with explicit "JS required" notice

Output JSON: { "surface": "signup", "findings": [...], "fields_count": N, "post_signup_destination": "..." }
```

## Surface 3: Pricing Page

```
Subject: Pre-launch pricing page readiness check

Read: pricing page source + plan / subscription model + checkout entry point

Assess:
- Each tier name communicates target user ("For Solo Founders", not "Starter")
- Value metric explained inline (not just "$X/month" — "what does $X buy me?")
- Plan differences obvious in <10 seconds (comparison table OR clearly differentiated cards)
- "Most popular" / "Recommended" badge with rationale
- Annual discount visible (15-25% is the convention) if annual billing supported — avoid exactly 20% or 17% (textbook AI defaults; Anti-pattern A2 in v-audit-sales-pricing): pick an LTV-calibrated value (A2's examples — 12% / 22% / 30% — may sit outside the convention; it's a norm, not a bound)
- Decision helper present ("Not sure which plan? Most teams of 5-20 pick Pro")
- FAQ section addresses top 3 pricing objections (cancellation, switching tiers, refunds)
- Enterprise / Contact Sales CTA ONLY when the project's CLAUDE.md declares a sales-led motion (`OUTBOUND_OK=1` per `v-core-solo-motion.md`); default self-serve motion: absence is correct — do not flag (a self-serve top tier is the right shape)
- Currency symbol matches target market (or auto-detection mentioned)
- Free tier / trial path is clear and frictionless to start

Output JSON: { "surface": "pricing", "findings": [...], "tier_count": N, "value_metric_legible": true|false }
```

## Surface 4: Demo / How It Works

```
Subject: Pre-launch demo readiness check

Read: any /demo, /how-it-works, /features pages + interactive elements + screenshots referenced

Assess:
- Demo link in hero or nav resolves (no 404)
- Demo content shows the actual product flow (not generic stock screenshots)
- If interactive: works without signup gate (or has clear signup-to-continue trigger)
- If video: <90 seconds, captioned, autoplay disabled, mobile-friendly
- Screenshots are CURRENT (not from 6 months ago — check git log on referenced image paths)
- "Try it" path from demo → signup is one click
- Mobile demo experience tested (often broken on solo-SaaS)

Output JSON: { "surface": "demo", "findings": [...], "demo_works_mobile": true|false }
```

## Surface 5: Docs Site

```
Subject: Pre-launch docs readiness check

Read: /docs path or referenced documentation site/repo

Assess:
- Docs site exists and is reachable (no 404 or "coming soon" placeholder)
- Quickstart / getting-started page is the first link in nav (not buried)
- Quickstart works end-to-end (no broken example, no missing dependency)
- API reference exists if product has API surface (auto-detect from /api routes)
- Search works (or there's a clear table of contents for sub-100-page docs)
- Examples include outputs / screenshots, not just commands
- Last-updated date visible per page (freshness signal)
- 404 page on docs has helpful "Try X / contact Y" content
- Support channel decision is documented (email vs widget vs ticketing) — see `~/.claude/skills/references/v-launch-help-docs-channel.md` for the decision frame; if no decision, flag SHOULD-FIX

Output JSON: { "surface": "docs", "findings": [...], "quickstart_resolves": true|false, "support_channel_documented": true|false }
```

## Surface 6: OG / Social Meta Tags

```
Subject: Pre-launch social meta readiness check

Read: head / metadata config in detected framework (Next.js metadata, Inertia head, Helmet, etc.)

Assess:
- og:title set per page (not site-wide static)
- og:description set per page (concise + page-specific; mirror the meta-description band, 120-160 chars per `v-audit-seo/references/dim-checklists.md` § Audit 2 — no separate OG length rule exists)
- og:image set with 1200×630 PNG (not SVG — most social platforms reject SVG)
- og:url canonical
- twitter:card with summary_large_image
- favicon set with .ico AND .png variants (Safari + Chrome + Firefox compat)
- apple-touch-icon present (iOS home-screen save)
- theme-color meta for mobile browser chrome
- Privacy-friendly analytics installed with Core Web Vitals capture, OR an explicit decision documented to use a consent-based stack — see `~/.claude/skills/references/v-launch-privacy-friendly-analytics.md` for the decision frame and pre-launch baseline-capture steps; if neither, flag MUST-FIX (no measurement substrate = no post-launch regression detection). The MUST-FIX's fix is always the IN-REPO twin: add first-party web-vitals capture code and/or commit the documented decision file — never "sign up for vendor X" (off-stack per `_v-audit.md` § In-App Actionability Boundary; a vendor-action finding would be dropped at consolidation and re-flag forever). Vendor selection lives in the decision reference only.

When og:image is missing or generic — solo SaaS that gets shared on LinkedIn / X / Slack with a generic preview signals "amateur." This is a top-3 trust signal.

Output JSON: { "surface": "og", "findings": [...], "og_image_per_page": true|false, "analytics_with_cwv_present": true|false }
```

## Surface 7: Dark Mode Parity

```
Subject: Pre-launch dark mode readiness check

Read: the `:root` / `html[data-theme="light"]` token blocks (or Tailwind v4 `@theme` mapping) and theme-switch code

The canonical mechanism (per ~/.claude/skills/_v-design.md § Canonical Token Set) is
html[data-theme] token switching — dark-first, light-ready. `.dark`/`dark:`-class
strategies and prefers-color-scheme-only switching are OFF-MECHANISM: report them as
findings (theming-mechanism violation, BLOCK-level per _v-design.md § Visual Craft Gate
Check 2), never count them as "dark mode declared."

Assess:
- Canonical token blocks present: `:root` dark values + `html[data-theme="light"]` overrides (or @theme mapping to them); all surfaces consume tokens (no hardcoded white backgrounds breaking dark mode)
- Theme toggle is discoverable (settings nav or persistent header) and sets `data-theme`; prefers-color-scheme may only PRE-SEED the initial `data-theme` before first paint, never be the sole switch
- Charts / data viz colors work in both modes (not hardcoded #FFFFFF text)
- Code blocks / syntax highlighting has dark variant
- Logo has dark/light variants OR is mono-color that works in both
- Modals / overlays don't break in dark mode
- Form input borders / placeholder text legible in both

If NO theming exists at all: that is a finding (dark-first is mandatory per
_v-design.md § Runtime-Critical Quality Bar), not a "consider for post-launch" note.

Output JSON: { "surface": "dark_mode", "findings": [...], "dark_mode_declared": true|false, "theming_mechanism": "data-theme"|"dark-class"|"media-query-only"|"none" }
```

## Surface 8: Mobile Critical Paths

```
Subject: Pre-launch mobile readiness check

Read: viewport meta, responsive classes, mobile-specific code paths

Assess:
- Viewport meta correct: `<meta name="viewport" content="width=device-width, initial-scale=1">`
- Hero readable on 375×812 (iPhone X / 12 / 13 width) without horizontal scroll
- Primary CTA reachable without scrolling on mobile
- Signup form fields stack cleanly (not crammed into 320px width)
- Pricing tier cards stack readably (not 5-tier horizontal scroll on mobile)
- Touch targets: ≥24×24px floor (WCAG 2.2 AA 2.5.8); primary buttons should hit the ≥44×44px best-practice target (2.5.5 AAA / Apple HIG) — per _v-design.md § Interactive Target Size
- No `:hover`-only interactions for critical actions (mobile has no hover)
- Modal / overlay systems work on iOS Safari (the most common mobile-only break)
- Navigation collapses to hamburger / bottom-bar pattern on small screens
- Text readable at default size (no zoom required) — body copy on the canonical scale (app UI 12–13px per _v-design.md § Typography; marketing section body 16–18px per spec §10 Marketing Typography Overrides; flag only sub-scale text or zoom-requiring layouts, and ensure inputs don't trigger iOS auto-zoom, e.g. via viewport meta or ≥16px on input elements specifically)

Output JSON: { "surface": "mobile", "findings": [...], "horizontal_scroll": true|false, "primary_cta_reachable": true|false }
```
