---
name: v-discover-features
description: "Use when prioritizing next features from competitor gaps, user requests, search, forum signals, or the operator's own support/cancellation/in-app feedback exports."
context: fork
model: sonnet
allowed-tools: Read, Write, Bash, Glob, Grep, TaskCreate, TaskUpdate, AskUserQuestion, WebSearch, WebFetch
user-invocable: true
disable-model-invocation: true
---
<!-- skill: v-discover-features | version: 1.4.0 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: User-facing. Competitive feature discovery and roadmap generation for existing products.

Follow `_v-core.md` and `_v-exec.md`.

For model routing, read `~/.claude/skills/references/v-core-model-routing.md`.
For parallel-subagent error handling, read `~/.claude/skills/references/v-core-error-handling.md`.
For prompt pack generation, read `~/.claude/skills/references/v-core-prompt-pack.md`.

```yaml
contract:
  tier: user-facing
  accepts: [project state, product URL (optional), competitor URLs (optional), own-feedback export path(s) (optional — support emails / cancellation reasons / in-app feedback exports)]
  produces: [FEATURE_ROADMAP_[timestamp]_${CLAUDE_SESSION_ID}.md, FEATURE_ROADMAP_[timestamp]_${CLAUDE_SESSION_ID}.json, ".v-prompt-packs/v-discover-features-<MM-DD>/ (00-README.md + w<N>-*.txt wave packs per v-runnable-pack-convention.md; legacy v-feature-prompts/ still scanned by /v for backward compat)"]
  invokes: []
  dispatches: 3-4 research dimensions in parallel + 1 prompt-pack generator, as fork-safe claude -p subprocesses (v-dispatch-subagent.sh — NOT the Agent tool)
  invoked-by: [/v, user]
  estimated_tokens: 60k-150k
  estimated_duration: 10-25 min
  subagent_count: 4-5
  dependencies: [WebSearch, optional Ahrefs MCP, optional marketing/product-management plugin skills]
```

## Why This Exists

Building the right feature is more important than building features fast. Solo operators competing against funded teams can't afford to build the wrong thing. This skill answers "what should I build next?" by combining competitive intelligence, market demand data, and user signal analysis into a prioritized feature roadmap with revenue impact estimates.

For the non-enterprise market (prosumers, small teams, indie SaaS), feature decisions must balance: what users ask for, what competitors offer, what drives organic discovery, and what converts free users to paid.

## Skill Boundaries

**SME persona:** This skill is run by a **senior product strategist** with experience running competitive feature-gap analyses across SaaS verticals. Reads the codebase as ground truth and marketing copy as aspiration, and reconciles the gap — surfacing user-facing features, capabilities, and edge cases the founder built and forgot, then weighing them against competitor and market signal.

### Best fit

- Deciding what to build next for an existing product using competitor signals, demand data, and product/user evidence
- Producing a prioritized roadmap artifact that should feed `/v-plan` or `/v-build`
- Feature gap analysis where revenue, retention, and discovery signals matter more than implementation details

### Use instead

- Use `/v-plan` when the user already knows the feature and needs a concrete implementation spec
- Use `/v-audit-growth` when the goal is diagnosing funnel performance rather than choosing the next feature investment
- Use `/v-audit-messaging`, `/v-audit-analytics`, or `/v-audit-sales-pricing` when the need is a focused audit of one dimension rather than roadmap discovery

### Not for

- Greenfield product planning from scratch
- Immediate implementation without a roadmap or prioritization layer
- Pure codebase architecture understanding without market or user-signal work

## Entry Point

**V_DEPTH parsing (mandatory):** Parse V_DEPTH from invocation args per `_v-core.md` § V_DEPTH Parsing Protocol. Default to 0 if absent.

**When V_DEPTH >= 1:** Skip all questions. Use product context from CLAUDE.md and auto-detect competitors (priority list below) without confirmation. Proceed to Step 0.

**When V_DEPTH == 0**, ask the goal question:

```yaml
question: "What's driving this feature discovery?"
header: "Goal"
multiSelect: false
options:
  - label: "Increase engagement & retention (Recommended)"
    description: "Find features that make existing users stick — habit loops, power features, workflow improvements"
  - label: "Grow acquisition & organic traffic"
    description: "Find features that attract NEW users — SEO-driven tools, free tiers, viral features"
  - label: "Increase revenue per user"
    description: "Find features that justify upgrades — premium tiers, usage-based pricing, team features"
  - label: "Full competitive gap analysis"
    description: "Comprehensive comparison: what do ALL competitors have that we don't?"
```

The goal biases scoring weights in Step 2 (e.g. "increase revenue per user" up-weights `revenue_impact`; "grow acquisition" up-weights acquisition-mechanism features) — it does not change which dimensions run.

