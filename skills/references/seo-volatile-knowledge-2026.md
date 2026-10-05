# SEO Volatile Knowledge (August 2026)

_Last reviewed: 2026-08-12 (this is the SINGLE stamp the § Staleness rule keys on). Facts last deep-verified 2026-08-12 (targeted pass 08-11/08-12: two parallel research agents, ~29 primary/named-methodology source checks — core/spam update timeline, zero-click rates, FAQ deprecation dates, AI Mode figures, bot taxonomy, llms.txt status, schema guidance all re-verified against primary sources; individual CTR coefficients from the 2026-07-02 pass [Ahrefs -58% cut, Amsive +18.7% branded, r≈0.66-0.71 mention correlation] were NOT re-derived, only checked for contradicting evidence — none found)._

Use this reference for time-sensitive SEO, schema, and AI-search guidance. Keep these facts out of the main skill bodies so they can be updated independently. Claims are tagged `[official]` (vendor announcement/docs), `[industry-observed]` (credible third-party measurement), or `[heuristic]` (practitioner consensus, unconfirmed).

## Staleness

**A single stamp can hide older sub-claims.** Noted 2026-08-13: the stamp above reads 2026-08-12
and therefore looks fresh, but it says in its own parenthesis that three CTR/correlation
coefficients were carried over from the **2026-07-02** pass and only checked for contradicting
evidence. Those hit the 45-day mark on **2026-08-16**, four days after the "last deep-verified"
date. Any claim carried rather than re-derived now carries its own inline
`[coefficient last derived …]` tag, so the reader does not have to reconstruct that from the
header. **Re-derived 2026-08-13** against primary sources, and two of the three had precision defects that a
re-stamp alone would have preserved:
- **Ahrefs -58%** — CONFIRMED (2026-02-04, methodology as described). But the line paired 1.6% with
  the wrong denominator: -58% is computed against a **3.7% forecast counterfactual**, not the 3.9%
  measured non-AIO CTR, and "deepening from -34.5%" compared a one-year window to a two-year one.
  Both fixed in place.
- **Amsive +18.68%** — figure CONFIRMED, tag deliberately **NOT** refreshed: the study is 2025-04-16
  and has never been re-run, so a fresh derivation date would misrepresent a 16-month-old number from
  a 10-site panel as newly confirmed. Re-tagged `[industry-observed]` with its weaknesses inline.
- **Ahrefs r≈0.66-0.71** — CONFIRMED (2025-12-12), but `rigorous` was **removed**: the two correlated
  variables are both proxies for brand prominence, both come from the vendor's own products, and the
  sample is DR>40 — the opposite of the operator the bullet advises.
The lesson worth keeping: **re-deriving a coefficient is not the same as refreshing its date.** Two of
these three were numerically right and still misleading, and one of them should not carry a fresh
stamp at all.

**This file is volatile and decays.** Re-review if the **facts last
deep-verified** date in the stamp above is **more than 45 days old**
(that date — not an editorial-pass date — is when the claims were
checked against primary sources) — AI-search behavior, schema
support, and core-update impact shift fast enough that month-old
numbers here may already be wrong. Consuming skills SHOULD check that
date when loading this reference and **warn the
operator** if it is stale (>45 days), e.g. "seo-volatile-knowledge is
N days old — treat its specifics as directional and re-verify against
current vendor docs before making high-confidence claims." Do not
block on staleness; surface it.

**Verification-sweep source checklist (process rule, learned 2026-08-11):** every deep-verify pass MUST include Google Merchant Center / commerce-agent developer blogs alongside the search-side sources — the 2026-07-02 pass missed both the Universal Commerce Protocol (Jan 2026) and Merchant Center Conversational Attributes (May 2026) *inside its own verification window* because no commerce/agent-protocol source was in the sweep.

## Core Web Vitals

- Primary thresholds remain `LCP <= 2.5s`, `INP <= 200ms`, and `CLS <= 0.1`, assessed at the 75th percentile. `[official]` — verified against web.dev July 2026; no threshold or definition changes in 2025-2026.
- `INP` replaced `FID` on March 12, 2024; `FID` was removed from Chrome tooling September 9, 2024. Do not present `FID` as a current metric.
- **No new Core Web Vital exists.** Circulating claims of "LCP tightened to 2.0s", a "Visual Stability Index", "Engagement Reliability", or "CWV composite scoring in the March 2026 core" appear in NO Google/Chrome documentation — treat as fabricated SEO-content-farm inventions and never repeat them in findings.
- The Soft Navigations API (per-route CWV for SPAs) is in origin trial (Chrome 147+, mid-2026) with no CrUX reporting or ranking impact yet `[official]` — mention as "watch", never as a current requirement.
- Google's stance unchanged: CWV are used by ranking systems but relevance can outrank page experience; no stated CWV role in AI features. `[official]`

