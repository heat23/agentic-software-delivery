# Anti-template-gauntlet check catalog

_Last reviewed: 2026-08-02 — Theme-3 P0 fix: added § Portfolio-distinctiveness check (the gate had no check for sameness across the operator's own products); decidability pass on Interaction/Behavior + Brand/Identity checks; restructured the AI-art row to a durable rule + dated snapshot; replaced the restated hex status-color table with a citation to `_v-design.md § Status Colors` (canon moved to oklch — cite, don't restate). Prior: 2026-07-06 (theme-consistency sweep A: SEO/AEO + growth-motion + copy/voice alignment; prev 2026-07-06 (design-language consistency pass))._

> **Persona for this reference:** senior product designer enforcing
> the canonical SaaS design system (`references/design-system-spec.md`)
> plus the surviving content/brand craft tells.
> Loaded on-demand by v-anti-template-gauntlet when running the
> pre-ship blocking gate.

This catalog defines what the gauntlet checks for: (a) SPEC CONFORMANCE
of visual output against the canonical design system, and (b) the
surviving content/brand tells. The gauntlet is a YES/NO gate — any
check fails → the gate BLOCKS ship.
Findings are categorized by severity:

- **CRITICAL** — instant fail. The output is unmistakably off-spec or
  AI-built/template-default; will damage brand trust on first impression.
- **HIGH** — strong deviation or tell. The output reads as "shipped off
  library defaults instead of the spec"; correctable in <30 minutes per finding.
- **MEDIUM** — subtle drift. Not blocking, but degrades conformance and
  professionalism in aggregate.

The gauntlet's verdict (Standard strictness shown; the SINGLE canonical
verdict table incl. Strict/Lenient lives in `../SKILL.md` § Step 7 — this
is a Standard-strictness excerpt, not a second definition):
- **0 CRITICAL + ≤2 HIGH** → PASS
- **0 CRITICAL + 3-5 HIGH** → CONDITIONAL PASS (operator approves with awareness)
- **≥1 CRITICAL or ≥6 HIGH** → BLOCK

Severity tiers map to the canonical scale in
`~/.claude/skills/references/v-core-severity.md` (CRITICAL = P0, HIGH = P1,
MEDIUM = P2); "≥1 CRITICAL ⇒ BLOCK" is that reference's "one P0 ⇒ failing
verdict" rule.

---

## Retired as tells (spec-mandated patterns — do NOT flag)

