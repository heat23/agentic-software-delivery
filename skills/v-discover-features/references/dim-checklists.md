# v-discover-features research dimensions

_Last reviewed: 2026-07-06 (theme-consistency sweep A: SEO/AEO + growth-motion + copy/voice alignment; prev 2026-07-05)._

> **Persona for this reference:** senior product strategist with
> experience running competitive feature-gap analyses across SaaS
> verticals — reads the codebase as ground truth and marketing copy
> as aspiration. Loaded on-demand by v-discover-features Step 1.

The dimension prompts below are dispatched as **fork-safe `claude -p`
subprocesses** via `~/.claude/skills/v/references/v-dispatch-subagent.sh`
(`--model sonnet --mode capture --extra-tools "WebSearch WebFetch"`) —
**NOT** the Agent tool. v-discover-features runs `context: fork`, so a
nested Agent dispatch fails silently and degrades to inline work; the
subprocess is a genuinely independent process. Each subprocess receives,
inlined verbatim in its briefing (it cannot read this file or the skill):
product context (CLAUDE.md content + detected stack), the competitor list,
and — for D2/D4 — any Ahrefs data pre-fetched in the main context during
Step 0. Each subprocess emits **ONLY its JSON object** as its final
message (no prose, no code fence); the helper writes it to
`$PROJECT_ROOT/.v/discover-features-<dim>-${CLAUDE_SESSION_ID}.json`.
Step 2 (Synthesize & Score) consolidates those files.

**Parallel fan-out is 3-5 dimensions:** D1, D2, D3 run on every
invocation; D4 (Content-Driven) runs when Ahrefs MCP is available, and
its WebSearch-only subset folds into D2 otherwise; D5 (Own User Feedback
Signals) runs when a feedback export was resolved in Step 0. Revenue
Impact is **not** a parallel dimension — it depends on D1–D5's merged
output and is applied in Step 2 via the Revenue Impact Scoring Rubric at
the bottom of this file. The dispatch sequence, synthesis logic, scoring formula, and
classification are owned by SKILL.md; this reference owns the dimension
content (focus areas + JSON schemas).

---

## Step 1: Launch Research Dimensions in Parallel

Dispatch D1–D3 always, D4 when Ahrefs is available. Each briefing gets
product context + competitor list (+ Ahrefs data for D2/D4).

### Dimension D1: Competitor Feature Mapping
```
For each competitor (3-5):
1. Visit their marketing site via WebSearch/WebFetch
2. Extract their feature list from: pricing page, features page, changelog, documentation
3. Map features to categories: core workflow, collaboration, analytics, integrations, billing, admin
4. Note which features are in which pricing tier (free vs paid vs enterprise)
5. Flag features we DON'T have (the gaps) — compare against the feature_list from Step 0
6. Sanity-check "shipped" vs "still promoted": a feature buried out of the nav/pricing may be abandoned (see SKILL Gotcha #1)

Output (emit ONLY this JSON as your final message):
{
  "dimension": "competitor_features",
  "status": "ok",
  "competitors": [
    {
      "name": "...",
      "url": "...",
      "feature_count": N,
      "features_by_tier": {"free": [...], "paid": [...], "enterprise": [...]},
      "features_we_lack": ["...", "..."],
      "features_we_have_better": ["...", "..."]
    }
  ],
  "universal_features": ["features ALL competitors have — table stakes"],
  "differentiator_features": ["features only 1-2 competitors have — potential moat"],
  "novel_opportunities": ["features NO competitor has — feature-level whitespace, not a moat claim"]
}
```