## Schema and Rich Result Drift

- `HowTo` rich results: dead since September 2023. **Audit finding rule:** "HowTo schema present" is NOT a Critical/high-value finding — flag at **Low** severity as "remove dead/ineffective schema" (cleanup). Absence of HowTo is correct, not a gap. Content skills must NOT emit HowTo JSON-LD — put step structure in the HTML (ordered lists / numbered H3s) under `Article`/`BlogPosting` schema instead.
- `FAQ` rich results: **fully deprecated in 2026** `[official]` — after the 2023 restriction to gov/health sites, Google added the deprecation notice to its FAQ structured-data docs on **May 7, 2026** and rich results stopped appearing the same day; the search-appearance filter, rich-result report and Rich Results Test support were removed in June 2026, and Search Console **API** support in August 2026. (Date corrected 2026-08-03 from "May 8" — re-verified against Search Engine Journal and two independent secondary sources; Google published no blog post, so the docs-notice date IS the event date.) Leftover FAQPage markup is harmless per Google, but do not recommend adding it. **FAQ-style structured content (visible Q&A patterns in the HTML) still has high value for AI Overview / AI Mode citation** — AI systems actively parse question-answer patterns; it's the rich result that's dead, not the format.
- Other 2025-2026 removals `[official]`: Practice Problem (docs removed Jan 6, 2026); Book Actions, Course Info, Claim Review, Estimated Salary, Learning Video, Special Announcement, Vehicle Listing (all purged Sept 9, 2025, explicitly "no ranking effect"); Breadcrumbs rich result desktop-only since Jan 2025; Sitelinks search box dead since late 2024.
- Direction of travel: editorial rich results are being culled while commerce/merchant markup expands (`MemberProgram` loyalty schema June 2025, `ProductGroup` variants, product `Certification`, shipping/return policies; Merchant Center **Conversational Attributes**, May 2026 — `question_and_answer`, `document_link`, `related_product`, `item_group_title`, `variant_option`, `popularity_rank` `[official]`). For content sites the durable set is: `Article`/`BlogPosting`, `Person` (author), `Organization`, `BreadcrumbList`, `ItemList`, `DefinedTerm`, `VideoObject` (for pages with genuinely embedded video — YouTube is a top AI-citation source, see § GEO (Generative Engine Optimization) Benchmarks), and product/offer types where genuinely applicable.
- **Agentic commerce** `[official]`: Google's Universal Commerce Protocol (UCP, announced Jan 11, 2026, co-developed with Shopify/Etsy/Target/Walmart) is live in AI Mode, Gemini, and YouTube Shopping — a site declares agent-transactability via a `/.well-known/ucp` JSON manifest (`ucp_version`, `capabilities`) tied to `Product`/`MerchantReturnPolicy`/`OfferShippingDetails` schema. Relevant ONLY to sites with a product/pricing surface; for those, absent UCP is a "watch — officially backed" finding (cap at MEDIUM), unlike llms.txt which no engine honors. For pure content sites it is not a finding at all.
- **No special schema exists for AI search.** Google's AI-features doc and its first generative-AI optimization guide (published May 15, 2026) both state no special structured data and no special optimizations are needed for AI Overviews / AI Mode — "AEO/GEO is still SEO". `[official]` Vendor claims that schema "boosts AI citations 30-40%" are unverified folklore — schema helps machines parse content (Illyes) but is not a ranking factor and has no credible measured citation uplift. Never present schema as an AI-visibility lever in findings; present it as parse-robustness hygiene.
- `Person` schema for article authors remains important for E-E-A-T signaling. Include `name`, `jobTitle`, `description`, and `sameAs` links. Keep the author entity consistent across articles.
- `isPartOf` relationships (Series schema) for article series signal topical authority clusters. Use when articles belong to a pillar-cluster structure.
- `Article` and `BlogPosting` schema MUST include both `datePublished` and `dateModified` in ISO 8601. Missing `dateModified` loses freshness signals.
- Schema support changes fast; validate against current Google documentation before making high-confidence claims.

