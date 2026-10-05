# UX Audit Checklists — v-polish

_Last reviewed: 2026-07-06 (theme-consistency sweep B: security/performance/UI-states alignment; prev design-language consistency pass)_

Detailed audit checklists, grep patterns, and fix templates for all 21 UX dimensions.
Read this file when executing the UX delight audit (Part 1).

---

## Part 1: UX Delight Audit

### 1.1 Micro-Interactions

```bash
# Find buttons/interactive elements
grep -rn "Button\|onClick" resources/js/Components --include="*.tsx" | head -20

# Check for active/hover states
grep -rn "active:scale\|hover:bg\|transition" resources/js/Components/ui/button.tsx
```

**Checklist:**
| Element | Expected | Check |
|---------|----------|-------|
| Buttons | `hover:bg-*` + `active:scale-[0.98]` | [ ] |
| Links | Hover underline or color | [ ] |
| Inputs | Focus ring | [ ] |
| Toggles | Animate on change | [ ] |
| Cards | Hover shadow (if clickable) | [ ] |

**Optimistic UI:**
| Pattern | Expected | Check |
|---------|----------|-------|
| Form submissions | Show success state immediately, revert on error | [ ] |
| List operations (add/remove/reorder) | Reflect locally before server confirmation | [ ] |
| Optimistic rollback | Clear visual rollback on failure (toast + undo) | [ ] |

```bash
# Find mutation patterns without optimistic updates
grep -rn "await.*mutate\|\.post(\|\.put(\|\.delete(" resources/js --include="*.tsx" | head -15

# Find Inertia router calls (fire-and-forget — good candidates for optimistic UI)
grep -rn "router\.post\|router\.put\|router\.delete" resources/js --include="*.tsx" | head -15
```

### 1.2 Success Celebrations

```bash
# Find success patterns
grep -rn "success\|Success\|created" resources/js --include="*.tsx" | head -15

# Find first-time patterns
grep -rn "first\|onboard\|welcome" resources/js --include="*.tsx" | head -10
```

**Checklist:**
| Scenario | Expected | Check |
|----------|----------|-------|
| First achievement | Celebration on consumer-facing surfaces (confetti/animation); internal/admin tools get a success toast, not confetti — restraint per v-audit-code's UX-craft lens ("gratuitous animation, novelty over usefulness") | [ ] |
| Successful actions | Toast notification | [ ] |
| Milestones | Acknowledgment message | [ ] |
| Form submissions | Success state | [ ] |

### 1.3 Loading States

```bash
# Find loading patterns
grep -rn "isLoading\|loading\|Spinner\|Skeleton" resources/js/Pages --include="*.tsx" | head -15
```

**Rule:** Skeleton for content, Spinner for actions

| Scenario | Use |
|----------|-----|
| Table/list loading | Skeleton rows |
| Card content | Skeleton |
| Button action pending | Spinner + text |
| Background refresh | Subtle fade |

**Skeleton Loading Best Practices:**
| Check | Expected | Status |
|-------|----------|--------|
| Skeleton dimensions | Match final layout dimensions of content | [ ] |
| Skeleton vs spinner | Skeletons used for content with known shape, spinners for unknown | [ ] |
| Shimmer animation | Uses CSS (`@keyframes shimmer` + `background` gradient), not JS | [ ] |

```bash
# Find loading states that use spinners where skeletons would be better
grep -rn "Spinner\|CircularProgress\|loading-spinner" resources/js/Pages --include="*.tsx" | head -10

# Check skeleton shimmer uses CSS animation
grep -rn "Skeleton" resources/js/Components --include="*.tsx" -A5 | grep -E "setInterval\|requestAnimationFrame" | head -5
```

### 1.4 Empty States

```bash
# Find list views without empty states — CANDIDATE LIST ONLY: single-line greps
# false-flag multi-line JSX (v-check audit-domains-extended § multi-line JSX warning);
# confirm each hit at block level BEFORE any safe_auto_fix edit.
grep -rn "\.map\|\.length === 0" resources/js/Pages --include="*.tsx" | head -15

# Check for naked "No data"
grep -rn '"No "\|"None"\|"Nothing"' resources/js/Pages --include="*.tsx" | head -10
```

**Required:**
- [ ] All list views have empty state
- [ ] Icon or illustration
- [ ] Clear CTA ("Create your first...")
- [ ] Helpful copy

