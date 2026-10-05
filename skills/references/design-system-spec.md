# SaaS Design System Specification

_Last reviewed: 2026-08-02 (modern-CSS pass: oklch/light-dark/color-mix color system, container queries, native popover + anchor-positioned overlays, view-transitions/scroll-driven motion, fluid type, skeleton component, universal-vs-reference-implementation component split, marketing editorial-typography lever)_

A foundation of **universal, domain-neutral primitives** — layout shell, typography, color system, buttons, cards, badges, tables, filters, overlays, progress/loading indicators — for building SaaS products with a professional dashboard experience and a high-conversion marketing site. Section 5 also ships **reference-implementation examples**, each labeled "**Reference implementation (illustrative)**," drawn from one hypothetical example product (a support desk) to show the primitives composed into something real. Their domain vocabulary (ticket, SLA, queue, customer) is illustrative only — re-derive it per product; do not ship it into an unrelated domain. This spec captures the structural, typographic, color, component, interaction, and responsive patterns that should be shared across all properties — while leaving room for per-product color palettes, branding, and domain-specific components.

---

## 1. Design Philosophy

**Power-user first, approachable to all.** The dashboard assumes daily use by people who know the domain. The marketing site assumes first-time visitors who need to understand value in seconds.

Core principles:

- **Information density over decoration.** Every pixel should earn its place. Prefer data-rich cards over empty whitespace.
- **Scannable hierarchy.** Users should locate what matters in under 2 seconds — via position, size, and color, not labels alone.
- **Consistency across tabs.** Sidebar, search, theme toggle, notifications, and user profile appear identically on every dashboard page. Content area is the only thing that changes.
- **Progressive disclosure.** Show summary by default; expand for detail on click. Never force users to navigate away to see secondary information.
- **Dark-first, light-ready.** Design in dark mode, verify in light. Both must be equally usable — light mode is not an afterthought.
- **Derive, don't duplicate.** Every token, dim/alpha variant, and theme pair has exactly one authored value plus a computed relationship — never two hand-maintained tables that can drift (see § 3 Color System). If you're about to write a second value "for light mode" or "for the dim version," stop — find the derivation instead.
- **Progressive enhancement, not version gates.** Modern CSS (native `popover`, anchor positioning, container queries, `light-dark()`, scroll-driven animation) is canonical. Where a browser lacks support, feature detection (`@supports`, `@container`, `CSS.supports()`) selects a documented fallback — never a comment gating behavior on "browsers released after 20XX," which is true until it isn't.
- **Universal primitives vs. reference implementation.** § 5 (Component Library) separates components any SaaS product needs from illustrative examples built for one product. When extending this spec with a new component, add it as a universal primitive (generic vocabulary) unless it is genuinely domain-specific — in which case label it "Reference implementation (illustrative)" like its siblings.

---

## 2. Typography

### Font Stack

| Role | Family | Weights | Usage |
|------|--------|---------|-------|
| **UI** | `Inter`, `system-ui`, `-apple-system`, `sans-serif` | 400 (body), 500 (labels/nav), 600 (headings/emphasis), 700 (hero numbers/titles) | All interface text, navigation, form labels, body copy, buttons |
| **Mono** | `JetBrains Mono`, `monospace` | 400, 500 | IDs, codes, technical values, timestamps, keyboard shortcuts, SLA percentages, version numbers |

**Why Inter:** Tall x-height for legibility at small sizes. Designed specifically for screens. Neutral enough for any SaaS vertical. Variable font available for performance. Tabular numerals for aligned data columns.

**Why JetBrains Mono:** Distinguishable characters (1/l/I, 0/O), ligature support optional. Signals "this is a system value" without needing a label.

### Type Scale

| Element | Size | Weight | Letter-spacing | Line-height |
|---------|------|--------|----------------|-------------|
| Hero metric value | 3.5rem (56px) | 700 | 0 | 1 |
| Page title | 22px | 700 | 0 | 1.3 |
| Section header | 13px | 600 | 1px | 1 |
| Card title / nav link | 13–14px | 500–600 | 0 | 1.4 |
| Body text | 12–13px | 400 | 0 | 1.5–1.6 |
| Badge / tag | 10–11px | 600–700 | 0.5–1.5px | 1 |
| Micro label (section labels, axis labels) | 10px | 600 | 1.5px | 1 |

### Typography Rules

- Section headers are UPPERCASE with `letter-spacing: 1px` and followed by a thin horizontal rule (flex `::after` pseudo-element).
- Monospace is applied via a `.mono` utility class — never set `font-family` inline.
- Never use decorative, display, or serif fonts in the dashboard. The marketing site may pair a serif/display face with Inter per the editorial-typography recipe in § 10 Marketing Typography Overrides — marketing body copy remains Inter regardless.
- Tabular numerals (`font-variant-numeric: tabular-nums`) on any column of numbers (tables, metrics, scores).
- `text-wrap: balance` on headings that can wrap onto multiple lines (page title, section headers, hero/section headlines, card titles); `text-wrap: pretty` on body/paragraph copy (marketing section body, longer dashboard descriptions). Both are progressive enhancement with no fallback CSS required — unsupported browsers get normal wrapping, which is the pre-existing behavior.

### Fluid Type Scale

A size given as a min–max range in this spec is one of two things — tell them apart by whether the range exists to scale with viewport width:

| Range kind | Rule | Example |
|---|---|---|
| **Viewport-fluid** — the range spans **≥ 8px** between min and max | Implement with `clamp(min, preferred, max)`. Never a discrete breakpoint jump. | Marketing hero headline 48–64px, section headline 32–40px |
| **Discretionary** — range spans **< 8px** | Pick one value, apply it everywhere on that surface. Not a `clamp()` candidate — the range was designer tolerance, not a responsive contract. | Hero subheadline 18–20px, marketing section body 16–18px, dashboard body text 12–13px |

**Deriving the `clamp()` value:** interpolate between this spec's own 700px/1100px breakpoints, so the fluid type scale and the layout breakpoints stay in lockstep. For a range from `min` px (at 700px viewport) to `max` px (at 1100px viewport): the vw-coefficient is `(max − min) / 4` (since 1100−700=400px of viewport maps to 100vw-units of that coefficient's scale), and the rem base is `(min − vw-coefficient × 7) / 16`.

Worked examples (§ 10 Marketing Typography Overrides):

```css
/* Hero headline: 48px → 64px between 700px and 1100px viewport */
font-size: clamp(3rem, 1.25rem + 4vw, 4rem);

/* Section headline: 32px → 40px between 700px and 1100px viewport */
font-size: clamp(2rem, 1.125rem + 2vw, 2.5rem);
```

Dashboard hero metric value (3.5rem/700, § 5.3) and page title (22px/700, § 5.1) are explicitly FIXED, single sizes — not ranges — and stay discrete on every breakpoint.

---

## 3. Color System

One authored value per semantic token, expressed in `oklch()`. The light/dark pair is a single `light-dark()` declaration, not two hand-maintained hex tables — and every `-dim`/alpha variant is DERIVED from its base token via `color-mix()`, not a hand-written `rgba()` pair. This is the single most important durability rule in this spec: a value that can drift (a second hex table, a hand-copied alpha) WILL drift; a value computed from one source cannot.

