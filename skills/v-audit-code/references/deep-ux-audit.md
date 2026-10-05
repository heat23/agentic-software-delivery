# Deep UX & Accessibility Audit

_Last reviewed: 2026-08-02 (F35 citation-accuracy sweep: EN 301 549 / ADA Title II legal-compliance-floor citations verified against source and pinned to specific versions/dates — EN 301 549 v3.2.1 (2021, WCAG 2.1 AA) vs. draft v4.1.1 (WCAG 2.2, expected 2026); DOJ ADA Title II final rule (April 2024, WCAG 2.1 AA, government sites) distinguished from Title III private-business litigation practice — so future staleness is detectable. WCAG 2.2 criteria table (§1) re-verified against W3C source, unchanged. Prev sweep B 2026-07-06: theme-consistency)._

**What this is.** A "deep mode" for the UX / UI craft & content quality
lens in `audit-lenses.md`. That lens is a one-paragraph thinking lens by
design — this file is where the lens goes when the operator (or the
project's stakes: public-facing SaaS, EU/US-regulated surface, a
pre-launch or quarterly brand review) calls for comprehensive
WCAG-compliance-floor depth, measured pixel-perfect findings, and the
full anti-AI-tells sweep instead of a lighter pass.

**When to load this file:** when running `v-audit-code` at `thorough`
depth on a user-facing product, when the invocation explicitly asks for
"deep UX," "accessibility audit," "WCAG compliance," or "does this look
AI-built," or when Phase-2-equivalent domain passes reach the UX/a11y
domain and the project has public or EU-facing surfaces. Skip it (stay
with the one-paragraph lens) for internal tools, quick passes, or
non-UI-heavy codebases.

**What NOT to port from here into the report uncritically:** the
severity numbers and floors below assume a mature, user-facing SaaS
product. Scale them down for early-stage/internal projects exactly as
`audit-lenses.md`'s "match the bar to the real audience" principle
already instructs.

**What this file is NOT.** `v-audit-code` is a flexible-framework
audit (`references/rating-framework.md`: "no mandated category list or
scale") plus prose thinking lenses (`references/audit-lenses.md`). This
file does not reintroduce a numbered-dimension checklist, per-dim
floor table, or numbered gate sequence — those belonged to the retired
`v-ui-audit` and did not carry forward. Where this file's history still
carries calibration numbers (severity thresholds, sample sizes), treat
them as useful defaults, not a mandatory scored rubric.

---

## Compliance floors (non-demotable in deep-UX mode)

Two categories of finding are compliance floors — reported at full
severity, never demoted to Low just because the surrounding pass is
framed as "craft" or "polish" — whenever this file's deep-UX mode is
active:

- **WCAG 2.2 AA accessibility.** Fully specified in § 1 below: the
  legal-compliance framing, baseline checks, the 8 new WCAG 2.2
  criteria, and the severity rubric. The only demotion path is an
  explicit, logged internal-only-tool declaration (§ 1, § 9) — never a
  default, never silent. `/v-pre-flight` Gate 24's warn-only default is
  a tooling statement, NOT a demotion signal for these floors — a green
  pre-flight does not soften a P0 a11y finding here.
- **Security-UI.** The security posture of user-facing surfaces (auth
  flows, session/token handling reachable from the client, trust-
  boundary violations visible in the UI — exposed stack traces,
  unsanitized `dangerouslySetInnerHTML`, client-side secret leakage,
  IDOR surfaced through UI state). This file does not re-derive
  security checks: apply `audit-lenses.md`'s "Security & trust
  boundaries" lens in full — it already runs on every `v-audit-code`
  pass, not only when deep-UX mode is loaded. What this file adds is
  the demotion rule: a security finding surfaced *during* a UX/craft
  pass keeps the severity it would get on its own. Being adjacent to
  aesthetic findings is never grounds to soften it.

Both floors report at the severity `~/.claude/skills/references/v-core-severity.md`
would assign on the evidence alone. `rating-framework.md` and
`audit-lenses.md` deliberately carry no fixed category list — this
section is the one durable place in the skill where the "compliance
floor" framing referenced elsewhere in the audit-family docs is
actually implemented.

**Deepening polish's core UX lens, not duplicating it.** Two checks in
`audit-lenses.md`'s "UX, UI craft & content quality" lens get extra
depth here rather than a full restatement:

- **Dark mode** — beyond the base lens's light/dark contrast-ratio
  check on token pairs, run the semantic-token-envelope check: grep
  the theme/token file for every token referenced on dark-mode routes
  and confirm each resolves to a value distinct from its light-mode
  counterpart rather than a copy-pasted alias (e.g. a "dark surface"
  token pinned to the same hex as the light-mode paper token). This
  catches a toggle that exists in markup but never actually re-themes.
- **Mobile responsiveness** — beyond the base lens's breakpoint-
  presence proxy (grep for responsive utility classes), run a
  long-content stress test: a static read of what key layouts do when
  content is unusually long (long emails/usernames, translated
  strings, many list items) at narrow viewports — truncation vs.
  overflow vs. wrap. The base lens verifies breakpoints exist; this
  checks whether they hold under real content, not just the empty
  demo state.

---

## Contents

1. WCAG 2.2 AA compliance floor
2. Anti-AI-tells catalog (content + structural)
3. Pixel-perfect measurement thresholds
4. Conversion & forms UX depth
5. Brand identity depth (logo / favicon / OG / PWA)
6. SEO-UI depth
7. Visual-system consistency (icon/chart/toast/modal, async/loading, email rendering)
8. Internationalization (i18n) depth
9. Tier-classification determinism concept
10. Frontend performance / Core Web Vitals

---

## 1. WCAG 2.2 AA compliance floor

**Frame this as compliance, not demotable polish.** Accessibility
findings on a public- or EU-facing product are a **legal-compliance
floor**, not a craft nice-to-have that can be waved off as Low severity
just because the project has other priorities:

- The **European Accessibility Act (EAA)** came into force **28 June
  2025** and binds a wide range of consumer-facing digital products and
  SaaS sold into the EU to **EN 301 549 v3.2.1 (2021)**, which
  currently incorporates **WCAG 2.1 AA** (verified against ETSI/EU
  Commission sources 2026-08-02). A draft **v4.1.1** aligning EN 301 549
  with **WCAG 2.2** is in public review with publication expected
  2026 — re-verify this paragraph once that version is finalized;
  treat WCAG 2.2 AA as the safer forward target in the meantime.
- In the US, the **ADA** has been applied to websites/apps by courts
  and the DOJ, with **WCAG AA** treated as the de-facto legal
  conformance target. The DOJ's **Title II final rule (April 2024,
  effective June 2024)** binds *state/local government* sites to
  **WCAG 2.1 AA** specifically (compliance deadlines were extended in
  2026 — verify current deadlines before citing one, but the WCAG 2.1
  AA technical standard itself is unaffected by the deadline
  extension). Private-business (Title III) exposure comes from
  litigation/settlement practice rather than a DOJ rule, but
  consistently converges on the same WCAG 2.1 AA floor. WCAG 2.2 AA is
  the safer forward target given the trajectory of both tracks.
