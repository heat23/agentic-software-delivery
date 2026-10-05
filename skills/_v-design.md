# V Design — Shared Design Governance Module

Shared governance module consulted by UI-touching skills. Enforces conformance
to the canonical SaaS design system across the v-* pipeline.

The full specification lives at `references/design-system-spec.md` (design
philosophy, typography, color, layout, component library, navigation,
data-viz, interaction, accessibility, marketing pages, responsive strategy,
naming conventions, implementation checklist). This module carries the
runtime-critical subset plus the enforcement gates. When a skill needs
component-level detail (sidebar spec, hero metrics bar, card tiers, ⌘K
overlay), read the full spec.

<!-- runtime -->
## Runtime-Critical Quality Bar

These standards are runtime-critical and must survive any future slimming or
runtime-derivative pass. Do not compress them into generic "good design"
advice.

- All product surfaces conform to the shared SaaS design system
  (`references/design-system-spec.md`): Inter + JetBrains Mono, the canonical
  CSS custom-property tokens (`oklch()` + `light-dark()` + `color-mix()`
  derivation, spec § 3 Color System), `html[data-theme]` theming, the
  prescribed component library, and breakpoints 700/900/1100px (container
  queries drive in-page grid collapse, true viewport queries drive sidebar
  collapse — spec § 4 Container Queries).
- Per-product identity is expressed ONLY through the sanctioned degrees of
  freedom: `--accent`, category `-bg`/`-text` color pairs, logo and branding,
  domain-specific components, product copy, the editorial-typography lever
  (marketing hero + at most one section lede, spec § 10 Editorial Typography
  — The Differentiation Lever), and the Dashboard Signature (below — exactly
  one per product, app-UI surface, never marketing).
- UX, copy, onboarding, empty states, marketing surfaces, and first-success
  flows are quality-critical surfaces. Optimize them for information density,
  scannable hierarchy, and progressive disclosure per the spec's philosophy —
  power-user first, dark-first, light-ready.
- Off-spec tokens, hardcoded hex/rgba values (including a hand-written
  `-dim`/alpha variant — those are `color-mix()` derivations now, spec § 3
  Color Rules), non-canonical fonts, or `.dark`-class theming in product
  surfaces are regressions, not stylistic choices.
- **Core Web Vitals floor (75th percentile, field data):** LCP < 2.5s,
  INP < 200ms, CLS < 0.1. These are the CURRENT thresholds — web.dev's Core
  Web Vitals definition is the authoritative live source; re-verify the
  numbers before citing them if this bullet is more than a year old, and
  re-verify the METRIC SET itself, not just the thresholds (INP replaced FID
  as the responsiveness metric in March 2024 — the set has changed before and
  can change again). Treat this bullet as a pointer to the current spec, not
  a frozen fact.
<!-- end-runtime -->

## Canonical Token Set

One authored value per token, in `oklch()`, switched via `color-scheme` +
`light-dark()` on `html[data-theme]` — full mechanism, `color-mix()`
derivation formulas, and Color Rules live at `references/design-system-spec.md
§ 3 Color System`; this table is the fast-access mirror and MUST stay
numerically identical to it. This is the ONLY theming mechanism —
no `.dark`/`.light` classes, and `prefers-color-scheme` must never be the sole
switch (it may pre-seed the initial `data-theme` before first paint).

### Semantic Palette

| Token | Dark | Light | Usage |
|-------|------|-------|-------|
| `--bg` | `oklch(14.7% 0.011 285)` | `oklch(97.1% 0.003 286)` | Page background |
| `--surface` | `oklch(19.4% 0.010 285)` | `oklch(100% 0 0)` | Cards, sidebar, panels |
| `--surface-elevated` | `oklch(23% 0.015 285)` | `oklch(100% 0 0)` | Dropdowns, modals, hover states, nested cards |
| `--text` | `oklch(95% 0.003 286)` | `oklch(22.8% 0.038 283)` | Primary text |
| `--text-muted` | `oklch(64.3% 0.028 286)` | `oklch(54.5% 0.028 285)` | Secondary text, labels, timestamps |
| `--border` | `oklch(29% 0.020 285)` | `oklch(90.9% 0.011 286)` | Card borders, dividers, grid lines |
| `--accent` | product-specific `oklch()` | product-specific `oklch()` | Primary action, active states |
| `--accent-dim` | `color-mix(in oklch, var(--accent) 12%, transparent)` | `color-mix(in oklch, var(--accent) 8%, transparent)` | Accent backgrounds (active nav, badges) |