### Dimension D2: Market Demand Signals
```
Using the Ahrefs data injected from Step 0 (if present) + WebSearch:

1. Keyword gap analysis (from injected Ahrefs organic-keywords data, if data_source=ahrefs):
   - Which keywords do competitors rank for that we don't?
   - Filter to keywords with commercial/transactional intent
   - Group by feature area (e.g., "invoice templates", "team collaboration", "API access")

2. Search demand for feature categories:
   - From injected keywords-explorer data: monthly volume, difficulty, CPC (commercial value)
   - Example: if we lack "team collaboration" and "[category] team features" has 2.4K/mo volume, that's signal
   - If no Ahrefs data was injected, estimate volume from WebSearch result density and mark source "estimated"

3. "People Also Ask" analysis (WebSearch — always available):
   - WebSearch the top 3 competitor names + "features"
   - Extract PAA questions — these reveal what users want but can't find

Output (emit ONLY this JSON as your final message):
{
  "dimension": "market_demand",
  "status": "ok",
  "data_source": "ahrefs|estimated",
  "keyword_gaps": [
    {"feature_area": "...", "keywords": [...], "total_monthly_volume": N, "avg_difficulty": N}
  ],
  "paa_signals": ["questions users ask about this category"],
  "highest_demand_features": ["features with most search volume we don't have"]
}
```

### Dimension D3: User Behavior & Friction Signals
```
Analyze the EXISTING product for engagement signals (codebase analysis — no web needed):

1. Feature usage patterns (proxies from codebase analysis):
   - Which routes/pages have the most complex logic? (proxy for most-used features)
   - Which features have the most tests? (proxy for business importance)
   - Which features are behind feature flags but not yet enabled?
   - Which features have TODO/FIXME comments? (unfinished value)

2. Onboarding friction:
   - How many steps from signup to first value?
   - What's the activation milestone? Is it instrumented?
   - Where do empty states exist without helpful CTAs?

3. Upgrade triggers:
   - What gates exist between free and paid?
   - Are limits generous enough to demonstrate value?
   - Do upgrade prompts appear at natural friction points?

4. Support signal proxies:
   - Grep for error/validation messages — where is the product saying "no"?
   - These are friction points that features could solve

Output (emit ONLY this JSON as your final message):
{
  "dimension": "user_signals",
  "status": "ok",
  "high_engagement_features": ["features with most code complexity/tests"],
  "dormant_features": ["feature-flagged but not enabled"],
  "friction_points": ["where the product says 'no' or users hit walls"],
  "upgrade_gap": "analysis of free→paid conversion barriers"
}
```

### Dimension D4: Content-Driven Feature Opportunities (Ahrefs available only)
```
Features that double as organic growth engines. When Ahrefs is NOT available,
this dimension is not dispatched; its WebSearch-only subset (free tools +
templates, no traffic data) folds into D2.

1. Free tool opportunities:
   - WebSearch: "[category] free tools", "[category] calculator", "[category] generator"
   - Identify tools competitors offer for free that drive traffic + signups
   - Example: a "ROI Calculator" page that ranks for "[category] ROI" and captures leads

2. Template/resource opportunities:
   - WebSearch: "[category] templates", "[category] examples"
   - Templates are features AND content — they rank in search AND reduce time-to-value

3. Integration ecosystem:
   - What integrations do competitors list?
   - Each integration page = SEO page + feature + integration-directory presence (zero-outreach per `~/.claude/skills/references/v-core-solo-motion.md` — never frame integrations as partnership-pitching opportunities)
   - From injected Ahrefs top-pages data: check traffic to competitor /integrations/ pages

Output (emit ONLY this JSON as your final message):
{
  "dimension": "content_features",
  "status": "ok",
  "free_tool_opportunities": [...],
  "template_opportunities": [...],
  "integration_opportunities": [...]
}
```

