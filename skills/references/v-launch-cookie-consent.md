# Cookie consent banner decision

_Last reviewed: 2026-08-02 (created)._

> **Persona for this reference:** senior solo-SaaS launch operator making the
> banner-or-no-banner call once, correctly, instead of defaulting to "add a banner
> because everyone has one" (unnecessary friction + a maintenance burden) or "skip it
> because it's annoying" (real compliance exposure). Loaded by
> `~/.claude/skills/references/v-launch-privacy-friendly-analytics.md` once the
> analytics-tool posture is chosen, and by `v-legal-docs-generate` when Dimension 5
> flags `consent_banner_gap`, `gpc_gap`, or `do_not_sell_link_required`.
>
> **Last verified:** 2026-08-02. The decision rule below (PII-bearing tracking →
> banner; no-PII, cookie-less analytics → no banner) follows directly from
> GDPR/ePrivacy's non-essential-cookie-consent requirement and CCPA/CPRA's
> sale/share opt-out — it does not depend on any single vendor's terms, so it's
> durable. The jurisdiction-specific enforcement posture and consent-rate figures
> ARE volatile — re-verify before citing a number; none are asserted here.

The decision is binary and gets made once per analytics/ad-tech stack, not per
page: does anything on the site set a non-essential cookie or otherwise track an
individual across visits/sites for analytics or advertising? If yes, a banner
(and GPC handling) is required. If no, it isn't — and adding one anyway is pure
conversion-rate cost with no compliance benefit.

---

## The decision tree

**1. Does the site load any tracking mechanism that reads/writes non-essential
cookies, or otherwise identifies/fingerprints an individual, on behalf of an
analytics or ad-tech vendor?** (a persistent visitor ID, an ad pixel, a
retargeting tag, a session-replay/heatmap tool)

- **NO** — privacy-friendly, cookie-less, no persistent PII-linked ID (the
  Plausible/Fathom/Umami-class tools in
  `v-launch-privacy-friendly-analytics.md` § Category-level decision frame) →
  **no consent banner required.** These tools don't set the non-essential
  cookie that triggers ePrivacy/GDPR consent, and don't sell/share personal
  information or serve cross-context behavioral advertising, so CCPA/CPRA's
  opt-out obligations don't attach either. Document the determination once
  (which tool, why it qualifies) and move on — do not re-litigate per page.
- **YES** → continue to step 2.

**2. Is the tracking PII-bearing, or used for cross-context behavioral
advertising (retargeting, lookalike audiences, ad-conversion tracking)?**

- **YES** → **banner required, AND Global Privacy Control (GPC) handling
  required.** This is exactly the `consent_banner_gap` / `gpc_gap` /
  `do_not_sell_link_required` territory `v-legal-docs-generate` already
  detects and flags (§ Cross-references) — build the minimum-viable banner
  below.
- **NO, but the tool still sets non-essential cookies for individual-level
  analytics** (e.g. a self-hosted product-analytics tool with per-user
  session tracking, not cross-site ad targeting) → **banner required** for
  GDPR/ePrivacy-scoped traffic (EU/UK visitors hit this regardless of the
  operator's home jurisdiction). Whether CCPA/CPRA's sale/share opt-out also
  applies depends on whether that data is "sold" or "shared" per Dimension
  5's finding — do not assume either way; read its output.

---

## Minimum-viable banner (when the tree says "required")

- **Actually blocks** non-essential trackers from firing until affirmative
  consent — a banner that displays but doesn't gate script execution is
  non-compliant theater, not consent.
- **Honors the browser's Global Privacy Control (GPC) signal as a valid
  opt-out automatically**, no additional click required (CCPA/CPRA + CA AG
  enforcement precedent) — read `navigator.globalPrivacyControl` on page
  load and route a positive signal to the same opt-out path a manual
  "reject" click uses.
- **"Reject all" is exactly as easy to find and click as "Accept all."** A
  banner with one-click accept and a reject buried several clicks deep is a
  dark pattern, not consent — regulators in both the EU and California have
  treated banner-asymmetry itself as the violation, independent of what's
  being tracked.
- **Records consent state** (granted/denied, timestamp, and what was
  disclosed) so a later audit can prove compliance from history, not just
  today's UI state.

---

## What this reference does NOT do

Building the banner is a `/v-build` implementation task — this reference
(and `v-legal-docs-generate`) makes the required/not-required call and states
the behavioral requirements above; neither generates the banner's UI code (see
`v-legal-docs-generate/SKILL.md` § What This Skill Does NOT Do).

---

## Cross-references

- Consent/GPC detection this decision is downstream of:
  `~/.claude/skills/v-legal-docs-generate/references/legal-analysis-dimensions.md`
  § Dimension 5: Jurisdiction, Consent & Compliance Surface (`do_not_sell_link_required`,
  `gpc_gap`, `consent_banner_gap` flags)
- Analytics posture decision (made first; this file assumes it's already picked):
  `~/.claude/skills/references/v-launch-privacy-friendly-analytics.md`
- Cookie Policy document generation: `~/.claude/skills/v-legal-docs-generate/SKILL.md`
  § Cookie Policy Generation
- Pre-launch readiness gate: `~/.claude/skills/v-prelaunch-readiness/SKILL.md`