The shared design system MANDATES uniformity (spec §1: "Consistency
across tabs — content area is the only thing that changes"). These
former template tells now describe the required system and are
RETIRED — flagging them is a false positive:

**Scope of this retirement:** these patterns are retired only WITHIN a
single product's own pages. Sameness ACROSS the operator's different
products is a separate, still-active question — see
§ Portfolio-distinctiveness check below. Do not re-retire that check by
reasoning "the spec mandates uniformity, so this table covers it" — it
doesn't; this table has never asked whether product N is distinguishable
from products 1..N-1.

| Retired tell | Now |
|---|---|
| Single font family throughout ("Inter the meme choice") | Inter + JetBrains Mono are FIXED (spec §2). The flag inverted: a THIRD family, or missing mono on data values. |
| Default Tailwind palette / no custom palette | Canonical token set is FIXED (spec §3). The flag inverted: raw palette classes without semantic binding to the tokens. |
| Identical pricing tier cards / 3-column identical grids / centered hero | Spec §10 prescribes card pricing with a highlighted recommended tier, uniform grids, and the hero structure. The flag inverted: pricing/hero/sections OFF spec §10. |
| Highlighted / "Most Popular" recommended middle tier | LEGITIMATE — `/v-pricing-design` § Step 4 mandates the recommended-tier highlight as a standard pricing-psychology tactic. NEVER flag a highlighted/recommended tier as a tell. Only the DARK-PATTERN versions below are tells. |
| Lucide-everywhere-no-system | Spec §12 mandates inline Lucide-compatible SVG. The flag inverted: icon fonts, sprites, wrong viewBoxes. |
| All-caps liberal use | Spec §2 mandates UPPERCASE section headers with letter-spacing. The flag inverted: uppercase OUTSIDE the section-header/badge patterns. |
| Identical layout structure across pages | Spec §1 mandates it. The flag inverted: pages that BREAK the shared shell. |
| Same vertical rhythm across sections | The fixed spacing scale mandates it. The flag inverted: spacing OFF the xs–2xl scale. |

---

## Portfolio-distinctiveness check (Step 1.6 — a separate question from the table above)

Every row in the table above retires a WITHIN-product uniformity tell because the canonical
system mandates that uniformity for a single product's own pages. **It says nothing about
sameness ACROSS the operator's different products, and it must never be read as saying so.**
Two products are allowed — required, even — to share one font, one palette mechanism, and one
page shell, and STILL be required to read as distinct products from each other. Nothing in this
file asked that second question until this section existed. **Do not fold this check back into
the table above** — within-product uniformity and across-product sameness have different,
sometimes opposite, correct answers; keeping them separate is deliberate, not an oversight to
"clean up."

Mechanics (when this runs, discovery, output format): `../SKILL.md § Step 1.6`. Discovery
sequence: `portfolio-registry.md § Discovery sequence`.

### What counts as a structural difference

Only these five categories. `--accent`, category `-bg`/`-text` pairs, branding/logo, and copy
voice are ALREADY-sanctioned per-product freedoms (§ Visual / Component checks below) — they
prove a product has AN identity, not that it's structurally DISTINCT from a sibling product that
also has its own accent and its own copy. A product that differs from its sibling ONLY in these
does not clear this check.

| Category | Decidable signal | Free today, or canon-constrained? |
|---|---|---|
| Navigation model | Sidebar nav-section count/depth; whether ⌘K is the primary launcher or a secondary search | **Constrained** — `design-system-spec.md § Dashboard Layout` fixes a 240px left sidebar for every product today. Both products having the mandated sidebar is NOT a difference; only variation within its configurable parts counts, at HALF weight |
| Primary-surface layout | Which section pattern renders FIRST on the product's home surface: hero-metrics-first, table/list-first, board-first, canvas-first | **Free** — the page-header/hero-metrics/section shell is fixed, but which CONTENT leads it is exactly the "content area is the only thing that changes" freedom the table above already names |
| Information density tier | Data-table row height; cards-per-viewport at a fixed 1440px reference width; which end of the `xs`–`2xl` band (`design-system-spec.md § Spacing Scale`) the product defaults to | **Free** |
| Signature component treatment | The domain component named in the overlay's Domain Components field (`interface-design/SKILL.md § Per-Product Overlay`) — requires a different component TYPE (ring gauge vs. score bar vs. custom chart vs. timeline vs. board), not a recolor of the same type | **Free** — already sanctioned, but a TYPE difference is a structural claim, not just an identity claim |
| Type pairing | The overlay's Branding → marketing-hero-display-font field — a different family, or one product declaring "none — Inter" against the other naming a display font | **Free** — already sanctioned, same reasoning as above |

### Verdict rule

Count categories with a genuine difference per sibling product (Navigation-model counts at 0.5
weight per the constrained note above; the other four count at 1). If ANY ONE discovered sibling
yields **fewer than 2 named structural differences**, that is a CRITICAL finding:

`"Reads as <sibling product> with a new --accent — N structural difference(s) found (need ≥2): <list, or 'none'>."`

This is a CRITICAL finding like any other in this catalog — it alone can move the Step 7 verdict
to BLOCK regardless of how clean every other check reads. "Looks like your last product with a
new hue" is CRITICAL, never PASS.

### Canon-dependency honesty note

Do not fail a product SOLELY because the Navigation-model axis reads 0 — that axis is weak by
DESIGN today because the dashboard shell is canon-fixed across every product (widening
per-product structural freedom beyond accent is an open item from the 2026-08-02 SME review,
tracked outside this file — `design-system-spec.md` is out of scope for this catalog's edits).
Score on the four free axes; a product clearing ≥2 differences there passes regardless of the
shared sidebar. If canon later widens the navigation/layout envelope, promote that axis back to
full weight — this note exists so a future editor knows WHY it's half-weight, not that it should
stay half-weight forever.

---

## Visual / Component checks (CSS, Tailwind, components)

All conformance judgments reference `_v-design.md` (canonical token
set, Spec-Deviation Detection Table) and `references/design-system-spec.md`.
Per-product freedoms (declared in `.interface-design/system.md`) are
sanctioned and never flagged: `--accent`, category `-bg`/`-text` pairs,
branding, domain components, copy voice, marketing-hero display font.

### Critical conformance checks

| Check | Detection | Severity |
|---|---|---|
| Off-mechanism theming | `.dark`/`.light` class selectors or per-element `dark:`-variant strategy instead of `html[data-theme]` token switching; `prefers-color-scheme` as the only switch | CRITICAL |
| Hardcoded hex in app-UI components | Raw hex / `bg-[#...]` arbitrary values instead of `var(--token)` (Visual Craft Gate BLOCK Check 1) | CRITICAL |
| Non-canonical font stack | Any family beyond `Inter` + `JetBrains Mono` (display font allowed on the marketing hero headline ONLY); serif/decorative fonts in the dashboard | CRITICAL |
| Default component-library appearance | shadcn/Radix/Bootstrap/Tailwind UI components rendered as library defaults instead of the spec §5 component library (buttons, cards, badges, hero-metrics bar) | CRITICAL |
| Tailwind UI / Flowbite / Headless UI default copy | Hero section uses "Boost your productivity" / "Welcome to your new dashboard" / "All-in-one platform" verbatim | CRITICAL |

### Token & identity conformance

| Check | Detection | Severity |
|---|---|---|
| Raw Tailwind palette without semantic binding | `bg-white`, `bg-gray-*`, `text-gray-*`, `blue-500` etc. not bound to the canonical tokens; light values must come from the `[data-theme="light"]` override | HIGH |
| Per-product identity missing or unverified | `--accent` absent/left default, category `-bg`/`-text` pairs absent, or accent/category pairs not WCAG-verified (accent on `--bg` ≥3:1, white on accent ≥4.5:1) | HIGH |
| Brand-tinted status colors | Severity/status colors (`--critical`/`--high`/`--medium`/`--resolved`/`--info`) differ from the fixed values in `_v-design.md § Status Colors` — never brand-tinted variants | HIGH |
| Missing mono on data values | IDs, codes, timestamps, scores, version numbers not using the `.mono` utility (JetBrains Mono); or inline `font-family` instead of `.mono` | HIGH |
| Icons off-spec | Icon fonts, external sprites, or non-standard viewBoxes — spec mandates inline Lucide-compatible SVG (`0 0 24 24`, or `0 0 18 18` for nav icons) | HIGH |
| Non-canonical elevation | `shadow-xl`/`shadow-2xl`, ad-hoc shadow values, or heavy 2px+ borders — spec pairs 1px `var(--border)` with `--shadow` (hover) / `--shadow-lg` (overlays) | MEDIUM (advisory in canon — same verdict as v-check) |
| Preset gradient in hero | `bg-gradient-to-r from-purple-600 to-blue-600` or similar Tailwind preset gradient with no token binding | HIGH |
| Arbitrary z-index | `z-[...]` values outside the layer system (`_v-design.md § Z-Index Layer Definitions`: 0/10/20/30/40/50/60, sidebar 100, hamburger 200) | MEDIUM |

### Layout conformance (spec §4, §10, §11)

| Check | Detection | Severity |
|---|---|---|
| Pricing section off spec §10 | Pricing present but not card-based tier comparison with a highlighted recommended tier | HIGH |
| Marketing hero off spec §10 | Missing the 48–64px/700 headline + 18–20px muted subheadline + primary CTA + interactive demo/screenshot structure | HIGH |
| Dashboard shell off spec §4 | Sidebar not fixed 240px (`--sidebar-w`), page missing the page-header / hero-metrics / section pattern | HIGH |
| Feature sections off spec §10 | Sections not alternating text/visual layout | MEDIUM |
| Grids off the canonical system | App-UI card/column gap ≠ 14px (marketing pricing/feature card grids use the sanctioned 32px per spec §10); grids not collapsing at 1100px/700px | MEDIUM |
| Section spacing off the fixed scale | App-UI padding/margins not on the xs–2xl scale (4/8/12–14/20–24/28–32/36–40px). Marketing section rhythm is exempt on the sanctioned extension only (spec §10: hero 120px, section 80px, card grid gap 32px) | MEDIUM |
| Non-spec breakpoints | 768/1024 grid logic where 700/900/1100 apply | MEDIUM |
| No `text-balance` on hero h1 | h1 ≥3rem without `text-balance` (browsers wrap awkwardly) | MEDIUM |

### Typography conformance (spec §2)

| Check | Detection | Severity |
|---|---|---|
| Weights off the fixed scale | Weights other than 400/500/600/700, or size-only hierarchy (all headings `font-bold`, no weight progression) | MEDIUM |
| Section headers off-pattern | Not UPPERCASE 13px/600 with 1px letter-spacing and thin-rule `::after` | MEDIUM |
| Uppercase outside sanctioned patterns | `uppercase` on elements other than section headers, micro labels, and priority/alert badges | MEDIUM |
| Line-heights off the type scale | Body copy not 1.5–1.6; headings/values off the fixed line-height column | MEDIUM |
| Missing tabular numerals | Numeric columns (tables, metrics, scores) without `font-variant-numeric: tabular-nums` | MEDIUM |

### Image / asset tells

**Rule for "generic AI-generated hero art" (durable — apply this test, not a fixed defect list):**
flag the asset when BOTH hold: (a) it is unlicensed/unattributable imagery with NO
product-specific customization — nothing in the composition ties it to this product's domain,
category, or brand motif — AND (b) it carries visible generation artifacts, OR reads as an
interchangeable "AI startup hero" that could be swapped onto any competitor's homepage with zero
edits. An AI-generated asset that IS customized to the product (specific motif, tied to the
spec'd `--accent`, a unique composition — per
`v-illustration-system/references/illustration-system-playbook.md § Abstract / Generative`) is
NOT this tell, regardless of which tool produced it.

| Check | Detection | Severity |
|---|---|---|
| Stock photography in hero | `/images/hero-team-meeting.jpg` or similar generic Unsplash names; or referenced from `unsplash.com` / `pexels.com` URLs | CRITICAL |
| Generic AI-generated hero art | Apply the rule above. If flagged, the paragraph below is a dated illustration of current tells, not the definition | CRITICAL |
| Placeholder images in production | Lorem Picsum, placehold.co, dummyimage URLs in committed code | CRITICAL |
| OG image is product logo on solid background | The "logo on plain bg" OG image — extremely common AI-built tell | HIGH |
| No favicon or generic favicon | Default Vite/Next/Laravel favicon still present | HIGH |

**Snapshot (dated — not a permanent definition):** as of this file's `_Last reviewed` stamp at the
top, the most common visible generation artifacts are hands/eyes/text-in-image garbling,
hyperreal "product photography" lighting on abstract subjects, and gradient-mesh/glassmorphism
"AI startup" blobs. **This snapshot decays** — image-generation quality and the industry's
overused-look both shift faster than this file gets edited; do not keep citing "slightly-off
hands" once that stops being a real defect. **Staleness window:** re-verify this paragraph against
current output from whatever generation tooling the operator is actually using whenever this
file's `_Last reviewed` date is more than 120 days old, OR immediately after a materially-better
mainstream image-generation capability ships — whichever comes first. **Refresh trigger:** update
this paragraph in place (don't append a second dated list) and bump `_Last reviewed` with the
reason. The RULE above does not decay; only this paragraph does.

---

## Copy / Microcopy tells

The full catalog lives in `~/.claude/skills/references/anti-ai-tells-content.md`. The gauntlet runs the bash gates from `humanizer.md` against:

- Homepage hero copy
- Pricing page copy
- Onboarding microcopy
- Email templates
- Empty states
- Error messages
- Button labels

**GENERIC COPY remains a hard tell.** The spec sanctions uniform
structure, never uniform voice — copy that could describe any product
is flagged at full severity regardless of visual conformance.

**CTA labels — avoid the false-positive machine.** A standalone primary
CTA reading "Get Started", "Start free trial", "Sign up", or "Try it free"
is a LEGITIMATE industry-standard primary action — do NOT flag it as a tell.
The genuine copy tells are: (a) "Click Here" / "Submit" / "Learn More" used
as the MAIN action label, and (b) the *site-wide* pattern where every CTA on
every surface is generic with zero product-specific value context anywhere.
Flag (b) ONCE at the site level, never once per surface.

### Severity mapping for copy gates

| Gate failure | Severity |
|---|---|
| ≥1 banned word over threshold (delve, leverage, comprehensive, etc.) on hero/pricing | HIGH |
| Hedging openers in the combined surface text (Step 3 runs the gates on ONE combined draft, so counts are combined-total; canon §B caps at 1 per article) | >1 = MEDIUM, ≥3 = HIGH |
| Em-dash density >3/500 words on any surface (canon §C threshold — same line the humanizer Gate 3 fails at) | MEDIUM |
| Contraction ratio <30% on conversational surfaces | MEDIUM |
| Zero first-person across the site | HIGH (signals "AI wrote this") |
| "Click Here" / "Submit" / "Learn More" as a primary CTA | HIGH (these are genuinely weak — never the main action label) |
| EVERY CTA across the site is generic with zero value context ("Get Started", "Sign Up", "Learn More" on every surface, no product-specific action anywhere) | HIGH (site-level, ONCE — not per surface) |
| "Welcome to {ProductName}" without value prop | CRITICAL (in hero) |
| Loading states without product-specific text | MEDIUM |
| Error messages = "Something went wrong" | HIGH |

---

## Pricing dark-pattern tells

A highlighted / "Most Popular" recommended tier is NOT a tell — `/v-pricing-design`
mandates it (see the retired-tells table). The actual pricing tells are DARK PATTERNS
that erode trust and carry legal exposure (FTC negative-option, state ARLs):

| Check | Detection | Severity |
|---|---|---|
| Fake scarcity / urgency on pricing | Countdown timers, "only N seats left", "price goes up in X hrs" with no real basis; static "limited time" that never ends | HIGH |
| Confirm-shaming on decline/cancel | Decline/cancel copy that guilts the user ("No thanks, I don't want to save money") instead of a neutral label | HIGH |
| Hidden / undisclosed auto-renewal | Recurring-billing or trial-to-paid conversion not clearly disclosed near the CTA before purchase (FTC negative-option / state ARL) | CRITICAL |
| Cancellation harder than signup | No self-serve online cancel when signup is online; retention gauntlet / phone-only cancel (state Automatic Renewal Law exposure — e.g. CA ARL; the 2024 federal FTC "click-to-cancel" rule was vacated July 2025, so do not cite it as the basis) | HIGH |
| Pre-checked add-ons / opt-outs | Paid add-ons or consent boxes checked by default (negative-option checkout) | HIGH |

These map to `/v-marketing-design`'s dark-pattern prohibitions and the auto-renewal
guidance in `/v-legal-docs-generate`. Cross-reference those when a pricing/checkout
surface is in scope.

## Brand / Identity tells

### Brand inconsistency

| Check | Detection | Severity |
|---|---|---|
| Logo appears in 3+ different sizes/colors across surfaces | Grep every `<img src=".../logo...">` / `<Logo />` usage on hero, footer, OG-image generator, and email templates; flag if declared width/height or CSS size class differs by surface with no responsive-breakpoint reason, or if fill/color values differ | HIGH |
| No accent-color usage discipline | `--accent` used <3 times OR used >50 times on a single page (grep `var(--accent)` / `bg-accent` / `text-accent` occurrences) | MEDIUM |
| Multiple "primary" CTA styles | Grep the className/style on every element matching the spec's primary-button pattern (`type="submit"` or the spec §5.2 primary-button component) across surfaces; flag if more than one distinct class/style combination is used for what the copy identifies as the main action | HIGH |

### Generic brand voice

| Check | Detection | Severity |
|---|---|---|
| About page reads as ChatGPT-output | Generic "We believe in empowering teams" / "Our mission is to..." | HIGH |
| Footer has no personality | Just navigation links, no founder photo / no story / no contact-a-human option | MEDIUM |
| Privacy / Terms pages are unmodified templates | No product name in body, generic "[Company Name]" placeholders | CRITICAL |
| Legal docs published with unresolved `[REVIEW NEEDED]` markers | `grep -srlnE '\[REVIEW NEEDED[^]]*\]' content/legal public/legal resources/legal app/legal` returns any file — `/v-legal-docs-generate` attorney-review markers left in a shipped doc | CRITICAL |
| Legal docs with leftover intake placeholders | Unfilled `[JURISDICTION_STATE]`, `[BUSINESS_ENTITY]`, `[PRODUCT NAME]`, `[OPERATOR LEGAL NAME]`, `[EFFECTIVE DATE]` brackets in a shipped legal doc | CRITICAL |

---

## Interaction / Behavior tells

| Check | Detection | Severity |
|---|---|---|
| Hover-only interactions on critical buttons | `hover:` classes or `onMouseEnter`/`onMouseLeave` styling a primary CTA or submit button with no `:active`/`:focus-visible`/tap-equivalent state in the same component (grep per `../SKILL.md § Step 5`) | HIGH |
| No loading states on async actions | An `onClick`/`onSubmit` handler calling `fetch`/`axios`/an Inertia `router.*` method with no adjacent `isLoading`/`disabled`/`<LoadingButton>` state in the same component (grep per `../SKILL.md § Step 5`) | HIGH |
| Error toast says "Failed" with no detail | A toast/alert call whose message argument is a literal generic string ("Failed", "Error", "Something went wrong", "An error occurred") with no interpolated reason — `grep -rnE "toast\.(error|show)\(|alert\("` then filter for the literal strings above | HIGH |
| Confirmation dialog uses default browser `confirm()` | Literal `confirm(` / `window.confirm(` call site outside test files (not a styled `<Modal>`/`<Dialog>` component) — `grep -rn "confirm(" --include=*.tsx \| grep -v __tests__` | MEDIUM |
| Form submissions don't disable button | A `<form onSubmit=...>` or submit `<button>` with no `disabled={isSubmitting \|\| isLoading}` (or equivalent) prop wired to the same handler | HIGH |
| Animations off the spec's motion system | `transition-all` with no eased duration matching the spec's 250ms theme transition; OR any CSS `@keyframes`/animation with no `prefers-reduced-motion` guard anywhere in the stylesheet | MEDIUM |

---

## SEO / Meta tells

Presence-only quick checks — `/v-audit-seo` is the depth owner for everything
below (schema type guidance, lengths, current deprecations live there and in
`~/.claude/skills/references/seo-volatile-knowledge-2026.md`).

| Check | Detection | Severity |
|---|---|---|
| Same `<title>` across all pages | Static site title; not page-specific | HIGH |
| Same meta description across all pages | Static description; not page-specific | HIGH |
| Missing OG tags entirely | No og:title, og:image, og:description | CRITICAL |
| OG image is generic | "logo on background" or default screenshot; not designed for social sharing | HIGH |
| No JSON-LD schema | `<head>` has no `<script type="application/ld+json">` | MEDIUM |

---

## Verdict logic

The canonical, strictness-aware verdict table is defined ONCE in
`../SKILL.md` § Step 7 — do not diverge from it. The pseudocode below is
the **Standard-strictness** rendering of that table (Strict: any HIGH → BLOCK,
0 HIGH → PASS; Lenient: blocks only on CRITICAL):

```
# Standard strictness (see SKILL.md § Step 7: Apply verdict — Strict/Lenient)
if CRITICAL_count >= 1:
  verdict = "BLOCK"
  reason = "Critical spec deviation or AI/template tell present — would damage brand on first impression"
elif HIGH_count >= 6:
  verdict = "BLOCK"
  reason = "High count of spec-conformance/craft findings — output reads as 'shipped off defaults, not the spec'"
elif HIGH_count >= 3:
  verdict = "CONDITIONAL_PASS"
  reason = "Multiple HIGH findings; operator should review and decide"
else:
  verdict = "PASS"
  reason = "Output passes the anti-template gauntlet"
```

**Conditional pass policy:** when CONDITIONAL_PASS is the verdict, the gauntlet emits the finding list with severity + suggested fix, and asks the operator to acknowledge before continuing. The operator can choose to ship anyway or address findings first.

**Block policy:** when BLOCK is the verdict, the gauntlet refuses to mark the gate green. The operator must address findings or explicitly override (`--force` flag, with override logged in the report for accountability).

---

## What's NOT checked

This gauntlet doesn't check:

- Functional correctness (use `/v-pre-flight`, `/v-verify-done`)
- Comprehensive UX (use `/v-audit-code`, absorbed `/v-ui-audit` 2026-07-06)
- Content quality at depth (use `/v-audit-messaging`, `/v-audit-seo`)
- Technical SEO beyond meta tags (use `/v-audit-seo`)
- Operational readiness (use `/v-check`)

The gauntlet is narrowly scoped: **does the visual output conform to the canonical design system, and is the copy/brand free of AI-built tells?**

That's the question. Nothing else.
