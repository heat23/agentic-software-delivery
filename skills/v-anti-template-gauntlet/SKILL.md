---
name: v-anti-template-gauntlet
description: "Use when gating user-visible output on spec conformance and content tells."
allowed-tools: Read, Glob, Grep, Bash, Write, AskUserQuestion, TaskCreate, TaskUpdate
user-invocable: true
disable-model-invocation: true
context: fork
model: sonnet
---
<!-- skill: v-anti-template-gauntlet | version: 1.3.2 | last-updated: 2026-08-12 -->
<!-- line-count exception (v-anthropic-2026-standards.md §1 row 6): body exceeds the 500-line
     target (within the <700 tolerance). Documented decision: Step 8.5 (grading rubric) and
     Step 8.6 (verbatim critic prompt + mutation-pass cap) stay inline because the global
     mutation-pass cap couples them to Steps 0-7; extraction risks desyncing the cap language.
     Revisit extraction to references/gauntlet-output-grading.md only if the body approaches 700. -->


# 2026 Canonical Contract

Tier: User-facing entry point. Pre-ship blocking gate; runs *before* shipping any user-visible surface.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-review.md`, and `_v-design.md`.

**Audit opener:** see `_v-audit.md` § Audit Skill Opener — perform PROJECT_ROOT resolution, V_DEPTH parsing, and TodoWrite initialization before Step 0 begins.

For the full gauntlet check catalog, read `references/gauntlet-checks.md`.
For copy-quality detection, read `~/.claude/skills/references/anti-ai-tells-content.md`.
For visual spec deviations, read `_v-design.md` § Spec-Deviation Detection Table.

```yaml
contract:
  tier: user-facing
  accepts: [project root, optional --surface=hero|pricing|signup|all|specific-files, optional --force (override BLOCK verdict; logged in report)]
  produces: [GAUNTLET_REPORT_${CLAUDE_SESSION_ID}.md, PASS/CONDITIONAL_PASS/BLOCK/BLOCK_OVERRIDDEN verdict (BLOCK_OVERRIDDEN only via --force; see Override policy), .v-prompt-packs/v-anti-template-gauntlet-<MM-DD>/ (only when verdict is BLOCK or CONDITIONAL_PASS; 00-README.md + w<N>-*.txt wave packs per v-runnable-pack-convention.md)]
  invokes: []
  conditional-invokes: [/v-build (when verdict is BLOCK and operator accepts findings)]
  invoked-by: [/v, user, /v-prelaunch-readiness, /v-audit-orchestrator]
  estimated_tokens: 40k-95k
```

## Skill Boundaries

**SME persona:** This audit is run by a **senior product designer who enforces the canonical SaaS design system** (`references/design-system-spec.md`) — someone who can spot an off-spec token, a third font family, or a `.dark`-class theming hack from 50 feet, and who still knows every surviving content/brand tell (generic copy, stock photos, unmodified legal templates) that separates crafted product identity from AI-built default. The verdict (PASS / CONDITIONAL_PASS / BLOCK) is binary; this isn't an exploratory audit.

**Distinct from `/v-prelaunch-readiness`:** the gauntlet checks **OUTPUT QUALITY** (does the visual output conform to the design-system spec, and is the copy/brand free of AI tells?). v-prelaunch-readiness checks **SURFACE PRESENCE/CORRECTNESS** (does the hero work? is the demo link not 404? are OG tags right?). Run BOTH before launch — different questions, different bars.

### Best fit

- Pre-ship gate before merging UI / copy / brand changes — **blocks** ship if visual output deviates from the design-system spec or copy/brand carries AI tells
- Solo SaaS pre-launch readiness check (run alongside `/v-prelaunch-readiness`)
- Defensive review when adopting new component libraries (shadcn, Radix, Tailwind UI) — catches components left at library defaults instead of rebuilt on the spec's component library
- Periodic brand-consistency audit on production sites

### Use instead

- `/v-audit-code` — for comprehensive product audit (200+ findings; absorbed `/v-ui-audit` 2026-07-06). v-anti-template-gauntlet is *narrowly* scoped to one question: "does this look AI-built?" v-audit-code is exhaustive; gauntlet is fast.
- `/v-prelaunch-readiness` — for product-readiness gate (hero clarity, signup flow, demo working). v-anti-template-gauntlet runs as a sub-check inside prelaunch-readiness for output-quality.
- `/v-pre-flight` — for code-level quality (tests, build, lint). Different concern.
- `/v-verify-done` — for convention checks (DOMPurify, lazy loading, types). Different concern.

### Not for

- Replacing comprehensive design review — this is a YES/NO gate, not exploratory critique
- Detecting bugs or functional issues
- Suggesting visual *improvements* — only flags what's wrong vs the standard
- Code-quality audits (correctness, security, performance)

## Why This Exists

You have detection patterns scattered across `_v-design.md` (Spec-Deviation Detection Table + Visual Craft Gate), `~/.claude/skills/references/anti-ai-tells-content.md` (8 sections of copy patterns), and `~/.claude/skills/v-audit-code/references/deep-ux-audit.md` (audit-level structural-tell entries; absorbed `v-ui-audit/references/checklist.md` 2026-07-06). What's missing is a **production gate** that consumes those patterns and produces a binary ship/block decision.

The gap matters because:

1. **Detection without enforcement is theater.** Knowing "this hero copy uses 'leverage' 3 times" is useless if no skill blocks ship. The gauntlet enforces.
2. **Solo SaaS without team review** has no human gatekeeper. The operator IS the team. Tools that block ship on deviations they'd otherwise miss are leverage.
3. **Spec drift is the #1 regression under AI generation.** shadcn, Radix, Tailwind UI, Bootstrap defaults — and freshly hallucinated palettes, fonts, and `dark:`-class theming — all deviate from the ONE canonical system every product shares. The gauntlet specifically checks that each surface is built FROM the spec, with identity expressed only through the sanctioned freedoms (accent, category colors, branding, copy voice, domain components, marketing hero font).
4. **AI-generated code defaults to template-default.** When Claude / Cursor / Copilot generate UI, the output is statistically closer to library defaults than to the canonical spec. The gauntlet is calibrated against this baseline.
5. **Portfolio sameness is invisible from inside one project.** Every other check here runs against a single codebase and can pass cleanly while the operator's fourth product still reads as the third product with a new `--accent`. Nothing checked that until Step 1.6 (`references/gauntlet-checks.md § Portfolio-distinctiveness check`) — the dominant genericity risk for an operator shipping several products off one shared system.

The verdict is binary: **PASS / CONDITIONAL_PASS / BLOCK**. The operator can override BLOCK with `--force`, but the override is logged in the report — accountability without paternalism.

## Entry Point

**Auto-detect everything. ONE multiple-choice question for the operator.**

### Auto-detection sequence

1. **Scope** — defaults to all changed files in the current branch (`git diff --name-only main...HEAD` plus uncommitted changes). If no changed files exist, fall back to all public-facing surfaces.

2. **Stack** — detect Tailwind / shadcn / Bootstrap / Radix / Lucide via config and import grep.

3. **Surface inventory** — locate marketing pages, components, styles, and asset files.

The operator overrides scope via `--surface=NAME` or `--files=path,path` arguments. Without overrides, the gate runs on changed files (incremental mode), which is the high-frequency use case.

### The single question

```yaml
question: "How strict should the gauntlet be?"
header: "Strictness"
multiSelect: false
options:
  - label: "Standard (Recommended default)"
    description: "PASS = 0 CRITICAL + ≤2 HIGH. BLOCK above. Fits most pre-ship gates."
  - label: "Strict (pre-launch / press-ready)"
    description: "PASS = 0 CRITICAL + 0 HIGH. Flags everything. Use when launching publicly."
  - label: "Lenient (early prototype, internal use)"
    description: "Block ONLY on CRITICAL tells. Use during exploratory builds."