### 1.5 Animations & Transitions

```bash
# Check modal/dialog animations
grep -rn "animate-in\|animate-out\|data-\[state=" resources/js/Components/ui --include="*.tsx"

# Check for View Transitions API usage
grep -rn "view-transition-name\|startViewTransition\|::view-transition" resources/js --include="*.tsx" --include="*.css" --include="*.scss" | head -10

# Check for scroll-driven animations
grep -rn "animation-timeline\|scroll()\|view()" resources/js --include="*.css" --include="*.scss" --include="*.tsx" | head -10

# Find JS scroll listeners that could use scroll-driven animations instead
grep -rn "addEventListener.*scroll\|onScroll\|useScroll" resources/js --include="*.tsx" --include="*.ts" | head -10
```

**Required animations:**
| Component | Animation |
|-----------|-----------|
| Modal/Dialog | fade-in + zoom-in-95 |
| Dropdown | fade-in + zoom-in-95 |
| Toast | slide-in-from-right |
| Accordion | transition-all |

**View Transitions API:**
| Check | Expected | Status |
|-------|----------|--------|
| Page navigations | Use CSS View Transitions for smooth cross-page animation | [ ] |
| Persistent elements (nav, hero images) | `view-transition-name` assigned | [ ] |
| Browser fallback | Progressive enhancement — works without View Transitions support | [ ] |

**Scroll-Driven Animations:**
| Check | Expected | Status |
|-------|----------|--------|
| Reading progress indicators | Use `animation-timeline: scroll()` instead of JS | [ ] |
| Parallax effects | Use scroll-driven animations, not JS scroll listeners | [ ] |
| Section reveal animations | Triggered by `animation-timeline: view()` | [ ] |

### 1.6 Smart Defaults

```bash
# Check timezone/theme detection
grep -rn "timezone\|prefers-color-scheme" resources/js --include="*.tsx"
```

**Checklist:**
- [ ] Timezone auto-detected
- [ ] Theme: `prefers-color-scheme` may PRE-SEED the initial `data-theme` before first paint only — the switch itself is `html[data-theme]` token switching, never a media-query-only strategy (`_v-design.md § Canonical Token Set`)
- [ ] Forms remember previous values
- [ ] Recently used items prioritized

### 1.7 Accessibility (Required)

```bash
# Find focus ring issues (missing or browser default showing through)
grep -rn "focus:ring-0" resources/js/Components --include="*.tsx" | head -10

# Find status colors not resolving to canonical tokens (raw palette classes
# should be bound to --resolved/--critical/--info etc.; light values come from
# the [data-theme="light"] override, not a per-element dark: twin)
grep -rn "text-\(green\|red\|blue\|amber\)-[567]00" resources/js --include="*.tsx"

# Find buttons without aria labels — candidates only: print the FULL block context and
# READ each element (the label often sits on a later line; do NOT pipe through a -v line
# filter — it deletes the exculpatory aria-label line while the <Button match survives,
# which is the exact false-flag class in v-check audit-domains-extended § multi-line JSX
# warning). Confirm each block BEFORE any safe_auto_fix edit; never add a redundant
# aria-label from a raw hit.
grep -rnE -A3 -B1 "<Button" resources/js --include="*.tsx"
```

**Checklist:**
| Check | Target | Tool |
|-------|--------|------|
| Focus rings visible | All interactive elements | Manual + grep |
| Color contrast | WCAG AA per `_v-design.md § Color Contrast Requirements` (4.5:1 body; 3:1 large text ≥24px/≥18.66px-bold and UI components) | WebAIM checker |
| Touch targets | ≥24×24px floor (WCAG 2.2 AA 2.5.8); ≥44px primary/mobile best-practice (`_v-design.md § Interactive Target Size`) | Manual |
| Keyboard navigation | Tab order logical | Manual test |
| Screen reader | Announces correctly | VoiceOver/NVDA |
| Reduced motion | All decorative animations respect `prefers-reduced-motion` | grep + manual |

**`prefers-reduced-motion` Compliance:**

All CSS animations and transitions must respect user motion preferences. Essential motion (progress indicators, state changes) is still allowed but should be simplified.

