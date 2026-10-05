# Privacy-friendly analytics + Core Web Vitals capture

_Last reviewed: 2026-08-02 (fixed dangling citations now that `v-launch-cookie-consent.md` exists; prev 2026-07-05 ecosystem review sweep)._

> **Persona for this reference:** senior solo-SaaS launch
> operator. Loaded by `v-prelaunch-readiness` Surface 6 check
> when the operator has not yet picked an analytics tool, and
> by `v-launch-channels` Step 8 pre-publish summary when launch
> traffic is imminent and no measurement baseline exists.
>
> **Last verified:** 2026-05-10. Re-litigate annually — the
> privacy-analytics tool landscape shifts on 18-month horizons.

The decision here is small but compounds: every other launch
recommendation (perf baseline drift, conversion lift attribution,
post-launch SEO compounding, retention diagnostics) needs a
measurement substrate. Without one, you ship blind.

---

## When this applies

You need this BEFORE launch when:

- No analytics is installed yet OR analytics is GA/UA-only and
  you haven't decided on a privacy posture.
- You want Core Web Vitals (LCP / INP / CLS) captured against
  real-user traffic, not lab data.
- You haven't decided whether the site needs a cookie-consent
  banner (privacy-friendly analytics with no PII can avoid the
  banner requirement; tracking pixels mandate the banner — see
  `~/.claude/skills/references/v-launch-cookie-consent.md`
  § The decision tree).

You do NOT need this if you've already deployed a privacy-friendly
analytics tool with CWV capture and a measurement baseline. Skip
this surface and proceed.

---

## Category-level decision frame

Pick by audience and PII appetite, not by brand:

| Posture | Use when | Tradeoff |
|---|---|---|
| **Privacy-friendly, no PII, no cookie banner needed** | EU traffic likely; B2B buyers' procurement may scrutinize; you don't need cross-device user tracking | Cohort analysis is shallow; can't follow individual users across sessions |
| **First-party + PII with cookie banner** | You need user-level funnels (signup → activation → upgrade) at individual-user resolution | Banner fatigue = consent rates 30-60% in EU; baseline data is incomplete |
| **Hybrid: privacy-friendly for marketing, in-app product analytics with consent** | You want clean marketing-site data + consented in-app product telemetry | Two systems to maintain; stitching cohorts is harder |

**Default for a solo SaaS at 0–100 customers:** privacy-friendly,
no PII, no banner. Add product analytics post-activation only
when a specific question requires individual-user resolution.

---

## Tool examples (last-verified 2026-05-10 — verify pricing + EU
data residency before adopting; brands listed are illustrative,
not endorsements)

**Privacy-friendly category:**
- Plausible (EU-hosted option; lightweight script ~1KB; cookie-less)
- SimpleAnalytics (EU-hosted option; cookie-less; CWV add-on)
- Umami (self-hostable; cookie-less)
- Fathom (cookie-less; US/EU regions)

**Core Web Vitals capture options:**
- The above tools have CWV add-ons or built-in capture
- Vercel Analytics (built-in CWV if hosted on Vercel)
- Google Search Console (CWV reporting at site level — lab + field)
- web-vitals npm package (~1KB; sends LCP/INP/CLS to any endpoint)

**What NOT to install pre-launch:**
- Heavy product-analytics (Mixpanel, Amplitude, Heap, PostHog) — fine
  later; pre-launch they slow LCP and require consent overhead
- Marketing pixels (Meta, LinkedIn Insight, Google Ads) — only when
  paid acquisition starts; mandates the cookie banner
- Heatmap tools (Hotjar, FullStory) — premature pre-launch; high
  PII surface area, mandates consent

---

## Pre-launch install checklist

1. **Pick category posture** (default: privacy-friendly + CWV)
2. **Install the chosen tool** with a script tag that fires on
   every page (not behind consent for the privacy-friendly path)
3. **Verify CWV capture** — visit the site from a real device
   (not localhost), wait 30 seconds, confirm LCP / INP / CLS
   values land in the dashboard within 10 minutes
4. **Capture baseline** — run 5-10 page loads from a US and EU
   IP (use a VPN if solo). Note baseline LCP / INP / CLS for
   the homepage, pricing page, signup page, and one logged-in
   page. **This is the pre-launch perf reference; post-launch
   regression detection depends on it.**
5. **Set CWV alerts** — even a manual weekly review beats no
   alerts. Threshold: LCP >2.5s or CLS >0.1 → investigate.

---

## What goes in the pre-launch report

Surface 6 (OG / Social Meta Tags) check should also confirm:
- [ ] Privacy-friendly analytics installed (or deliberate
      decision to use consent-based stack documented)
- [ ] CWV capture verified end-to-end
- [ ] Pre-launch baseline LCP / INP / CLS captured per surface
      (homepage, pricing, signup, logged-in)
- [ ] CWV thresholds documented for post-launch regression
      detection

If any of the above are not met before launch, flag MUST-FIX in
the readiness report.

---

## Cross-references

- Pre-launch readiness gate: `~/.claude/skills/v-prelaunch-readiness/SKILL.md`
- Surface 6 (OG / Social Meta Tags): `~/.claude/skills/v-prelaunch-readiness/references/surface-checks.md`
- Volatile SEO knowledge (CWV thresholds + 2026 ranges): `~/.claude/skills/references/seo-volatile-knowledge-2026.md`
- Cookie consent decision (when consent IS required): `~/.claude/skills/references/v-launch-cookie-consent.md`