### Status Colors (fixed across ALL products — never brand-tinted)

| Token | Value | Dim % (dark / light) | Usage |
|-------|-------|------------------------|-------|
| `--critical` | `oklch(63.7% 0.208 25)` | 10% / 6% | Critical severity, destructive, errors |
| `--high` | `oklch(70.5% 0.187 48)` | 10% / 6% | High severity, actionable warnings |
| `--medium` | `oklch(79.5% 0.162 86)` | 10% / 6% | Medium severity, caution |
| `--resolved` / `--success` | `oklch(72.3% 0.192 150)` | 8% / 5% | Resolved, success, healthy |
| `--info` | `oklch(62.3% 0.188 260)` | 10% / 6% | Informational highlights |

Each `-dim` value is `color-mix(in oklch, var(--token) N%, transparent)` at
the dark-mode percentage above, wrapped in `light-dark(…, …)` with the
light-mode percentage as the other branch — full worked declarations at spec
§ 3. A hand-written `rgba()`/hex dim value is a spec violation, not a style
choice (Spec-Deviation Detection Table below).

### Elevation & Structure

| Token | Dark | Light |
|-------|------|-------|
| `--shadow` | `0 1px 3px rgb(0 0 0 / 0.4)` | `0 1px 3px rgb(0 0 0 / 0.08)` |
| `--shadow-lg` | `0 8px 24px rgb(0 0 0 / 0.5)` | `0 8px 24px rgb(0 0 0 / 0.10)` |
| `--sidebar-w` | `240px` | `240px` |

Depth strategy is FIXED: 1px `var(--border)` borders on all containers plus
the two shadow tokens (`--shadow` on card hover, `--shadow-lg` on
overlays/tooltips). It is not a per-project choice. Dim variants are used for
backgrounds; the full color goes on text/icons above them.

### Typography (fixed)

| Role | Family | Weights |
|------|--------|---------|
| UI | `Inter, system-ui, -apple-system, sans-serif` | 400 body, 500 labels/nav, 600 headings, 700 hero/titles |
| Mono | `JetBrains Mono, monospace` (via `.mono` utility, never inline `font-family`) | 400, 500 |