Theming mechanism is unchanged in spirit — `html[data-theme]` is still the ONLY switch; no `.dark`/`.light` classes, and `prefers-color-scheme` may only pre-seed the initial `data-theme` before first paint, never be the sole switch — but the CSS primitive is now `color-scheme` + `light-dark()`:

```css
:root {
  color-scheme: light dark; /* both supported; UA-styled controls (scrollbars, form widgets) match before JS runs */
}
html[data-theme="dark"]  { color-scheme: dark; }
html[data-theme="light"] { color-scheme: light; }
```

`light-dark(light-value, dark-value)` resolves against whichever scheme the attribute above sets — driven by the toggle + `localStorage`, not the OS preference, once it has fired (§ 8 Theme Toggle is unchanged).

> **Tailwind v4 implementation (canonical for the operator's stack).** When building on Tailwind, import with `@import "tailwindcss";` and expose these tokens through the CSS-first `@theme { --color-accent: …; }` block — **not** a `tailwind.config.js`, **not** the legacy `@tailwind base/components/utilities` directives, and **not** raw shadcn/Radix defaults left un-tokenized. The `--token` names below map 1:1 onto `@theme` custom properties; components reference `var(--token)` (or the generated `bg-accent` / `text-muted` utilities), never hard-coded hex. Tailwind v3 vocabulary (`tailwind.config.js` theme extension, `@tailwind` directives) is stale — do not emit it.

### Semantic Palette

Each token is ONE declaration. The `oklch()` values below were converted directly from the previous hex palette (sRGB → OKLCH, D65) — visually equivalent to the old table; re-derive precisely with a color tool on a future rebrand rather than hand-tweaking these.

| Token | Declaration | Usage |
|-------|-------------|-------|
| `--bg` | `light-dark(oklch(97.1% 0.003 286), oklch(14.7% 0.011 285))` | Page background |
| `--surface` | `light-dark(oklch(100% 0 0), oklch(19.4% 0.010 285))` | Cards, sidebar, panels |
| `--surface-elevated` | `light-dark(oklch(100% 0 0), oklch(23% 0.015 285))` | Dropdowns, modals, hover states, nested cards |
| `--text` | `light-dark(oklch(22.8% 0.038 283), oklch(95% 0.003 286))` | Primary text |
| `--text-muted` | `light-dark(oklch(54.5% 0.028 285), oklch(64.3% 0.028 286))` | Secondary text, labels, timestamps |
| `--border` | `light-dark(oklch(90.9% 0.011 286), oklch(29% 0.020 285))` | Card borders, dividers, grid lines |
| `--accent` | Product-specific `oklch()` value (dark and light may differ — set via `.interface-design/system.md` overlay) | Primary action, active states, success |
| `--accent-dim` | `light-dark(color-mix(in oklch, var(--accent) 8%, transparent), color-mix(in oklch, var(--accent) 12%, transparent))` | Accent backgrounds (active nav, status badges) |

### Status Colors (Fixed Across Products)

The hue is the one authored value per status; the dim background is a `color-mix()` derivation, never a second hand-picked color.

| Token | Declaration (base) | Declaration (`-dim`) | Usage |
|-------|---------------------|------------------------|-------|
| `--critical` | `oklch(63.7% 0.208 25)` | `light-dark(color-mix(in oklch, var(--critical) 6%, transparent), color-mix(in oklch, var(--critical) 10%, transparent))` | Critical severity, destructive actions, error states |
| `--high` | `oklch(70.5% 0.187 48)` | `light-dark(color-mix(in oklch, var(--high) 6%, transparent), color-mix(in oklch, var(--high) 10%, transparent))` | High severity, warnings needing action |
| `--medium` | `oklch(79.5% 0.162 86)` | `light-dark(color-mix(in oklch, var(--medium) 6%, transparent), color-mix(in oklch, var(--medium) 10%, transparent))` | Medium severity, caution states |
| `--resolved` / `--success` | `oklch(72.3% 0.192 150)` | `light-dark(color-mix(in oklch, var(--resolved) 5%, transparent), color-mix(in oklch, var(--resolved) 8%, transparent))` | Resolved, success, healthy |
| `--info` | `oklch(62.3% 0.188 260)` | `light-dark(color-mix(in oklch, var(--info) 6%, transparent), color-mix(in oklch, var(--info) 10%, transparent))` | Informational, neutral highlights |

Status hues are fixed and never theme- or brand-tinted. Only the dim percentage differs by scheme (matching the original 0.06–0.12 dark / 0.05–0.10 light split) — and that split is now a formula, not a second palette.

### Shadow System

Also one declaration per token via `light-dark()`. Shadows stay `rgb(0 0 0 / alpha)` — black-alpha is the correct primitive for a shadow, not `oklch()` — but they still shouldn't be two hand-maintained rows.

| Token | Declaration |
|-------|-------------|
| `--shadow` | `light-dark(0 1px 3px rgb(0 0 0 / 0.08), 0 1px 3px rgb(0 0 0 / 0.4))` |
| `--shadow-lg` | `light-dark(0 8px 24px rgb(0 0 0 / 0.10), 0 8px 24px rgb(0 0 0 / 0.5))` |

### Color Rules

- **Never hardcode hex values in components.** Always reference `var(--token)`.
- **Dim/alpha variants are DERIVED, never hand-written.** Any new `-dim`, `-bg`, or translucent variant is `color-mix(in oklch, var(--base-token) N%, transparent)` (swap `transparent` for `var(--surface)` when compositing onto a known opaque background matters, e.g. a flattened export). A literal `rgba(r,g,b,a)` or a second hex value for a variant is a spec violation, not a style choice — see `_v-design.md § Spec-Deviation Detection Table`.
- **Category-specific colors** (e.g., ecosystem badges, tag types) are defined per-product following the same derivation pattern: one authored base hue, `-bg` via `color-mix(in oklch, var(--category) 10%, transparent)`, `-text` is the base color at full strength.
- **Theme transitions**: All color-bearing properties transition over `250ms ease`. Respect `prefers-reduced-motion: reduce` by disabling all transitions and animations.
- **Browser support is not tracked here going forward.** `oklch()`, `color-mix()`, and `light-dark()` are Baseline-safe as of this spec's 2026-08-02 review. If a target ever needs to drop support, that is a `@supports` fallback decision made at build time — not a reason to revert this section to hex tables.

---

## 4. Layout System

### Dashboard Layout

```
┌──────────────────────────────────────────────┐
│  SIDEBAR (fixed, 240px)  │  MAIN CONTENT     │
│                          │  (fluid, padded)   │
│  ┌──────────────────┐    │                    │
│  │ Logo             │    │  Page Header       │
│  │ Search (⌘K)      │    │  Hero Metrics      │
│  │                  │    │  Section + Content  │
│  │ OVERVIEW         │    │  Section + Content  │
│  │  Dashboard       │    │  ...               │
│  │  [Tab 2]         │    │                    │
│  │  [Tab 3]         │    │                    │
│  │  [Tab 4]         │    │                    │
│  │                  │    │                    │
│  │ MANAGE           │    │                    │
│  │  Action links    │    │                    │
│  │                  │    │                    │
│  │ SYSTEM           │    │                    │
│  │  Status pill     │    │                    │
│  │                  │    │                    │
│  ├──────────────────┤    │                    │
│  │ ☽  🔔  ⚙        │    │                    │
│  │ Avatar + Name    │    │                    │
│  └──────────────────┘    │                    │
└──────────────────────────────────────────────┘
```

### Sidebar Specification

| Property | Value |
|----------|-------|
| Width | `240px` (CSS variable `--sidebar-w`) |
| Position | `fixed`, full viewport height |
| Background | `var(--surface)` |
| Border | `1px solid var(--border)` on right edge |
| Z-index | `100` |
| Internal layout | `display: flex; flex-direction: column` |
| Scrollable region | `.sidebar__nav` only (`overflow-y: auto; min-height: 0`). Logo, search, and bottom section do NOT scroll. |

#### Sidebar Sections (top to bottom)

1. **Logo** — Product name + icon. `padding: 20px 20px 16px`. Font: 16px/700.
2. **Search input** — Triggers the Cmd+K search overlay on focus. Shows `⌘K` keyboard shortcut badge. Does NOT perform inline search.
3. **Nav section(s)** — Grouped under uppercase section labels (10px, 600wt, 1.5px letter-spacing). Each link: icon (18×18 SVG) + label (13px/500) + optional trailing badge. Active link: `color: var(--accent); background: var(--accent-dim); font-weight: 600`.
4. **System status** — Green pill with pulse-dot animation: `"All systems operational"`. Background: `var(--accent-dim)`.
5. **Bottom bar** — Pinned via `flex-shrink: 0`. Contains:
   - Icon button row: theme toggle (moon/sun swap), notification bell (with red count badge), settings (gear icon). Each 32×32px.
   - User profile row: avatar (32px circle, gradient background, initials), name (13px/600), plan label (11px, muted).

#### Sidebar Interaction Details

- **Theme toggle**: Swaps `data-theme` attribute on `<html>`. Persists to `localStorage`. Moon icon visible in dark mode, sun in light.
- **Notification bell**: Opens a dropdown panel positioned with `position: fixed` to the RIGHT of the bell button (calculated via `getBoundingClientRect()`). This prevents clipping by the sidebar. Dropdown width: 320px.
- **Settings gear**: Must use a proper gear/cog SVG (Lucide `settings` icon, viewBox 0 0 24 24). Must NOT resemble the sun/theme-toggle icon.

### Main Content Area

| Property | Value |
|----------|-------|
| Margin | `margin-left: var(--sidebar-w)` |
| Padding | `28px 32px 40px` |
| Min-height | `100vh` |
| `container-type` | `inline-size` (named container: `container-name: main-content`) |

The main content region's available width changes because of the 240px sidebar, not the viewport — a container query is the correct primitive here, not a second viewport breakpoint. See Container Queries below.

### Grid System

Use CSS Grid for all multi-column layouts. No framework dependency.

| Pattern | Grid | Collapse |
|---------|------|----------|
| Hero metrics | `repeat(4, 1fr)` | 2-col at 700px |
| Kanban board | `repeat(4, 1fr)` | 2-col at 1100px, 1-col at 700px |
| Card grid (3-up) | `repeat(3, 1fr)` | 2-col at 1100px, 1-col at 700px |
| Dual panels | `1fr 1fr` | 1-col at 700px |

Gap: `14px` between cards/columns. No gap within the hero metrics bar (cards are visually joined with internal dividers).

### Container Queries

The 700px/900px/1100px numbers above are unchanged, but the MECHANISM depends on what's varying:

- **Sidebar-collapse breakpoint (900px) is a true viewport query.** The sidebar disappearing behind the hamburger is a viewport-width event, not a component-local one — keep `@media (max-width: 900px)` here (§ 11 Responsive Strategy).
- **Every grid collapse listed in the table above (hero metrics, kanban, card grid, dual panels) is a `@container` query on the main-content container**, not a viewport media query. These grids live beside a sidebar whose presence changes their available width independent of the viewport — the textbook case for container queries. Same thresholds (700px/1100px), evaluated against the container's inline size instead of the viewport:

```css
.main-content { container-type: inline-size; container-name: main-content; }

.hero-metrics { grid-template-columns: repeat(4, 1fr); }
.card-grid    { grid-template-columns: repeat(3, 1fr); }

@container main-content (max-width: 1100px) {
  .card-grid, .kanban-board { grid-template-columns: repeat(2, 1fr); }
}
@container main-content (max-width: 700px) {
  .hero-metrics, .card-grid, .kanban-board, .dual-panels { grid-template-columns: 1fr; }
}
```

This is why container queries matter beyond novelty: a card grid inside a modal, a split panel, or a resizable sidebar-adjacent region reacts correctly to ITS width — a viewport media query cannot express "narrow because the sidebar is open," only "narrow because the window is narrow." The same rule applies to any future component whose available width varies independently of the viewport (a card grid inside a drawer, a hero-metrics-style row inside a two-column detail view). Container queries have no meaningful "unsupported" fallback path worth building — treat `@container` as required baseline, same as CSS Grid itself.

### Spacing Scale

Use a consistent spacing scale throughout:

| Token | Value | Usage |
|-------|-------|-------|
| `xs` | 4px | Icon gaps, badge padding |
| `sm` | 8px | Card body gaps, inner padding |
| `md` | 12–14px | Card padding, section gaps, sidebar padding |
| `lg` | 20–24px | Card content padding, page header margin |
| `xl` | 28–32px | Main content padding, section spacing |
| `2xl` | 36–40px | Between major page sections |

---

## 5. Component Library

Everything below is a **universal primitive** — build it for any SaaS product — EXCEPT the entries explicitly marked "**Reference implementation (illustrative)**." Those show a primitive composed into something real, using one hypothetical example (a support-desk product). Their domain nouns (Ticket, SLA, Queue, Customer) are illustrative, not canon: re-derive the equivalent for your product's domain (e.g. an inventory product might badge by stock level instead of ticket priority, using the identical badge primitive with different labels).

### 5.1 Page Header

Every dashboard page starts with a page header:

```
[Title]                                    [Secondary Btn] [Primary Btn]
[Subtitle — muted, contextual]
```

- Title: 22px, weight 700.
- Subtitle: 13px, `var(--text-muted)`. Contains contextual info (last scan time, date range, counts).
- Actions: right-aligned, `display: flex; gap: 8px`.
- Margin-bottom: `24px`.

### 5.2 Buttons

| Variant | Background | Border | Text | Hover |
|---------|-----------|--------|------|-------|
| Default | `var(--surface)` | `var(--border)` | `var(--text)` | Border darkens |
| Primary | `var(--accent)` | `var(--accent)` | `oklch(100% 0 0)` | 10% darker accent |

All buttons: `padding: 8px 16px`, `border-radius: 8px`, `font-size: 13px`, `font-weight: 500` (600 for primary). Icon + text with `gap: 6px`. Focus-visible: `outline: 2px solid var(--accent); outline-offset: 2px`.

### 5.3 Hero Metrics Bar

A single unified bar displaying 3–5 key metrics. Visually one card, internally divided.

- Container: `var(--surface)` background, `1px solid var(--border)`, `border-radius: 12px`, `overflow: hidden`.
- Each metric cell: centered text, separated by `1px var(--border)` vertical dividers (CSS `::after` pseudo-element, 60% height).
- Label: 11px, 600wt, uppercase, 1.2px letter-spacing, muted.
- Value: 3.5rem, 700wt.
- Trend line: 12px, 500wt, colored by sentiment (green = good, red = bad, orange = caution, muted = neutral).
- Optional: one cell can have a tinted background (e.g., `var(--critical-dim)`) to draw attention.

### 5.4 Section Headers

Thin uppercase dividers that separate content zones:

```css
.section-header {
  font-size: 13px; font-weight: 600;
  text-transform: uppercase; letter-spacing: 1px;
  color: var(--text-muted);
  display: flex; align-items: center; gap: 10px;
  margin-bottom: 14px;
}
.section-header::after {
  content: ''; flex: 1; height: 1px; background: var(--border);
}
```

### 5.5 Cards

The primary content container. Three tiers:

| Tier | Background | Border | Use |
|------|-----------|--------|-----|
| Panel | `var(--surface)` | `var(--border)` | Outer containers (kanban columns, feed panels) |
| Card | `var(--surface-elevated)` | `var(--border)` | Items inside panels (ticket cards, queue rows) |
| Nested | — | Top-only `var(--border)` | Expanded detail within a card |

All cards: `border-radius: 8–10px` (panels 10px, inner cards 8px). Hover: `border-color: var(--text-muted); box-shadow: var(--shadow)`. Clickable cards get `cursor: pointer` and `transition: border-color 150ms, box-shadow 150ms`.

#### Expandable Cards

Cards that reveal detail on click use a smooth expand pattern:

```css
.card__details {
  max-height: 0; overflow: hidden; opacity: 0;
  transition: max-height 300ms ease, opacity 250ms ease 50ms;
}
.card.expanded .card__details {
  max-height: 300px; opacity: 1;
  margin-top: 10px; padding-top: 10px;
  border-top: 1px solid var(--border);
}
```

Keyboard: `Enter` and `Space` trigger expand. `aria-expanded` attribute tracks state. Only one card expanded per group at a time (accordion behavior).

### 5.6 Badges & Tags

| Type | Style | Examples |
|------|-------|---------|
| Severity badge | `background: var(--severity-dim); color: var(--severity); padding: 2px 8px; border-radius: 99px; font-size: 11px; font-weight: 700` | Critical count, high count — `--severity` is a placeholder for whichever fixed status token applies (`--critical`/`--high`/`--medium`/`--resolved`/`--info`, § 3) |
| Category tag | Same shape, product-specific `-bg`/`-text` variable pairs | Ecosystem badges, status tags |
| Priority / alert tag | `background: var(--alert-bg); color: var(--alert-text); font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; border-radius: 4px; padding: 2px 6px` | Universal primitive: a high-priority category tag, product-specific `-bg`/`-text` pair derived per § 3 Color Rules. **Reference implementation (illustrative):** a support desk's `--escalated-bg`/`--escalated-text` pair labels ESCALATED, VIP, URGENT |
| Nav badge | `font-size: 11px; font-weight: 600; padding: 1px 6px; border-radius: 99px; margin-left: auto` | Sidebar nav counts |

### 5.7 Progress Indicators

#### SVG Ring (Project Health)

```
- ViewBox: 0 0 42 42, circle at (21,21), radius 17
- Background ring: stroke var(--border), stroke-width 6
- Fill ring: stroke var(--accent) or var(--high), stroke-width 6, stroke-linecap round
- stroke-dasharray: 106.81 (2 × π × 17)
- stroke-dashoffset: 106.81 × (1 - percentage)
- Container rotated -90deg so fill starts at 12 o'clock
- Center text: percentage, 20px/700wt, absolutely positioned
```

#### Linear Score Bar (Inline)

Universal primitive: a thin horizontal bar showing any inline percentage/score value (confidence score, completion, risk score, probability):

```
- Height: 4px, border-radius: 2px
- Background: var(--border)
- Fill: colored by severity token (critical/high/medium) or --accent for a non-severity score
- Width: percentage value
- Paired with numeric label in mono font
```

**Reference implementation (illustrative):** a support desk's "SLA Bar" applies this primitive to the share of the response window already used, fill colored by the associated priority token — same markup, domain-specific label and data source.

### 5.8 Filter Toolbar

Horizontal bar with filter chips and dropdown selects:

- Chips: `padding: 6px 14px`, `border-radius: 99px`, `font-size: 12px`, `font-weight: 500`. Default: `border: 1px solid var(--border)`, `color: var(--text-muted)`. Active: `background: var(--accent-dim)`, `color: var(--accent)`, `border-color: var(--accent)`.
- Dropdowns: styled `<select>` elements with `appearance: none` and custom chevron via background SVG.
- Layout: `display: flex; gap: 8px; align-items: center; flex-wrap: wrap`.

### 5.9 Data Tables / Row Cards

For tabular data that needs more visual weight than a plain table:

- Each row is a card: `display: grid` with named columns.
- Rows have `border-bottom: 1px solid var(--border)` instead of full card borders (except first and last).
- Rows are clickable and expandable (same accordion pattern as cards).
- Status icons (checkmark, spinner, X) are 24×24 SVG with colored fills.
- Entire row is the click target (`cursor: pointer`), not an action column.

### 5.10 Skeleton / Loading Placeholder

Universal primitive. "Loading" is first among the six canonical UI states owned by `v-build/references/saas-patterns.md § UI state management checklist` (cite that file for the full state list — it is not restated here); this subsection is the missing visual spec for that state.

**Decidable trigger rule — skeleton vs. spinner vs. optimistic, keyed on expected latency and whether the final layout is known:**

| Signal | Use |
|---|---|
| Latency likely **> 300ms** AND the final shape is known in advance (a card grid, table rows, the hero-metrics bar) | **Skeleton** matching that shape (below). Delay showing it by 200ms so a fast response never flashes one. |
| Latency likely **> 300ms** AND the final shape is NOT known in advance (variable-length search results, first paint of an unfamiliar page) | **Spinner** — centered, `role="status"`, `aria-live="polite"`, labelled via `aria-label` or visually-hidden text. |
| Mutation is low-risk / near-certain to succeed (toggle, mark-read, reorder, star) | **Optimistic update** — render the end state immediately; reconcile silently on success, roll back + toast on failure. No loading indicator at all. |
| Latency likely **< 300ms** | **No indicator.** A skeleton or spinner that flashes under 300ms reads as jank, not feedback. |

**Shapes** (match the primitives they stand in for):

- `.skeleton--card` — same border-radius/padding footprint as the Card tier (§ 5.5): a title-width bar + 2–3 body-width bars.
- `.skeleton--row` — same `display: grid` column template as a Data Table row (§ 5.9): one skeleton bar per cell.
- `.skeleton--metric` — sized to the Hero Metrics Bar cell's label+value footprint (§ 5.3).

**Base CSS and shimmer** (respects `prefers-reduced-motion`):

```css
.skeleton {
  background: var(--border);
  border-radius: 4px;
  position: relative;
  overflow: hidden;
}

@media (prefers-reduced-motion: no-preference) {
  .skeleton::after {
    content: '';
    position: absolute; inset: 0;
    background: linear-gradient(90deg, transparent, var(--surface-elevated), transparent);
    animation: skeleton-shimmer 1.4s ease-in-out infinite;
  }
  @keyframes skeleton-shimmer {
    from { transform: translateX(-100%); }
    to   { transform: translateX(100%); }
  }
}
/* prefers-reduced-motion: reduce → static var(--border) fill, no ::after, no animation.
   The placeholder still communicates "loading" without motion. */
```

---

## 6. Navigation Patterns

### 6.1 Sidebar Navigation

See Section 4 for full specification. Key behavioral rules:

- Active link: highlighted with accent color + dim background. Only ONE link active at a time.
- Badge counts on nav links: use `--critical` dim for urgent counts, `--text-muted` for informational counts.
- Sidebar links navigate between full pages (not tabs within a page). Each page is a standalone HTML document (or route) with the same sidebar.
- The sidebar's optional secondary nav group (e.g. "Manage") holds 2–4 action shortcuts specific to the product's core workflows; each opens a modal or navigates. **Reference implementation (illustrative):** a support desk's Manage section — New Ticket, Import, Schedules, API.

### 6.2 Search Overlay (⌘K)

A full-screen overlay search dialog, triggered by:
- Clicking the sidebar search input (input blurs and opens overlay instead)
- Pressing `Cmd+K` / `Ctrl+K`

Structure:
```
┌─────────────────────────────────────┐
│  [Search input, 16px, full width]   │
├─────────────────────────────────────┤
│  [Type badge] Result text    [Meta] │
│  [Type badge] Result text    [Meta] │
│  [Type badge] Result text    [Meta] │
├─────────────────────────────────────┤
│  Press Esc to close · ⌘K to open   │
└─────────────────────────────────────┘
```

**Canonical mechanism: `popover="manual"`.** This is a centered, non-anchored overlay — it isn't positioned relative to a trigger element, so it needs `popover`'s top-layer/backdrop behavior but NOT anchor positioning (anchor positioning is for overlays anchored to a trigger — see § 6.3 Notification Dropdown).

```html
<div id="cmdk" popover="manual" aria-label="Search" role="dialog">
  <input type="text" placeholder="Search…" />
  <!-- results list -->
</div>
```

```js
const cmdk = document.getElementById('cmdk');
document.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
    e.preventDefault();
    cmdk.togglePopover();
  }
});
```

- Backdrop: the native `::backdrop` pseudo-element (`#cmdk::backdrop { background: rgb(0 0 0 / 0.6); backdrop-filter: blur(4px); }`) replaces the hand-rolled overlay div — no separate scrim element needed.
- Dialog: `560px` max-width, `var(--surface-elevated)` background, `border-radius: 12px`.
- Results: filtered live on input. Each result has a colored type badge (entity type — e.g. Project, or a product-specific equivalent) and meta text. **Reference implementation (illustrative):** a support desk's result types are Project, Ticket, Customer.
- `Escape` closes and click-outside closes automatically once a popover is open (`popover="manual"` still needs an explicit outside-click handler calling `.hidePopover()` — `"auto"` gets it for free, but `"manual"` is required here so the keyboard shortcut can toggle it without being tied to a `popovertarget` element). Results hidden when query is empty.
- **Focus-trap gap:** `popover` does not natively trap focus or mark the rest of the page `inert` (that's a `<dialog>.showModal()` behavior). Since § 9 Accessibility requires overlays to trap focus, pair the popover with either a small Tab/Shift+Tab focus-trap utility scoped to `#cmdk`, or set `inert` on the main-content/sidebar landmarks while the popover is open. Restore focus to the element that had it before the overlay opened, on close.
- **Fallback (no `popover` support):** feature-detect with `if (!("popover" in HTMLElement.prototype))`. Fallback path is the pre-2026 mechanism — a manually rendered overlay div (`position: fixed; inset: 0`) with hand-rolled `Escape`/click-outside handlers and a real focus trap. Keep this path tested; it is documented fallback, not dead code.

### 6.3 Notification Dropdown

- Triggered by bell icon in sidebar bottom bar.
- **Canonical mechanism: `popover="auto"` + CSS anchor positioning**, replacing the old manual `getBoundingClientRect()` calculation:

```html
<button id="bell-btn" popovertarget="notif-panel" aria-label="Notifications" style="anchor-name: --bell">🔔</button>
<div id="notif-panel" popover="auto" style="position-anchor: --bell">…</div>
```

```css
#notif-panel {
  position: fixed;                 /* prerequisite for position-anchor */
  position-anchor: --bell;
  position-area: block-end inline-end;      /* below and right-aligned to the bell */
  position-try-fallbacks: flip-inline, flip-block; /* auto-flips if it would clip past the sidebar/viewport edge */
  margin: 0; inset: auto;          /* reset the UA popover default (auto-centered) */
  width: 320px;
}
```

`position-try-fallbacks` is what used to be hand-computed: the old spec opened the panel "to the RIGHT of the sidebar to avoid clipping" via a one-off JS calculation. Anchor positioning's try-fallback list makes that a CSS declaration — it flips to whichever side actually fits, at every viewport size, without a resize listener.
- `popover="auto"` gets light-dismiss (click outside closes) and `Escape`-to-close for free — no hand-rolled listeners needed for those two behaviors.
- Width: 320px. Header: "Notifications" with bold text. Items: colored dot + message + relative timestamp.
- **Fallback (no `popover`/anchor-positioning support):** feature-detect with `@supports not (anchor-name: --a)` for styling and `if (!("popover" in HTMLElement.prototype))` for behavior. Fallback path is the pre-2026 mechanism: `position: fixed` set via JS from `getBoundingClientRect()` of the bell button, with hand-rolled click-outside/`Escape` handlers. Keep this path tested; it is documented fallback, not dead code.

**Z-index note:** an open `popover`/`<dialog>` renders in the browser's top layer, above every non-top-layer element regardless of z-index — it needs NO z-index tier assignment on the canonical path. The tiers this affects in `_v-design.md § Z-Index Layer Definitions` (Dropdowns/Popovers 20, Overlay backdrops 30, Modal/Dialog 40, Toast 50, Command palette 60) apply only to the documented manual-fallback implementation above; don't set them defensively on a `popover`-based component.

---

## 7. Data Visualization

### General Principles

- **No chart library dependency.** Simple visualizations (rings, bars, sparklines) are hand-rolled SVG/CSS. Complex interactive charts (bubble, area, time-series) may use a library but must respect the color tokens.
- **Axis labels**: 10px, mono font, muted color.
- **Grid lines**: `1px dashed var(--border)`.
- **Tooltips**: `var(--surface-elevated)` background, `var(--border)` border, `border-radius: 8px`, `box-shadow: var(--shadow-lg)`. Appear on hover, `pointer-events: none`. **Position via CSS anchor positioning** (`anchor-name` on the hovered element — a bubble, a bar segment — and `position-anchor` + `position-try-fallbacks` on the tooltip), NOT `getBoundingClientRect()` math. Anchor positioning is a positioning primitive independent of the Popover API — reveal/hide with a plain CSS `:hover`/`:focus-visible` opacity transition; the `popover` API's click/keyboard-oriented dismiss model doesn't suit a hover tooltip. Fallback (no anchor-positioning support): the pre-2026 JS-computed `position: fixed` + `getBoundingClientRect()` approach, feature-detected via `@supports not (anchor-name: --a)`.

### Chart Types Used

| Chart | Use Case | Implementation |
|-------|----------|---------------|
| SVG progress ring | Health/completion percentage | Inline SVG with `stroke-dashoffset` |
| Horizontal bar | SLA percentages, inline metrics | CSS width percentage |
| Bubble chart | Risk radar (2D: severity × probability) | Absolute-positioned circles in a container |
| Stacked area (SVG) | Trend over time, severity breakdown | SVG `<path>` with layered fills |
| Vertical bar chart | Resolution velocity by category | CSS or SVG bars |
| Vertical timeline | Event history | CSS with `::before` dot + connecting line |

### Bubble Chart Spec

- Container: relative positioned, fixed height (~280px).
- Y-axis: left side, labeled top-to-bottom (100% → 0%).
- X-axis: bottom, labeled with categories.
- Grid area: bordered left and bottom with `var(--border)`.
- Bubbles: absolute positioned, `border-radius: 50%`, sized by impact. Colored borders with translucent fills. Hover: `transform: scale(1.15)` with tooltip.

---

## 8. Interaction Patterns

### Theme Toggle

- Attribute: `data-theme="dark"` or `data-theme="light"` on `<html>`.
- Persistence: `localStorage.setItem('product-theme', theme)`. Read on page load before first paint to prevent flash.
- Icons: Moon (dark mode active) / Sun (light mode active). Swap via `style.display`.
- All themed properties transition over `250ms ease`.

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘K` / `Ctrl+K` | Toggle search overlay |
| `Escape` | Close any open overlay/dropdown |
| `Enter` / `Space` | Expand focused card |

### Hover & Focus States

- Cards: `border-color: var(--text-muted); box-shadow: var(--shadow)`. Optional `transform: translateY(-2px)` for grid cards.
- Buttons: border darkens or background shifts.
- Focus-visible: `outline: 2px solid var(--accent); outline-offset: 2px` on ALL interactive elements. No outline on click (`:focus-visible` only).
- Links inside overlays: `color: var(--accent); text-decoration: none`. Underline on hover.

### Parent-State Styling — `:has()`

Style a container from the state of its descendants, with no JS-toggled class:

```css
/* Card reacts to its own focused control — no onFocus handler needed */
.card:has(:focus-visible) {
  border-color: var(--accent);
  box-shadow: var(--shadow-lg);
}

/* Field wrapper reflects its input's validation state */
.field:has(input:invalid:not(:placeholder-shown)) {
  border-color: var(--critical);
}

/* Toolbar reveals "clear" only when a filter chip exists */
.filter-toolbar:has(.filter-chip) .filter-toolbar__clear { display: inline-flex; }
```

Use `:has()` to delete JS state that exists ONLY to toggle a parent class for styling
(`isFocused`, `hasError`, `hasActiveFilter`). Keep JS state the component logic actually reads.
**Support (Aug 2026):** Baseline across Chrome/Edge, Safari, Firefox — no fallback needed.

### Card Accordion

When a card is clicked:
1. All sibling cards in the same container collapse (remove `expanded` class).
2. Clicked card toggles `expanded`.
3. `aria-expanded` attribute updated.
4. If the click target is a link (`<a>`) inside the card, the link action takes priority — card does NOT toggle.

### Smooth Transitions

```css
/* Applied globally */
*, *::before, *::after {
  transition: background-color 250ms ease, color 250ms ease,
              border-color 250ms ease, box-shadow 250ms ease;
}

/* Card expand/collapse */
.card__details {
  transition: max-height 300ms ease, opacity 250ms ease 50ms,
              margin-top 200ms ease, padding-top 200ms ease;
}
```

### Page Transitions, Scroll Reveals & Enter Animations

All rules in this subsection are wrapped in `@media (prefers-reduced-motion: no-preference)` — under `reduce`, page/section changes are instant with no transition, exactly like the reduced-motion rule already in force above.

**Page transitions — `view-transition-name` on main content:**

```css
@media (prefers-reduced-motion: no-preference) {
  #main { view-transition-name: main-content; }
}
```

For an Inertia/SPA route change, wrap the DOM swap in `document.startViewTransition()`, feature-detected:

```js
function navigate(applyNewPage) {
  if (document.startViewTransition && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    document.startViewTransition(applyNewPage);
  } else {
    applyNewPage();
  }
}
```

For a classic server-rendered multi-page transition (no SPA router), the equivalent is the `@view-transition { navigation: auto; }` at-rule — no JS required. Pick the mechanism matching how the page actually navigates; don't add both.

**Scroll reveals — `animation-timeline: view()` with an IntersectionObserver fallback:**

```css
@media (prefers-reduced-motion: no-preference) {
  @supports (animation-timeline: view()) {
    .reveal-on-scroll {
      animation: reveal-fade-in linear both;
      animation-timeline: view();
      animation-range: entry 0% cover 30%;
    }
  }
}
@keyframes reveal-fade-in {
  from { opacity: 0; transform: translateY(12px); }
  to   { opacity: 1; transform: translateY(0); }
}
```

```js
// Fallback only when animation-timeline: view() is unsupported
if (!CSS.supports('animation-timeline', 'view()') &&
    !matchMedia('(prefers-reduced-motion: reduce)').matches) {
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => e.target.classList.toggle('is-visible', e.isIntersecting));
  }, { threshold: 0.3 });
  document.querySelectorAll('.reveal-on-scroll').forEach((el) => io.observe(el));
}
```

`.reveal-on-scroll` in the fallback path starts `opacity: 0; transform: translateY(12px)` and transitions to visible on `.is-visible` — same visual result as the native path, via `transition` instead of `animation-timeline`.

**Enter animations — `@starting-style` for popovers/dialogs entering the top layer:**

```css
@media (prefers-reduced-motion: no-preference) {
  [popover] {
    opacity: 0;
    transform: scale(0.96) translateY(-4px);
    transition: opacity 150ms ease, transform 150ms ease,
                overlay 150ms allow-discrete, display 150ms allow-discrete;
  }
  [popover]:popover-open {
    opacity: 1;
    transform: scale(1) translateY(0);
  }
  @starting-style {
    [popover]:popover-open {
      opacity: 0;
      transform: scale(0.96) translateY(-4px);
    }
  }
}
```

This is the standard pattern for animating a top-layer element's entry AND exit (`transition-behavior: allow-discrete` + `@starting-style`) — it replaces the old max-height/opacity expand pattern above for anything implemented as `popover`/`<dialog>` (§ 6.2, § 6.3); the card-accordion `.card__details` pattern above is unaffected since expandable cards aren't top-layer elements.

---

## 9. Accessibility

### Required

- **Skip navigation link**: First element in DOM. `position: absolute; top: -40px`, visible on focus. Links to `#main`.
- **ARIA roles**: `role="navigation"` on sidebar, `role="toolbar"` on filter bars, `role="dialog"` on modals/overlays, `role="button"` on clickable non-button elements (with `tabindex="0"`).
- **`aria-expanded`**: On all expandable cards, toggles between `"true"` / `"false"`.
- **`aria-pressed`**: On filter chips, toggles between `"true"` / `"false"`.
- **`aria-label`**: On icon-only buttons (theme toggle, notifications, settings, close buttons).
- **Reduced motion**: `@media (prefers-reduced-motion: reduce)` disables all transitions and animations — this now also gates view-transitions, scroll-driven reveals, `@starting-style` enter animations, and the skeleton shimmer (§ 8, § 5.10); none of those rules exist outside the `no-preference` branch.
- **Keyboard navigation**: All interactive elements reachable via Tab. Cards respond to Enter/Space. Overlays trap focus while open. `popover`-based overlays (§ 6.2, § 6.3) do NOT get this for free — `popover` provides top-layer stacking and light-dismiss, not focus trapping or `inert`-ing the background; pair every `popover` overlay with an explicit focus-trap utility or `inert` on the background landmarks (required in production, not implemented in static mockups).
- **Color contrast**: All text on backgrounds meets WCAG AA. Status colors on dim backgrounds pass. Muted text (`--text-muted` `oklch(64.3% 0.028 286)` on `--bg` `oklch(14.7% 0.011 285)`) = 5.8:1 ratio in dark (passes AA).
- **Semantic HTML**: `<main>`, `<aside>`, `<nav>`, `<section>`, `<footer>`, `<button>` used correctly. No `<div>` buttons.

