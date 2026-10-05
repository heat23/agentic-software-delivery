# anti-ai-tells-content — Shared catalog of AI-built content fingerprints

_Last reviewed: 2026-07-06 (theme-consistency sweep A: de-enumerated the consumer list, added the casing note inside §H; earlier same day: design-language consistency pass)_

Copy-generating and copy-judging skills reference this catalog when
checking for AI-generated content fingerprints — do not enumerate
consumers here (the list rots; at last count there were 15+). Distilled from
v-ui-audit's checklist + v-content-create's humanizer pass. (v-ui-audit
was retired 2026-07-06 and absorbed into `/v-audit-code`'s deep
UX/a11y mode, § 2 "Anti-AI-tells catalog" in
`skills/v-audit-code/references/deep-ux-audit.md` — that section
defers structural-tell judgment here and adds its own calibration
rule on top, per its own Cross-references.)

**How to use this file:** each content skill's SKILL.md adds one
line: *"Apply the AI-tells catalog from
`~/.claude/skills/references/anti-ai-tells-content.md` before
declaring content ready to ship."*

The thresholds below are battle-tested in the v-content-create
programmatic humanizer gate (Step 9).

---

## A. Banned-word frequency (case-insensitive)

| Word / phrase | Threshold (per article) | Replacement direction |
|---|---|---|
| comprehensive | ≤2 | concrete claim ("covers 8 file formats, 200K records") |
| powerful | ≤2 | what it does specifically |
| modern | ≤2 | what year, what stack, what pattern |
| next-generation | ≤1 | what's the previous generation, what's new |
| AI-powered | ≤1 | which AI, which task, what the user gains |
| leverage | ≤2 | "use" or specific verb |
| synergy | ≤1 | drop entirely (always meaningless) |
| robust | ≤2 | "handles X edge cases" |
| seamless | ≤1 | what's the friction it removes |
| delve | 0 | "we look at" / "we cover" |
| tapestry | 0 | drop |
| navigating | ≤1 | "moving through" / specific action |
| embark | 0 | "start" |
| utilize | 0 | "use" |
| streamline | ≤1 | "remove N steps from X workflow" |
| revolutionize | 0 | "change how teams do X" |
| transformative | 0 | "changes [specific outcome]" |
| cutting-edge | 0 | name the technique / year of the technique |

**Rule:** if any banned word appears more than its threshold in a
single document, FAIL the gate and rewrite the offending sentences.

## B. Hedging openers (sentence-initial)

These phrases at the start of a sentence are AI fingerprints. Cap
at **1 hedging opener per article**:

- "It is important to..."
- "It's worth noting that..."
- "It's worth mentioning..."
- "In today's fast-paced world..."
- "In an era where..."
- "In the world of..."
- "When it comes to..."
- "At the end of the day..."
- "At its core..."
- "Ultimately,..."

**Rule:** delete the opener; start with the point. The "important
note" is either important enough to be the headline of the
section, or it's not important enough to keep.

## C. Em-dash density

LLM output overuses em-dashes as a default rhythm. Threshold:
**≤3 em-dashes per 500 words** of body copy.

Mix in:
- Colons (introduce a list, definition, or punchline)
- Periods (separate clauses)
- Parenthetical commas (subordinate detail)
- Semicolons (related independent clauses)

Em-dashes for emphasis are fine. Em-dashes as the dominant
punctuation are the tell.

## D. Contraction ratio (conversational content only)

Email, blog, social, in-product copy MUST use contractions in at
least **30%** of opportunities. Formal documents (legal, terms,
changelog) are exempt.

Forms to count:
- formal (denominator): "it is", "do not", "cannot", "will not",
  "would not", "should not", "could not", "are not", "is not",
  "we are", "you are", "they are", "i am"
- contracted (numerator): "it's", "don't", "can't", "won't",
  "wouldn't", "shouldn't", "couldn't", "aren't", "isn't",
  "we're", "you're", "they're", "i'm"

If `contracted / (formal + contracted) < 0.30`, FAIL.

## E. First-person presence