Scale: hero metric 3.5rem/700 · page title 22px/700 · section header
13px/600/1px tracking, UPPERCASE with thin-rule `::after` · card title/nav
13–14px/500–600 · body 12–13px/400 · badge 10–11px/600–700 · micro label
10px/600/1.5px tracking. Tabular numerals (`font-variant-numeric:
tabular-nums`) on any numeric column. `text-wrap: balance` on headings,
`text-wrap: pretty` on body copy. No decorative/serif fonts in the dashboard,
ever. Fluid sizing (`clamp()` for ranges ≥ 8px): `references/design-system-spec.md § Fluid Type Scale`. Marketing editorial-typography lever (family criteria, weight/measure, where it's allowed vs. mandatory Inter): `references/design-system-spec.md § Editorial Typography`.

### Spacing Scale & Breakpoints (fixed)

Spacing: `xs 4` · `sm 8` · `md 12–14` · `lg 20–24` · `xl 28–32` · `2xl 36–40`
(px). Grid gap between cards/columns: 14px. Breakpoints: grids collapse at
**1100px**, sidebar collapses behind hamburger at **900px**, single-column at
**700px**.

## Design System Application Order

The shared spec is authoritative for every product. There is no per-project
token discovery — only locating WHERE the canonical tokens live so you can
verify conformance and know which file to edit.

| Step | Action |
|------|--------|
| 1 | Apply the canonical token set above. It is the design system for all products. |
| 2 | Read `.interface-design/system.md` if present — it is the per-product OVERLAY only: `--accent` value, category `-bg`/`-text` pairs, branding, domain-specific components. It cannot override palette, typography, spacing, or components. |
| 3 | Locate the token implementation: Tailwind v4 `@theme` block in `resources/css/app.css` / `src/app/globals.css`, or plain-CSS `:root` block. Verify it matches the canonical set. |
| 4 | Tokens absent or off-spec? Invoke `/interface-design` to install the canonical `:root` + `html[data-theme="light"]` blocks (and generate the overlay if the product has none). |

### Locate Commands

```bash
# Canonical :root block (plain CSS or Tailwind v4 @theme)
grep -rEn ':root|@theme[[:space:]]*\{|data-theme' --include="*.css" resources/ src/ app/ 2>/dev/null | head -10
grep -rEn -- '--(bg|surface|surface-elevated|text|text-muted|border|accent|critical|sidebar-w)\s*:' --include="*.css" resources/ src/ app/ 2>/dev/null | head -20

# Per-product overlay
test -f .interface-design/system.md && echo "OVERLAY=present"
```

### Framework Mapping

The spec is written framework-free (plain CSS custom properties + BEM-like
classes). In Tailwind v4 projects, expose the same custom properties through
`@theme` so utilities resolve to them; theme switching still happens via the
`html[data-theme]` attribute variant, never a `.dark` class. In React/Inertia
components, consume tokens via semantic utility classes or `var(--token)` —
the token names and values are identical either way.

---

## Spec-Deviation Detection Table

Patterns to detect and flag during build/polish/check. Context determines
severity — app UI is held to the strictest bar.

| Deviation | Detection | Context |
|-----------|-----------|---------|
| Hardcoded hex values in components | Grep `#[0-9a-fA-F]{6}` in `.tsx`/component CSS | Always flag |
| Non-canonical font family (anything but Inter/JetBrains Mono; a display/serif font anywhere but the marketing hero + at most one section lede, spec § 10) | Check `font-family` declarations + font imports | Always flag |
| `.dark`/`.light` class theming, or `prefers-color-scheme` as the only switch | Grep `\.dark\b` selectors, `dark:` variants layered on a class strategy, media-query-only theming | Always flag |
| Inline `font-family` for mono instead of `.mono` utility | Grep `font-family.*[Mm]ono` in components | App UI = flag |
| Off-scale spacing values (not on the xs–2xl scale) | Spot-check padding/gap/margin against the scale | App UI = flag |
| Non-spec breakpoints (768/1024 grid logic where 700/900/1100 apply) | Grep media queries / responsive prefixes | App UI = flag |
| Brand-tinted status colors (custom red/orange/yellow/green/blue) | Compare severity/status color values to the fixed set | Always flag |
| Glassmorphism on app UI surfaces | Grep `backdrop-filter` in non-marketing, non-overlay components | App UI = flag (spec uses it only on overlay backdrops) |
| Gradient text in app UI | Grep `bg-gradient-*` + `bg-clip-text` | App UI = flag, marketing hero = OK |
| Arbitrary z-index (`z-[999]`) outside the layer system | Grep `z-\[` | Always flag |
| Size-only typography hierarchy (no weight variation) | Check heading styles vs the fixed weight scale | Always flag |
| `<div>` buttons / missing `aria-expanded` on expandables / missing `:focus-visible` outline | Grep interactive markup | Always flag |
| Hand-written `rgba()`/hex dim or alpha variant instead of `color-mix()` derivation | Grep `rgba\(` or a second hex literal next to a `-dim`/`-bg` custom-property definition in theme CSS | Always flag (spec § 3 Color Rules) |
| Viewport `@media` driving grid-column collapse for a component beside the sidebar (card grids, hero-metrics rows, kanban) instead of `@container` | Grep `@media` adjacent to `.card-grid`/`.hero-metrics`/`.kanban` (or component-scoped equivalents) selectors in main-content CSS | App UI = flag (spec § 4 Container Queries) |
| New dropdown/tooltip built on manual `getBoundingClientRect()` positioning with no `popover`/anchor-positioning attempt and no feature-detection guard | Grep `getBoundingClientRect` in new overlay components; check for `popover`/`anchor-name` nearby, or an explicit `"popover" in HTMLElement.prototype` / `@supports not (anchor-name: --a)` fallback guard | App UI = flag (spec § 6.2/§ 6.3 — manual positioning is the documented fallback, not a free alternative) |

### Grep Patterns for Detection

```bash
# Hardcoded hex values in components
grep -rn '#[0-9a-fA-F]\{6\}' resources/js/Pages resources/js/Components --include="*.tsx" | grep -v "\.test\." | head -15

# Non-canonical fonts
grep -rn "font-family\|fontFamily" resources/js resources/css --include="*.tsx" --include="*.css" | grep -viE "inter|jetbrains|system-ui|monospace|var\(--" | head -10

# Class-based or media-query-only theming (should be html[data-theme])
grep -rn '\.dark\b\|prefers-color-scheme' resources/css src --include="*.css" | grep -v "data-theme" | head -10

# Non-semantic colors (raw Tailwind palette instead of tokens)
grep -rn "bg-white\|bg-gray-[1-9]\|text-gray-[1-9]" resources/js/Pages --include="*.tsx" | head -15

# Glassmorphism in app UI (not marketing, not overlay backdrops)
grep -rn "backdrop-filter\|backdrop-blur" resources/js/Pages --include="*.tsx" | grep -viE "overlay|modal|search" | head -5

# Hand-written rgba()/hex dim variant instead of color-mix() derivation
grep -rn 'rgba(' resources/css src --include="*.css" | grep -v "color-mix(" | head -10

# Viewport media query doing grid-collapse work that belongs to @container
grep -rn '@media' resources/css src --include="*.css" -A2 | grep -B2 -iE 'card-grid|hero-metrics|kanban' | head -10

# Manual getBoundingClientRect positioning on a new overlay with no popover/anchor-positioning attempt
grep -rln "getBoundingClientRect" resources/js/Components resources/js/Pages --include="*.tsx" | xargs grep -L "popover\|anchor-name\|position-anchor" | head -10
```

---

## Context Sensitivity Matrix

| Context | Conformance bar | Notes |
|---------|-----------------|-------|
| App UI (Pages/, Components/, dashboard) | Full — canonical tokens, typography, components, breakpoints | Strictest |
| Marketing (landing, pricing, blog) | Shared tokens + typography; layout per spec §10 (top navbar, hero 48–64px, alternating sections, card pricing); section rhythm uses the marketing spacing extension (spec §10: hero vertical padding 120px, section vertical padding/gap 80px, card grid gap 32px — sanctioned divergence beyond the app xs–2xl scale; component-internal spacing stays on the app scale) | Display font allowed for hero headline only |
| Showcase HTML (standalone preview) | Tokens + fonts required; structure may simplify | Quality bar still applies |

**Context classification globs (canonical list — consumers keep in lockstep):**
files matching `*landing*`, `*pricing*`, `*marketing*`, `*campaign*`,
`*welcome*`, `*home*` (homepage), `*blog*` (layout, not content), `*about*`,
`*features*` (public page), `*contact*`, `*faq*` are marketing surfaces; all
others are app UI. Disambiguate compound names by context
(`marketing-dashboard.tsx` is app UI, not a marketing page).

---

## Visual Craft Gate

Lightweight automated checklist run during build/polish for UI files. Findings
use `_v-review.md` FINDING_FORMAT with `type: ux`, severity high (P1) or
medium (P2).

**Two checks are BLOCK-level — they must be fixed before deployment:**

### BLOCK Check 1: Hardcoded hex colors in components

**Pattern:** Component output contains `bg-[#...]`/`text-[#...]` arbitrary
values or raw hex in styles instead of canonical tokens.

```bash
grep -rn 'bg-\[#[0-9a-fA-F]\{3,8\}\|text-\[#[0-9a-fA-F]\{3,8\}\|border-\[#[0-9a-fA-F]\{3,8\}' \
  resources/js/Pages resources/js/Components --include="*.tsx" | grep -v "\.test\."
```

**Block condition:** Any match in app UI files (Pages/, Components/ — not marketing).
**Fix required:** Replace with the canonical token (`var(--accent)`,
`var(--critical)`, or the project's semantic utility bound to it). If no
canonical token maps to the color, the color choice itself is wrong — consult
`references/design-system-spec.md § 3. Color System`.

### BLOCK Check 2: Off-mechanism theming

**Pattern:** New UI hardcodes light-mode colors (`bg-white`, `text-black`) with
no token equivalent, or introduces `.dark`-class / media-query-only theming
instead of `html[data-theme]` token switching.

```bash
# Hardcoded light-mode colors with no token semantics
grep -rn 'bg-white\|text-black' resources/js/Pages resources/js/Components --include="*.tsx" | grep -v "\.test\."
# Class-strategy or media-query-only theming
grep -rn '\.dark\b\|prefers-color-scheme' resources/css --include="*.css" | grep -v "data-theme"
```

**Block condition:** Any hardcoded `bg-white`/`text-black` in app UI without a
canonical-token replacement, or any new theming path that bypasses
`html[data-theme]`.
**Fix required:** Use the token (`var(--surface)`, `var(--text)`, or the
semantic utility bound to it) — the light value comes from the
`[data-theme="light"]` override, never from a per-element light-mode class.

**False positive note:** Intentional white exists in print-targeted components
and public shared-view pages — downgrade to advisory there.

**Known exception:** a QR code (for example in two-factor setup) may sit on `bg-white` for
scanner compatibility (scanners require a white background). Treat it as advisory — do
not block it.

**Grep limitation:** These patterns check lines, not element scope. Use them
as a fast screen, then verify flagged instances manually.

---

All other visual craft checks are advisory:

1. **Token compliance (broader):** every color/spacing value traces to the
   canonical set (no raw Tailwind palette colors without a semantic binding)
2. **Typography conformance:** Inter/JetBrains Mono only; weights and sizes on
   the fixed scale; section headers UPPERCASE with thin-rule `::after`;
   tabular-nums on numeric columns
3. **Component conformance:** cards follow the 3-tier system (panel → card →
   nested); page header, hero-metrics bar, filter chips, badges match the
   spec's component library
4. **Interaction conformance:** `:focus-visible` outline on all interactive
   elements; `Escape` closes overlays; expandables carry `aria-expanded`;
   reduced-motion media query disables transitions
5. **Layout conformance:** 240px fixed sidebar on dashboard pages; content
   grids collapse at 1100/700; sidebar collapses at 900

### Finding Format

Uses `_v-review.md` FINDING_FORMAT with domain-prefixed IDs (`FND-VIS-*`).
Visual craft maps to `type: ux` and uses severity `high` (P1) or `medium` (P2).
Blocking checks use severity `high` with `blocking: true`.

```markdown
#### FND-VIS-001: [Issue Title]
file: [path:line]
type: ux
severity: [high | medium]
blocking: [true | false]
confidence: [high | medium | low]
issue: |
  ...
evidence: |
  ...
fix: |
  ...
verification: |
  ...
```

Advisory findings surface in reports but do not block deployment or fail
pre-flight gates. BLOCK findings (FND-VIS checks 1 and 2) MUST be resolved
before claiming done. (FND-VIS `severity: high|medium` maps to canonical P1/P2
per `references/v-core-severity.md`; ship-blocking is carried by `blocking: true`,
not by inventing a `critical` level.)

---

## Spacing Application Rules

Apply the fixed scale by structural level:

| Use Case | Scale token | Value |
|----------|-------------|-------|
| Icon gaps, badge padding | `xs` | 4px |
| Card body gaps, inner padding | `sm` | 8px |
| Card padding, section gaps, sidebar padding | `md` | 12–14px |
| Card content padding, page-header margin | `lg` | 20–24px |
| Main content padding, section spacing | `xl` | 28–32px |
| Between major page sections | `2xl` | 36–40px |

**Rule:** Within a single component, use at most 3 spacing values. Spacing
increases monotonically from inner to outer.

### Responsive Spacing Adaptation

Inner spacing (`xs`/`sm`) stays constant across breakpoints. Outer spacing
(`xl`/`2xl`) reduces ~40–50% below 700px — main content padding drops to
`60px 20px 40px` when the hamburger replaces the sidebar (≤900px). If mobile
sections feel disconnected by whitespace, the outer spacing hasn't been
scaled down.

## Color Contrast Requirements (WCAG AA)

All text must meet WCAG AA contrast ratios. Verify in BOTH themes — the
canonical pairs pass (e.g., `--text-muted oklch(64.3% 0.028 286)` on
`--bg oklch(14.7% 0.011 285)` = 5.8:1 in dark),
but per-product `--accent` and category pairs must be re-verified when chosen.

| Element | Minimum Ratio |
|---------|--------------|
| Body text (< 24px, or < 18.66px bold) | 4.5:1 |
| Large text (≥ 24px, or ≥ 18.66px bold — WCAG "large scale") | 3:1 |
| UI components (icons, borders, focus rings) | 3:1 |
| Placeholder text | 4.5:1 |

Status colors on their dim backgrounds pass AA by construction — do not
substitute custom tints.

### Interactive Target Size (WCAG 2.2)

One standard, two tiers — auditors and fix templates must use exactly this
framing (do not relabel 44px as an AA requirement):

| Tier | Size | Basis |
|------|------|-------|
| Floor (required) | ≥ 24×24 CSS px | WCAG 2.2 AA — 2.5.8 Target Size (Minimum) |
| Target (best practice) | ≥ 44×44 CSS px for primary/mobile touch actions | WCAG 2.5.5 Target Size (Enhanced) — AAA |

Below 24px is a finding. 24–43px on primary mobile actions is advisory
(recommend 44px). 2.5.8's own exceptions apply: inline targets within a
sentence (links in prose) are exempt, and undersized targets pass when an
offset of ≥24px to each adjacent target provides equivalent spacing (dense
toolbars).

## Z-Index Layer Definitions

The spec fixes two concrete values: sidebar `100`, mobile hamburger `200` —
real, non-top-layer, fixed-position elements that keep real z-index values.
Within content, map to layers — never arbitrary values (`z-[999]`):

| Layer | z-index | Use | Still needed? |
|-------|---------|-----|-----------------|
| Base content | 0 | Page content, cards, sections | Yes — real stacking context |
| Sticky elements | 10 | Sticky headers | Yes — real stacking context |
| Dropdowns/Popovers | 20 | Select menus, tooltips | Fallback-path only — canonical dropdowns are `popover`, which renders in the top layer above every non-top-layer element regardless of z-index (spec § 6.3) |
| Overlay backdrops | 30 | Modal/search-overlay backdrops | Fallback-path only — canonical backdrops are the native `::backdrop` pseudo-element on a `popover` |
| Modal/Dialog | 40 | Modal content, notification dropdown | Fallback-path only — canonical implementation is `popover` (spec § 6.2, § 6.3) |
| Toast/Notification | 50 | Toast messages | Fallback-path only if implemented as `popover`; keep the tier if toasts stay a plain fixed-position stack |
| Command palette | 60 | ⌘K search overlay dialog | Fallback-path only — canonical implementation is `popover="manual"` (spec § 6.2) |
| Sidebar | 100 | Fixed dashboard sidebar (spec §4) | Yes — real stacking context |
| Mobile hamburger | 200 | Hamburger button above overlay (spec §11) | Yes — real stacking context |

**Reconciliation rule (native top-layer stacking obviates tiers 20–60 on the
canonical path):** an element promoted to the top layer (an open `popover` or
`<dialog>`) renders above every non-top-layer element regardless of its
z-index — it needs NO tier assignment from this table. Assign a z-index from
tiers 20/30/40/50/60 ONLY on the documented manual-fallback path (feature
detection failed, spec § 6.2/§ 6.3). Don't set them defensively on a
`popover`-based component — that duplicates a guarantee the top layer already
gives you, and is itself a Spec-Deviation Detection Table finding (arbitrary
z-index). If two top-layer elements must stack in a specific relative order
(rare — e.g. a tooltip opened from inside an already-open dialog), verify
current browser behavior before assigning z-index within the top layer rather
than assuming a fixed rule; treat it as an edge case, not the default path.

### Third-Party Component Z-Index Integration

Third-party components (date pickers, editors, payment iframes, chat widgets)
often ship huge z-index values. Integrate without breaking the layer system:

1. **Containment:** wrap the third-party component in a positioned container at
   the correct layer; its internal z-indexes stack within that container.
2. **Override when possible:** components that accept z-index via props/CSS
   custom properties (Radix, Headless UI) get layer-system values.
3. **Isolation for stubborn components:** `isolation: isolate` on the parent
   constrains a portal's z-indexes to its subtree.
4. **Document exceptions** in the per-product overlay under "Z-Index
   Exceptions" with the reason.

```bash
grep -rn 'z-\[' resources/js --include="*.tsx" | grep -v "z-\[10\]\|z-\[20\]\|z-\[30\]\|z-\[40\]\|z-\[50\]\|z-\[60\]\|z-\[100\]\|z-\[200\]" | head -10
```

## Dashboard Signature (Sanctioned Per-Product Differentiation)

Every product built on this spec shares the same shell, components, and
(beyond `--accent`) the same visual bones — that's the point of a shared
system. But it also means the only sanctioned differentiation used to live on
marketing surfaces a logged-in user rarely sees. This section adds exactly
ONE sanctioned differentiation point INSIDE the dashboard itself.

**Rule:** a product may declare exactly ONE Dashboard Signature, chosen from
exactly these two options, in its `.interface-design/system.md` overlay. Not
both. Not a third option. Not applied ad hoc per page — one choice, applied
everywhere that element/motion type occurs.

| Option | What may vary | What may NOT vary |
|---|---|---|
| **(a) Primary metric treatment** | The FIRST cell of the Hero Metrics Bar (spec § 5.3) only: an animated count-up on load, a sparkline rendered behind the number, or a gradient-text fill using `var(--accent)`. | The number's typography (still 3.5rem/700, tabular-nums), the OTHER metric cells (stay plain per spec), and the component's structure/borders/dividers. Must respect `prefers-reduced-motion` — count-up/sparkline motion disabled → renders the static final value. |
| **(b) Signature motion** | ONE custom easing curve, declared once as `--motion-signature-easing` and referenced everywhere that motion type occurs (e.g. every `view-transition`, or every skeleton shimmer tinted with `color-mix(in oklch, var(--accent) N%, var(--surface-elevated))` instead of the default `var(--surface-elevated)`). | Every timing VALUE fixed by spec § 8 (150/200/250/300ms) — only the easing function or shimmer tint may vary, never a duration. Must fire consistently (that motion type, everywhere it occurs, or nowhere) — not per-page. |

No declaration in the overlay = no signature — the spec's plain, static
default applies, which is always a valid choice. Record the choice in the
overlay's `## Dashboard Signature` entry (template below), including the
exact CSS values and confirmation it was verified under
`prefers-reduced-motion: reduce` (both options must degrade to the spec's
plain default under reduced motion).

## Per-Product Overlay (`.interface-design/system.md`)

The overlay records ONLY the sanctioned per-product decisions. It never
restates (and can never override) the canonical palette, typography, spacing,
components, or breakpoints.

```markdown
# Design Overlay — [Product Name]

## Accent
- --accent: [oklch()] (dark) / [oklch() if different] (light)
- --accent-dim: color-mix() percentages — 12% dark / 8% light (spec § 3 formula)
- Contrast verified: [accent on --bg ≥ 3:1, white on accent ≥ 4.5:1]

## Category Colors
- --[category]-bg / --[category]-text: [pairs — ecosystem badges, tag types]

## Branding
- Logo asset + sidebar logo text (16px/700)
- Avatar gradient: [colors]
- Marketing hero display font: [family or "none — Inter"] (spec § 10 Editorial Typography)
- Marketing section lede treatment: [same family, or "none"] — at most one, per spec § 10

## Domain Components
[Product-specific components beyond the spec's library — name, purpose,
which spec primitives they compose (card tiers, badges, rings, bars)]

## Dashboard Signature
[Exactly one: "(a) Primary metric treatment" or "(b) Signature motion" with
the exact CSS values, or "none — spec default". Verified under
prefers-reduced-motion: reduce: yes/no.]

## Marketing Surfaces
[Written and owned by /v-marketing-design — competitive context, visual
thesis, navbar behavior, hero scale, section rhythm (marketing spacing
extension per spec §10), CTA spec, typography extensions. Copy/positioning
decisions only; it cannot override the canonical tokens either.]

## Z-Index Exceptions
[Third-party components that break the layer system, with reason]
```

## Token Staleness

The canonical set is fixed, so staleness only applies to the overlay and the
project's token implementation. If the session modifies the `:root` blocks,
`@theme` mapping, or `.interface-design/system.md`, re-verify conformance
before the next UI generation or audit step.

---

## Reference

Full component-level detail (sidebar anatomy, ⌘K overlay, notification
dropdown, hero metrics bar, card tiers, filter toolbar, progress rings,
skeleton/loading placeholders, marketing page structure and editorial
typography, responsive behavior, BEM naming), the universal-vs-reference-implementation
component split, and the underlying modern-CSS mechanics (color derivation,
container queries, popover/anchor-positioned overlays, view-transitions and
scroll-driven motion): `references/design-system-spec.md`.

For conformance critique of finished UI (does the build match the spec, are
per-product freedoms within the envelope), invoke `/interface-design:critique`.