**Competitor auto-detection (not a question — resolved by the skill):** the competitor list is resolved from the highest-fidelity source that returns ≥3 candidates, in priority order:

1. **Explicit override** — `--competitors="name1 (url1), name2 (url2)"` always wins
2. **Ahrefs MCP organic-competitors** — top 5 by ranking overlap with project domain (highest-fidelity signal when MCP available)
3. **CLAUDE.md** — explicitly named competitors in the product description (cross-check against Ahrefs; flag discrepancies)
4. **Existing `/compare/*` or comparison pages** in the content directory — extract competitor names (signals prior operator research)
5. **WebSearch fallback** — `"{product domain} alternatives"` and `"{product domain} competitors"`; extract the top 5 mentioned in 2+ results

The list is the union of what's found at the highest-priority source that returns ≥3 candidates. If Ahrefs MCP returns 5 organic competitors, that list is canonical and CLAUDE.md is used only as a cross-check.

**At V_DEPTH == 0 only**, after resolving the list, confirm it with a single `AskUserQuestion` (`header: "Competitors"`, options = the detected list + "Use these" / "Let me edit") so the operator can correct a bad auto-detection before the expensive research fan-out. At V_DEPTH >= 1, skip the confirm and use the resolved list directly.

## Step 0: Orientation

Resolve project root per `_v-core.md` § Project Root Detection. Resolve the skill directory as `SKILL_DIR="${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/v-discover-features}"` for loading the dimension reference (bare relative paths resolve to the Claude-internal `pwd` under `context: fork`, not the skill dir).

**Progress reporting (MANDATORY):**

Create the step list with one `TaskCreate` per step below, then move each to `in_progress`/`completed` with `TaskUpdate` as you go. (The harness renamed `TodoWrite` → `TaskCreate`/`TaskUpdate` on 2026-07-05 — see `~/.claude/skills/references/v-core-error-handling.md` § Audit Skill Progress Reporting.)

1. Orientation & competitor discovery
2. Launch research dimensions in parallel
3. Synthesize findings into feature opportunities
4. Score and prioritize features
5. Generate feature roadmap + implementation prompts

1. **Product context:** Read CLAUDE.md for product description, target audience, current features, pricing tiers, tech stack.
2. **Current feature inventory:** Scan routes, controllers, pages to build a feature list (this is what dimensions compare against — "features we lack" is meaningless without it).
3. **Competitor discovery:** resolve the competitor list per the Entry Point priority order (3-5 competitors).
4. **Ahrefs enrichment (main context only):** if Ahrefs MCP is available, gather keyword/organic data **here, in the main context** — MCP servers are not reliably available inside headless `claude -p` subprocesses, so the dimension subprocesses must not call MCP. Bake the gathered Ahrefs data (organic-competitors, keyword gaps, top-pages) into the Dimension 2 and Dimension 4 briefings as pre-fetched context. If Ahrefs is unavailable, mark all keyword metrics `data_source: estimated` and note it in the roadmap.
5. **Tech-debt context:** find the latest `/v-check` or `/v-audit-code` artifact for this project (`ls -t .v/artifacts/CHECK_REPORT_*.md CHECK_REPORT_*.md .v/artifacts/AUDIT_CODE_REPORT_*.md AUDIT_CODE_REPORT_*.md .v/artifacts/REFACTOR_PLAN_*.md REFACTOR_PLAN_*.md 2>/dev/null | head -1`, or the `.v-prompt-packs/v-check-*` / `v-audit-code-*` dirs — `REFACTOR_PLAN_*.md` / `v-refactor-*` are legacy recognizers for pre-existing files from the retired `/v-refactor`). If present and not expired (per `references/v-core-artifacts.md`), load it — Step 2 uses it to flag features blocked by high-leverage tech debt.
6. **Own-feedback source detection (optional input — never blocks the run if absent):**
   - **Explicit path(s)** in the invocation (`--feedback=path1,path2`) → use exactly those files.
   - **Auto-detect** common locations: `feedback/`, `support-exports/`, `.v/feedback/`, or any
     project-root file matching `*feedback*.csv`, `*cancellation*.csv`, `*churn-survey*.csv` (or
     `.json`/`.txt` variants) modified within the last 90 days.
   - **None found** → proceed without D5; do not ask the operator to go find one (this input is
     opt-in enrichment, not a blocking requirement). Record `own_feedback_source: not_provided`.
   - **Found (auto or explicit)** → record the resolved path(s) for the D5 briefing in Step 1;
     note `own_feedback_source: <path(s)>` for the roadmap's `## Decisions` section.