| Check | Expected | Status |
|-------|----------|--------|
| Decorative animations | Wrapped in `@media (prefers-reduced-motion: no-preference)` or reduced via `@media (prefers-reduced-motion: reduce)` | [ ] |
| View Transitions | Disabled when reduced motion preferred | [ ] |
| Scroll-driven animations | Disabled when reduced motion preferred | [ ] |
| Essential motion (progress bars, state changes) | Still present but simplified (e.g., instant instead of animated) | [ ] |

```bash
# Find animations/transitions NOT guarded by prefers-reduced-motion
grep -rn "animation\|transition\|@keyframes" --include="*.css" --include="*.scss" --include="*.tsx" resources/js | grep -v "prefers-reduced-motion" | head -20

# Check if prefers-reduced-motion media query exists at all
grep -rn "prefers-reduced-motion" resources/js --include="*.css" --include="*.scss" --include="*.tsx" | head -10
```

**Output format:**
```markdown
### A11Y-001: Missing focus ring on Command input
file: resources/js/Components/ui/command.tsx:45
type: accessibility/focus
confidence: high
effort: 5 min
fix: |
  Add the canonical focus indicator (spec §5.2): `outline: 2px solid
  var(--accent); outline-offset: 2px` on `:focus-visible` (or the
  project utility bound to it) — never a generic `ring-ring` default
  Suppress browser default with `focus:ring-0 focus-visible:ring-0`
  only when the canonical outline replaces it
```

### 1.8 Dark Mode Verification (Required)

Theming is `html[data-theme]` token switching ONLY — the check is "does the
color resolve to a canonical token", not "is there a `dark:` twin". Light
values come from the `[data-theme="light"]` override, never from per-element
dark-mode classes.

**For EVERY UI change, verify:**
- [ ] Light mode (`[data-theme="light"]`) looks correct
- [ ] Dark mode (`:root` values) looks correct
- [ ] No hardcoded colors (every value resolves to a canonical token)
- [ ] Contrast ratios meet WCAG AA in both themes

**Common issues:**
| Issue | Fix |
|-------|-----|
| `text-green-600` hardcoded status color | Bind to the fixed status token: `var(--resolved)` (light value via `[data-theme="light"]`) |
| Browser focus ring visible where a canonical replacement exists | Add the canonical `:focus-visible` outline first (spec §5.2), THEN `focus:ring-0 focus-visible:ring-0` to suppress the default — NEVER suppress without a visible replacement (WCAG 2.4.7 AA fail; deep-ux-audit + dispatch-ux-critique heuristic 7 flag bare suppression) |
| White background hardcoded | Use the utility bound to `var(--surface)`, not `bg-white` |
| Hardcoded border colors | Use the utility bound to `var(--border)`, not `border-gray-200` |

```bash
# Find hardcoded colors not resolving to canonical tokens (flag regardless of
# any dark: twin — per-element dark: is not the theming strategy)
# Exemptions (per _v-design.md § Visual Craft Gate): print-targeted/shared-view pages advisory;
# one grandfathered settings-page bg-white — do not re-flag.
grep -rn "bg-white\|bg-gray-\|border-gray-" resources/js --include="*.tsx"
```

### 1.9 Mobile Responsiveness

**Viewport checklist** (test viewports straddling the canonical 700/900/1100
breakpoints — these are screenshot widths, not grid breakpoints):
| Viewport | Width | Check |
|----------|-------|-------|
| Mobile | 390px | No horizontal scroll; touch targets ≥24px floor / ≥44px primary (per `_v-design.md § Interactive Target Size`); outer spacing reduced ~40–50% vs desktop (`_v-design.md § Responsive Spacing Adaptation`) |
| Single-column boundary | 700px | Content collapses to single column at ≤700px |
| Sidebar boundary | 900px | Sidebar collapses behind hamburger at ≤900px |
| Grid boundary | 1100px | Content grids collapse at ≤1100px |
| Desktop | 1440px | Full layout, no wasted space |

**Common issues:**
```bash
# Find tables without responsive wrapper
grep -rn "<Table" resources/js/Pages --include="*.tsx" | grep -v "overflow"

# Find fixed widths that may break mobile
grep -rn "w-\[.*px\]" resources/js --include="*.tsx" | head -10
```

**Required responsive patterns:**
- [ ] Tables have horizontal scroll wrapper on mobile
- [ ] Forms stack vertically on mobile
- [ ] Navigation collapses to hamburger/drawer
- [ ] Modals are full-screen on mobile

### 1.10 Frontend Consistency