### Dimension D5: Own User Feedback Signals (when a feedback export is provided/detected)
```
Cluster the operator's OWN user feedback into feature-request themes — support emails,
cancellation/churn survey responses, and in-app feedback tool exports. This dimension is the
counterweight to D1-D4 (which infer demand from competitors/search/codebase): it reads what
YOUR users actually said, in their own words.

Input: one or more feedback export files (path(s) resolved in Step 0 — CSV, plain text, or
JSON exports from a support tool, survey tool, or in-app feedback widget). Read them ALL; do
not sample.

1. Extract individual feedback items:
   - One item per email/response/submission — do not merge multiple people's feedback into one
     item even if the theme overlaps (frequency counting in step 2 needs the individual count).
   - Note the source type per item: support_email | cancellation_reason | in_app_feedback |
     other (whatever the export's own labeling provides).

2. Cluster into feature-request themes:
   - Group semantically-similar requests (not just keyword-identical) into one theme.
   - A theme needs >=2 independent items to be reported as a theme; singleton requests go into
     a `long_tail_mentions` bucket (still visible in output, but not scored as a theme).

3. Weight each theme:
   - `mention_count`: number of distinct items in the theme (unique users, not unique emails —
     dedupe by the export's own user/email identifier when available).
   - `recency_weighted`: weight items from the last 30 days higher than older ones (a theme
     that was hot 8 months ago and has gone quiet is a WEAKER signal than a small but recent
     cluster) — apply a simple recency multiplier (last 30d: 1.5x, 30-90d: 1.0x, >90d: 0.5x) if
     the export includes timestamps; if it doesn't, note `recency_data: unavailable` and skip
     the multiplier (never fabricate dates).
   - `churn_correlated`: true if >=1 item in the theme came from a `cancellation_reason` source
     — a feature request that's ALSO a churn reason is a stronger retention signal than a
     feature request alone. This flag feeds Step 2's revenue_mechanism classification (a
     churn-correlated theme skews toward RETENTION).

4. Anti-loud-minority guard (mandatory): a theme driven by 1-2 unusually vocal users (e.g. the
   same user submitting the same request 5 times) must NOT inflate `mention_count` — count
   unique users per theme, not raw submission count. Note any theme where a single user
   accounts for >50% of its raw submissions as `dominated_by_single_user: true` so Step 2 can
   discount it.

Output (emit ONLY this JSON as your final message):
{
  "dimension": "own_user_feedback",
  "status": "ok" | "no_feedback_source_found",
  "themes": [
    {
      "theme": "short description of the requested feature/change",
      "mention_count": N,
      "unique_users": N,
      "source_breakdown": {"support_email": N, "cancellation_reason": N, "in_app_feedback": N, "other": N},
      "recency_weighted_score": N,
      "recency_data": "available" | "unavailable",
      "churn_correlated": true | false,
      "dominated_by_single_user": true | false,
      "representative_quote": "one verbatim (anonymized) excerpt illustrating the theme"
    }
  ],
  "long_tail_mentions": ["singleton requests not meeting the >=2-item theme threshold"],
  "total_items_processed": N
}
```

**If no feedback export is provided or auto-detected:** this dimension is not dispatched at all
(not dispatched-and-failed — genuinely skipped, since the input is optional). Step 2 proceeds
with D1-D4 only; the roadmap notes `own_feedback_source: not_provided` rather than treating its
absence as a failure.

---

## Revenue Impact Scoring Rubric (applied in Step 2 — NOT a dispatched dimension)

This runs in the main context during synthesis because it consumes the
merged output of D1–D5 (D5 when a feedback export was available). For each merged feature gap:

1. Classify by **revenue mechanism**:
   - ACQUISITION: brings new users (SEO tool, free-tier feature, viral mechanism)
   - ACTIVATION: gets users to first value faster (onboarding, templates, sample data)
   - CONVERSION: moves free → paid (feature gates, upgrade triggers, premium features)
   - EXPANSION: increases ARPU (team features, usage-based pricing, add-ons)
   - RETENTION: reduces churn (habit loops, integrations, workflow automation)
   - **D5 override:** a feature whose merged D5 theme has `churn_correlated: true` classifies as
     RETENTION regardless of what D1-D4 would otherwise suggest — a request that users cited AS
     their cancellation reason is a direct retention signal, not an inference.

2. Estimate **revenue_impact** (1-5) for the non-enterprise market:
   - Acquisition: est. new organic traffic × conversion rate × ARPU
   - Activation: est. lift in activation rate × downstream conversion
   - Conversion: est. % uplift in free→paid × current free-user count × ARPU
   - Expansion: est. % of users who'd upgrade × price delta
   - Retention: est. churn reduction × LTV increase
   Map the magnitude to 1-5 (5 = directly and materially drives MRR; 1 = negligible).

3. Estimate **effort** (small | medium | large) from the CLAUDE.md tech stack:
   - Small (1-3 days), Medium (1-2 weeks), Large (2-4 weeks)
   - Step 2 maps this to `effort_inverse`: small→5, medium→3, large→1.

The resulting `revenue_mechanism`, `revenue_impact`, and `effort` feed the
`PRIORITY_SCORE` formula and the goal-weighting in SKILL.md Step 2.