7. **Store context:** product_name, product_category, target_market, pricing_model, feature_list, competitor_list, ahrefs_available (bool), tech_debt_summary, feedback_paths (list, possibly empty).

## Step 1: Launch Research Dimensions in Parallel

**Dimension content moved to:** `${SKILL_DIR}/references/dim-checklists.md` (focus areas + per-dimension JSON output schema). Load it at this step.

**Dimensions (3-5 run in parallel as research subprocesses):**

| Dim | Name | When it runs |
|-----|------|--------------|
| D1 | Competitor Feature Mapping | always |
| D2 | Market Demand Signals | always (WebSearch PAA baseline; Ahrefs data injected from Step 0 when available) |
| D3 | User Behavior & Friction Signals | always (codebase analysis of the existing product) |
| D4 | Content-Driven Feature Opportunities | when Ahrefs available; otherwise its WebSearch-only subset folds into D2 |
| D5 | Own User Feedback Signals | when a feedback export was resolved in Step 0 (item 6) — support emails, cancellation reasons, in-app feedback exports, clustered into feature-request themes weighted by frequency/recency/churn-correlation |

So the parallel research fan-out is **3-5 dimensions**: 3 without Ahrefs or feedback, up to 5 when both are available. D5 is the only dimension that reads the operator's OWN user signal rather than inferring demand externally — it is NOT web research, so it does not need `WebSearch`/`WebFetch` tool access (unlike D1/D2/D4). Revenue Impact Estimation is **not** a parallel dimension — it depends on D1–D5's outputs and is applied during Step 2 synthesis (its rubric lives in the reference under "Revenue Impact Scoring Rubric").

**Dispatch mechanism (fork-safe — the Agent tool DOES NOT work here):** this skill runs `context: fork`, i.e. it is itself a subagent, and a subagent cannot dispatch another subagent via the Agent tool (platform limit — the call fails silently and degrades to inline work on the already-consumed main context). Dispatch each dimension as an independent `claude -p` subprocess via the shared helper. A no-agent `--model` dispatch defaults its allowlist to read-only tools (`Bash Read Grep Glob BashOutput`) — the research dimensions need web access, so pass `--extra-tools "WebSearch WebFetch"`. Use `--model sonnet` per `~/.claude/skills/references/v-core-model-routing.md` (competitive/market research is structured extraction, not deep architectural reasoning).

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/v-discover-features}"
DISPATCH="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
SCRATCH="$PROJECT_ROOT/.v"; mkdir -p "$SCRATCH"

# Build one fully-substituted briefing per dimension. Each briefing MUST contain,
# inlined verbatim (the subprocess cannot read the skill or the reference):
#   - product context (name, category, target market, pricing, feature_list)
#   - competitor_list (3-5 with URLs)
#   - for D2/D4: the Ahrefs data pre-fetched in Step 0 (or "data_source: estimated")
#   - for D5: the resolved feedback file path(s) from Step 0 item 6 — the briefing instructs the
#     subprocess to Read those files directly (D5 needs no web access; it still receives the
#     blanket --extra-tools grant below, same harmless over-grant D3's codebase-analysis
#     dimension already gets — simpler than per-dimension tool differentiation)
#   - the dimension's focus areas + JSON output schema (copied from dim-checklists.md)
#   - the instruction: "Emit ONLY the JSON object as your final message — no prose, no code fence."
#
# DIMS is "competitor demand user-signals" (3) plus "content" when Ahrefs is available and/or
# "feedback" when a feedback export was resolved in Step 0 — 3 to 5 dimensions total.
for dim in $DIMS; do
  BRIEF="$SCRATCH/discover-brief-$dim-$CLAUDE_SESSION_ID.md"   # write the substituted briefing here
  ART="$SCRATCH/discover-features-$dim-$CLAUDE_SESSION_ID.json"
  "$DISPATCH" \
    --model sonnet --mode capture \
    --extra-tools "WebSearch WebFetch" \
    --prompt-file "$BRIEF" \
    --artifact "$ART" &          # background for true parallelism