Code-level consistency issues that affect developer experience and maintainability.

```bash
# Find raw date/number formatting bypassing centralized helpers
grep -rn "toLocaleString\|toLocaleDateString\|toFixed\|Intl.NumberFormat" resources/js --include="*.tsx" | head -15

# Find inconsistent import quote styles
grep -rn "^import" resources/js --include="*.tsx" | head -20

# Find inline styles that should be utility classes
grep -rn 'style={{' resources/js --include="*.tsx" | head -10
```

**Checklist:**
| Issue | Check |
|-------|-------|
| Date/number formatting uses centralized helpers | [ ] |
| Import quote style consistent (single vs double) | [ ] |
| Import group ordering consistent (third-party, local, types) | [ ] |
| No static inline styles that could be utility classes | [ ] |
| Component prop naming consistent (`onClose` vs `onDismiss`) | [ ] |
| Toast/flash message capitalization and punctuation consistent | [ ] |
| Empty state message phrasing consistent | [ ] |

**Fix templates:**
```markdown
### POLISH-0XX: Inconsistent date formatting
file: resources/js/Pages/Example.tsx:42
type: consistency/formatting
confidence: high
effort: 10 min
fix: |
  Replace `new Date(date).toLocaleDateString()` with centralized helper:
  `import { formatDate } from '@/lib/format'; formatDate(date)`
```

### 1.11 Backend Consistency

```bash
# Find JSON columns missing 'json' cast
grep -rn "'json'" app/Models --include="*.php" | head -10

# Find bare Exception catches
grep -rn "catch (\\\Exception\|catch (Exception" app --include="*.php" | head -10

# Find missing explicit const visibility
grep -rn "^\s*const " app --include="*.php" | grep -v "public\|private\|protected" | head -10

# Find mixed validation rule syntax (pipe vs array)
grep -rn "'required|" app/Http/Requests --include="*.php" | head -5
grep -rn "\['required'" app/Http/Requests --include="*.php" | head -5

# Find date columns missing datetime cast
grep -rn "protected \$casts" app/Models --include="*.php" -A20 | grep -v "datetime\|date" | head -10

# Find services returning mixed types
grep -rn "return \[" app/Services --include="*.php" | head -10
grep -rn "return collect(" app/Services --include="*.php" | head -10
```

**Checklist:**
| Issue | Check |
|-------|-------|
| All JSON columns have `'json'` cast | [ ] |
| All date columns have `'datetime'` cast | [ ] |
| All enum columns cast to enum class | [ ] |
| No bare `catch (Exception)` — use specific types | [ ] |
| Service return types consistent (no mixed array/Collection) | [ ] |
| Constants have explicit visibility modifiers | [ ] |
| Validation rules use consistent syntax (pipe or array) | [ ] |
| Columns in WHERE/ORDER BY/JOIN have indexes | [ ] |

**Fix templates:**
```markdown
### POLISH-0XX: JSON column missing cast
file: app/Models/Example.php:15
type: consistency/model-cast
confidence: high
effort: 5 min
fix: |
  Add to $casts array:
  `'metadata' => 'json',`
```

### 1.12 Developer Experience (DX)

```bash
# Check for missing convenience scripts
cat package.json | grep -A2 '"scripts"'
cat composer.json | grep -A2 '"scripts"'

# Check for .editorconfig
ls -la .editorconfig 2>/dev/null || echo "MISSING"

# Check for .gitattributes
ls -la .gitattributes 2>/dev/null || echo "MISSING"

# Check .env.example completeness
diff <(grep -oE '^[A-Z_]+=' .env.example | sort) <(grep -roE "env\(['\"][A-Z_]+" config --include="*.php" | grep -oE '[A-Z_]+$' | sort -u) 2>/dev/null | head -20
```

**Checklist:**
| Issue | Check |
|-------|-------|
| `typecheck` / `lint:fix` / `test:watch` / `preflight` scripts exist | [ ] |
| `.editorconfig` present and matches project conventions | [ ] |
| `.gitattributes` handles line ending normalization | [ ] |
| All env vars from config files documented in `.env.example` | [ ] |
| Seeder produces useful local dev data | [ ] |
| Non-obvious config choices have comments explaining "why" | [ ] |