Articles longer than 800 words must contain at least **1
first-person reference per 1000 words**. Pronouns: I, we, our,
us, me, my.

First-person presence is an E-E-A-T experience signal. Zero
first-person across an entire article = AI default. Add 1-2
opinionated/experience-based statements per 1000 words.

## F. Structural fingerprints

Beyond word-level checks, watch for these structural patterns:

| Pattern | Symptom | Fix |
|---|---|---|
| Uniform paragraph length | All paragraphs 3-4 sentences | Vary: some 1-sentence, some 5-6 |
| Uniform sentence length | All sentences 15-20 words | Mix short (5-8) with longer explanatory |
| List-heavy structure | >3 bullet lists per 1000 words | Convert some to prose paragraphs |
| Symmetric H2 structure | Every H2 has exactly 3 sub-points | Vary section depth (2, 4, none) |
| Predictable conclusions | "In conclusion, [restate everything]" | End with specific CTA or provocative thought |
| Sycophantic intros | "This powerful tool revolutionizes..." | State facts plainly: "This tool does X" |
| Three-feature row | `<icon> <h3> <p>` × 3 with parallel structure | Vary; one feature gets longer treatment |
| Pricing dark patterns | Fake urgency ("only 3 seats left"), hidden auto-renewal, confirm-shaming ("No thanks, I hate saving money"), pre-checked upsells | Remove the manipulative cue. **NOTE:** a highlighted / "Recommended" / "Most Popular" middle tier is **NOT** a tell — it is a mandated pattern (`design-system-spec.md` §10 "Marketing Page Structure", Pricing item: "Highlight recommended tier"). Only the dark-pattern cues above are findings; a normal recommended-tier highlight is correct-by-default. |
| Initials-only testimonials | "Priya S. — Staff Engineer" | Real names + companies + photos |

## G. Marketing-page-specific tells (Critical-Craft on key surfaces)

When auditing marketing pages (Home / Pricing / About / Features),
these patterns are Critical-Craft. Each one is a finding:

| Pattern | What to grep / look for |
|---|---|
| "Comprehensive {category}" / "Modern {category}" / "Powerful {noun}" / "Next-generation" / "AI-powered" | Read homepage h1 / og:title; grep for these literal phrases |
| Generic abstract claims with no specifics ("Save hours every week", "10x your team's productivity") | Hero subhead and CTA copy — count specific numerals or named workflows |
| Centered hero stack: badge + h1 + subhead + 2 CTAs (left primary, right outline) | Hero markup matches `text-center` + `<Badge>` + `<h1>` + `<p>` + 2 `<Button>`s pattern |
| 60/40 hero with stock illustration on the right | Hero has 2-column layout where right column is undraw.co / storyset / freepik / pexels SVG |
| Pastel gradient backgrounds without intent (`from-indigo-100 via-purple-100 to-pink-100`) | Grep `bg-gradient-` in hero/section backgrounds |
| Over-rounded corners on EVERYTHING (`rounded-3xl`, `rounded-[24px]`) | Count `rounded-3xl` usages; >5 across primary surfaces = finding |
| Pricing dark patterns (fake scarcity, hidden auto-renewal, confirm-shaming) | Grep the pricing page for countdown timers, "only N left", pre-checked add-ons, or renewal terms hidden below the fold. **A highlighted / "Recommended" middle tier is a MANDATED pattern** (`design-system-spec.md` §10 Marketing Page Structure, Pricing item) — do NOT flag it as a tell; only the manipulative cues here are findings. |
| "Trusted by 10,000+ teams" / "Loved by users worldwide" with no specific company logos | Hero has social proof copy + zero named-customer evidence |
| Generic three-feature row icons + heading + paragraph | Look for `grid grid-cols-3` with `<icon /> <h3> <p>` cells under hero |
| AI-illustration aesthetic (3D blob renders, glassmorphism, gradient mesh) | Hero / dashboard graphics use trendy-AI visual styles |
| "Get started in seconds" / "Setup in 30 seconds" as a CTA caption | CTA caption contains these literal phrases |
| Stock illustrations on About / Team / Empty pages | `<img>` referencing undraw.co / storyset.com / freepik.com / pexels.com / unsplash.com (decorative) |
| Generic emoji as decoration (🚀 ⚡ ✨ 💡 in headlines or feature labels) | Modest use is fine; cluster of 4+ on a marketing page = AI-tell |
| Default Radix / shadcn appearance everywhere (no design tokens beyond rename) | Read `Components/ui/*.tsx` — if they're nearly identical to shadcn defaults |
| "Built with Next.js / Tailwind / shadcn" in footer or About | Grep for these strings in footer markup |
| Newsletter signup with "Get updates" or "Join our newsletter" | Generic CTA copy with no specific value prop |
| Footer with 4-column link grid + "© {year} Brand. All rights reserved." | Standard SaaS footer with no signature treatment |
| Identical button widths in 3-up CTA arrangements | All CTAs same `w-full` or fixed width across columns; no asymmetry |
| Animation: every section uses `animate-in fade-in` on scroll | All sections have identical reveal animation = template feel |