done
wait                             # barrier: all dimensions must land before Step 2
```

In `--mode capture` the subprocess has no Write; it emits the dimension JSON as its final message and the helper writes it to `--artifact`. Completion = a non-empty `.json` on disk per dimension (helper exit 0), never the subprocess's prose. Per-dimension failures are handled in Step 2 / § Error Handling — never fabricate a dimension's findings.

## Step 2: Synthesize & Score

After all launched dimensions return (respecting the § Error Handling threshold):

1. **Load results:** read each `$PROJECT_ROOT/.v/discover-features-<dim>-${CLAUDE_SESSION_ID}.json`, including `discover-features-feedback-*.json` when D5 ran. Accept partial results; drop any dimension marked `failed` from the merge (do not fabricate it). If D5 wasn't dispatched (no feedback source), that's a normal `own_feedback_source: not_provided` state, not a failure.

2. **Merge feature opportunities** across all returned dimensions. Deduplicate by normalized feature name/description (case-insensitive, singular/plural-folded). **D5 themes merge into this same pool** — when a D5 theme's description semantically matches a D1-D4 feature gap, merge them into one feature entry and carry forward D5's `mention_count`/`churn_correlated`/`representative_quote` alongside the competitor/search evidence; when a D5 theme has no D1-D4 match, it becomes its own feature entry (a real user asked for it even though no competitor offers it and no search volume shows it — that's a legitimate whitespace signal, not noise to discard).

2a. **Zero-outreach gate (apply BEFORE scoring — solo operator, no sales/support team).** Per `~/.claude/skills/references/v-core-solo-motion.md`, any competitor feature that is outbound- or team-shaped — a sales-assisted/"contact sales" tier, "book a demo", dedicated account manager, 24/7 human support, staffed live chat — must NOT enter the scored pool as a build recommendation (this skill's output is a paste-ready `/v` build prompt; an unfiltered "Table Stakes" gap here becomes an autonomously-built feature the operator can't staff). Reframe each to its passive/self-serve equivalent (dedicated AM → in-app onboarding + docs; staffed live chat → async help + AI assistant) or mark it correctly-absent, never a gap to build. This governs D1's competitor-coverage findings, not just D4's integrations — unless the project CLAUDE.md declares an outbound motion.

3. **Apply the Revenue Impact rubric** (from the reference) to each merged feature: classify its `revenue_mechanism` (acquisition | activation | conversion | expansion | retention — a D5-sourced `churn_correlated: true` theme overrides to retention per the rubric's D5 override rule) and estimate `revenue_impact` (1-5) for the non-enterprise market. This is the step that consumes D1–D5, which is why it runs here and not as a parallel dimension.

4. **Score each feature:**

```
PRIORITY_SCORE = (demand_signal × 3) + (competitor_coverage × 2) + (revenue_impact × 3) + (effort_inverse × 2)