**Fix templates:**
```markdown
### POLISH-0XX: Missing typecheck script
file: package.json
type: dx/convenience
confidence: high
effort: 2 min
fix: |
  Add to scripts:
  `"typecheck": "tsc --noEmit",`
  `"preflight": "./vendor/bin/pest --parallel --processes=4 && npm run build && npm run lint && npx tsc --noEmit"`
```

### 1.13 Infrastructure Polish

```bash
# Check CI timeout settings
grep -rn "timeout" .github/workflows --include="*.yml" | head -5

# Check CI artifact upload conditions
grep -rn "if:.*always\|if:.*failure" .github/workflows --include="*.yml" | head -5

# Check sourcemap control in production build
grep -rn "sourcemap\|source-map\|devtool" vite.config* webpack.config* 2>/dev/null | head -5
```

**Checklist:**
| Issue | Check |
|-------|-------|
| CI jobs have timeout limits | [ ] |
| Coverage/test artifacts upload on `always()` or `failure()` | [ ] |
| Expensive CI steps use caching (browser binaries, large packages) | [ ] |
| Production build controls sourcemap generation | [ ] |
| Deploy script validates beyond homepage (DB, cache, queue) | [ ] |

**Fix templates:**
```markdown
### POLISH-0XX: CI job missing timeout
file: .github/workflows/ci.yml:15
type: infra/ci
confidence: high
effort: 2 min
fix: |
  Add to job:
  `timeout-minutes: 15`
```

### 1.14 Naming & Copy Consistency

```bash
# Check log event naming patterns
grep -rn "Log::" app --include="*.php" | head -15

# Check boolean variable naming
grep -rn "const \[.*\] = useState" resources/js --include="*.tsx" | head -15

# Check for user-facing error messages with technical jargon
grep -rn "Exception\|Stack trace\|SQL\|SQLSTATE" resources/js --include="*.tsx" | head -10

# Check case convention consistency
grep -rn "const [a-z].*_[a-z]" resources/js --include="*.tsx" | head -5
```

**Checklist:**
| Issue | Check |
|-------|-------|
| Log event naming follows consistent pattern | [ ] |
| Error messages avoid technical jargon for end users | [ ] |
| Boolean variables use `is`/`has`/`can` prefix | [ ] |
| No camelCase/snake_case mixing within same language | [ ] |

**Fix templates:**
```markdown
### POLISH-0XX: Technical jargon in user-facing error
file: resources/js/Pages/Example.tsx:85
type: copy/jargon
confidence: high
effort: 5 min
fix: |
  Replace `"SQLSTATE error occurred"` with
  `"Something went wrong. Please try again or contact support."`
```

### 1.15 Documentation Gaps (Light)

Not a full docs audit — just fit-and-finish items.

```bash
# Count stale TODOs
grep -rn "TODO\|FIXME\|HACK\|XXX" app resources/js --include="*.php" --include="*.tsx" --include="*.ts" | wc -l

# Check for CONTRIBUTING.md
test -f CONTRIBUTING.md && echo "EXISTS" || echo "MISSING"

# Check formatter config enforced
test -f .prettierrc -o -f prettier.config.js && echo "Prettier configured" || echo "No Prettier config"
ls .php-cs-fixer.php vendor/bin/pint 2>/dev/null && echo "PHP formatter configured"
```

**Checklist:**
| Issue | Check |
|-------|-------|
| CONTRIBUTING.md exists (or dev setup in README) | [ ] |
| Zero TODO/FIXME in session-changed files (gate-blocking: banned by pre-flight Gates 4/6 + CLAUDE.md "never leave TODO/FIXME/HACK in delivered code"); whole-repo stale count <20 is a separate legacy-debt advisory trend only | [ ] |
| Formatter config exists and is enforced | [ ] |

### 1.16 Test Polish (Light)

Not coverage gaps — just consistency items.

```bash
# Check test naming patterns
grep -rn "it('\|test('\|it(\"" tests --include="*.php" --include="*.tsx" --include="*.ts" | head -15

# Check for co-located vs separate test files
ls tests/ resources/js/**/*.test.* 2>/dev/null | head -10

# Check for stale snapshots
find tests resources/js -name "*.snap" -mtime +90 2>/dev/null | head -5

# Check test description consistency
grep -rn "it('" tests --include="*.php" | head -5
grep -rn "it(\"" tests --include="*.php" | head -5
# If both styles exist, flag inconsistency
```