## H. In-product microcopy tells

**Casing (owned here — cite this note, don't restate the rule):** pick ONE
convention per product for in-product headings, labels, and microcopy;
sentence case is the editorial default. EXCEPTION: spec-mandated UPPERCASE
section headers/labels (`design-system-spec.md` §2 Typography → "Typography
Rules", `_v-design.md`) are design-system conformance — never flag them as a casing inconsistency or
rewrite them to sentence case. Mixed title-case/sentence-case within the same
surface IS a tell.

| Pattern | Example | Fix |
|---|---|---|
| Generic confirm dialog | "Are you sure?" / "Confirm / Cancel" | Name the consequence ("Delete project / Keep project") |
| Generic error toast | "Something went wrong" / "An error occurred" | Be specific ("Couldn't reach the server — try again or [reconnect]") |
| Generic empty state | "No X yet" with no follow-on orientation | Add 1-line orientation + primary CTA |
| Boilerplate page titles | `{Page} \| {Brand}` template | Distinctive titles ("Find the invoices that need action") |
| Footer "Made with ❤️" / "Built with React" | Brand-trust withdrawal on a B2B tool | Remove or replace with a real signature line |
| 500 page boilerplate | "Something went wrong on our end. We've been notified." | Brand-deposit copy that acknowledges the irony or reinforces reliability |

---

## Severity calibration when used in an audit context

| Surface | Severity if a tell is found |
|---|---|
| Homepage / Pricing / About hero (highest leverage) | Critical-Craft |
| Marketing secondary pages | Medium-Craft |
| In-product primary surfaces (Dashboard, Settings, Billing) | Medium-Craft |
| Footers, sidebars, modals | Low-Craft |
| Email lifecycle templates | Medium-Craft if on welcome/checkout/upgrade emails |

For content-CREATION skills (not audits), failing thresholds A-E
are HARD FAILURES — re-task the writer/agent before shipping.

---

## Why this catalog exists

Generic SaaS content is the default LLM output. The thresholds
above are calibrated to push past that default. They are not
arbitrary stylistic preferences — each one corresponds to a
specific failure mode of LLM-generated content that hurts SEO
(Google Helpful Content), reader trust, and brand differentiation.

Skills referencing this file inherit the calibration. Update this
file (not individual skills) when thresholds need to shift.

## Staleness

**The per-word thresholds and tell catalogue in this file decay.** What reads as an AI fingerprint
tracks how current models actually write, so a threshold tuned against one model generation
mis-fires against the next — both directions matter: a retired tell produces false positives that
train the operator to ignore this file, and a NEW tell goes uncaught entirely.

Re-review if the `_Last reviewed:` stamp above is **more than 90 days old** (slower than
`seo-volatile-knowledge-2026.md`'s 45 days — writing-style drift is real but not weekly). Consuming
skills SHOULD check that date on load and **warn, never block**: "anti-ai-tells-content is N days
old — treat its per-word caps as directional and confirm a flagged phrase still reads as a tell."
On re-review, re-derive the thresholds from current output rather than adjusting the existing
numbers, and record what was checked in the stamp.