## AI Overviews

- Model timeline `[official]`: Gemini 3 shipped into Search day-one on Nov 18, 2025; **Gemini 3.5 Flash became the default AI Mode model globally at I/O 2026 (May 2026)**. AI Overviews report 2.5B+ monthly users (Alphabet Q1 2026 earnings remarks, secondary-sourced).
- Trigger rate is methodology-dependent: ~15-25% of tracked keywords (Semrush panel) up to ~48% (BrightEdge, enterprise-skewed); Pew measured AI summaries on 18% of real user searches. Health/informational queries trigger far more than transactional. Never quote a single universal percentage.
- **Query fan-out is officially documented** `[official]`: AI features issue multiple related sub-queries across subtopics, so content can be cited for queries it wasn't directly targeting. Citations pull from deeper than the top-10 (the earlier ~76%→~38% top-10-citation-share drop remains `[industry-observed]`) — content structure matters more than rank position for getting cited.
- **Being cited matters measurably** `[industry-observed]`: Seer (2.43B impressions, Feb 2026): pages cited inside an AI Overview got 2.07% organic CTR vs 0.94% when not cited (+120%). Only ~1% of users click links inside the summary itself (Pew) — the citation's value is trust + the accompanying organic listing, not in-summary clicks.
- **Citable-chunk guidance (single source of truth):** lead each section with a ~**40-60 word** self-contained answer to the section's implied question, then keep extractable sub-sections short and stat-dense. This one hedged range is the canonical guidance — do NOT cite competing magic numbers. (Earlier drafts floated 40-70 / 134-167 / 50-150 word figures; all removed. The optimal length is not officially defined by Google — treat ~40-60 words as a pragmatic lead-answer target, not a rule.)
- **New spam policy (May 15, 2026)** `[official]`: Google's spam policies now explicitly name "attempting to manipulate generative AI responses in Google Search" as spam. Prompt-injection-style content ("ignore previous instructions", hidden text addressed to AI systems) is a policy violation — flag it CRITICAL if found.

## AI Mode (Google)

- Google AI Mode is a separate conversational search surface (same Googlebot index; retrieval via query fan-out). 1B+ monthly users with queries "more than doubling every quarter" `[official, I/O 2026]` — but clickstream shows AI Mode at only ~0.34% of US Google search sessions Jan-Apr 2026 `[industry-observed, SparkToro]`. Both are true: huge user count, still small share of search behavior. Do not repeat the "AI Mode handles 40% of queries" claim — contradicted by clickstream data.
- ~93% of AI Mode sessions end without an external click `[industry-observed, Semrush, desktop]` — treat AI Mode as a brand-visibility surface, not a traffic surface.
- Ads went official in AI Mode at Google Marketing Live 2026 (May) `[official]`. AI Mode shows a text ad on ~29% of commercial queries, and **ad spend buys no citation advantage**: only ~11.5% domain-level and ~2% URL-level overlap between advertisers and cited sources, with no advantage after controlling for brand strength `[industry-observed — SE Ranking, 50,032 commercial keywords, data collected June 30, 2026]`. Never let a finding imply Google Ads spend moves AI-citation visibility.
- **No separate optimization exists** `[official]`: eligibility = normal indexing + snippet eligibility. Content structured for AI Overview citation is what AI Mode retrieves. Audits must NOT produce separate "AI Mode optimization" findings — fold into citation-readiness.
- Google Search Console added **"Search Generative AI performance" reports (June 3, 2026)** `[official]`: impressions for AI Overviews / AI Mode / Discover gen-AI features per page; no click data yet; rolling out per-site. Check for it when analyzing GSC data. (An accompanying GSC opt-out toggle for AI surfaces was industry-reported but is unverified — do not cite it.)

## Zero-Click and CTR Reality

Use these when estimating traffic potential from keyword volume. Never blend numbers across studies — cite one with its methodology.

