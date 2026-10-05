# Presentation & voice — practice what you preach

How you present the audit matters as much as what's in it. Build the output the way a sharp product team would, and hold yourself to the same UX and content bar you're judging the app against.

## Presentation
- **Lead, don't bury.** Verdict and the handful of things that matter go first — someone should get 80% of it in fifteen seconds. Use a clear scorecard, cards, callouts, and a small chart/visual where it genuinely earns its place.
- **No walls of text.** Break dense reasoning into tight, skimmable units — one idea per section. If a paragraph is getting long, it's probably two bullets. Dense prose is where attention goes to die.
- **Design with restraint.** A small, consistent system — a sensible type scale, real spacing, a disciplined palette, light purposeful motion — reads as "professional team." No gradient soup, no gratuitous animation, no emoji confetti, no generic stock-dashboard look. Taste, not maximalism. Match the polish to the audience: consumer surfaces can be more engaging; an internal tool should look clean, calm, and productive.
- **Prefer a self-contained, responsive artifact** (a single HTML page — scorecard, filterable findings, verdict — everything inlined, no external dependencies or vendors) over a long document, when the material warrants it. `assets/dashboard-template.html` is a ready base: fill its `SCORE` and `FINDINGS` arrays and the verdict line rather than rebuilding one from scratch. Only ship it if it's genuinely better than prose, never as decoration. Pair it with a short written report for the detail.

## Voice — write like a person, not an AI
- Direct, specific, a little opinionated. Say the thing. If it's good, say it's good; if it's broken, say what broke and why you'd care.
- **Cut the AI tells** (base catalog: `~/.claude/skills/references/anti-ai-tells-content.md` §A/§B; report-voice-specific additions here: "By leveraging", "Let's dive in"; "In today's fast-paced landscape" and "It's important to note that" are §B-class VARIANTS — the canon list and Gate 2 regex carry the "world"/"note that" forms, so catch these variants manually): "In today's fast-paced landscape", "It's important to note that", "By leveraging", "robust/seamless/comprehensive" as filler, "Let's dive in", hedging on every clause, and the tell-tale cadence where every sentence is the same measured length. Vary rhythm. Use a short sentence to land a point.
- Prefer concrete nouns and real anchors over abstractions ("the reset action fires two upstream API calls on a double-click" beats "there are potential concurrency concerns").
- Don't over-qualify. One honest "this is fine, ship it" is worth more than three paragraphs of throat-clearing.
- Keep humor dry and rare; keep it professional; never fabricate warmth. Confidence comes from evidence, not adjectives.

## Anti-patterns to avoid in the deliverable
- A findings table so long it's clearly padded (a mature codebase should yield few, sharp findings).
- Severity inflation to look thorough, or fear-mongering language unsupported by evidence.
- Restating the same point in the summary, the scorecard note, and the finding.
- Charts that decorate rather than inform; animation that delays reading.