---

## 10. Marketing / Public Pages

The marketing site shares the same typography and color token system but has a fundamentally different layout.

### Key Differences from Dashboard

| Aspect | Dashboard | Marketing Site |
|--------|-----------|----------------|
| Navigation | Fixed left sidebar | Fixed top navbar (transparent → solid on scroll) |
| Layout | Sidebar + content | Full-width, vertical sections |
| Information density | High (data-rich cards) | Low-medium (focused messaging) |
| Primary goal | Productivity | Conversion |
| Typography scale | Compact (12–22px) | Expressive (16–18px section body per the Overrides table below, 48–64px hero) |

### Marketing Page Structure

1. **Navbar**: Fixed top, transparent on hero, gains `var(--surface)` background + border on scroll. Logo left, nav links center, CTA button right.
2. **Hero section**: Large headline (48–64px, 700wt), subheadline (18–20px, 400wt, muted), primary CTA button, and an interactive product demo or screenshot.
3. **Social proof bar**: Logo strip or stat counters. Muted, understated.
4. **Feature sections**: Alternating layout (text left / visual right, then swap). Each section has a heading, body text, and a supporting visual (screenshot, animation, or code snippet).
5. **Interactive demo**: An embedded, functional preview of the product. Works without authentication. Shows real (or realistic mock) data.
6. **Pricing** (optional): Card-based tier comparison. Highlight recommended tier.
7. **Footer**: Minimal. Links, copyright, social icons.