- **Only a purely-internal tool (employee-only, no EU/public reach)**
  may have this demoted to a baseline-only pass (focus rings, semantic
  HTML, alt text on critical images) — and that demotion should be an
  explicit, logged decision, not a default.

### Baseline checks (every run)

- Heading hierarchy correctness (no h1→h3 skips)
- Color contrast ≥4.5:1 body text, ≥3:1 large text (≥24px/18pt normal
  weight OR ≥18.66px/14pt bold) and UI components
- All interactive elements have visible focus rings
- All images have alt text (or are explicitly `aria-hidden` if
  decorative)
- Keyboard navigation: interactive elements are real `<button>`/`<a>`/
  `<input>`, or a `div`/`span` with BOTH `role` + `tabIndex={0}` + a key
  handler. A click-only `div` with no keyboard affordance is a finding;
  flag any positive `tabIndex` value. Live end-to-end tab-through is
  UNVERIFIABLE-STATICALLY — use the static proxy, mark the traversal
  itself unverified, never claim you tabbed through it.
- All animations honor `prefers-reduced-motion`
- Form fields have associated labels
- ARIA live regions on dynamic content (live tickers, status updates,
  toasts)
- Touch targets: ≥24×24px AA floor (WCAG 2.2, 2.5.8); ≥44×44px
  best-practice target for primary/mobile actions (2.5.5 AAA) — per
  `_v-design.md § Interactive Target Size`
- No reliance on color alone for state (red/green without icons)
- `lang` attribute on `<html>`
- Skip-to-main-content link

### New WCAG 2.2 criteria most commonly missed in 2025/2026 — 6 AA/A-level + 2 AAA shown for context

WCAG 2.2 added 9 criteria. **Three** are AAA and sit outside an AA floor:
2.4.12 Focus Not Obscured (Enhanced), 2.4.13 Focus Appearance, and
3.3.9 Accessible Authentication (Enhanced). So the AA-and-below set is **6**
(2.4.11, 2.5.7, 2.5.8, 3.2.6, 3.3.7, 3.3.8). The table below lists those 6 plus
2.4.12/2.4.13 as labelled best-practice rows; 3.3.9 is omitted entirely.
(An earlier header said "8 AA-level criteria" by subtracting only 3.3.9 — the
per-row Level column was always correct, the header arithmetic was not.)

| Criterion | Level | What to check | Severity |
|---|---|---|---|
| 2.4.11 Focus Not Obscured (Minimum) | AA | Focused elements must not be entirely hidden behind sticky headers/cookie banners/chat widgets. Static proxy: locate `position: sticky`/`fixed` headers with a `z-index` above content; check for `scroll-margin-top` on focusable targets or `scroll-padding-top` on the scroll container. Mark the visual confirmation unverified — never tick it as tested. | Medium |
| 2.4.12 Focus Not Obscured (Enhanced) | AAA | Stricter form (no part obscured). Best-practice note only. | — |
| 2.4.13 Focus Appearance | AAA | Focus indicator size/contrast (≥3:1, roughly a 2px outline perimeter). Best-practice. **Distinct from 2.4.7 Focus Visible (WCAG 2.1, AA, non-negotiable):** a *missing or invisible* focus indicator (`outline-none` with no visible replacement) is an outright AA fail under 2.4.7. | Medium (missing indicator) |
| 2.5.7 Dragging Movements | AA | Any drag-based interaction (reorderable lists, kanban, sliders, drag-to-select) needs a single-pointer (click/tap) alternative. Drag-only reordering with no up/down buttons or menu = violation. | Critical on a primary flow |
| 2.5.8 Target Size (Minimum) | AA | 24×24 CSS px minimum, or ≥24px spacing to adjacent targets. Small icon-only buttons, tight pagination, dense table-row actions are usual offenders. | Medium |
| 3.2.6 Consistent Help | A (required for AA) | A help mechanism (contact/chat/help/FAQ link) appearing on multiple pages must stay in a consistent relative order/location. | Low |
| 3.3.7 Redundant Entry | A (required for AA) | Don't force users to re-enter info already provided in the same process (multi-step checkout/onboarding) without auto-populating or offering it for selection. | Medium |
| 3.3.8 Accessible Authentication (Minimum) | AA | Login must not require a cognitive function test (memorizing/transcribing, puzzle-solving) with no accessible alternative. CAPTCHA-only logins, no-paste password fields, "type the characters you see" gates are violations unless an alternative (passkeys, email link, OAuth, copy-paste-allowed password manager flow) exists. Object-recognition/personal-content CAPTCHAs are exceptions. | Critical (blocks login) |

### Zoom, reflow, forced-colors (2.1-era but frequently missed)

- **1.4.4 Resize Text (AA):** viewport meta must NOT contain
  `user-scalable=no` or `maximum-scale` < 2 (blocks pinch zoom — outright
  AA fail on a public product). Body text must not be locked to px
  sizes that ignore user font-size preferences.
  `grep -rn "user-scalable\|maximum-scale" {html-shell}` — any hit is a
  candidate.
- **1.4.10 Reflow (AA):** content must reflow to 320 CSS px width
  without 2-D scrolling (data tables/charts get their own scroll
  container exception). `grep -rnE "min-w-\[[5-9][0-9]{2,}px\]|w-\[[5-9][0-9]{2,}px\]" {pages-dir}` on page-level wrappers finds candidates.
- **Forced-colors / prefers-contrast survivability:** in Windows High
  Contrast (`forced-colors: active`), backgrounds and shadows strip out
  — controls whose ONLY affordance is a background color, shadow, or
  subtle fill vanish. `grep -rn "forced-colors\|prefers-contrast" {css-tokens}` — 0 hits + custom borderless controls means this was never
  considered; sample 3 icon-only/borderless controls and judge
  survivability.

### Forms-specific a11y depth (always full coverage — never demoted)

Forms are the highest-leverage interaction surface; even under a light
a11y pass, sample 3 forms (registration, billing/checkout, the
highest-traffic settings page) and tick ✅/⚠️/❌ on:

- Programmatic label association (`<label htmlFor>` / `aria-label` /
  `aria-labelledby`) on every input