```

The strictness setting affects the verdict logic; same checks run; different bar.

### What's NOT asked

- Scope (defaults to changed files; override via `--surface` or `--files`)
- Output path (auto-determined: `.v/artifacts/GAUNTLET_REPORT_${CLAUDE_SESSION_ID}.md` — Phase-2: under `.v/artifacts/`, create the dir; the Stop-hook `_PB_*` gate dual-searches)
- Override flag (operator explicitly passes `--force` if needed; not asked upfront)


## Workflow

| Step | Action | Skip conditions |
|---|---|---|
| Step 0 | Audit opener (PROJECT_ROOT, V_DEPTH, TodoWrite) | — |
| Step 1 | Discover surfaces in scope (all public pages OR --surface OR --files) | — |
| Step 1.5 | **Spec-conformance sampling** — load the canonical spec + per-product overlay; sample each surface against tokens/typography/components | If `--no-baseline` flag is set |
| Step 1.6 | **Portfolio-distinctiveness check** — discover sibling products the operator has already shipped; require ≥2 named structural differences from EACH; CRITICAL if not met | Never fully skips — degrades to a logged `portfolio_distinctiveness: unresolved` advisory when no sibling products are discoverable |
| Step 2 | Run visual / component checks (fork-safe `claude -p` subprocess via `v-dispatch-subagent.sh --model sonnet --mode capture` — spec-conformance + craft judgment) | If no UI files in scope, skip |
| Step 3 | Run copy / microcopy checks via humanizer gates | If no user-visible text in scope, skip |
| Step 4 | Run brand / identity checks | If no brand assets in scope, skip |
| Step 5 | Run interaction / behavior checks | If no interactive components in scope, skip |
| Step 6 | Run SEO / meta tag checks | If no public-facing pages in scope, skip |
| Step 7 | Apply verdict logic per strictness setting | — |
| Step 8 | Write `.v/artifacts/GAUNTLET_REPORT_*.md` with findings + verdict | — |
| Step 9 | **Generate prompt pack (dispatched as a sonnet subprocess)** — dispatch a fork-safe `claude -p` subprocess (`v-dispatch-subagent.sh --model sonnet --mode self-write` — NOT the Agent tool) to create `.v-prompt-packs/v-anti-template-gauntlet-<MM-DD>/` directory (00-README.md + flat `.txt` wave packs, `99-verify.txt` last) | Skip if verdict is PASS (no findings to fix) |
| Step 10 | Validate prompt pack — per `~/.claude/skills/references/v-core-prompt-pack.md` | Skip if Step 9 was skipped |

### Step 1: Discover surfaces

```bash
# Public-facing pages
find resources/js/Pages src/pages app/pages pages -maxdepth 4 \
  \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' \) 2>/dev/null | head -30

# Component customization detection
grep -rln "@/components/ui/" --include="*.tsx" --include="*.jsx" 2>/dev/null | head -20