### Marketing Typography Overrides

| Element | Size | Weight |
|---------|------|--------|
| Hero headline | 48–64px | 700 (Inter) — see Editorial Typography below for the serif-recipe weight when that option is used |
| Hero subheadline | 18–20px | 400 |
| Section headline | 32–40px | 700 |
| Section body | 16–18px | 400 |
| Nav links | 14px | 500 |
| CTA button | 15–16px | 600 |

Hero headline and Section headline are the two ranges ≥ 8px in this table — implement both as `clamp()` per § 2 Fluid Type Scale, not a discrete breakpoint jump. Hero subheadline and Section body are under the 8px threshold — discretionary, pick one value.

### Editorial Typography — The Differentiation Lever

`references/competitor-signals-2026.md § Distinctive` documents editorial typography (serif headlines, magazine-style layout) as present on only 1–2 of 15 surveyed B2B SaaS marketing sites — the highest-leverage differentiation signal in that file's own table. This spec previously locked marketing to Inter with a bare "may use a display font for the hero headline only." This subsection is that allowance made executable.

**Where it's allowed (decidable boundary):**

| Surface | Editorial serif | Rule |
|---|---|---|
| Marketing hero headline | Allowed | One instance per page |
| ONE marketing section lede/pull-quote per page (a thesis statement, a customer quote used as a section opener) | Allowed | Optional; maximum 2 editorial-serif instances total per marketing page (hero + one lede) |
| Every other section headline, all body copy, nav, CTA, footer, all marketing forms | **Inter, mandatory** | Not a per-project choice — editorial serif is a hero (+ optional lede) treatment, not a wholesale type-system swap. Most of the page stays grounded in the same system as the dashboard. |
| Dashboard / app UI | **Inter, mandatory, no exception** | Unchanged from § 2 Typography Rules |