- Server-error attached to the field via `aria-describedby` +
  `aria-invalid="true"` — not toast-only (toast-only misses screen
  reader users)
- `aria-required="true"` on required inputs (in addition to a visible
  asterisk)
- Submit-button disabled state announced to screen readers, not just a
  CSS class change
- Error summary at the top for forms with >5 fields, linking to each
  erroring field

### Severity rubric

- **Critical:** any WCAG 2.2 AA violation blocking an entire user
  journey for assistive-tech users; images critical to flow without alt
  text; form fields without programmatic labels; CAPTCHA-only login
  with no accessible alternative; drag-only interaction with no
  single-pointer alternative on a primary flow; `user-scalable=no` /
  `maximum-scale<2` on a public product.
- **Medium:** contrast 3.0–4.4 (close to AA but failing); animations
  without reduced-motion fallback; missing/obscured focus rings; pointer
  targets <24×24 CSS px with crowded neighbors; redundant re-entry in a
  multi-step flow; page-level layout that can't reflow to 320px; a
  primary control invisible/unusable under forced-colors.
- **Low:** help mechanism inconsistent placement; decorative images
  without `aria-hidden`.

**Compliance-floor severity note:** when the product has EU-facing or
US-public surfaces, do NOT let these findings get auto-demoted to a low
tier just because the operator generally treats UX/a11y as secondary —
see § 9 Tier-classification, edge case **[EC-1]**.

---

## 2. Anti-AI-tells catalog (content + structural)

**Content-level tells live in the shared catalog — use it, don't
duplicate it.** For banned-word frequency, hedging openers, em-dash
density, contraction ratio, first-person presence, structural
fingerprints (uniform paragraph/sentence length, symmetric H2s,
sycophantic intros), marketing-page-specific copy tells, and in-product
microcopy tells, apply
`~/.claude/skills/references/anti-ai-tells-content.md` in full. That
file already carries the severity-calibration table
(homepage/pricing = Critical-Craft, secondary pages = Medium-Craft,
footers/modals = Low-Craft).

### The calibration rule this file adds (not in the shared catalog)

**Combination, not presence.** A structural pattern alone is NOT a tell
by itself anymore. The centered hero stack (badge + h1 + subhead + 2
CTAs) and the three-tier-middle-highlighted pricing layout are now
**dominant HUMAN patterns** — Linear, Vercel, Resend, and Stripe all
ship them. Flagging those structures Critical-Craft on their own
produces false positives against exactly the sites held up as the bar.
A pattern is a genuine tell only when it **combines** with other tells
— typically generic/abstract copy + default Tailwind palette +
stock/undraw illustration. Score the COMBINATION, not the presence of
any single element:

- Em-dash density within the `anti-ai-tells-content.md` §C threshold
  (≤3 per 500 words of body copy) is a **weak supporting signal only** —
  not a standalone finding. Over the §C threshold (>3 per 500 words) it
  IS a standalone Medium finding (the same line the anti-template
  gauntlet and the humanizer Gate 3 fail at — canon owner: §C).
- The centered hero stack is flagged (Medium-Craft, not Critical) only
  when combined with generic copy + default palette + stock
  illustration.
- The three-tier highlighted-middle pricing layout is flagged
  (Low-Craft, not Critical) only when combined with generic tier names
  + generic feature copy + default palette — highlighting the
  recommended tier is good CRO on its own, not an AI-tell.
- When a real combination fires on a high-leverage surface (homepage,
  pricing, dashboard hero), the cluster is **Critical-Craft**.

### Structural anti-patterns not covered by the shared content catalog

The shared catalog is copy/content-focused. These are the
UI-structural anti-patterns that supplement it — each a finding when
present on a high-leverage surface (homepage, dashboard, primary
conversion page):

**Visual / layout:**

| Anti-pattern | What to grep / look for | Severity (key surface) |
|---|---|---|
| All cards use floating shadow + `rounded-xl` | `shadow-` + `rounded-xl` on >5 card components, no hairline-cell-grid pattern | Medium-Craft |
| No monospace data type anywhere | `grep -rn "font-mono\|tabular-nums\|font-data" {pages-dir}/` returns nothing | Medium-Craft |
| Heavy section dividers | `border-y-2`/`border-y-4` between marketing sections, no hairline-rule pattern | Low-Craft |
| All buttons filled-primary or outline-secondary only | No ghost-with-arrow secondary CTAs ("Sign up →" text-link style) | Low-Craft |
| Equal-padding cards in a 3-column grid | All feature cards same `p-6`, no asymmetric/numbered treatment | Low-Craft |

**Visual system:**

| Anti-pattern | What to grep / look for | Severity |
|---|---|---|
| All loading states are `<Loader2 className="animate-spin" />` | `grep -rn "Loader2"` count >> `grep -rn "Skeleton"` count | Medium-Craft |
| All charts use default Recharts colors | Hardcoded `#8884d8`/`#82ca9d` instead of canonical tokens | Medium-Craft |
| All toasts are Sonner default styling | No custom `<Toaster className=` / variants | Low-Craft |
| Modals are Radix Dialog defaults | No brand-specific styling beyond border-radius | Low-Craft |
| Mixed icon libraries | Both `lucide-react` AND `react-icons` AND `@radix-ui/react-icons` in the same project | Medium-Craft (consistency) |

**Brand identity:**

| Anti-pattern | What to grep / look for | Severity |
|---|---|---|
| Inline data-URI logo SVG | `<svg` data URIs in the app shell/layout templates | Medium-Craft |
| Single shared OG image across all pages | All `og:image` meta tags reference the same file | Medium-Craft |
| Stock photography on homepage | `<img src=` referencing unsplash/pexels/istockphoto | Medium-Craft (B2C: Critical) |
| Logo without dark-mode variant | Fixed `fill="..."` not `fill="currentColor"` | Low-Craft |
| No favicon variants for OS theming | `<link rel="icon">` block has no media query / color-scheme variants | Low-Craft |

**Documentation / trust:**

| Anti-pattern | What to grep / look for | Severity |
|---|---|---|
| No /security or /compliance page | No route matching `*security*`/`*compliance*` outside Legal/Privacy | Medium-Craft (B2B: Critical) |
| No /changelog as product surface | No `/changelog` route, no in-app "what's new" | Medium-Craft |
| No in-app status/health surface | No `/status`-style route served by the app itself (an external `status.{domain}` service is off-stack per `_v-audit.md` § In-App Actionability Boundary — never flag its absence) | Medium-Craft |
| No "How we use AI" page (if product uses AI) | No route + AI feature exists in code | Medium-Craft |
| Generic Privacy Policy obviously copy-pasted | Zero references to product specifics | Medium-Craft |