# Stylesheet / Tailwind config
ls tailwind.config.{js,ts,mjs} 2>/dev/null
ls resources/css/*.css resources/scss/*.scss src/styles/*.css 2>/dev/null

# Asset inventory
find public images src/assets resources/images -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) 2>/dev/null | head -10
```

If `--changed` mode, restrict to files modified in current branch:

```bash
git diff --name-only main...HEAD 2>/dev/null
git status --porcelain 2>/dev/null | awk '{print $2}'
```

### Step 1.5: Spec-conformance sampling (calibrate against the canonical design system)

The calibration layer is no longer a moving web baseline — it is the prescriptive spec. Uniformity across pages and products is MANDATED (spec §1: sidebar, search, theme toggle, notifications, and profile appear identically on every dashboard page; the content area is the only thing that changes). What must be sampled per surface is (a) conformance to the canonical tokens/typography/components and (b) whether product identity is expressed within the sanctioned freedoms.

**Load, in order:**

1. `~/.claude/skills/_v-design.md` — canonical token set, Spec-Deviation Detection Table, Visual Craft Gate
2. `~/.claude/skills/references/design-system-spec.md` — component-level detail (sidebar anatomy, hero-metrics bar, card tiers, ⌘K overlay, §10 marketing structure, breakpoints 700/900/1100)
3. `.interface-design/system.md` (if present) — the per-product OVERLAY: `--accent`, category `-bg`/`-text` pairs, branding, domain components, marketing-hero display font

**For each surface in scope, catalog:**

| Dimension | Conformant when... | Flag when... |
|---|---|---|
| Tokens | colors/spacing/shadows resolve to the canonical set; theming via `html[data-theme]` only | raw hex, raw Tailwind palette without semantic binding, `.dark`-class or per-element `dark:`-strategy theming |
| Typography | Inter + JetBrains Mono only; weights 400/500/600/700 on the fixed scale; UPPERCASE section headers per spec | a third family; missing mono on data values; display font outside the marketing hero |
| Components | cards on the 3-tier system; §10 hero/pricing/sections; hero-metrics bar; inline-SVG icons | off-spec components, non-canonical elevation, icon fonts, wrong viewBoxes |
| Identity | `--accent` + category pairs present and WCAG-verified; branding and copy voice distinct | identity expressed by mutating palette/typography/components; OR no identity at all (default accent, generic copy) |

**GENERIC COPY remains a hard tell.** Spec conformance sanctions uniform structure, never uniform voice — copy that could describe any product is flagged at full severity in Step 3.

Cache the per-surface conformance table in `BASELINE_2026_${CLAUDE_SESSION_ID}.md` (legacy artifact name retained; it now records the spec-conformance baseline) for the rest of this audit. No network access is required.

**Output conformance summary** appended to the audit metadata:

```markdown
## Spec-Conformance Calibration

Sampled: [N] surfaces — [list files]
Spec sources: design-system-spec.md + _v-design.md [+ .interface-design/system.md overlay]

### Spec-mandated patterns present (conformant — do NOT flag)
- [Pattern 1] — [surfaces]

### Deviations from the canonical system (flag per severity catalog)
- [Deviation 1] — [surface:line]

### Sanctioned per-product freedoms in use (verified against overlay)
- [Freedom 1] — [accent value / category pair / hero font]
```

This conformance table is the *calibration layer* the rest of the gauntlet (Steps 2-6) reads. Without it, findings drift into flagging spec-mandated uniformity or missing overlay-sanctioned identity choices.

**Skip sampling if:** `--no-baseline` flag is set. In that case, log `baseline_2026: skipped — using static catalog` in the audit metadata and proceed with the existing reference catalogs as-is.

### Step 1.6: Portfolio-distinctiveness check (mandatory — never silently skips)

**Why this exists:** § Retired as tells (`references/gauntlet-checks.md`) correctly stops flagging uniformity the canon mandates WITHIN one product; it has no opinion on sameness ACROSS the operator's different products, and nothing else in this gate ever asked whether product N is distinguishable from products 1..N-1 already shipped — the dominant genericity risk for a multi-product operator on one shared system. Full category table, verdict rule, and canon-dependency note: `references/gauntlet-checks.md § Portfolio-distinctiveness check`. This is a SEPARATE check from spec-conformance sampling above — never fold it back into the retired-tells rationale.

**Discover siblings** per `references/portfolio-registry.md § Discovery sequence` (env var → pointer file → self-updating manifest → auto-scan of sibling repo dirs). Log `portfolio_discovery: <method|none>`.

**Zero found → never a silent PASS.** Append `portfolio_distinctiveness: unresolved — no sibling products discovered (checked: <methods tried>)` to the Step 8 report — advisory, not blocking (nothing to compare against on a genuinely first product) — and continue to Step 2.

**For each discovered sibling**, read its overlay (`.interface-design/system.md`) and primary surface file (reuse the Step 1 discovery patterns above, run against the sibling's own repo path), then apply the category table + verdict rule at `references/gauntlet-checks.md § Portfolio-distinctiveness check`. A sub-2-difference result is a CRITICAL finding and feeds the Step 7 tally exactly like any other CRITICAL finding — it can BLOCK ship on its own.

Append the comparison to `BASELINE_2026_${CLAUDE_SESSION_ID}.md` under `## Portfolio-Distinctiveness Calibration`, then append/update this product's own row in `references/portfolio-registry.md § Known products` (repo path, overlay path, this run's structural profile, today's date) — every run contributes a row regardless of verdict, so the next product's gauntlet run can find this one.

### Step 2: Visual / component checks

Write the briefing below (plus the gauntlet check catalog) to `/tmp/gauntlet-step2-brief-${CLAUDE_SESSION_ID}.md`, then dispatch a fork-safe `claude -p` subprocess — NOT the Agent tool, which fails silently from `context: fork`:

`~/.claude/skills/v/references/v-dispatch-subagent.sh --model sonnet --mode capture --prompt-file "/tmp/gauntlet-step2-brief-${CLAUDE_SESSION_ID}.md" --artifact "/tmp/gauntlet-step2-findings-${CLAUDE_SESSION_ID}.md"`

The explicit `sonnet` pin: craft judgment must not inherit the session model (which may be fable — refuses the /v role — or a premium [1m] variant), and the sonnet-max policy (CLAUDE.md Model Policy 2026-07-07) caps all /v dispatches at sonnet; opus is operator-explicit only. Completion = the `--artifact` findings file exists and is non-empty. Merge the returned findings into the Step 7 verdict tally and the Step 8 report alongside the Steps 3-6 results.

```
Subject: Anti-template gauntlet — visual & component spec-conformance checks

Apply checks from `references/gauntlet-checks.md` § Visual / Component checks
(conformance target: `_v-design.md` + `references/design-system-spec.md`;
sanctioned freedoms: `.interface-design/system.md` overlay):

CRITICAL checks:
- Off-mechanism theming (.dark/.light classes or dark:-strategy instead of html[data-theme])
- Hardcoded hex in app-UI components instead of canonical tokens
- Non-canonical font stack (anything beyond Inter + JetBrains Mono; display font outside marketing hero)
- Default component-library appearance (shadcn/Radix/Bootstrap defaults instead of the spec's component library)
- Stock photography in hero
- Generic AI illustration in hero
- Placeholder images in production

HIGH checks:
- Raw Tailwind palette classes without semantic binding to the canonical tokens
- Per-product identity missing (--accent absent/default, category pairs absent or not WCAG-verified)
- Brand-tinted status colors (off the fixed critical/high/medium/resolved/info set)
- Missing mono on data values (IDs, codes, timestamps without the .mono utility)
- Icons off-spec (icon fonts, sprites, wrong viewBoxes — spec mandates inline Lucide-compatible SVG)
- Non-canonical elevation (shadow-xl/2xl, 2px+ borders — spec pairs 1px var(--border) with --shadow/--shadow-lg)
- Uppercase outside the section-header/badge patterns
- Pricing/hero/sections off spec §10 (no highlighted recommended tier, hero off the prescribed structure)
- OG image is logo on solid background
- Default favicon

For each finding, return: file:line, severity, what was detected, 1-sentence fix.
```

### Step 3: Copy / microcopy checks

Run the bash gates from `~/.claude/skills/v-content-create/references/humanizer.md` against the discovered surface text:

```bash
# Set DRAFT to combined surface text
DRAFT=/tmp/gauntlet-surface-text-${CLAUDE_SESSION_ID}.md
# (Extract user-visible text from JSX/TSX/Vue files into the draft)

# Run all 5 humanizer gates (banned words, hedging, em-dash, contractions, first-person)
# Map gate failures to gauntlet severity per references/gauntlet-checks.md § Severity mapping
```

Apply the severity mapping from `gauntlet-checks.md` § Severity mapping for copy gates.

### Step 4: Brand / identity checks

```bash
# Logo consistency
find . -iname "*logo*" -type f 2>/dev/null | head -10  # Should be small, intentional set

# Brand color discipline
grep -roE "primary|brand-color" --include="*.tsx" --include="*.css" 2>/dev/null | wc -l

# About page presence + quality
test -f resources/js/Pages/About.tsx && echo "ABOUT_EXISTS=true"

# Privacy/Terms unmodified template detection
grep -li "{Company Name}\|\\[Operator\\]\\|\\[Date\\]" content/legal/*.md public/legal/*.md 2>/dev/null

# Unresolved [REVIEW NEEDED] / bracketed placeholders in legal docs about to ship
# (the #1 solo-founder publish failure: shipping /v-legal-docs-generate output with its
#  attorney-review markers still in place). -s suppresses missing-dir noise; a non-empty
# result is a CRITICAL finding — legal docs must not publish with unresolved markers.
grep -srlnE '\[REVIEW NEEDED[^]]*\]' content/legal public/legal resources/legal app/legal 2>/dev/null
# Also flag leftover bracketed intake placeholders that should have been filled:
grep -srlnE '\[(JURISDICTION_STATE|BUSINESS_ENTITY|PRODUCT NAME|OPERATOR LEGAL NAME|YOUR_COUNTY|YOUR_DISTRICT|EFFECTIVE DATE)[^]]*\]' \
  content/legal public/legal resources/legal app/legal 2>/dev/null
```

### Step 5: Interaction / behavior checks

```bash
# Hover-only critical actions
grep -rln "onMouseEnter\|hover:" --include="*.tsx" 2>/dev/null | head -10  # Cross-ref with mobile usage

# Loading state coverage
grep -roE "isLoading|loading\s*=\s*true|<Spinner|<LoadingButton" --include="*.tsx" 2>/dev/null | wc -l

# Generic error toasts
grep -rln "Something went wrong\|Failed\|Error occurred" --include="*.tsx" --include="*.ts" 2>/dev/null
```

### Step 6: SEO / meta tag checks

```bash
# Title uniqueness across pages
grep -rh "<title>" resources/views/ 2>/dev/null | sort -u | head
grep -rln "<Head\|metadata.*title\|<title>" --include="*.tsx" --include="*.blade.php" 2>/dev/null

# OG image presence
grep -rh "og:image" --include="*.tsx" --include="*.blade.php" --include="*.html" 2>/dev/null | head -10

# JSON-LD schema
grep -rln 'application/ld\+json' --include="*.tsx" --include="*.blade.php" 2>/dev/null
```

### Step 7: Apply verdict

**This table is the SINGLE canonical verdict definition for the gauntlet** — Step 7's Verification-Gates notes, the Progress checklist, and `references/gauntlet-checks.md` § Verdict logic all defer to it; do not restate a divergent version anywhere. Severity tiers map to the canonical scale in `~/.claude/skills/references/v-core-severity.md` (CRITICAL = P0, HIGH = P1, MEDIUM = P2), and the "any CRITICAL ⇒ BLOCK" rule is this skill's application of that reference's "one P0 ⇒ failing verdict" discipline.

| CRITICAL | HIGH | Strictness | Verdict |
|---|---|---|---|
| ≥1 | any | any | BLOCK |
| 0 | ≥6 | Standard | BLOCK |
| 0 | 3-5 | Standard | CONDITIONAL_PASS |
| 0 | ≤2 | Standard | PASS |
| 0 | ≥1 | Strict | BLOCK |
| 0 | 0 | Strict | PASS |
| 0 | ≤5 | Lenient | PASS (Lenient blocks only on CRITICAL) |

Note: CONDITIONAL_PASS exists only at Standard strictness (0 CRITICAL + 3-5 HIGH). Strict has no CONDITIONAL_PASS band — any HIGH blocks; Lenient has none either — only CRITICAL blocks.

## Verification Gates

**Apply Gates 0, 1, and 8 from `~/.claude/skills/references/v-audit-gates.md` before writing the report (Step 8).** Gate 2 (per-dim minimum-findings floor) does NOT apply — gauntlet is a binary blocking gate, not a finding-density audit. The verdict bands are defined ONCE in the Step 7 canonical table above; each verdict has its own legitimate finding count — e.g. PASS may carry ≤2 HIGH (advisory, not blocking), and a 0-finding return is legitimate when the surface genuinely has no AI-tells.

| Gate | What it enforces | Why the gauntlet needs it |
|---|---|---|
| Gate 0 | Each detection check (severity-tier classification + spec-section lookup + per-product-overlay cross-check) emits a per-check exploration block: which patterns were grepped, which spec sections and overlay entries were consulted, which findings were verified | Without Gate 0, a PASS verdict is just subagent confidence — no falsifiable evidence that the spec/overlay was actually consulted before downgrading a finding from CRITICAL to MEDIUM. |
| Gate 1 | Every CRITICAL/HIGH finding row cites a parseable `file:line` for the location in the project under audit. Downgrade rationale (sanctioned-freedom / spec-mandate analysis) lives in the BASELINE_2026 conformance artifact, NOT in the finding row's citation field — Gate 1 does not require citing the downgrade source. | The finding's `file:line` is what the operator opens to fix the issue. The downgrade rationale is auditable separately via the BASELINE_2026 artifact's conformance table. Conflating these would either drop legitimate downgrades or weaken the in-project citation rule. |
| Gate 8 | Both `GAUNTLET_REPORT_${CLAUDE_SESSION_ID}.md` AND `.v-prompt-packs/v-anti-template-gauntlet-<MM-DD>/` (when verdict is BLOCK or CONDITIONAL_PASS) are Glob-verified before methodology emits a "phase ran" claim | The gauntlet conditionally produces the prompt pack. Methodology must distinguish three cases: "verdict was PASS so no pack was generated (correct, see PASS-pack-skip rationale below)", "verdict was BLOCK/CONDITIONAL_PASS and pack exists (correct)", "pack generation failed silently (defect)". |

### PASS-pack-skip rationale (resolves Step 9 contradiction)

Step 9 (prompt pack generation) is **intentionally skipped on a PASS verdict**, even when PASS includes ≤2 HIGH findings. The pack exists to drive `/v-build` remediation sessions for blocking issues; PASS findings are advisory ("worth fixing but not ship-blocking") and the operator addresses them via the regular `/v` workflow, not via paste-ready blocking-remediation prompts. Operators who want a pack on PASS-with-findings should re-run with `--strictness=strict` to escalate the verdict.

This is documented contract behavior, not a bug. Methodology must NOT emit "Pack skipped — generation failed" on a PASS verdict; it must emit "Verdict: PASS — pack intentionally skipped per contract".

### Per-check exploration block (Gate 0 contract)

Each detection phase (banned-word/humanizer gates, visual-tells, copy-tells, brand-discipline, portfolio-distinctiveness) MUST emit a block:

```markdown
## Per-check exploration

### Check {name} — e.g., "Non-canonical font family detection"
- **Files searched:** `resources/js/Pages/*.tsx`, `resources/css/app.css` (full list)
- **Greps run:**
  - `grep -rn "font-family\|fontFamily" resources/css resources/js` → N hits
  - `grep -rn "fonts.googleapis" resources/views` → N hits
- **Spec lookup:** "Spec §2 fixes Inter + JetBrains Mono; overlay declares marketing-hero display font = 'none — Inter'. The third family found is not a sanctioned freedom; classification stays CRITICAL."
- **Verifications done:** "Confirmed `Space Grotesk` import at resources/css/app.css:3; used on dashboard headings, not the marketing hero."
```

Returns missing this block are rejected and re-tasked. The orchestrator picks 2 random `file:line` citations from CRITICAL/HIGH findings and verifies the cited line actually contains the flagged pattern. 1-of-2 mismatch → re-task; 2-of-2 mismatch → drop the affected detection's findings.

### Citation parseability (Gate 1 contract)

CRITICAL and HIGH findings must cite either:
- A `path/file.ext:NN` substring (single line) or `path/file.ext:NN-MM` (range) for the location in the project under audit, OR
- A verbatim quote of the violated spec/overlay clause (`design-system-spec.md` section or `.interface-design/system.md` entry) when the finding is a structural conformance gap (e.g., missing ⌘K overlay) rather than a single-line deviation

MEDIUM and LOW findings may use generalized references ("hero section", "pricing CTA") since they're advisory. CRITICAL and HIGH are blocking-tier and need falsifiable specificity. **This intentionally narrows canonical Gate 1's drop-on-fail rule (`~/.claude/skills/references/v-audit-gates.md` § Gate 1) to CRITICAL/HIGH only:** in the gauntlet, MEDIUM/LOW never affect the binary verdict, so they retain generalized references consistent with their advisory-only status — the same rationale as the Gate 2 exemption above.

**Downgrade rationale is NOT subject to Gate 1.** When a flagged pattern gets downgraded or removed because it is spec-mandated or a sanctioned per-product freedom declared in the overlay, the downgrade reasoning lives in the BASELINE_2026 artifact's conformance table, not in the finding row. The finding row still cites file:line for the in-project occurrence; the downgrade is auditable separately.

### File-existence verification (Gate 8 contract)

Before methodology emits any "phase ran" claim, verify each expected artifact:

- `GAUNTLET_REPORT_${CLAUDE_SESSION_ID}.md` — always expected
- `.v-prompt-packs/v-anti-template-gauntlet-<MM-DD>/` directory with `00-README.md` + flat `.txt` wave packs — expected ONLY when verdict ∈ {BLOCK, CONDITIONAL_PASS} (per PASS-pack-skip rationale above)

Methodology must include one of: "Generated at {path} — verified by Glob"; "Not generated this run. Verdict: PASS — pack intentionally skipped per contract"; "Partially generated: N of M files written. Reason: {specific cause}".


### Step 8: Write report

```markdown
# GAUNTLET_REPORT
generated: [ISO timestamp]
scope: [scope description]
strictness: [standard | strict | lenient]
verdict: [PASS | CONDITIONAL_PASS | BLOCK]

## Verdict reasoning

[1-2 sentences explaining why the verdict landed where it did]

## Findings

### CRITICAL (N)

[For each: ID, file:line, severity, what was detected, 1-sentence fix]

### HIGH (N)

[Same format]

### MEDIUM (N)

[Same format]

## What this gauntlet did NOT check

- Functional correctness (use /v-pre-flight, /v-verify-done)
- Comprehensive UX (use /v-audit-code, absorbed /v-ui-audit 2026-07-06)
- Content quality at depth (use /v-audit-messaging, /v-audit-seo)
- Operational readiness (use /v-check)

## Recommended next step

[If PASS: "Cleared the gauntlet. Ship when ready."]
[If CONDITIONAL_PASS: "Review the HIGH findings; ship if they're acceptable for your context."]
[If BLOCK: "Address CRITICAL findings before shipping. Run /v-build with this report's findings list, OR run with --force to override (override will be logged)."]

## Override accountability (if --force used)

[If applicable: "BLOCK overridden by operator at [timestamp]. Findings remained unaddressed: [list]"]
```

### Step 8.5: Output grading + re-task gate (Mandatory)

The verdict (PASS / CONDITIONAL_PASS / BLOCK) tells the operator IF the surface ships. The grading tells the operator HOW WELL THE GAUNTLET ITSELF DID. A gauntlet can produce a clean PASS verdict by missing actual deviations; it can produce a BLOCK verdict on false-positive flags against spec-mandated patterns. Score the audit run on these 4 axes (1-10):

| Axis | What "10" looks like | What "<7" looks like |
|---|---|---|
| Spec calibration (Step 1.5) | Each visual finding is calibrated against the canonical spec + per-product overlay; spec-mandated patterns and sanctioned freedoms are NOT flagged | Findings flag patterns the spec mandates (uniform grids, Inter, UPPERCASE section headers, highlighted pricing tier) — false positives |
| Evidence specificity per finding | Each CRITICAL/HIGH finding cites a specific file:line OR a verbatim quote of the violated spec/overlay clause; no hand-wavy claims | Findings reference "the hero" without naming the file or quoting the code |
| Severity proportionality | CRITICAL findings actually break spec conformance or brand trust; MEDIUM findings are real but survivable | All findings tagged the same severity; no triage discipline |
| Anti-fabrication discipline | Conformance-table rows and finding evidence have evidence_excerpts proving they came from real file reads; no plausible-but-fabricated code or spec quotes | Evidence quotes code that doesn't exist at the cited file:line, or "spec" clauses not present in design-system-spec.md |

**Vocabulary note:** in grading rubrics throughout the v-* family, "evidence_excerpt", "verbatim quote", "specific text", and "exact quote" all refer to the same concept — a literal substring from the artifact that supports the score. Treat them as synonymous when scoring; pick one canonical term in your output (preferred: `evidence_excerpt`) for grep-friendliness.

**Honesty rule:** for each axis, you must be able to **quote** specific text from the audit output earning the score. If you cannot quote text supporting a 7+ score, the score is at most 6 — refine and re-grade.

If ANY axis scores <7, re-task the relevant earlier step:
- Spec calibration <7 → re-do Step 1.5 spec-conformance sampling
- Evidence specificity <7 → re-task Step 2-6 to add file:line refs and verbatim quotes
- Severity proportionality <7 → re-task Step 7 verdict to triage findings
- Anti-fabrication <7 → re-do Step 1.5, re-verifying every evidence excerpt against the on-disk file before re-grading

Cap re-task at 2 iterations per axis. **Escape hatch:** if an axis is still <7 after 2 re-tasks, log `axis_N: low_quality_shipped` in the audit metadata and proceed — do NOT loop indefinitely. The verdict report banner prominently flags any axis under low_quality_shipped status. The audit ships only when verdict is determined AND ≥3 of 4 axes score ≥7 (one axis can be low_quality_shipped without blocking).

### Step 8.6: Critic dispatch (adversarial review of output)

**Skip this step ONLY when:** `V_DEPTH ≥ 1` (orchestrator owns post-output review), `HEADLESS_BATCH=1`, `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1`, or `--no-critic` flag is set. In skip cases, log `critic_review: skipped — reason=<flag>` in the output metadata and proceed. Skipping silently is not allowed.

The output produced through the prior steps is the result of the SAME AI's reasoning at every gate (spec-conformance sampling, detection checks, output grading). A critic from a different dispatch catches blind spots the producer cannot see by self-review. Write the adversarial prompt below to a SID-scoped briefing file (`/tmp/gauntlet-critic-brief-${CLAUDE_SESSION_ID}.md`), then dispatch a fork-safe `claude -p` subprocess via `~/.claude/skills/v/references/v-dispatch-subagent.sh` with adversarial focus per `_v-review.md` § Agent Dispatch Protocol. Use the FIRST tier whose precondition holds:

- **Primary** — when `codex-adversarial-reviewer.md` exists in the project's `.claude/agents/` OR `~/.claude/agents/`:
  `v-dispatch-subagent.sh --agent codex-adversarial-reviewer --mode capture --prompt-file "/tmp/gauntlet-critic-brief-${CLAUDE_SESSION_ID}.md" --artifact "/tmp/gauntlet-critic-findings-${CLAUDE_SESSION_ID}.md"`
  Do NOT pass `--model` here — on an `--agent` dispatch the agent's frontmatter model pin is authoritative and the script ignores a caller-passed `--model` (it warns loudly); log the pinned model in the report, not haiku.
- **Last resort** — agent file absent from both locations:
  `v-dispatch-subagent.sh --model sonnet --mode capture --prompt-file "/tmp/gauntlet-critic-brief-${CLAUDE_SESSION_ID}.md" --artifact "/tmp/gauntlet-critic-findings-${CLAUDE_SESSION_ID}.md"`
  (sonnet per the 2026-08-02 critic-tier decision (_v-review.md § Critic Dispatch).)

There is deliberately no Skill-tool fallback tier: this skill runs `context: fork` and grants no `Skill` tool, so a same-process skill dispatch is unreachable from here — the last-resort inline adversarial prompt covers that gap.

Completion = the `--artifact` findings file exists on disk and is non-empty; never trust the subprocess's prose exit message.

The critic's role: **adversarial spec-conformance reviewer — specialty is identifying false-positive flags (on spec-mandated patterns or sanctioned per-product freedoms) and missed deviations (off-spec tokens/typography/components and surviving content/brand tells the producer's self-review passed)**

Pass the critic this prompt verbatim (substitute `<artifact-path>` with the actual path to the primary output artifact):

```
You are an adversarial spec-conformance reviewer — specialty is identifying false-positive flags (on patterns the canonical design system mandates, or on sanctioned per-product freedoms declared in the overlay) and missed deviations (off-spec tokens/typography/components and surviving content/brand tells the producer's self-review passed). Your job is NOT to be helpful — it is to actively try to break the output, probe edge cases, question architectural decisions, and surface what the producer's self-review missed.

Read: <artifact-path> + any sibling spec/conformance artifacts in the same SID-qualified set. Conformance authority: ~/.claude/skills/_v-design.md + ~/.claude/skills/references/design-system-spec.md; sanctioned freedoms: the project's .interface-design/system.md overlay.

Spot-check 5 random findings against the BASELINE_2026 conformance table. **If total findings < 5, spot-check ALL of them and log `spot_check_n: <actual>` in metadata** rather than fabricating findings to reach the quota. The 5-count is a sample-size target, not a generation quota.
1. False positives — for each CRITICAL/HIGH visual finding, verify the flagged pattern is NOT mandated by design-system-spec.md (uniform grids, Inter, UPPERCASE section headers, highlighted recommended pricing tier, identical page shells) and NOT a sanctioned freedom declared in the overlay (accent, category pairs, branding, hero display font). If it is, it's conformance or identity, not a tell — remove or downgrade.
2. Missed deviations — review the audited surfaces and identify ≥1 deviation the gauntlet did NOT flag (e.g., off-scale spacing, non-spec breakpoints, brand-tinted status colors, `.dark`-class theming, missing mono on data values, missing ⌘K overlay on a dashboard, generic copy)
3. Severity drift — pick 2 random findings; was each CRITICAL actually a MEDIUM (subtle drift that doesn't break conformance/brand trust) or vice versa?
4. Anti-fabrication — pick 2 evidence excerpts (from findings or the BASELINE_2026 conformance table) and verify each exists verbatim at the cited file:line via a real Read/grep. Smoking gun: quoted code or "spec" clauses that don't appear on disk
5. Override-accountability risk — if `--force` is invoked and a BLOCK is overridden, does the surviving deviation actually deserve to ship?

Output format: 3-5 findings, each as JSON:
{
  "severity": "P0|P1|P2|P3",
  "finding": "specific issue, named in concrete terms",
  "evidence": "exact quote from the artifact OR specific reasoning chain",
  "suggested_fix": "concrete intervention",
  "confidence": "high|medium|low"
}

If after honest review zero issues exist, return `findings: []` with metadata `review_outcome: clean`. Do NOT fabricate concerns to meet a quota — fabricated noise pollutes adjudication. Only record findings you can defend with concrete evidence.
```

#### Adjudicate findings

For each critic finding:
- **ACCEPT** → fix the issue NOW (re-task the relevant earlier step), then re-run output grading on the fixed output, then proceed
- **MODIFY** → apply the suggested fix with adjustments documented inline
- **REJECT** → document the reason ("we considered this in Step X — explicit choice because Y")

No DEFER. If ≥1 ACCEPT/MODIFY: complete the fix loop, then re-dispatch the critic ONCE for cycle 2 (regression check on fixes). **Global mutation-pass cap:** across all gates in this skill (variance re-task + grading re-task + critic adjudication), maximum 4 total content-mutation passes per session. On the 5th proposed mutation, ship as-is and log `gate_chain_capped: true` in output metadata to prevent infinite ping-pong between gates. Cap at 2 critic cycles total — if cycle 2 produces ≥1 ACCEPT findings, log `critic_review: contested` in output metadata and ship with prominent banner ("adversarial review surfaced unresolved concerns: [list]").

If 0 ACCEPT/MODIFY findings: log critique under `## Adversarial review` in the output and proceed to Step 9 prompt pack generation.

### Step 9: Generate prompt pack (dispatched as a sonnet subagent — only when verdict is BLOCK or CONDITIONAL_PASS)

Pre-dispatch shell setup (run before dispatching the subprocess):

**`/v` first-line requirement:** every pack file (excluding `00-README.md`) MUST be a flat `.txt` file whose line 1 is the literal `/v ` prefix (the orchestrator routing prefix) — the unified wave form per `~/.claude/skills/references/v-runnable-pack-convention.md` § Canonical form, NOT the deprecated `NN-*.md` shape. Files that do not start with `/v ` are rejected by the post-generation validator and the pack will fail. The dispatched subagent must produce paste-ready files: operator copy-pastes the entire file content into a fresh `/v` session with zero edits required.


```bash
PROMPT_DIR=".v-prompt-packs/v-anti-template-gauntlet-$(date +%m-%d)"

# Idempotent re-run: archive any prior pack, then create the active dir.
# Per `_v-audit.md` § Step 3: Prompt Generation Contract — see the Pre-dispatch shell block.
# Without this, fewer-or-renamed sessions on re-run leave stale wave packs orphaned;
# the post-generation validator counts them and reports a false-positive PASS.
if [ -d "$PROJECT_ROOT/$PROMPT_DIR" ] && [ -n "$(ls -A "$PROJECT_ROOT/$PROMPT_DIR" 2>/dev/null)" ]; then
  PACK_TS=$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)
  mv "$PROJECT_ROOT/$PROMPT_DIR" "$PROJECT_ROOT/$PROMPT_DIR.bak-$PACK_TS"
fi
mkdir -p "$PROJECT_ROOT/$PROMPT_DIR"
```

Per `~/.claude/skills/references/v-runnable-pack-convention.md` (folder ownership per `v-core-prompt-pack.md`). Set `PROMPT_DIR=".v-prompt-packs/v-anti-template-gauntlet-$(date +%m-%d)"`. Write the verdict + findings list + sections 9a/9b/9c below verbatim to `/tmp/gauntlet-pack-brief-${CLAUDE_SESSION_ID}.md`, then dispatch a fork-safe `claude -p` subprocess:

`~/.claude/skills/v/references/v-dispatch-subagent.sh --model sonnet --mode self-write --prompt-file "/tmp/gauntlet-pack-brief-${CLAUDE_SESSION_ID}.md" --artifact "$PROJECT_ROOT/$PROMPT_DIR/00-README.md"`

The `--artifact` names `00-README.md` as the single-file proof-of-life that self-write mode verifies; full-pack completeness is independently checked by Step 10's validator and Gate 8's Glob check, so no per-pack artifact flag is needed.

**Skip Step 9-10 entirely** when the verdict is PASS — there are no findings to fix.

#### 9a. Group findings by category

Cluster findings into these session-able groups:
- **Visual / Component fixes** — off-spec tokens, non-canonical fonts, off-mechanism theming, off-spec components/elevation, default-component appearance
- **Copy / Microcopy fixes** — hedging openers, banned words, generic CTAs, default error messages
- **Brand / Identity fixes** — logo inconsistency, generic about page, unmodified legal templates
- **Asset fixes** — stock photography, generic AI illustration, default favicon, generic OG image
- **SEO / Meta fixes** — same title/desc across pages, missing OG tags, missing JSON-LD

Each group with ≥1 CRITICAL or ≥1 HIGH finding gets its own session pack. CRITICAL findings always come first within each session.

**Security-bearing pack clause:** N/A for this skill. The gauntlet's domain is exclusively visual/component spec-conformance, copy/microcopy, brand/identity, asset, and SEO/meta findings — none of these categories touch request signing/HMAC/webhook verification, credential handling, host/URL construction, auth/authz decisions, or payment flows. Per `v-runnable-pack-convention.md` § Security-bearing packs, the clause is skipped for this skill's entire output domain — a pure UI/copy gate never produces a security-bearing pack.

#### 9b. Assign session packs

For each group with ≥1 finding, per `v-runnable-pack-convention.md` § Wave assignment: these category groups are disjoint-file, non-dependent work items ⇒ they are ALL wave 0 (no filename prefix) unless the file-dependency graph proves a real conflict/order between two groups (e.g. a Visual fix and a Brand fix touching the same layout file — merge those into one pack instead of splitting, per the convention's "same-file, different-fix ⇒ different waves" rule if they truly can't merge).
- File name: `[category-slug].txt` (e.g., `visual-component-fixes.txt`, `copy-fixes.txt`), wave-0 unless ordering is proven necessary
- File starts with `/v ` literal — the rest of the file is the operator's paste body
- **Closing waves (mandatory, per `v-runnable-pack-convention.md` § Closing waves):** after the last implementation wave (wave 0 above), append `w1-pre-flight.txt` + `w1-review.txt` as a parallel READ-ONLY verification wave (`## Goal`/`## Checks`/`## Acceptance` only — no `## Files`, no "leave staged" line), then a single sequential `w2-hardening.txt` that triages the verification findings, fixes CRITICAL/HIGH, re-runs gates, and runs `/v-verify-done`. Always append a closing `99-verify.txt` read-only pack last (re-runs the gauntlet + confirms verdict). **The `99-verify.txt` MUST carry a single `<!-- v-verify-gate: <the project's full green-bar gate command> -->` HTML-comment line** (the SAME command its `## Checks` prose names — e.g. `<!-- v-verify-gate: npm run build && npm run lint -->`). Per `v-runnable-pack-convention.md § Self-validate`, its absence HARD-fails the pack; and it is the runner's fork-park backstop — a verify session that backgrounds its gates exits at 0 turns with no completion token, so `run-v-packs` re-runs this command synchronously to key GO/NO-GO on a real exit code instead of stranding a green batch at exit 2.

#### 9c. Per-file format

Each pack is the entire content the operator pastes into `/v`. No frontmatter, no metadata, no commentary outside the prompt body. MUST carry the full body schema from `v-runnable-pack-convention.md` § Pack body schema, in order: `## Goal` · `## Context` · `## Files` (literal H2, REQUIRED — v-build's scope guard keys on it) · `## Changes` · `## Acceptance criteria` · `## Tests` · `## Constraints` · `## Dependencies`.

```markdown
/v Fix anti-template-gauntlet findings: [category] for [Project Name].

## Goal
Bring [category] back into spec conformance so the gauntlet verdict flips to PASS — [1-3 sentences on why].

## Context
Tech stack: [from detection].
Design tokens: canonical set per `_v-design.md` § Design System Application Order (+ per-product overlay accent/category pairs).
The gauntlet found these spec deviations / surviving AI tells. Each is a `BLOCK`-tier or `HIGH`-tier finding that must be fixed before ship.

### Finding 1: [title] ([severity])
**File:** path/to/file.tsx:42
**Detected:** [what was found — e.g., "Default shadcn Button used instead of the spec's button component"]
**Why it's a finding:** [1-sentence rationale — e.g., "Off the spec §5.2 button system; indistinguishable from library defaults"]

### Finding 2: ...

## Files
- path/to/file.tsx — [what changes]

## Changes
- [specific change — e.g., "Rebuild on the spec's button pattern: var(--accent) primary, 8px radius, 13px/500, focus-visible outline"]

## Acceptance criteria
- [ ] [check after fix — e.g., "Button matches spec §5.2 in both themes; colors resolve to canonical tokens"]

## Tests
- [visual/behavioral check or test that proves the fix, per finding]

## Constraints
Read CLAUDE.md first for stack + conventions. Do not deviate from the canonical design tokens.

## Dependencies
Wave 0. Requires: none.

## After all fixes

Re-run the gauntlet to confirm verdict flipped to PASS:
`/v-anti-template-gauntlet --strictness=standard`

If still BLOCK or CONDITIONAL_PASS, address the remaining findings.

Leave all changes staged; do NOT commit — the operator/orchestrator owns commits.
```

#### 9d. README

Write `.v-prompt-packs/v-anti-template-gauntlet-$(date +%m-%d)/00-README.md` with:
- Project name, gauntlet date, verdict (BLOCK or CONDITIONAL_PASS), strictness setting
- Wave/session map table: `| Pack | Wave | Category | Findings (CRITICAL/HIGH/MEDIUM) |` — every name in this table MUST have a matching file on disk and vice versa, INCLUDING the closing waves (`w1-pre-flight.txt`, `w1-review.txt`, `w2-hardening.txt`, `99-verify.txt`)
- Sessions touching the same files cannot run in parallel — note conflicts and their wave
- Recommended order: CRITICAL-bearing sessions first, then HIGH-only, then polish, then the closing verification/hardening waves, then `99-verify.txt` last

### Step 10: Validate prompt pack

Self-validate per `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate (or `~/.claude/scripts/validate-audit-prompt-packs.sh "$PROJECT_ROOT/$PROMPT_DIR"`), then `run-v-packs "$PROMPT_DIR" --dry-run`. On failure, retry once. On second failure, mark `prompt_pack: validation_failed` in the gauntlet report.

### Override policy

When the operator passes `--force` to override a BLOCK verdict:

1. The override is logged in the report's "Override accountability" section
2. The verdict in the report header changes to `BLOCK_OVERRIDDEN` (not `PASS`) — this distinction matters for downstream tooling
3. The findings list is preserved verbatim — the operator made an informed choice, not an ignorant one
4. A console message warns: "BLOCK overridden — N findings remain unaddressed in shipped code"

This is accountability without paternalism: the operator can ship, but the choice is documented.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Findings flag patterns the spec mandates (uniform grids, Inter, UPPERCASE section headers, highlighted pricing tier, identical page shells) | Step 1.5 spec-conformance sampling skipped | When `baseline_2026: skipped`, re-run with sampling before blocking; never block on spec-mandated uniformity or overlay-sanctioned freedoms |
| 2 | False-negative: gauntlet passes a clearly off-spec or AI-shipped page | Deviation/tell catalog out-of-date with current AI output | Run Step 8.6 critic dispatch; the critic specifically looks for off-spec deviations and content tells the catalog hasn't caught yet |
| 3 | Conformance table or finding evidence fabricated (quoted code/spec clauses not on disk) | Sampling done from memory instead of real Read/grep of project files and the spec | Every conformance-table row and evidence excerpt must come from an actual read of the cited file; Step 8.6 item 4 spot-checks this |
| 4 | Override accountability log written but verdict still ships BLOCK | `--force` invoked but the BLOCK should have been respected | Override accountability does NOT override BLOCK — it logs that the operator chose to override; manual review still required |
| 5 | Audit ships with verdict PASS but Step 8.5 grading shows multiple low_quality_shipped axes | Output grading axes not blocking ship | Per Step 8.5's ship rule: the audit ships only when ≥3 of the **4** grading axes score ≥7 (the 4th may be explicit `low_quality_shipped` with reason); verdict PASS does NOT bypass grading |
| 6 | Identity findings flag the product's declared accent/category colors or hero display font | Per-product overlay not loaded at Step 1.5 | Read `.interface-design/system.md` before flagging identity choices; overlay-declared freedoms are sanctioned (WCAG verification still applies) |
| 7 | Gauntlet passes with a clean report but the product still looks like the operator's last one | Step 1.6 skipped or its zero-siblings-found case treated as an automatic PASS | Step 1.6 is mandatory and never silently skips; a `portfolio_distinctiveness: unresolved` line is required whenever no siblings were discoverable — its absence from the report is itself a defect |

## Progress Checklist (copy into your response, check off as you go)

```markdown
## Anti-template-gauntlet progress

Mirror the section headers from this skill's body workflow (Steps 1-10 documented below) into your response — one checkbox per ### Step / ### Phase / ### Gate as you progress. The body workflow is the single source of truth for what gates exist; treat the checklist as a render of THAT structure, not a parallel definition.

Example (replace with your actual sections as you go):
- [ ] Step 1: <skill-specific name>
- [ ] Step 2: <skill-specific name>
- ...
- [ ] Final: <output artifact written>
```

This avoids drift between the checklist and the body workflow when the body changes — only one source of truth (the body's `### Step N:` headers) needs to stay current. Operator-facing visibility comes from the AI rendering the actual current sections into its response, not from a hard-coded duplicate.

## Idempotency

Re-running on the same project produces a fresh verdict. Findings are not cross-run-stable (this is a gate, not a tracking audit). For tracked findings across runs, use `/v-audit-code` instead (absorbed `/v-ui-audit` 2026-07-06).

## Cross-references

- Gauntlet check catalog: `references/gauntlet-checks.md`
- Portfolio-distinctiveness discovery mechanics: `references/portfolio-registry.md`
- Anti-AI-tells (copy): `~/.claude/skills/references/anti-ai-tells-content.md`
- Structural / audit-level tells: `~/.claude/skills/v-audit-code/references/deep-ux-audit.md`
- Canonical design system: `~/.claude/skills/references/design-system-spec.md`
- Visual spec deviations: `~/.claude/skills/_v-design.md` § Spec-Deviation Detection Table
- Humanizer bash gates: `~/.claude/skills/v-content-create/references/humanizer.md`
- For broader UX audit: `/v-audit-code` (absorbed `/v-ui-audit` 2026-07-06)
- For pre-launch product readiness: `/v-prelaunch-readiness`