**Family selection criteria** (a candidate must satisfy all four before it's used):

1. Variable font available (matches Inter's own performance rationale, § 2) — or ships in only the 1–2 static weights actually used.
2. Has a distinct-at-large-size personality — legible and clearly "not Inter" at 48px+. A serif indistinguishable from a sans at hero size defeats the point.
3. Open-license or a held license for the exact weights/subsets loaded — self-hosted with `font-display: swap`, subset to the Latin range actually used. No full-family download for a six-word headline.
4. Passes WCAG AA at hero size against `--bg` in BOTH themes (§ Color Contrast Requirements) — verify the specific weight/size combo chosen, not just the family in the abstract.

**Starting set** (pick ONE — this is a starting point to check against the criteria above, not a closed list, and not an invitation to audition all of them per project): `Fraunces`, `Newsreader`, `Source Serif 4`, `Instrument Serif` — all variable, open-license, and distinct at hero size.

**Weight / size / measure:**

- **Hero headline (serif):** weight 500–600. Editorial serif families read visually heavier than a sans at the same numeric weight — 500–600 in the chosen serif approximates Inter 700's visual weight at hero size; don't default to 700 in the serif without checking. Size: the same `clamp(3rem, 1.25rem + 4vw, 4rem)` derived above. Line-height 1.05–1.15 (tighter than body — an editorial convention). Measure: cap at ~20–24 characters per line; enforce structurally with `text-wrap: balance` (§ 2) rather than hand-tuned line breaks.
- **Section lede (serif, optional):** weight 400–500. Size: one step below the Section headline clamp, or that clamp itself if the lede functions as the section's headline. Measure: cap at ~60–75 characters (`max-width: 60ch` to `70ch` on the lede container) — the classic body-copy readability ceiling. Any supporting copy beneath the lede returns to Inter.
- **Everything else on the page:** Inter, per the table above — unchanged.

**Enforcement:** `_v-design.md § Spec-Deviation Detection Table`'s "Non-canonical font family" check flags anything outside Inter/JetBrains Mono; its exception is exactly this recipe (hero + ≤1 lede, marketing-context only, family passing the four criteria) — not an open license to add fonts freely.

### Marketing Spacing Extension

Marketing pages use a section-level rhythm ABOVE the app xs–2xl scale — this
is the sanctioned divergence (mirrored in `_v-design.md § Context Sensitivity
Matrix`); component-internal spacing (inside cards, buttons, forms) stays on
the app scale:

| Use | Value |
|-----|-------|
| Hero vertical padding | 120px |
| Section vertical padding | 80px |
| Section gap | 80px |
| Card grid gap (pricing/feature cards) | 32px |

Below 700px these reduce ~40–50% (hero ~64px, sections ~48px), matching the
app spec's responsive outer-spacing rule.

### Marketing CTA Buttons

Larger than dashboard buttons: `padding: 12px 28px`, `border-radius: 10px`, `font-size: 15–16px`, `font-weight: 600`. Primary: filled accent. Secondary: ghost/outline.

---

## 11. Responsive Strategy

### Breakpoints

| Breakpoint | Target | Layout Changes |
|------------|--------|----------------|
| `> 1100px` | Desktop | Full grid layouts |
| `900–1100px` | Small desktop / tablet landscape | 4-col → 2-col grids |
| `700–900px` | Tablet portrait | Sidebar collapses off-screen behind hamburger. Main content goes full-width. |
| `< 700px` | Mobile | Hero metrics 2-col. All grids 1-col. Page header stacks vertically. Filter bars wrap. |

The numbers in this table are the single source of truth for both mechanisms below it (§ 4 Container Queries): sidebar collapse (900px), marketing navbar/hamburger behavior, and outer/global spacing reduction are true `@media` viewport queries — genuinely viewport-driven events. Grid collapse (hero metrics, card grid, kanban, dual panels — the "2-col"/"1-col" layout changes in the table above) is implemented as `@container` on the main-content wrapper at the identical 700px/1100px thresholds, because those grids' available width depends on the sidebar, not the viewport. When the sidebar collapses at ≤900px, main-content's container width and the viewport width converge, so both mechanisms agree at the extremes — they only diverge (correctly) at desktop widths where the sidebar is present.

### Sidebar Mobile Behavior

At `≤ 900px`:
- Sidebar: `transform: translateX(-100%)` (hidden). Add `transition: transform 250ms ease`.
- Hamburger button: `position: fixed; top: 12px; left: 12px; z-index: 200`. Shows a 3-line icon. 40×40px, `var(--surface)` background, rounded.
- Overlay: `position: fixed; inset: 0; background: rgba(0,0,0,0.5); backdrop-filter: blur(2px)`. Click to close.
- When open: sidebar gets `.open` class → `transform: translateX(0)`.
- Main content: `margin-left: 0; padding: 60px 20px 40px` (top padding accounts for hamburger).

### Marketing Mobile Behavior

- Navbar: hamburger menu for nav links. CTA button always visible.
- Hero: headline scales down. Demo collapses below text.
- Feature sections: stack vertically (no alternating).
- All images: `max-width: 100%`.

---

## 12. File & Naming Conventions

### Cascade Layers (`@layer`)

Tailwind v4's `@import "tailwindcss";` already declares `@layer theme, base, components, utilities;`.
Project component CSS slots into that order rather than fighting it:

```css
@import "tailwindcss";

@layer components {
  .card { /* losing cleanly to a utility override is CORRECT, not a bug */ }
}
```

- Author project component classes inside `@layer components` so a utility on the same element
  always wins predictably — that ordering is the point, not a defect to route around.
- **Never** ship an un-layered override to win a specificity fight: an un-layered rule outranks
  every `@layer`, silently defeating the order Tailwind v4 set up. Same reasoning as the
  no-`!important` rule — if you need one, the layer is wrong, not the specificity.
- **Support (Aug 2026):** Baseline across Chrome/Edge, Safari, Firefox since 2022 — no fallback.

### CSS Custom Properties

```
--bg, --surface, --surface-elevated      (backgrounds)
--text, --text-muted                     (foregrounds)
--border                                 (borders & dividers)
--accent, --accent-dim                   (primary brand color)
--critical, --critical-dim               (red status)
--high, --high-dim                       (orange status)
--medium, --medium-dim                   (yellow status)
--resolved, --resolved-dim               (green status)
--info, --info-dim                       (blue informational)
--shadow, --shadow-lg                    (elevation)
--sidebar-w                              (sidebar width)
--[category]-bg, --[category]-text       (product-specific category colors)
```

Token NAMES are unchanged from prior versions of this spec — every consumer using `var(--critical-dim)` etc. keeps working. What changed (§ 3) is that each `-dim`/`-bg` value is now a `color-mix()` DERIVATION from its base token wrapped in `light-dark()`, not two hand-authored values — same surface, computed value.

### CSS Class Naming (BEM-like)

```
.component                     → block
.component__element            → element within block
.component__element--modifier  → variant
.component.active              → state class (not BEM modifier)
```

Examples: `.sidebar__link`, `.sidebar__link-badge--critical`, `.ticket-card.expanded`, `.hero-metric--critical`.

### HTML Conventions

- One `<aside>` for the sidebar.
- One `<main>` for page content with `id="main"`.
- `<section>` for each content zone within main.
- `data-*` attributes for JS hooks and filter terms (not classes).
- All SVG icons inline (no icon font, no external sprite). Standard viewBox: `0 0 24 24` (Lucide-compatible) or `0 0 18 18` for nav icons. Icons use `stroke="currentColor"` (or `fill="currentColor"` for filled glyphs) so they inherit the text token — never hardcoded hex inside icon SVGs.

---

## 13. Implementation Checklist

When building a new SaaS product from this spec:

1. **Set up CSS variables** — Copy the `:root` `color-scheme`/`light-dark()` token block (§ 3) and the `html[data-theme]` overrides. Customize `--accent` (as an `oklch()` value) and category colors following the same `color-mix()` derivation pattern.
2. **Load fonts** — Google Fonts link for Inter (400–700) and JetBrains Mono (400–500). If using the editorial-typography lever (§ 10), self-host the chosen serif with `font-display: swap`, subset to the weights actually used.
3. **Build sidebar** — Copy the full sidebar component (HTML + CSS + JS). Update logo, nav links, and manage section for your product.
4. **Add theme toggle** — Copy the toggle JS (localStorage read, `data-theme` swap, icon swap).
5. **Add overlays** — Build the ⌘K search overlay (`popover="manual"`, § 6.2) and any dropdowns (`popover="auto"` + anchor positioning, § 6.3) on the canonical mechanism, with the documented manual-fallback path feature-detected and tested. Populate search results with your product's entities.
6. **Build page template** — Page header + hero metrics + section header + content grid, with `container-type: inline-size` on the main-content wrapper (§ 4) so grid collapse is a container query. Adjust grid columns for your data.
7. **Build cards** — Use the 3-tier card system (panel → card → nested detail). Add expand/collapse if needed.
8. **Add filter toolbar** — Chips + dropdowns, styled per spec.
9. **Add loading states** — Skeletons matching the shapes you built in steps 6–7 (§ 5.10), applying the skeleton/spinner/optimistic decision rule. Don't improvise a new loading pattern per page.
10. **Verify accessibility** — Skip nav, ARIA attributes, keyboard navigation, reduced motion (including the new view-transition/scroll-reveal/`@starting-style`/shimmer rules, § 8, § 5.10), color contrast, and explicit focus-trapping on every `popover` overlay (§ 9).
11. **Test responsive** — Sidebar collapse at 900px (viewport query), grid collapse at 1100px/700px (container query, § 4), fluid type scaling between the two (§ 2).
12. **Test both themes** — Dark and light. Verify every component in both, including `light-dark()` resolution and status-color dim derivations.
13. **Marketing site** — Switch to top navbar layout. Scale up typography (fluid `clamp()` per § 2/§ 10). Add hero, features, demo, pricing sections. Decide whether this product uses the editorial-typography lever (§ 10) before writing hero copy — it changes the hero's markup.