**Forms / async UX anti-patterns:** see § 4 and § 7 below — these
overlap with conversion and visual-system depth and are listed there
with their checklists rather than duplicated here.

This catalog is not exhaustive — add new anti-patterns observed (with
file:line evidence) as you find them.

---

## 3. Pixel-perfect measurement thresholds

**Hard rule: every Craft-class visual finding must cite at least one
measurement, or it gets dropped.** A measurement is one of:

1. A specific pixel value at a specific viewport ("8px gap at
   1366×768")
2. A WCAG contrast ratio ("3.2:1 text-on-bg, fails AA 4.5:1")
3. A line-height/font-size ratio ("leading 1.0 on 14px body — too
   tight")
4. A typography-rhythm violation ("h2 at 18px while h3 at 20px —
   inverted hierarchy")
5. A z-axis depth violation against the project's OWN fixed depth
   strategy
6. A token-usage violation against the project's OWN canonical token
   set

If a finding can't cite a measurement, it does not ship — "the hero
feels cramped" / "the button is too small" / "the colors clash" /
"looks dated" are vibes, not findings.

### The spec is the shared canon (no adoption predicate)

Every product this orchestrator manages is governed by the shared canonical
design system — `_v-design.md` (runtime subset + gates) and
`references/design-system-spec.md` (full spec). There is no per-project
"own design system" to discover and no adoption question to litigate
(`_v-design.md § Design System Application Order`: "The shared spec is
authoritative for every product"). Wherever a threshold below says "the
project's own spec/scale/tokens," read: the canonical spec, with
`.interface-design/system.md` as the ONLY sanctioned per-product overlay
(accent, category pairs, branding, domain components, marketing
surfaces — it cannot override palette, typography, spacing, or
components). Off-spec tokens, hardcoded hex, non-canonical fonts, and
`.dark`-class theming in product surfaces are regressions, not
stylistic choices — the Critical severities below apply unconditionally.

### Spacing / alignment

| Severity | Threshold | Example |
|---|---|---|
| Critical | Off by ≥16px on a primary CTA, hero, or above-the-fold layout | "Sign-up button 24px below intended baseline grid; collides with adjacent text at 1366×768" |
| Medium | Off by 4-15px on visible-but-secondary elements | "Footer link spacing 18px instead of the canonical `md` (12–14px) step" |
| Low | Off by ≤3px | Not a finding unless it causes a visible artifact |

Measure in CSS pixels at the viewport(s) the project actually targets —
don't measure on a 4K monitor and call it a mobile finding.

### Typography

| Issue | Threshold | Severity |
|---|---|---|
| Heading hierarchy inverted (h2 < h3) | Any inversion | Critical |
| Body line-height too tight | <1.4× font-size on >50-char lines | Medium |
| Font-size scale off by ≥4px between adjacent levels vs. the project's own scale | e.g. h2=24, h3=18 (gap=6) but project uses an 8-step scale | Medium |
| Font-weight inversion | h1 lighter than h2 | Medium |
| Off-spec font families | A third family beyond the canonical Inter/JetBrains Mono pairing anywhere (marketing hero display font excepted); mono applied via inline `font-family` instead of the `.mono` utility; a display font inside a data-dense surface (dashboard) | Critical |

### Color / contrast

| Issue | Threshold | Severity |
|---|---|---|
| Text contrast | <4.5:1 (WCAG AA) for body | Critical |
| Text contrast | <3:1 (WCAG AA Large — ≥24px/18pt normal weight OR ≥18.66px/14pt bold) | Critical |
| Token violation (hardcoded hex not resolving to a canonical token) | Any occurrence in a changed file | Critical (BLOCK-level per `_v-design.md § Visual Craft Gate`; exemptions: print and shared-report pages advisory, a QR-code settings page's `bg-white` grandfathered) |
| Accent drift / brand-tinted status colors | Inline override of the accent token by ≥10% HSL distance; any deviation from the fixed status hex values (`_v-design.md § Status Colors`) | Medium (status-color deviation: Critical) |
| Resting-state heavy shadow on cards | `shadow-md`+ on a resting card — the canonical depth strategy is border-at-rest, `--shadow` on hover | Medium |

### Z-axis / depth strategy

| Issue | Threshold | Severity |
|---|---|---|
| Off-spec depth strategy | Borderless floating-shadow cards or shadow-only depth — the canonical spec fixes border-at-rest / shadow-on-hover-or-overlay (`_v-design.md § Elevation & Structure`: not a per-project choice) | Medium (advisory in canon — elevation is NOT one of the two BLOCK-level `_v-design.md § Visual Craft Gate` checks; same verdict as v-check + gauntlet). Escalate to Critical only when the depth treatment breaks contrast or affordance on a primary flow |
| Default `shadow-md`/`shadow-lg` on resting cards | Any occurrence — the canonical spec reserves shadow for hover/overlay | Medium (matches this file's color/contrast table row and the v-check/gauntlet advisory-in-canon verdict) |
| Depth conflict at same z-layer | Two elements claiming the same elevation with different z-context | Medium |

### Iconography

| Issue | Threshold | Severity |
|---|---|---|
| Stroke width inconsistent across icon set | >0.5px variance within the same set | Medium |
| Sizing off-spec | Icon size not on the project's own spec sizes | Medium |
| Optical alignment | Icon visually mis-aligned with adjacent text baseline by >2px | Medium |

### Additional pixel-perfect tells (what a senior designer notices in 5 seconds)

- **Optical alignment vs. CSS centering** — icons inside buttons should
  sit on the visual midline of the text, not just `align-items: center`.
- **Hairlines at 1px, not 1.5px** — `border-[0.5px]`/`0.75px`/`1.5px`
  border widths are a tell; specify 1px with crisp rendering.
- **Baseline grid consistency** — vertical spacing should sit on the
  canonical scale (`_v-design.md § Spacing Scale`: xs 4 · sm 8 · md
  12–14 · lg 20–24 · xl 28–32 · 2xl 36–40, grid gap 14px). One-off
  values off that scale (`pt-7`, `mb-[26px]`) are tells — but canonical
  values that aren't multiples of 4/8 (13px, 14px gap, `space-y-3.5` =
  14px) are conformance, never flag them. On marketing pages, the
  sanctioned marketing spacing extension (spec §10: hero 120px, section
  80px, card grid gap 32px) is likewise conformance, not a tell.
- **Optical spacing on type** — headlines need negative letter-spacing
  (`-tracking-tight`); body text doesn't.
- **Line length on body copy** — 50-75 characters optimal; lines wider
  than ~90 characters (no `max-w-prose` constraint) are a finding.
- **Orphans and widows on key headlines** — use `text-balance` /
  `text-wrap: balance`; a hero h1 without it is a finding.
- **Numeric tabular alignment** — data tables/dashboards need
  `tabular-nums`; without it, columns wobble as digits change width.
- **Title-case vs. sentence-case consistency** — pick one; sentence case is
  the editorial default per `~/.claude/skills/references/anti-ai-tells-content.md`
  §H casing note (which also exempts spec-mandated UPPERCASE section
  headers — never flag those).
- **Icon weight matches text weight** — a `font-semibold` label paired
  with a default-stroke icon feels mismatched.
- **Button label punctuation** — no trailing periods ("Get started" not
  "Get started.").
- **Emoji rendering inconsistency** — native emoji renders differently
  across OSes; flag for SVG-icon replacement in product copy.
- **Default cursor on interactive elements** — missing `cursor-pointer`
  on a custom-styled clickable element is a finding.
- **Focus rings resolve to the project's own accent token, not a
  generic default** (`ring-blue-500` etc.).

### How to measure without a browser

If you can't run the page live, infer from CSS:

```bash
grep -rn "btn-primary\|btn-cta" resources/css/ resources/js/Components/
grep -E "--spacing|--gap|gap:" resources/css/app.css src/app/globals.css 2>/dev/null
```

If CSS says `padding: 16px 24px` but the surrounding element has
`gap: 8px`, that's an 8px-too-tight finding. A padding/gap/margin value
sitting off the project's own scale entirely is a finding on its own.

Contrast: use `webaim.org/resources/contrastchecker`,
`npx wcag-contrast-cli "#888888" "#ffffff"`, or hand-calculate the WCAG
2.2 relative-luminance formula:

```javascript
function contrast(fgHex, bgHex) {
  const luminance = (hex) => {
    const rgb = hex.replace('#', '').match(/.{2}/g).map(x => parseInt(x, 16) / 255);
    const [r, g, b] = rgb.map(v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const l1 = Math.max(luminance(fgHex), luminance(bgHex));
  const l2 = Math.min(luminance(fgHex), luminance(bgHex));
  return (l1 + 0.05) / (l2 + 0.05);
}
// contrast("#888888", "#FFFFFF") ~= 3.54 — fails AA 4.5:1
```

### What does NOT count as a measurement

"The hero feels cramped," "the button is too small," "the colors
clash," "hierarchy is unclear," "looks dated" — all vibes. Drop these
findings if no measurement accompanies them.

---

## 4. Conversion & forms UX depth

Forms are the highest-conversion-leverage surface in any SaaS and where
AI-built sites consistently ship 2020-grade defaults. Sample ≥3 forms
(registration, billing/checkout, the highest-traffic settings page) and
tick ✅/⚠️/❌ on each:

- **Inline validation timing** — validate on blur, not on every
  keystroke (eager validation before the user finishes typing = a
  finding).
- **Error message specificity** — "Invalid input" fails; "Email must
  include an @ — try again" is baseline; "We didn't find an account at
  that email — sign up?" is brand-grade.
- **Field-state error semantics** — server-returned field errors need
  `aria-describedby` + `aria-invalid="true"`, not a toast/banner only
  (banner-only is Critical for screen-reader users; also an a11y
  finding).
- **Disabled submit-button affordance** — a disabled CTA needs an
  inline explainer of why ("Required: email" helper text), not silent
  disabling.
- **Password field UX** — show/hide toggle, caps-lock indicator,
  strength meter or "8+ characters," and correct `autocomplete`
  (`new-password` on registration, `current-password` on login).
- **Email field UX** — `autocomplete="email"`, `inputmode="email"`,
  `type="email"`.
- **Autofill compatibility (static proxy)** — grep each form field for
  correct `autocomplete=` tokens (`email`, `new-password`/
  `current-password`, `name`, `tel`, `street-address`, `cc-number`) plus
  `name`/`id`/`type`. Missing/wrong token = a finding per field. Whether
  a password manager actually populates the field is
  UNVERIFIABLE-STATICALLY — mark unverified, never fabricate a
  "verified in browser" result.
- **Submit-while-submitting** — the submit button must disable +
  show a loading state on click, or the user can double-submit
  (Medium-Correctness on any payment/mutation form).
- **Network failure recovery (static proxy)** — grep the submit handler
  for `try/catch`/`.catch()`, an error branch that sets a visible error
  state, and confirmation that field state survives a failed request
  (controlled inputs / `react-hook-form` state, not reset-on-submit). No
  error branch, or clearing inputs before the request resolves = a
  finding (Critical-Correctness on payment, Medium elsewhere). The
  actual "cut wifi mid-submit" test is UNVERIFIABLE-STATICALLY — do not
  claim you ran it live.
- **Multi-step form recovery** — refreshing mid-flow must not lose
  state (Critical for any flow >2 steps, especially billing).
- **Optimistic UI vs. server confirmation** — optimistic success without
  rollback on failure is Critical-Correctness for mutations.
- **Field labels above vs. floating** — floating labels hurt
  accessibility (WCAG 1.3.1) and scanability; static labels above are
  the current standard (Medium-Craft finding on a B2B form otherwise).
- **Required field indication** — asterisk, "Required" tag, or marking
  optional fields instead; no indication at all = Medium-Correctness.
- **Focus trap and tab order (static proxy)** — grep for positive
  `tabIndex={1+}` (anti-pattern, flag every occurrence); check DOM
  source order matches intended visual order (CSS `order:`,
  `flex-direction:*-reverse`, or grid placement that reorders fields
  visually away from source = finding); modals/dialogs need a
  focus-trap primitive (Radix/Headless `Dialog`, `FocusTrap`, or
  `inert` on the background) — absent = finding. Live keyboard
  traversal is UNVERIFIABLE-STATICALLY.
- **CTA copy specificity** — "Submit"/"Save" is template; "Create
  project"/"Add card"/"Send invite" is specific (Low-Craft on typical
  forms, Medium-Craft on registration/billing).

### Billing/checkout-specific

- **Card input UX** — Stripe Elements/equivalent, or hand-rolled?
  Hand-rolled card input on B2B SaaS = Critical-Correctness (PCI
  exposure) AND Medium-Craft.
- **Address autocomplete** — manual-only address entry on a paid plan =
  Medium.
- **Order summary persistence** — hidden behind a collapsed accordion =
  friction finding.

### Session-expiry and entitlement-state UX

- **Session/CSRF-expiry recoverability** — a long-filled form submitted
  after session/CSRF expiry must fail into a recoverable state
  (branded re-auth preserving input), not a raw framework "Page
  Expired" dead end that eats the user's input. `grep -rn "419\|Page Expired\|TokenMismatch\|router.on('invalid'"` — 0 hits means expired-session UX was
  never designed.
- **Entitlement-state UI** — plan-gated features should be visibly
  disabled WITH an explanation + upgrade path (not silently hidden, not
  a raw 403); upgrade prompts should state the specific limit hit ("3 of
  3 projects used"), not generic "Upgrade to Pro"; the post-downgrade
  over-limit state should be designed.

### Onboarding momentum + telemetry completeness

- Count pre-value decisions from registration to first success; >3 is
  a friction finding (best-in-class gets there in 2 or fewer).
- Each onboarding step should fire started, completed, skipped, and
  abandoned (timeout) events — naming per the `/v-audit-analytics` canon
  (`object_action` snake_case, e.g. `onboarding_step_started`); most
  products fire only one; missing granularity is a telemetry-gap
  finding. Depth owner for instrumentation coverage is
  `/v-audit-analytics` (Dim 6) — flag the gap here, leave
  taxonomy/coverage scoring to that skill.
- Stalled-state detection: is there logic re-engaging users who
  registered but never completed onboarding (>24h, no first-value
  action)? Absence on a paid product = Medium-Craft.
- Trial-end mechanic taste: graceful downgrade preview vs. a hard wall
  (hard walls are dated).

---

## 5. Brand identity depth

- **Logo system** — currentColor / SVG variants (light/dark/mono)?
  Legibility tested at actual rendered sizes (favicon 16px, mobile nav),
  not just at 200px. Optical kerning on letter pairs (Va, Wa, Ye) at
  24px and 64px.
- **Color ownership** — is the brand color a unique HSL, or a
  recognizable Tailwind palette value (`indigo-500`)? Recognizable
  defaults signal "we used the default."
- **Favicon set completeness** — 16/32/180/192/512, apple-touch-icon,
  mask-icon, manifest icons; variants per OS theme signal craft.
- **OG image system tiers:** static-shared OG image (2020) → per-page
  static OG with headline rendered (2024) → dynamic Vercel-OG/Satori
  with brand grid + monospace data + page-specific metric (2026).
  Verify by reading 5 different page templates and diffing `og:image`
  values.
- **PWA manifest (static proxy only — do not claim you installed the
  PWA)** — read `manifest.webmanifest`/`manifest.json` and verify
  `name`, `short_name`, `theme_color`, `background_color`,
  `display: standalone`, and a full icon set (512×512 + maskable +
  apple-touch-icon in the HTML head). Missing/placeholder values = a
  finding; the felt "sequence intentional?" judgment stays unverified.
- **Brand-color restraint** — used at strategic emphasis points (one
  primary CTA, one accent rule) vs. sprinkled across every component.
  Restraint signals design maturity.
- **Off-brand assets** — stock photos on a SaaS claiming a polished
  brand is a flag, especially on About/Team/Empty pages.

---

## 6. SEO-UI depth

Depth owner + current facts for everything in this section:
`/v-audit-seo` (`references/anti-patterns.md`, `references/dim-checklists.md`)
and `~/.claude/skills/references/seo-volatile-knowledge-2026.md` — this list is
a UI-surface subset; on any conflict, those files win.

- Every public page has a unique `<title>` (≤60 chars) and meta
  description (120-160 chars, per `v-audit-seo/references/dim-checklists.md`
  § Audit 2 canonical band); catalog every page missing one or
  over-length.
- Per-page OG image strategy — shared OG across high-traffic pages is a
  Medium-Craft finding per page that should have its own.
- JSON-LD schema completeness — Organization, WebSite, BreadcrumbList on
  every page; SoftwareApplication on product pages; Article on blog
  posts. (FAQPage/HowTo rich results are deprecated — flag their
  presence as dead-schema cleanup, Low, not a gap.)
- Canonical tags on indexable pages; watch for SSR-vs-SPA
  double-emission with drifting values (sample 3 pages).
- hreflang correctness (at minimum `en` + `x-default` if
  English-only).
- sitemap.xml and robots.txt exist, are complete, are correct; check for
  pages appearing in BOTH robots.txt Disallow AND meta noindex (the
  robots.txt block prevents the meta tag from ever being read).
- 404s return proper HTTP 404 (not 200) — check for a catch-all route
  masking 404s.
- Image alt text quality (SEO-relevant, not just a11y baseline).
- Internal linking structure — orphan pages, broken links, hub-and-spoke
  vs. flat structure.
- Sitemap freshness — `lastmod` populated and accurate, or a static
  date forever.
- Meta description CTR engineering — written for SERP click-through
  (specific number, specific value prop) vs. template-generic.

---

## 7. Visual-system consistency (icon/chart/toast/modal, async/loading, email rendering)

### Baseline consistency

- Iconography: same icon for the same concept everywhere.
- Chart palette consistent across surfaces, resolving to design tokens
  rather than library defaults.
- Loading states: is there an explicit skeleton/shimmer/spinner rule?
- Toast hierarchy: info/success/warning/error visually distinct in
  weight and color, not just saturated-bg-with-white-text variants.
- Modal behavior: dismissal (click-outside, Esc, X), focus trap, mobile
  sheet vs. desktop centered.
- Cursor states used logically on non-button interactives.
- Transition timings consistent (pick 150ms or 200ms, not both).

### Async/loading depth (sample ≥5 async-bearing surfaces)

Default sample: dashboard initial load, a paginated list, a debounced
server-search box, a mutation button on a detail page, a long-running
job trigger. Tick ✅/⚠️/❌ on:

- **Skeleton vs. spinner discipline** — initial loads should use
  shape-matching skeletons; in-place mutations should use inline
  spinners; background jobs need a persistent indicator. Mixed and
  inconsistent = Medium-Craft; all-spinner on a data-heavy product =
  Critical-Craft.
- **Skeleton fidelity** — matches rendered layout (row count, column
  widths, approximate text length) vs. a generic 4-row gray shimmer.
- **`aria-busy` and live-region announcements** on loading containers
  and live-updating regions.
- **Optimistic mutation UX** — immediate UI update + background sync,
  vs. blocking every micro-action on the round-trip.
- **Inflight protection** — a mid-submit mutation button that doesn't
  disable fires duplicate requests (Medium-Correctness).
- **Long-running job UX** — persistent progress visibility (progress
  bar, durable toast, sidebar dot) vs. an 8-second toast that
  disappears (Medium-Craft minimum on loss of visibility).
- **Cancel affordance** — modal-blocking spinner with no cancel on a
  >10s operation = Critical-Craft.
- **Stale-while-revalidate on lists** — old data stays visible during a
  refresh vs. a jarring skeleton flash on every sort/filter/poll.
- **Empty-during-load disambiguation** — showing the empty state during
  the loading window is Critical for first-run dashboards.
- **Error-during-load recovery** — inline retry with a clear message vs.
  a generic error page/blank region (Critical-Craft on dashboards).
- **Loading-state typography** — skeleton rhythm matches loaded-state
  rhythm; mismatches cause visible CLS on hydration.
- **Animation timing consistency** — mixed `duration-150/200/300/500`
  across similar interactions = Medium-Craft.
- **Reduced-motion gating** — all entrance/exit animations gate behind
  `motion-safe:`/`prefers-reduced-motion`; misses are a11y findings even
  at otherwise-light a11y coverage.
- **Async error toasts that auto-dismiss** — non-trivial errors
  (mutation failures, payment errors) must not auto-dismiss on a default
  `duration: 4000` — they need acknowledgment.

### App-level failure states

- A global error boundary exists (React `ErrorBoundary`, Vue
  `onErrorCaptured`, framework error page) so a component crash renders
  a branded recovery surface, not a white screen.
- Failed data fetches on key surfaces render a designed retry state, not
  an infinite skeleton or a silent empty state that reads as "no data."
- Offline vs. server-error is at least distinguished in the message
  shown to the user.

### Email surface rendering

Copy is a content-lens concern; **rendering** belongs here:

- Transactional templates use email-safe construction (framework mail
  components / MJML / Maizzle / table-based layout — not the app's
  Tailwind flex/grid, which Outlook's Word renderer strips).
- Logo `<img>` has alt text and a fixed width (a broken-image state is
  what most clients show until images are enabled).
- Template survives dark-mode mail clients (no transparent dark logo
  assumed against a white background).
- A plain-text part is configured.
- Preheader/preview text is set (not leaking "View in browser" or raw
  CSS as the inbox preview line).

`ls {emails-dir}/` then read 2 transactional templates for the above.

---

## 8. Internationalization (i18n) depth

Full i18n readiness (translation externalization, RTL, hreflang) is
often out of scope for single-language products — but **base locale
correctness is not**, and stays in scope even when full i18n is
deferred:

- **Timezone correctness (default-on even for single-language
  products):** timestamps shown to users must be user-local or
  explicitly labeled ("14:02 UTC") — raw server-UTC timestamps
  presented as if local is a Correctness finding. Check whether the
  frontend formats dates via `Intl.DateTimeFormat`/`toLocale*`/
  dayjs-tz/date-fns-tz from an ISO/UTC wire value, or the backend bakes
  a pre-formatted server-zone string into the payload.
- **Ambiguous date formats** — `03/04/2026` reads as March 4 (US) or
  April 3 (EU); flag numeric ambiguous formats on user-facing surfaces
  (month-name or ISO formats are safe).
- **Currency display** — amounts show a currency indicator where users
  can be non-US; minor-units bugs (cents rendered as dollars) are
  Critical-Correctness.

When full i18n readiness IS in scope (multi-locale product):

- hreflang tags in `<head>`.
- All copy externalized to translation files vs. hardcoded strings.
- Locale switcher present in UI (or its absence explicitly noted).
- Date/number/currency formatting respects locale throughout, not just
  the base-correctness items above.
- RTL support for Arabic/Hebrew if applicable.
- Translatable strings escape correctly (no naive concatenation that
  breaks under pluralization/gendered languages).

**Severity:** hreflang present but copy hardcoded English = Medium
(mismatch); no i18n at all where none is intended = Low (often
intentional, not a finding to manufacture).

---

## 9. Tier-classification determinism concept

A recurring failure mode in UX/a11y audits is run-to-run drift: the
same finding lands in a high tier on one run and gets dropped on the
next, because "craft" scoring is inherently more subjective than
correctness scoring. Apply this classification to keep findings
reproducible.

### Stable vs. exploratory vs. transient

Every finding gets one of three classifications before tiering:

- **`[stable]`** — evidence is reproducible (the file:line, copy text,
  or measurement still exists at the same location); severity
  calibration is consistent across reviewers; the finding ID can be
  regenerated from the same input. **Default:** all Correctness-class
  findings (a11y violations, broken UX, security holes) start
  `[stable]`.
- **`[exploratory]`** — subjective evidence ("this feels off" without a
  measurement), opinion-driven severity, or trend-dependent judgment.
  **Default:** Craft-class findings (visual/brand/copy taste) start
  `[exploratory]` UNLESS they cite a measurement from § 3 above, in
  which case they get promoted to `[stable]`.
- **`[transient]`** — race-condition-flavored, environment-dependent
  (fails on one browser/viewport only), or a one-off that appeared this
  run with no clear cause. Very few findings start here; don't count
  these toward severity floors.

If a `[stable]` finding doesn't reappear on a re-audit, either it was
fixed (good) or the audit silently dropped it (investigate — that's a
bug in the audit, not a real fix).

### Edge cases that cause run-to-run drift

- **[EC-1] Compliance-floor dims are NOT auto-demoted.** a11y findings on a
  public/EU-facing surface keep their default tier regardless of any
  general "light-touch" operator preference — a Critical a11y violation
  stays high-tier, a Medium stays mid-tier. Only an explicit
  internal-only-tool designation demotes by one level, and that
  demotion should be logged with its justification.
- **Cluster-lead Medium-Craft** promotes to a higher tier only when it
  is explicitly the lead in a remediation plan's migration grouping, or
  it appears in the executive summary's systemic-patterns section — a
  subagent/reviewer self-tagging "this is a cluster lead" does not
  qualify on its own.
- **Cross-dim duplicates** (the same root cause flagged from two
  different lenses) — use the higher severity, the more specific
  evidence (file:line beats "the homepage"), and mark `[stable]` if
  either contributing flag was stable.
- **Re-observed findings from a prior audit** keep their tier unchanged
  if unfixed; if re-observed for 3+ consecutive audits at Medium/Low
  severity, consider (with an explicit note, reviewable by the
  operator) auto-demoting one tier as an aging signal.
- **Findings whose file:line no longer exists** — verify before
  dropping. If the issue is genuinely gone, mark resolved and exclude.
  If the file moved, update the citation and keep the finding. Never
  silently drop a stale citation without checking.

### Determinism check (run after tiering, before shipping the report)

1. If a prior audit report exists for this project, diff the top-tier
   sections — stable findings (same content/location) should land in
   the same tier both times. Drift is a bug; document it.
2. Verify severity floors are met, or document why not ("below floor —
   no other Critical findings detected" is an acceptable, honest
   result).
3. Log every compliance-floor-demotion decision with its justification
   so it's auditable later.

---

## 10. Frontend performance / Core Web Vitals

**What this section is for.** `audit-lenses.md`'s "Performance &
scalability" lens is backend-focused (query patterns, caching,
pagination, job/queue behavior) with one line covering "frontend
payload weight and render cost where a UI exists." This section is
the deepening for user-facing frontend performance — the genuine gap
left when `v-ui-audit` retired: its former Dim 8 ("Performance & web
vitals") does not otherwise exist anywhere in `v-audit-code`.

**What's verifiable without a browser vs. not.** Actual LCP/INP/CLS
numbers require a real browser/Lighthouse/CrUX run and are
UNVERIFIABLE-STATICALLY — do not claim you measured them or ran
Lighthouse. What IS verifiable from source: the structural choices
that predict CWV outcomes.

### Largest Contentful Paint (LCP) — static proxies

- Hero/above-fold image uses `next/image`-equivalent with
  `priority`/`fetchpriority="high"` (or `<link rel="preload">` for a
  plain `<img>`) — absence on the largest above-fold image is a
  finding.
- That image has explicit `width`/`height` (or `aspect-ratio`) —
  missing dimensions forces layout after load, delaying LCP paint and
  causing CLS (see below).
- The LCP candidate is not `loading="lazy"` — lazy-loading exists to
  defer off-screen images; applying it to the above-fold hero is a
  direct regression.
- Custom fonts used in the hero are preloaded
  (`<link rel="preload" as="font">`) or declare `font-display:
  swap`/`optional` — a blocking web font with no `font-display` delays
  text paint.

### Interaction to Next Paint (INP) — static proxies

- Heavy synchronous work in click/input handlers (large
  `.map`/`.filter`/`.sort` chains, an unthrottled search-input handler
  with no `debounce`) on interactive surfaces.
- Third-party scripts (analytics, chat widgets, ads) loaded
  synchronously in `<head>` rather than deferred/async or loaded
  post-hydration.
- Large client component trees with no code-splitting
  (`dynamic()`/`React.lazy` absent on heavy, rarely-used surfaces —
  modals, charts, rich-text editors).

### Cumulative Layout Shift (CLS) — static proxies

- Images/iframes/ads without explicit `width`/`height` or
  `aspect-ratio` — the single largest source of CLS.
- Web fonts with no fallback-metric override — `font-display: swap`
  without a size-matched fallback can still cause a visible reflow;
  `next/font` or a manual `size-adjust` fallback is current practice.
- Content injected above existing content without reserved space
  (cookie banners, promo bars, social-proof badges that push the
  layout down after mount).
- Skeleton/loading states (§ 7 above) whose dimensions don't match the
  loaded layout — this file already treats the mismatch as a Craft
  finding under async/loading depth; the CLS framing here is the same
  root cause read as a measurable Core Web Vital.

### Font-loading strategy

- Self-hosted vs. third-party font CDN — a render-blocking `<link>` to
  a third-party font host (a direct Google Fonts link rather than
  self-hosting or `next/font`) adds a DNS + connection round trip
  before text paints.
- `font-display` value present (`swap`/`optional`) vs. absent
  (defaults to `block` in most browsers — invisible text until the
  font loads, a direct LCP/CLS regression).
- Number of font families/weights loaded — more than 2 families or 4
  weights on a single page is a payload-weight finding independent of
  CWV.

### Bundle-size static proxy

Without a live Lighthouse run, treat these as the static proxy for
"does this ship too much JS":

```bash
# Barrel-file imports pulling an entire library into a client bundle
grep -rn "^import \* as\|from 'lodash'\|from \"lodash\"" src/ resources/js/ 2>/dev/null
# Heavy client-only libraries imported without a dynamic()/lazy split
grep -rln "from 'framer-motion'\|from 'recharts'\|from '@monaco-editor" src/ 2>/dev/null
```

- A whole-library import (`import _ from 'lodash'` instead of
  `import debounce from 'lodash/debounce'`) on a client-rendered page
  is a Medium finding — ships kilobytes of unused code for one
  function.
- A heavy client-only library (charting, rich-text editor, code
  editor) imported at the top of a route file rather than behind a
  dynamic import — Medium if below-the-fold, Critical if it blocks
  first paint of an above-fold surface.
- If the project has a bundle-analyzer script (`next build
  --analyze`, `vite-bundle-visualizer`, webpack-bundle-analyzer) but
  it has never been run or its output committed as evidence, note that
  as a coverage gap rather than fabricating a number.

### Severity rubric

- **Critical:** LCP-candidate image lazy-loaded or missing dimensions;
  a blocking web font with no `font-display` on the hero; a
  synchronous heavy computation in a hot input handler with no
  debounce.
- **Medium:** missing `width`/`height` on non-hero images; third-party
  scripts loaded synchronously in `<head>`; whole-library imports on a
  client bundle; a heavy library imported without code-splitting on a
  below-fold surface.
- **Low:** font weight/family count above the recommended ceiling; a
  bundle-analyzer script present but stale or never run.

As with every other measurement-gated section in this file (§ 3), a
finding here still needs a `file:line` citation — "the page feels
slow" is not a finding, "hero `<img>` at `resources/js/Pages/Home.tsx:42`
has no `width`/`height` and no `priority`" is.

---

## Cross-references

- `~/.claude/skills/_v-design.md` — the canonical design governance
  module (token set, typography/spacing scales, WCAG contrast + target
  size definitions, Visual Craft Gate BLOCK checks, per-product overlay
  envelope). Every visual threshold in this file judges against it; the
  full component-level spec is
  `~/.claude/skills/references/design-system-spec.md`.
- `audit-lenses.md` § "Performance & scalability" — the backend-
  focused base lens § 10 above deepens for frontend/CWV; that lens's
  one line on "frontend payload weight and render cost" is the pointer
  into this section, not a restatement of it.
- `audit-lenses.md` § "UX, UI craft & content quality" — the default
  lens this file deepens.
- `~/.claude/skills/references/anti-ai-tells-content.md` — the shared
  content-tells catalog (banned words, hedging, em-dash density,
  contraction ratio, first-person presence, structural fingerprints,
  marketing-copy tells, in-product microcopy tells). Apply it alongside
  § 2 above rather than re-deriving its thresholds here.
- `~/.claude/skills/references/findings-id-convention.md` — if this
  skill's findings use a `[DIM]-[NN]`-style ID convention, apply it the
  same way for re-run dedup.
- `~/.claude/skills/references/v-core-severity.md` — canonical P0-P3
  severity scale; map this file's Critical/Medium/Low vocabulary onto
  it the same way: Critical → P0 when it blocks a core flow entirely or
  causes data loss/security/payment compromise, P1 when high-impact but
  a workaround exists; Medium → P2; Low → P3.