**Checklist:**
| Issue | Check |
|-------|-------|
| Test descriptions follow consistent pattern | [ ] |
| Test file organization consistent (co-located or separate tree) | [ ] |
| No stale snapshots or fixtures with outdated data | [ ] |

**Fix templates:**
```markdown
### POLISH-0XX: Inconsistent test description style
file: tests/Feature/ExampleTest.php:12
type: test/naming
confidence: medium
effort: 10 min
fix: |
  Standardize on the project's dominant style. If most tests use:
  `it('does something', ...)` then convert `it("does something", ...)` to match.
```

### 1.17 Visual Craft (Spec-Conformance Detection)

**Prerequisite:** Canonical token set per `_v-design.md` § Design System Application Order (the spec is the design system for all products; `.interface-design/system.md` is the per-product overlay only).

#### Grep Patterns

```bash
# Token compliance — hardcoded hex in components
grep -rn '#[0-9a-fA-F]\{6\}' resources/js/Pages resources/js/Components --include="*.tsx" | grep -v "\.test\." | head -15

# Non-canonical elevation — shadows beyond --shadow/--shadow-lg, heavy 2px+ borders
# (spec pairs 1px var(--border) with the two shadow tokens; anything else = flag)
grep -rn "shadow-xl\|shadow-2xl" resources/js --include="*.tsx" | head -10
grep -rn "border-2\|border-\[" resources/js --include="*.tsx" | head -10

# Glassmorphism in app UI (not marketing, not overlay backdrops)
grep -rn "backdrop-filter\|backdrop-blur" resources/js/Pages --include="*.tsx" | head -5

# Gradient text in app UI
grep -rn "bg-gradient.*bg-clip-text\|background-clip.*text" resources/js/Pages --include="*.tsx" | head -5

# Arbitrary z-index outside the layer system (_v-design.md § Z-Index Layer Definitions)
grep -rn 'z-\[' resources/js --include="*.tsx" | grep -v "z-\[10\]\|z-\[20\]\|z-\[30\]\|z-\[40\]\|z-\[50\]\|z-\[60\]\|z-\[100\]\|z-\[200\]" | head -10

# Non-semantic colors (raw palette instead of canonical tokens — flag regardless of dark: twins)
# Exemptions (per _v-design.md § Visual Craft Gate): print-targeted components and
# shared-view pages are advisory-only; one grandfathered settings-page bg-white is exempt.
grep -rn "bg-white\|bg-gray-[1-9]\|text-gray-[1-9]" resources/js/Pages --include="*.tsx" | head -15
```

#### Fix Templates