Where (each 1-5):
  demand_signal:        5 = high search volume + strong PAA/forum signal, OR a D5 theme with
                        mention_count >= 5 unique users (own-user demand is at least as strong a
                        signal as inferred search demand — take the MAX of the D2-derived and
                        D5-derived signal, never average them down); 1 = no observable demand.
                        Discount (do not zero out) a D5 theme flagged dominated_by_single_user.
  competitor_coverage:  5 = all competitors have it (we don't); 3 = 1-2 have it; 1 = none have it
  revenue_impact:       5 = directly drives MRR for the non-enterprise market; 1 = negligible
  effort_inverse:       small effort → 5, medium → 3, large → 1
                        (map the dimension's small|medium|large effort estimate)

Range: 10 (all 1s) to 50 (all 5s). Higher = build sooner.
```

**Goal weighting:** multiply the goal-aligned factor by 1.25 before summing, **then cap `PRIORITY_SCORE` at 50** so the 10–50 range and the `[N/50]` display stay valid (the boost re-ranks mid-scoring features toward the goal without overflowing the scale) — engagement/retention goal ⇒ boost retention-mechanism features; acquisition ⇒ acquisition-mechanism; revenue ⇒ `revenue_impact`; comprehensive ⇒ no boost. State the applied weighting in the roadmap `## Decisions` section.

5. **Classify each feature** by competitor coverage, then `PRIORITY_SCORE` as tiebreak. Evaluate the classes **top-to-bottom and assign the first that matches** — Nice-to-Have is the explicit catch-all, so every feature lands in exactly one class with no gaps (`competitor_coverage` is an integer 1-5; 1 = no competitor has it):
   - **Table Stakes** — `competitor_coverage >= 4` (all/most competitors have it, we don't): build to avoid losing deals.
   - **Differentiator** — `competitor_coverage` 2-3 (1-2 competitors have it): build to win competitive deals.
   - **Novel Bet** — `competitor_coverage == 1` (no competitor has it) AND `PRIORITY_SCORE >= 30` (real demand/revenue signal): build to create feature-level whitespace. (Renamed from "Blue Ocean" — this is a feature-level whitespace signal, not Kim & Mauborgne's market-level value-innovation/moat claim; one competitor-blind feature doesn't establish a moat.)
   - **Nice-to-Have** — **catch-all: any feature not matching a class above.** This is exactly the `competitor_coverage == 1` gaps with `PRIORITY_SCORE < 30` (weak demand/revenue signal): defer unless user demand is explicit.

6. **Tech-debt gate:** cross-reference each top feature against the tech-debt summary loaded in Step 0. If a feature is blocked by or significantly harder because of known high-leverage tech debt, tag it `blocked_by_tech_debt: "<ref>"` and note in its "Why" that the debt may need to ship first. Do not silently drop it.

7. **Rank by `PRIORITY_SCORE`** (descending) within the priority order Table Stakes → Differentiator → Novel Bet → Nice-to-Have, and produce the top 10-15 features.

## Step 3: Generate Outputs

Write three artifacts (all SID-stamped; file on disk, not text in the response — per `_v-core.md` § Session ID).

### 1. `FEATURE_ROADMAP_[timestamp]_${CLAUDE_SESSION_ID}.md`

```markdown
# Feature Roadmap: [Product Name]

Generated: [date]
Goal: [engagement | acquisition | revenue | comprehensive]
Competitors analyzed: [list]
Data source: [ahrefs | estimated]   ← estimated when Ahrefs unavailable
Own feedback source: [path(s) | not_provided]   ← from Step 0 item 6 / D5
Dimensions completed: [N of M]      ← flags any partial run

## Executive Summary
[3-4 sentences: biggest competitive gap, highest-impact opportunity, recommended first build]

## Priority Feature Ranking

### Rank 1: [Feature Name] — [Table Stakes | Differentiator | Novel Bet | Nice-to-Have]
**Score:** [N/50] | **Effort:** [small/medium/large] | **Revenue mechanism:** [acquisition/activation/conversion/expansion/retention]
**Why:** [1-2 sentences — competitive gap + demand signal + revenue impact]
**Competitors with this:** [list or "none"]
**Search demand:** [keywords + volume if available, else "estimated"]
**Own user demand:** [D5 mention_count + churn_correlated flag + one representative quote, or "no feedback source" — omit this line entirely when own_feedback_source is not_provided]
**Spec outline:** [high-level: what it does, key screens/endpoints, data model changes]
**Blocked by tech debt:** [ref, or omit if none]
**Next step:** paste `.v-prompt-packs/v-discover-features-<MM-DD>/[feature-slug].txt` (or its `w<N>-` wave file, if bumped for a file conflict) into a fresh `/v` session

### Rank 2: [Feature Name] — [Classification]
...

## Content-Driven Feature Opportunities
[Free tools, templates, integrations that double as SEO + features — from Dimension 4]

## Own User Feedback Themes
[Only include this section when D5 ran. List each theme not already merged into the Priority
Feature Ranking above (e.g. long_tail_mentions, or themes below the ranking cutoff): theme,
mention_count, churn_correlated, representative_quote. Omit this section entirely when
own_feedback_source is not_provided — do not print an empty section.]

## Competitive Landscape Summary
[2-3 paragraph overview of where this product stands vs competitors]

## Decisions
[Judgment calls made this run — required per `_v-core.md` § Session ID (rule 10: Model decision audit trail). Record:
 goal weighting applied; competitor list source (Ahrefs/CLAUDE.md/WebSearch) + any override;
 dimensions skipped/failed and why; Ahrefs availability; own-feedback source resolution (path(s)
 or not_provided) and any dominated_by_single_user themes that were discounted; any features
 deferred behind tech debt; dedup merges that collapsed two competitor names into one feature.]
```

### 2. `FEATURE_ROADMAP_[timestamp]_${CLAUDE_SESSION_ID}.json`

Structured JSON for programmatic consumption (this is the machine-readable twin of the .md; `/v` and re-run delta comparison read it):

```json
{
  "roadmap_metadata": {
    "product_name": "...",
    "generated": "ISO date",
    "skill": "v-discover-features",
    "goal": "engagement|acquisition|revenue|comprehensive",
    "competitors_analyzed": ["..."],
    "competitor_source": "ahrefs|claude_md|comparison_pages|websearch|override",
    "data_source": "ahrefs|estimated",
    "own_feedback_source": "path(s) or not_provided",
    "dimensions_completed": 4,
    "dimensions_total": 4,
    "partial": false
  },
  "features": [
    {
      "rank": 1,
      "name": "...",
      "classification": "table_stakes|differentiator|novel_bet|nice_to_have",
      "priority_score": 44,
      "scores": {"demand_signal": 5, "competitor_coverage": 5, "revenue_impact": 4, "effort_inverse": 3},
      "revenue_mechanism": "acquisition|activation|conversion|expansion|retention",
      "effort": "small|medium|large",
      "competitors_with_this": ["..."],
      "search_demand": {"keywords": ["..."], "monthly_volume": 2400, "source": "ahrefs|estimated"},
      "own_user_demand": {"mention_count": 0, "churn_correlated": false, "representative_quote": null},
      "spec_outline": "...",
      "blocked_by_tech_debt": null,
      "why": "..."
    }
  ],
  "content_opportunities": {"free_tools": [], "templates": [], "integrations": []},
  "competitive_landscape": "..."
}
```

### 3. `.v-prompt-packs/v-discover-features-<MM-DD>/` — Implementation Prompts

Emits the same unified `.txt` wave form + body schema as every other producer (per
`~/.claude/skills/references/v-runnable-pack-convention.md`; folder rule —
`~/.claude/skills/references/v-core-prompt-pack.md`). One prompt file per top-5 feature:

```
.v-prompt-packs/v-discover-features-<MM-DD>/
  00-README.md              ← Roadmap summary, feature/wave priority table, dependencies, post-build gate commands (the only .md)
  [feature-slug].txt        ← wave 0 (no prefix): paste-ready /v prompt for the top feature (full competitive context)
  w1-[feature-slug].txt     ← wave 1: only if this feature's file set conflicts with (or depends on) a wave-0 feature
  ...
  w<N>-pre-flight.txt       ← closing wave (read-only): project's full quality gates
  w<N>-review.txt           ← closing wave (read-only, parallel with pre-flight): adversarial/second-opinion review
  w<N+1>-hardening.txt      ← sequential: triages findings, fixes CRITICAL/HIGH, re-runs gates, /v-verify-done
  99-verify.txt             ← always last: re-asserts every feature pack landed
```

**Wave assignment:** features are independent verticals by default, so most packs are wave 0 (no prefix,
parallel-safe). Bump a feature to `w1-`/`w2-` only when its file set intersects an earlier feature's (e.g.
two features extending the same shared component/model) or it explicitly depends on an earlier feature's
output — apply the same conflict/dependency test as `~/.claude/skills/references/v-runnable-pack-convention.md`
§ Wave assignment.

**Closing waves (always append, per `v-runnable-pack-convention.md` § Closing waves).** After the last
feature wave, append a parallel READ-ONLY verification wave at the next wave number —
`w<N>-pre-flight.txt` (runs the project's full quality gates) + `w<N>-review.txt` (dispatches the
adversarial/second-opinion reviewer agents, plus a framework-pitfall reviewer only when a feature touched
queues/listeners/signature-verification/cache-keys) — then a single sequential `w<N+1>-hardening.txt`
(triages findings, fixes CRITICAL/HIGH, re-runs gates until green, runs `/v-verify-done`, walks the
acceptance criteria), then `99-verify.txt` last. The two verification packs use `## Goal` / `## Checks` /
`## Acceptance` and OMIT `## Files`/`## Tests` and the "leave staged" line — they never edit source.
Reflect these in the 00-README.md priority table like every other wave.

**Generation (dispatched, not inline):** by the time this step runs the main context has consumed the dimension research, so generate the pack via a fork-safe `claude -p` subprocess in `--mode self-write` per `v-core-prompt-pack.md` § Generation requirements:

```bash
PROMPT_DIR=".v-prompt-packs/v-discover-features-$(date +%m-%d)"
# Same-day re-run: archive the prior pack before regenerating (unified convention).
if [ -d "$PROJECT_ROOT/$PROMPT_DIR" ] && [ -n "$(ls -A "$PROJECT_ROOT/$PROMPT_DIR" 2>/dev/null)" ]; then
  mv "$PROJECT_ROOT/$PROMPT_DIR" "$PROJECT_ROOT/$PROMPT_DIR.bak-$(date +%Y%m%d-%H%M%S)-$(printf %04x $RANDOM)"
fi
mkdir -p "$PROJECT_ROOT/$PROMPT_DIR"
"$HOME/.claude/skills/v/references/v-dispatch-subagent.sh" \
  --model sonnet --mode self-write \
  --prompt-file "$BRIEF_FILE" \
  --artifact "$PROJECT_ROOT/$PROMPT_DIR/00-README.md"
```

**Prompt file rules** (inline the roadmap context + these rules verbatim in `$BRIEF_FILE` — the subprocess can't read this skill). Each pack MUST start on **line 1 with `/v `** (the orchestrator routing prefix — routes to plan → tdd → build for that feature; NOT `/v-plan` — the bare `/v ` entry lets a fresh session classify and plan+build end-to-end) and carry the body schema below, in order:

```
/v Plan and implement [feature] for [Product].

## Goal
[1-2 sentences: the feature, its classification (Table Stakes/Differentiator/Novel Bet/Nice-to-Have), and why it ranked here — competitive gap + demand signal + revenue impact]

## Context
[Competitive context: competitors with it (or "none"). Demand: keywords/monthly volume (or "estimated").
Spec outline: what it does, key screens/endpoints, data model changes. NO reference to the roadmap
JSON/MD or a sibling prompt file — inline everything needed.]
Tech stack: [detected stack].

## Files
[Every file this feature is expected to create/modify — models, migrations, controllers, pages, tests.]

## Changes
[The concrete build steps for this feature, in dependency order.]

## Acceptance criteria
- [ ] [from the roadmap's spec outline — observable, testable done-conditions]

## Tests
[TDD test cases for this feature — the implementing agent writes these first]

## Constraints
Read the project's CLAUDE.md first. [Any guardrail: tenant isolation, billing gating, framework version.]
[If this feature's ## Files touches request signing/HMAC/webhook or signature verification,
credential/secret handling, host/URL construction from variables, auth/authz decisions, or payment
flows (the common case for a billing/Stripe/usage-metering feature): "This pack touches security-bearing
code — dispatch an adversarial reviewer (codex-adversarial-reviewer, fallback
superpowers:requesting-code-review) on your own diff before finishing; fix CRITICAL/HIGH in-session."]

## Dependencies
Wave [N]. Requires: [prior wave's feature slug, or "none" for wave 0].

Leave all changes staged; do NOT commit — the operator/orchestrator owns commits.
```

- Each file is **paste-ready**: all placeholders substituted with real values (product name, tech stack, competitor names/URLs), no frontmatter, no meta-commentary, `>= 50` lines.
- Each file is **self-contained**: it embeds that feature's competitive context, demand signal, spec outline, and detected tech stack — no references to the roadmap JSON or sibling prompt files.
- The literal `## Files` H2 is REQUIRED — `/v-build`'s scope guard keys on it.
- End with the exact phrase "leave all changes staged; do NOT commit" (a test checks this literal phrase).
- `00-README.md` lists every pack in a table (`| Wave | File | Feature | Classification | Est. Effort | Depends on |`) and the post-build quality-gate commands from CLAUDE.md.

**Post-generation validation (main context, after the subprocess returns):** run the shared validator and a dry-run against the runner, same as every other producer:

```bash
"$HOME/.claude/scripts/validate-audit-prompt-packs.sh" "$PROJECT_ROOT/$PROMPT_DIR"
run-v-packs "$PROJECT_ROOT/$PROMPT_DIR" --dry-run
```

Also confirm `00-README.md` exists, every pack (excluding README) starts with `/v `, is `>= 50` lines, has no unsubstituted `[placeholder]`, and carries `## Files`. On failure, re-dispatch once with the failures as context; a second failure is recorded in the roadmap under a "Prompt Pack: generation failed" note (do not silently omit the pack).

Each prompt gives `/v` rich input for Route 3 (Specific Feature) planning.

## Integration Points

- **Input from:** `/v-audit-growth` (existing funnel data), `/v-audit-seo` (keyword data), `/v-check` or `/v-audit-code` (tech-debt context, loaded in Step 0), the operator's own support/cancellation/in-app feedback exports (Dimension D5, optional — see § Entry Point / Step 0 item 6)
- **Output feeds:** `/v-plan` (Route 3 per feature), `/v-new-feature` (for complex features), `/v-build` (direct implementation)
- **Periodic re-run:** run quarterly or when competitors ship major features. Compare against the prior `FEATURE_ROADMAP_*.json` to track competitive position over time.

## Available Integrations

**Ahrefs MCP (strongly recommended — called in the main context during Step 0, never inside dimension subprocesses):**
- `site-explorer-organic-competitors` — find competitors by organic overlap
- `site-explorer-organic-keywords` — competitor keyword portfolios
- `site-explorer-top-pages` — competitor's highest-traffic pages (reveals feature priorities)
- `keywords-explorer-overview` — volume + difficulty for feature-related keywords
- `keywords-explorer-matching-terms` — discover related feature keywords
- `batch-analysis` — compare domain metrics across competitors

**Plugin skills (optional enhancers):**
- `marketing:competitive-analysis` — structured competitive positioning
- `product-management:competitive-analysis` — feature comparison matrices
- `product-management:roadmap-management` — RICE/ICE prioritization frameworks

**If Ahrefs unavailable:** fall back to WebSearch-only research. Keyword volume estimates are marked `data_source: estimated` instead of `data_source: ahrefs`, and Dimension 4's WebSearch-only subset folds into Dimension 2.

## Error Handling

Follows the Parallel Subagent Error Handling Contract in `~/.claude/skills/references/v-core-error-handling.md`.

| Scenario | Fallback |
|----------|----------|
| A dimension subprocess crashes/times out (helper exit ≠ 0, empty artifact) | Mark that dimension `{status: "failed"}`, score `null`, exclude from the merge. Do NOT fabricate its findings. |
| Feedback export path resolved but unreadable/malformed (bad CSV, corrupt export) | Mark D5 `{status: "failed", reason: "unreadable_export"}`, exclude from merge, note it in `## Decisions` — do NOT block the whole run over an optional input. |
| No feedback export found (auto-detect and no explicit path) | D5 is not dispatched at all (not a failure) — proceed with D1-D4; `own_feedback_source: not_provided`. |
| Ahrefs MCP unavailable | WebSearch-only research; mark all keyword metrics `data_source: estimated`; fold D4 into D2. |
| Competitor site blocks WebFetch | Use cached search-result snippets + marketing-page analysis; note reduced fidelity for that competitor. |
| < 3 competitors found at every source | Expand search to adjacent categories; if still < 3, proceed and flag `competitor_coverage` scores as low-confidence in `## Decisions`. |
| Plugin skills unavailable | Run dimensions natively using WebSearch. |
| ≥ 50% of launched dimensions fail (`ceil(N/2)+... ` per the shared contract — e.g. 2 of 3, 2 of 4) | Abort synthesis; write `FEATURE_ROADMAP_*` with `partial: true` and a top-line `AUDIT_INCOMPLETE` note per `v-core-error-handling.md`. Do not produce a misleading ranking from insufficient data. |
| Prompt-pack subprocess fails twice | Record "Prompt Pack: generation failed" in the roadmap; keep the .md/.json. Do not claim completion without noting it. |

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Feature gap analysis recommends features competitors built years ago | Competitor analysis didn't include "abandoned" features | Just because a competitor SHIPPED feature X doesn't mean it WORKED; check usage signals (still on homepage? still in pricing tiers?) |
| 2 | User-requested features list is heavily skewed by 1-2 loud users | Demand signal not weighted | Each request needs source attribution + frequency; weight = unique users requesting × recency. D5's `dominated_by_single_user` flag is the mechanical enforcement of this rule specifically for the own-feedback dimension — discount, don't zero out. |
| 3 | Roadmap output ignores existing tech debt that blocks proposed features | Tech-debt context not loaded | Step 0 (item 5) loads the latest `/v-check` or `/v-audit-code` artifact; Step 2 (item 6, the tech-debt gate) flags features blocked by high-leverage debt — that debt may need to ship first |
| 4 | Search/forum signal scraped but ranking ignored discussion volume | Volume vs intensity confused | A topic mentioned 50× casually ranks differently than 10× with strong frustration; weight by sentiment |
| 5 | Dimensions dispatched via the Agent tool return nothing | This skill runs `context: fork`; nested Agent dispatch fails silently | Dispatch dimensions as `claude -p` subprocesses via `v-dispatch-subagent.sh` with `--extra-tools "WebSearch WebFetch"` — never the Agent tool |
| 6 | Dimension subprocess produces no web research | No-agent `--model` dispatch defaults to read-only tools (no WebSearch/WebFetch) | Always pass `--extra-tools "WebSearch WebFetch"`; run Ahrefs/MCP in the main context and inject its data into the briefing |
| 7 | Session stalls/asks the operator to "go find a feedback export" | Step 0 item 6 treated as a required input instead of optional enrichment | A feedback export is opt-in — auto-detect it, use it if found, proceed silently without it if not. Never block or ask for one. |
| 8 | A real, frequently-requested feature (per support emails) is missing from the roadmap entirely | D5 wasn't merged into Step 2's feature pool, or its theme didn't reach the >=2-item threshold and got silently dropped instead of appearing in `long_tail_mentions` | D5 themes merge into the SAME feature pool as D1-D4 (§ Step 2 item 2); singleton requests still surface under `long_tail_mentions`, never silently discarded |

## Idempotency

**Idempotent in effect, not side-effect-free.** Re-running on the same codebase produces a fresh, SID-stamped discovery report (`FEATURE_ROADMAP_*` .md/.json) and prompt pack — it never mutates source or prior-session artifacts. It DOES write files: per-dimension scratch JSON under `$PROJECT_ROOT/.v/`, the two roadmap artifacts (`FEATURE_ROADMAP_*` .md/.json) under `$PROJECT_ROOT/.v/artifacts/` (Phase-2 — create the dir; readers dual-search), and the dated prompt pack. A same-day prompt-pack re-run archives the prior pack to `.bak-<timestamp>/` per the unified convention before regenerating; different-day re-runs create a new dated dir alongside the old.