- **68% of US Google searches ended with zero clicks** (SparkToro/Similarweb clickstream, Jan-Apr 2026; was ~60% in 2024). `[industry-observed — best single methodology; excludes Google's native mobile app]`
- Position-1 organic CTR when an AI Overview is present: **~1.6% vs a ~3.7% forecast counterfactual — a -58% cut** (Ahrefs, 300K keywords / 150K with an AIO vs 150K informational without, aggregated GSC, desktop, published **2026-02-04**: https://ahrefs.com/blog/ai-overviews-reduce-clicks-update/) `[coefficient re-derived 2026-08-13 from the primary source]`. **Do not write "1.6% vs 3.9%" as the basis of -58%** — an earlier version of this line did. Both numbers are real but they are different quantities: **3.9%** is the *measured* Dec-2025 position-1 CTR for informational keywords with no AIO; **3.7%** is the *forecast counterfactual* for AIO keywords had they not triggered one, and Ahrefs computes (0.016-0.037)/0.037 from the latter. Pairing 1.6% with 3.9% yields -59%, not -58%. **"Deepening from -34.5%" is not a like-for-like series**: that figure (https://ahrefs.com/blog/ai-overviews-reduce-clicks/, 2025-04-17) compared Mar-2024 to Mar-2025, a one-year window, while -58% compares Dec-2023 to Dec-2025, two years; Ahrefs says so itself. Direction is well supported; the 34.5 -> 58 progression is not one method measured twice. Pew: users click a traditional result on 8% of searches with an AI summary vs 15% without (https://www.pewresearch.org/short-reads/2025/07/22/, published 2025-07-22, **browsing data from March 2025** — 900 US adults, 68,879 searches; no 2026 re-run of this metered measurement exists, the 2026 Pew AI work is attitudinal, so treat 8%/15% as a 17-month-old and probably conservative floor).
- Branded keywords with an AI Overview showed CTR *gains* (**+18.68%**, Amsive, https://www.amsive.com/insights/seo/google-ai-overviews-new-research-reveals-how-to-navigate-click-drop-off/) `[industry-observed — 10 client sites, 10K AIO-triggering keywords, data source unstated]` — zero-click damage is concentrated on unbranded informational queries. **This tag was deliberately NOT refreshed on 2026-08-13.** The study is dated **2025-04-16** and has never been re-run; every 2026 article quoting +18.68% traces back to this one post, which is the circular-vendor-citation pattern rather than replication. Re-stamping it with a fresh derivation date would misrepresent a 16-month-old figure as newly confirmed. Its weaknesses are load-bearing and should stay visible: 700K keywords across only **10 websites** in 5 industries, narrowed to 10K that both triggered an AIO and already ranked; only **4.79% of branded keywords triggered an AIO at all**, so the branded cell is a slice of a slice; no stated data source (GSC or rank tracker), no confidence intervals, no significance testing, no limitations section; and it predates AI Mode entirely. **The § Zero-Click calibration rule "branded -> no discount" rests entirely on this single unreplicated 10-site figure** — that dependency is stated here so it is visible wherever the rule is applied.
- AI-assistant referrals (ChatGPT, Perplexity, Claude, Gemini, Copilot) are still only **~1-3% of typical content-site traffic** `[industry-observed]`, growing fast (+40-350% YoY on a small base) and converting markedly better than average (panel-dependent; treat uplift figures as directional). ChatGPT began surfacing clickable brand links inside answers May 7, 2026, boosting referral volume `[industry-observed]`.
- **Practical keyword calibration:** informational keyword with likely AI Overview → apply high zero-click discount (assume ~50-80% CTR haircut vs historical curves); commercial/comparison/transactional intent → smaller discount; branded → no discount. This is what `ai_click_probability` in v-audit-seo Dim 4 encodes.

## GEO (Generative Engine Optimization) Benchmarks

- **The real academic basis** is the Princeton/Georgia Tech GEO study (Aggarwal et al., KDD 2024): adding **quotations (+~41%), statistics (+~32%), and source citations (+~30%)** improved generative-engine visibility; keyword stuffing did nothing. Cite this, not vendor folklore.
- **Newer and larger:** Vishwakarma et al. 2026, "What Gets Cited: Competitive GEO in AI Answer Engines" (arXiv 2605.25517; published in SIGIR '26 proceedings, July 2026 — peer-reviewed) — 252,000 paired-comparison trials across 6 LLMs in a controlled two-document RAG testbed, 18 content factors with source order counterbalanced, measuring which source the FIRST citation marker references. Finds **topical relevance and list position are the biggest drivers of being cited first** — content quality matters, but where a source sits among competing retrieved passages matters at least as much. Implication: traditional ranking work and multi-engine index presence remain load-bearing for AI citation; citability formatting alone cannot compensate for weak retrieval position.
- **YouTube is a first-class AI-citation surface** `[industry-observed — Otterly.ai, 100M+ citation instances, May 2026]`: ~23% of Google AI Overview citations are YouTube URLs; ~94% of cited videos are long-form (not Shorts), instructional/how-to dominant. A published long-form video is a zero-outreach citable asset; pages embedding genuinely relevant video should carry `VideoObject` schema (see § Schema and Rich Result Drift).
- Stat density target: 1 specific statistic or data point per 150-200 words, each with source attribution `[heuristic, Princeton-aligned]`. AI engines preferentially cite content with hard data. Do NOT quote specific "X% visibility uplift" numbers beyond the Princeton figures — the rest are unsourced vendor panels.
- **Unlinked brand mentions correlate with AI visibility more strongly than backlinks** `[industry-observed]` `[coefficient re-derived 2026-08-13 from the primary source]`: Ahrefs' 75,000-brand study, **2025-12-12, https://ahrefs.com/blog/ai-brand-visibility-correlations/** — branded web mentions vs AI-engine visibility, **Spearman**: ChatGPT 0.664, AI Mode 0.709, AI Overviews 0.656; link metrics 0.19-0.33 (AI Overviews DR 0.326 sits just above the quoted 0.2-0.3 band). **Pin that URL** — there are TWO Ahrefs 75K-brand studies, and 0.664 means *AI Overviews* in the May-2025 one (https://ahrefs.com/blog/ai-overview-brand-correlation/) but *ChatGPT* in this December one, so a re-derivation can land on the wrong paper and get a plausible false match. **The `rigorous` tag was removed on 2026-08-13** for three reasons: the independent variable (brand mentions on the web, Ahrefs' index) and the dependent variable (brand mentions in AI answers, Ahrefs Brand Radar) are both proxies for brand prominence, so r≈0.7 is close to correlating a quantity with itself with brand size as common cause; both variables come from the vendor's own index and from a product it sells for this purpose; and the sample is restricted to **DR > 40** domains with a keyword at **>=800 monthly searches**, which is the opposite of the zero-outreach operator this bullet advises, so the implication is an extrapolation beyond the sampled population. Note also that "AI visibility" here means brand *mentions* in AI responses, not citations — and this file's own § GEO section records that the two diverge ~62% of the time. **Correlation, and not a tactic:** Google's AI-features guidance (https://developers.google.com/search/docs/fundamentals/ai-optimization-guide, last updated **2026-07-10**) says verbatim that *"Seeking inauthentic 'mentions' across the web isn't as helpful as it might seem"* — note **inauthentic**, which is narrower than the older paraphrase "seeking mentions for their own sake does not work", and which actually supports the *organically earned* reading better than that paraphrase did. Implication for zero-outreach operators: build assets that get *named* (free tools, data, canonical definitions); do not go acquiring mentions.
- **Freshness is heavily weighted by AI engines** `[industry-observed]`: ~50% of AI-cited content is <13 weeks old; recently updated content ~4.3× more likely to be cited. Visible "Last Updated" dates + genuinely refreshed content are a first-order AI-citation lever.
- ~62% of AI citations don't produce a brand mention and vice versa ("ghost citations", Semrush) — citations correlate with topical authority + original content; mentions with brand positioning. Track both.
- Extractable "knowledge snippets" per section: use the canonical citable-chunk guidance from § AI Overviews (lead with a ~40-60 word self-contained answer, then short stat-dense sub-sections). Do not introduce a separate word-count band here.
- Entity specificity: use proper nouns, named technologies, and concrete examples. LLMs identify and cite content through entity recognition.
- Multi-engine awareness: optimize for citation across Google AI Overviews/AI Mode, ChatGPT search, Perplexity, Copilot, and Claude. All pull from well-structured, fact-dense, cited content; ChatGPT citations overlap heavily with Bing top-10 and skew to Wikipedia-class sources `[industry-observed]`. Citation-weighting "formulas" circulating for any engine are reverse-engineered folklore — never present them as fact.

## Google Core and Spam Updates (2026)

Five confirmed updates in 2026, all completed; nothing ongoing as of July 2, 2026 `[official, Search Status Dashboard]`:

| Update | Dates | What it was |
|---|---|---|
| February 2026 Discover update | Feb 5-27 | **Discover-only** (first ever): less clickbait, favors in-depth/original content from sites with topic-level expertise. Did NOT affect Search rankings — never cite it as a Search ranking change. |
| March 2026 spam update | Mar 24-25 (~20h) | SpamBrain enforcement of existing policies; no new policies. |
| March 2026 core update | Mar 27 - Apr 8 | Standard broad core update. Industry chatter about "E-E-A-T amplification" is speculation — Google described it generically. |
| May 2026 core update | May 21 - Jun 2 | Standard core update; felt larger than March's `[industry-observed]`; attribution muddied by I/O-week AI Mode changes. |
| June 2026 spam update | Jun 24-26 | General spam update; reportedly NOT link-spam and NOT site-reputation abuse. |

- **Scaled content abuse**: policy unchanged since March 2024 (method-agnostic — AI-generated at scale without added value). Enforced via spam updates + manual-action waves (notably June 2025 against high-volume AI-content sites). Do not attribute the policy name to 2026. Reports of 60-90% losses for near-identical template pages are plausible but unconfirmed by Google.
- **Site reputation abuse**: manual-actions-only as of mid-2026 `[official statements]` — claims it "went algorithmic" are unverified conflation.
- **Programmatic SEO**: **no official numeric thresholds exist** — Google has never published uniqueness percentages, page counts, or velocity limits. The circulating "70% uniqueness ratio" survivability line is `[heuristic, industry observation]` only. Durable guidance: pSEO built on genuinely unique per-page data (live pricing, real comparisons, verified listings) survives spam updates; template text with keyword swaps does not. Noindex thin/duplicate pages; each page must answer a distinct query.
- **Small-site context**: the Sept-2023 HCU-hit class saw its first real recoveries at the June 2025 core update; as of mid-2026 that class is no longer uniformly suppressed. Topical authority (site-wide demonstrated expertise in a niche) is the closest officially-aligned theme (echoed in the Feb 2026 Discover update language).
- Treat specific threshold numbers as current enforcement observations, not permanent rules.

## AI Search and Bot Guidance

Three-tier bot structure is now officially documented by OpenAI and Anthropic — reflect it in robots.txt recommendations:

| Tier | Bots | Note |
|---|---|---|
| Search indexing (allow if you want AI citations) | `OAI-SearchBot`, `Claude-SearchBot`, `PerplexityBot`, `Bingbot`, `Googlebot`, `Applebot`, `Amzn-SearchBot` | Google AND Apple have NO separate AI-answer bot — AI Overviews/AI Mode and Siri/Apple Intelligence both ground on the normal index crawl |
| Live user-triggered fetch (allow) | `ChatGPT-User`, `Claude-User`, `Perplexity-User`, `Meta-ExternalFetcher`, `Amzn-User` | Fired when a user's question fetches your page; OpenAI's and Meta's docs note these may not fully honor robots.txt for user-initiated fetches |
| Training (operator's call) | `GPTBot`, `ClaudeBot`, `CCBot`, `Google-Extended`, `Applebot-Extended`, `Meta-ExternalAgent`, `Amazonbot` | Blocking these does NOT affect search citations |

- **Most common misconception** `[official]`: blocking `Google-Extended` does NOT remove a site from AI Overviews / AI Mode — those are Search features fed by Googlebot; only snippet controls (`nosnippet`, `max-snippet`) or `noindex` do that.
- **Apple mirrors Google's no-separate-AI-bot pattern** `[official — support.apple.com/en-us/119829, doc updated 2026-06-08]`: Applebot-crawled content grounds Siri/Apple Intelligence answers directly; `Applebot-Extended` controls training-use opt-out only and does not itself crawl.
- **Amazon split Amazonbot into three UAs (2026-06-15)** `[official — developer.amazon.com/amazonbot]`: `Amazonbot` (training), `Amzn-SearchBot` (search indexing — eligibility for Alexa/Alexa+ search experiences), `Amzn-User` (live fetch on a user's behalf). The prior single-bot mental model is stale.
- **Grok/xAI remains undocumented** `[industry-observed, verified 2026-08]`: xAI publishes no official crawler UA, robots.txt guidance, or bot-docs page. Do NOT recommend allow/block rules targeting "Grok" — there is nothing authoritative to target; revisit when xAI documents one.
- OpenAI's official "cited but not trained" recipe: Allow `OAI-SearchBot`, Disallow `GPTBot`; robots.txt changes propagate ~24h. `[official]`
- Default recommendation for sites that WANT AI-citation traffic: allow all search-tier + user-tier bots; training-tier is a business decision with no citation impact. robots.txt is honor-system — enforcement requires WAF/edge rules (bot spoofing is common).
- **CDN/WAF edge posture now overrides robots.txt in practice** `[official — Cloudflare blog "Your site, your rules" + changelog 2026-07-01, verified 2026-08-12]`: Cloudflare blocks training-tier bots by default on new zones (since July 2025); from **Sept 15, 2026** it defaults to blocking Training- AND Agent-tier bots (`ChatGPT-User`, browser-driving agents) on ad-supported pages — scope: new domains, new sites on existing accounts, and Free-tier accounts with unchanged settings; existing configured zones keep their settings — and its one-click "Block AI Bots" toggle does NOT distinguish training crawlers from citation-earning search crawlers — a single click silently kills citation eligibility. Search-tier bots stay allowed by default. **A robots.txt read is NEVER sufficient evidence of AI-crawler accessibility** — the only valid evidence is a live fetch per user-agent (anti-pattern I3's curl loop, including search-tier AND user-tier UAs). Cloudflare's Content Signals Policy (machine-readable `search` / `ai-input` / `ai-train` robots.txt lines) is an emerging precision improvement over bare UA blocks — nascent adoption, note-only, never above LOW.
- **llms.txt (as of July 2026): no major AI engine officially honors it.** Google officially will NOT use it (Mueller compared it to the keywords meta tag; Illyes confirmed) `[official]`. OpenAI: no support; GPTBot fetches it only incidentally. Anthropic publishes one for its own docs but has never confirmed consuming third-party llms.txt. Perplexity's "we retrieve it" claim is weakly-sourced vendor hearsay. Adoption ~6-10% skewed to dev-docs sites; log studies show no measurable citation effect. Worth publishing only for docs-heavy sites at zero cost; **cap llms.txt findings at LOW severity** and never recommend as a priority item.
- Measurement surfaces `[official]`: Bing Webmaster Tools **AI Performance report** (Feb 2026, expanded June 16, 2026 — citation counts, grounding queries, citation share across Copilot + partner surfaces; the most granular official AI-citation telemetry). GSC **Search Generative AI performance** report (June 3, 2026, impressions only, per-site rollout). GA4: custom channel group with AI-referrer regex, placed above Referral; AI apps often strip referrers → measured AI traffic is a floor.

## Content Freshness

- Freshness tactics such as visible update dates, current examples, and refreshed statistics should be treated as current search behavior guidance, not timeless guarantees.
- Avoid hard performance or traffic uplift claims in SKILL bodies.
- Visible "Last Updated" dates near the author byline are a freshness signal for both Google and AI retrieval systems — and AI engines weight recency hard (see § GEO (Generative Engine Optimization) Benchmarks: ~50% of cited content <13 weeks old).
- The freshness signal must be honest: `dateModified` bumps without material content changes are detectable (v-audit-seo anti-pattern C2) and risk trust damage.

## E-E-A-T Author Signals

- Google's official position `[official, docs updated Dec 2025]`: "E-E-A-T itself isn't a specific ranking factor" — systems use a mix of signals that can identify content with good E-E-A-T. Frame E-E-A-T work as aligning with what ranking systems reward, never as "increasing your E-E-A-T score".
- Quality Rater Guidelines (Jan 2025 update, current as of mid-2026): AI-generated or paraphrased content with "little effort, originality, added value" rates **Lowest** — generative AI is explicitly named as a scaled-abuse tool. This is the strongest official basis for the anti-AI-tells and humanizer gates.
- Sites with strong author bios, consistent topic coverage, and external citations correlate with ranking gains `[industry-observed]`. First-hand experience (the first "E") is consistently rewarded per Google's published guidance, but claims that any specific 2026 update "amplified E-E-A-T weighting" are speculation — do not cite them.
- Author entity consistency across articles within a topic cluster supports topical authority. Implement `Person` schema with `sameAs` links (see § Schema and Rich Result Drift).
- Treat all ranking impact claims in this section as current observations, not confirmed ranking factors.

## Usage Rule

If a workflow step depends on the items above, point here from the skill body and keep the body focused on:
- what to inspect
- what to verify
- what to report

Do not restate these volatile facts inline unless the reference is being updated at the same time.