| Finding | Safe Auto-Fix |
|---------|--------------|
| `bg-white` without semantic token | -> utility bound to `var(--surface)` (light value from `[data-theme="light"]`) |
| `text-gray-600` without semantic | -> utility bound to `var(--text-muted)` |
| `border-gray-200` without semantic | -> utility bound to `var(--border)` |
| Hardcoded `#3b82f6` | -> `var(--info)` (or `var(--accent)` if it's the brand action color) |
| Shadows beyond `--shadow`/`--shadow-lg` (`shadow-xl`, ad-hoc values) | -> flag; replace with `1px var(--border)` border + `box-shadow: var(--shadow)` on hover (`--shadow-lg` for overlays only) |

#### Component Conformance Check (manual inspection)

Uniformity across cards/grids is spec-MANDATED — never flag identical layouts as such. Instead, when 3+ cards/metrics/list items are generated:
- Do cards sit on the spec's 3-tier system (panel `var(--surface)` → card `var(--surface-elevated)` → nested top-border detail)? -> Off-tier cards: flag
- Do section headers follow the spec pattern (UPPERCASE 13px/600/1px-tracking with thin-rule `::after`)? -> Off-pattern headers: flag
- Do metric rows follow the hero-metrics bar pattern (one joined card, internal 1px dividers)? -> Ad-hoc metric layouts: flag
- Are grid gaps 14px with collapse at 1100/700px? -> Off-spec grid values: flag

### 1.18 Error & Validation Feedback

Detection + fixes for how the UI communicates failure and guides recovery (`.tsx`/`.jsx`).
- **Error toasts:** styled with the semantic error token, an icon, a sensible position, and a dismiss affordance — success/info toasts may auto-dismiss (≥5s); mutation/payment/data-loss error toasts must persist until acknowledged (no auto-dismiss, per deep-ux-audit.md § Async/loading depth). Grep: `rg -n -g '*.tsx' -g '*.jsx' 'toast\.error|toast\(' resources/js` → for each, confirm it isn't a bare string with no icon/variant.
- **Inline validation:** field-level errors highlight the field and place the message adjacent (not only a top-of-form summary). Grep: `rg -n -g '*.tsx' -g '*.jsx' 'errors\.[a-zA-Z]|formState\.errors' resources/js` → confirm the field renders its own error, not just a page banner.
- **Full-page errors:** error boundaries / error pages are designed (not a raw stack or a blank screen), with a recovery path (retry / go-back / contact).
- **Recovery paths:** every destructive or failable action has a way forward after failure.

#### POLISH-0XX: Raw error string with no styling or recovery
**Severity:** Medium-Craft. `toast.error(e.message)` dumps a raw exception with no icon, no friendly copy, no retry. Fix: map to a user-facing message, use the error-variant toast, offer a retry action.

### 1.19 Navigation Consistency

- **Sidebar width uniform** across pages (240px per the design spec — grep for divergent widths): `rg -n -g '*.tsx' -g '*.jsx' 'w-\[?2[0-9]{2}px|sidebar' resources/js` → flag any sidebar not on the canonical width.
- **Breadcrumb format consistent** across pages (same separator, same casing).
- **Active nav item highlighting** present and consistent (the current route is visibly marked).
- **Mobile nav pattern** consistent (one drawer/hamburger pattern, not per-page variants).

#### POLISH-0XX: Sidebar width differs across pages
**Severity:** Medium-Craft. Dashboard sidebar is `w-[240px]`, Settings is `w-64` (256px) → visible shift on navigation. Fix: use one shared layout/token for sidebar width.

### 1.20 Inclusive Design

- **Color never the sole signal:** status/meaning pairs color with text or an icon/pattern. Grep for color-only status: `rg -n -g '*.tsx' -g '*.jsx' '(text|bg)-(red|green|yellow)-[0-9]{3}' resources/js` → confirm an adjacent label/icon, not color alone.
- **prefers-reduced-motion respected** by animations. Grep: `rg -n 'transition|animate-|framer|motion\.' resources/js` → confirm a `motion-reduce:` variant or a `prefers-reduced-motion` guard exists for non-trivial motion.
- **Click targets ≥24×24px floor** (WCAG 2.2 AA 2.5.8), **≥44px on primary/mobile actions** (best-practice / 2.5.5 AAA) — per `_v-design.md § Interactive Target Size`, matches dim 1.9.
- **Copy is jargon-free**; content degrades gracefully without images (alt text, no image-only meaning).

#### POLISH-0XX: Status shown by color alone
**Severity:** High-Craft (a11y). A status dot uses only `bg-green-500`/`bg-red-500` with no text → invisible to color-blind users. Fix: add a text label or a shape/icon alongside the color.

### 1.21 Internationalization Readiness

- **Text expansion:** layouts tolerate 20–30% longer strings (no fixed-width truncation of labels/buttons).
- **No LTR-only assumptions:** avoid hardcoded left/right where logical start/end is meant.
- **No hardcoded date/number/currency formats** in the UI (use a locale-aware formatter). Grep: `rg -n -g '*.tsx' -g '*.jsx' 'toLocaleDateString|new Date\([^)]*\)\.get|\\$\{.*\}/[0-9]' resources/js` and hand-rolled `MM/DD/YYYY` strings.
- **No culturally-specific icons/colors** carrying required meaning.

#### POLISH-0XX: Hardcoded US date format
**Severity:** Low-Craft. `date.toLocaleDateString('en-US')` (or a hand-built `MM/DD/YYYY`) is pinned to one locale. Fix: format via the app's locale-aware helper.

### Severity Calibration for Code Polish (1.10-1.21)

| Checks Passing | Score |
|---------------|-------|
| 0-1 / total | 1-2 (poor — major consistency issues) |
| 2-3 / total | 3-4 (below average — noticeable inconsistencies) |
| 4-5 / total | 5-6 (average — some gaps) |
| 6+ / total | 7-8 (good — minor items only) |
| All / total | 9-10 (excellent — consistent codebase) |

---

## W48-F3: Spacing / tokens / consistency checklist (post-implementation)

This section is appended in W48-F3. It complements the F2 UX critique (which covers heuristics: contrast, focus states, microcopy, state coverage, etc.) by narrowing `/v-polish` to the dimensions `/v-polish` is uniquely positioned to enforce — design-system token usage and spatial rhythm.

**Run after the existing /v-polish dimensions complete. For each item below: check, propose smallest fix on ✗, do NOT remediate (orchestrator decides).**

### Project style discovery (W48-F3 review-fix M3)

Before applying the checklist, locate WHERE the canonical tokens live (the spec's fixed scales are the standard for every product; discovery only finds the implementation to verify/edit):

```bash
find . -maxdepth 2 -name '_v-design.md' -o -name 'CLAUDE.md' -o -name 'AGENTS.md' 2>/dev/null | head -3
find ./resources/css -name 'app.css' -o -name 'tokens.css' 2>/dev/null | head -3
find . -maxdepth 1 -name 'tailwind.config.*' 2>/dev/null
```

Spacing, casing, and color are judged against the fixed canonical scales in `_v-design.md` (spacing `xs 4 / sm 8 / md 12–14 / lg 20–24 / xl 28–32 / 2xl 36–40` px; canonical token set). The spec IS the absolute standard. Project docs and `.interface-design/system.md` supply only the sanctioned overlay (accent, category pairs, branding, domain components, marketing surfaces, z-index exceptions — the full set per `_v-design.md § Per-Product Overlay`).

### Three narrowed checks (no overlap with F2's heuristic walkthrough)

#### 1. Spacing rhythm

Spacing values in newly-edited files must sit on the fixed canonical scale (`xs`–`2xl` above; grid gap 14px between cards/columns). Verify against the scale, then check the edited file's neighbors for rhythm coherence:

```bash
# Sample the edited files' spacing values to check against the canonical scale
git diff --name-only HEAD -- '*.tsx' '*.jsx' '*.css' | head -5 | while read f; do
  grep -oE '(p|m|gap|space)-(x|y|t|b|l|r)?-?[0-9]+' "$f" 2>/dev/null | head -10
done
```

| Check | Pass condition |
|---|---|
| Edited file uses spacing tokens (not hardcoded `style={{margin: 16}}`) | All `style=` on UI primitives use tokens or pass-through |
| Spacing values are on the fixed canonical scale (xs–2xl) | No `p-[5]` or `m-[13px]` arbitrary values off the scale |
| Spacing increases monotonically inner→outer, ≤3 values per component | Per `_v-design.md` § Spacing Application Rules |

#### 2. Design tokens (no hardcoded values)

| Check | Pass condition |
|---|---|
| Colors resolve to canonical tokens, not raw hex or unbound palette classes | `bg-[var(--accent)]` or a semantic utility bound to a canonical token; never `style={{background: '#1e40af'}}` or bare `bg-blue-600` |
| Border radius uses tokens (`rounded-md`, `rounded-lg`) | No `style={{borderRadius: 6}}` |
| Font sizes use Tailwind classes (`text-sm`, `text-base`) | No `style={{fontSize: '14px'}}` unless inline-rich-text context |

#### 3. Consistency with existing component patterns

| Check | Pass condition |
|---|---|
| New `Button`-shaped elements use the project's `<Button>` component | Not raw `<button class="...">` when `~/Components/Button.tsx` exists |
| New form fields use the project's form pattern | Same wrapper, same label-position, same error-display |
| Modals/dialogs use existing primitives | Not `<div role='dialog'>` from scratch when `Dialog` component exists |

### Output

Append to `/v-polish`'s existing report:

```
## W48-F3 spacing/tokens/consistency findings
- spacing_rhythm: <pass | findings: N>
- design_tokens: <pass | findings: N>
- consistency: <pass | findings: N>
- project_style_source: <_v-design.md path or "defaults">
```

This output is informational — it complements but does NOT duplicate the F2 UX critique's heuristic findings. F2 owns the 10 dispatch heuristics (`~/.claude/skills/v/references/dispatch-ux-critique.md`): information hierarchy, scannability, Fitts' law, contrast, microcopy, state coverage, focus states, token conformance (a per-file spot check — heuristic 8), cognitive load, affordance. F3 owns the deeper post-implementation sweep: spacing rhythm, design-token scale conformance, and cross-component consistency. F3 intentionally overlaps F2's heuristic 8 and goes deeper (scales, rhythm, component-pattern reuse across files) — the depth split is by design, not a contradiction.
