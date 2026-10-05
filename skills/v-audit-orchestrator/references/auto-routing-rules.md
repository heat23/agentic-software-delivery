# Auto-routing rules for "Advise me" path

_Last reviewed: 2026-07-05._

> **Persona for this reference:** senior consulting auditor —
> someone who's run audits across hundreds of projects and can
> read project signals to recommend the right audit bundle in
> 30 seconds. Loaded on-demand by v-audit-orchestrator when the
> operator picks "Advise me — pick based on project state."

The "Advise me" path is the killer feature of the orchestrator.
The operator says "I don't know what to run," the skill reads
the project's signals, recommends a specific bundle with
rationale, and offers a one-key confirmation to proceed.

This reference codifies the signal-reading + bundle-selection
logic.

---

## Signal-reading pass

Before recommending, gather these signals (parallel-safe; can run
in one Bash call):

```bash
# A. Project stage signals — defensive defaulting on missing files / sparse signals
PUBLISHED_ARTICLES=$(find content/blog public/blog resources/content -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
PUBLISHED_ARTICLES=${PUBLISHED_ARTICLES:-0}
HAS_LIVE_PRICING=$([ -f resources/js/Pages/Pricing.tsx ] || [ -f resources/views/pricing.blade.php ] && echo 1 || echo 0)
HAS_LIVE_PRICING=${HAS_LIVE_PRICING:-0}
HAS_PLACEHOLDER_PRICING=$(grep -rh "Coming soon\|TBD\|Beta access\|Pricing TBA\|Coming Soon\|Early access" resources/js/Pages/Pricing* resources/views/pricing* src/pages/pricing* pages/pricing* 2>/dev/null | head -1 | wc -l | tr -d ' ')
HAS_PLACEHOLDER_PRICING=${HAS_PLACEHOLDER_PRICING:-0}
# Best-effort signal — fails silent on stacks/paths not listed; downgrade confidence to MEDIUM when this matters
# NOTE: `grep -c` on 2+ files prefixes each line with "file:count" (e.g. "CLAUDE.md:1"), which is not an
# integer and breaks any `-ge`/`-gt` comparison downstream — `cat` the files into one stream first so `-c`
# returns a single number. Bare "customers" also false-positives on any product that merely mentions
# customers (CRM/support features) with zero revenue signal — require revenue-shaped phrasing instead.
HAS_REVENUE_MENTIONS=$(cat CLAUDE.md README.md 2>/dev/null | grep -ic "MRR\|ARR\|paying customers\|paying users\|first revenue\|first customer\|monthly recurring revenue")
HAS_REVENUE_MENTIONS=${HAS_REVENUE_MENTIONS:-0}
HAS_GSC_DATA=$(test -f .seo/gsc-export-*.csv && echo 1 || echo 0)
HAS_GSC_DATA=${HAS_GSC_DATA:-0}

# B. Recent audit history (last 14 days)
RECENT_AUDITS=$(find "$PROJECT_ROOT" -maxdepth 4 \
  \( -name '*_REPORT_*.md' -o -name '*_AUDIT_*.md' \
     -o -name 'PRELAUNCH_READINESS_REPORT_*.md' \
     -o -name 'GAUNTLET_REPORT_*.md' \
     -o -name 'PRE_FLIGHT_REPORT_*.md' \
     -o -name 'VERIFY_DONE_REPORT_*.md' \) \
  ! -name 'CONSOLIDATED_AUDIT_REPORT_*' \
  -mtime -14 2>/dev/null | wc -l | tr -d ' ')

# C. Implementation activity (uncommitted / recent commits)
UNCOMMITTED_FILES=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
RECENT_COMMITS=$(git log --since="3 days ago" --oneline 2>/dev/null | wc -l | tr -d ' ')

# D. Codebase characteristics
HAS_TESTS=$(find tests __tests__ test -maxdepth 3 -name '*.test.*' -o -name '*Test.php' 2>/dev/null | head -1 | wc -l | tr -d ' ')
HAS_ADMIN_ROUTES=$(grep -rl "Route::prefix('admin')\|/admin" routes/ 2>/dev/null | head -1 | wc -l | tr -d ' ')
```

These signals classify the project into one of 5 routing-ready states.

---

## State classification

| State | Signals | Recommendation |
|---|---|---|
| **AUDIT-PENDING** | `RECENT_AUDITS >= 2` AND no `CONSOLIDATED_AUDIT_REPORT_*` exists in last 7 days | Recommend `v-audit-consolidate` — multiple audits exist, consolidation is the next step |
| **MID-IMPLEMENTATION** | `UNCOMMITTED_FILES >= 5` AND `RECENT_COMMITS >= 1` | Pre-merge gate (`v-pre-flight` + `v-verify-done`) — verify the work-in-progress before committing |
| **LAUNCHED** | `HAS_REVENUE_MENTIONS >= 1` OR `HAS_GSC_DATA == 1` | Recommend specialist audit based on the operator's most-recent audit gap (if no recent SEO audit + has GSC data → SEO; if no recent messaging audit → messaging; etc.). Note: this state checks revenue/traffic FIRST so launched products with content history don't mis-classify as PRE-LAUNCH. |
| **GREENFIELD** | `PUBLISHED_ARTICLES <= 3` AND `HAS_REVENUE_MENTIONS == 0` AND `HAS_PLACEHOLDER_PRICING == 1` AND not LAUNCHED above | Pre-launch readiness sweep (`v-prelaunch-readiness` + `v-anti-template-gauntlet` + auto-consolidate). Greenfield-mode dispatched to specialists where applicable. |
| **PRE-LAUNCH** | (`PUBLISHED_ARTICLES > 3` OR `HAS_LIVE_PRICING == 1`) AND `HAS_REVENUE_MENTIONS == 0` AND not LAUNCHED above | Pre-launch full sweep (`v-prelaunch-readiness` + `v-anti-template-gauntlet` + `v-audit-seo` + `v-audit-messaging` + `v-check` + auto-consolidate) |
| **UNCLASSIFIED** | None of the above match (e.g. ≤3 articles, no placeholder pricing, no live pricing, no revenue mentions — a genuinely ambiguous or too-sparse signal set) | LOW-confidence catch-all: do not silently pick a bundle. If `UNCOMMITTED_FILES >= 1`, lean toward the Pre-merge gate; otherwise recommend the Pre-launch readiness sweep as the safest default, but present both options and explicitly invite the operator to pick from the main menu instead |

States are evaluated **top-to-bottom in the table above**. Take the FIRST matching state. The state-classification logic is therefore:

1. **AUDIT-PENDING** beats everything (consolidation is highest-leverage when reports exist)
2. **MID-IMPLEMENTATION** beats stage states (verify before committing — tactical priority)
3. **LAUNCHED** beats GREENFIELD and PRE-LAUNCH (a launched product with content history must NOT mis-classify as pre-launch)
4. **GREENFIELD** beats PRE-LAUNCH (greenfield is a stricter version of pre-launch)
5. **PRE-LAUNCH** is the catch-all for partial-pre-launch state
6. **UNCLASSIFIED** is the final backstop — every prior state's conditions can legitimately all be false (e.g. a near-empty repo with no pricing surface at all), so this row guarantees the classifier always terminates in a defined, LOW-confidence recommendation instead of falling through undefined

**The previous ordering had a bug:** `PUBLISHED_ARTICLES > 3` was checked before revenue, causing launched products with content to mis-classify as PRE-LAUNCH. Fixed: AUDIT-PENDING/MID-IMPLEMENTATION/LAUNCHED are evaluated before any stage-based classification.

---

## Recommendation output format

When the operator picks "Advise me," the skill responds with:

```markdown
## Recommendation

Based on project signals, recommended bundle: **[BUNDLE NAME]**

### Why this bundle

[2-3 sentences explaining the signal-reading]:
- "Project shows pre-launch state: 0 published articles, placeholder pricing, no revenue mentions in CLAUDE.md."
- "Recent audit history is empty — no `*_REPORT_*.md` files in the last 14 days."
- "This bundle is the recommended pre-launch readiness sweep."

### What this will run

[List the skills + bundle steps]:
1. `/v-prelaunch-readiness` (8 surfaces, ~10-15 min)
2. `/v-anti-template-gauntlet` (output quality gate, ~5-10 min)
3. `/v-audit-consolidate` (auto-triggered after both complete, ~5 min)

### Estimated total time

~25-30 minutes wall-clock.

### Alternative bundles

If the recommendation doesn't fit:
- For broader pre-launch: "Pre-launch full sweep" (5 audits, ~45-60 min)
- For code-only: "Code quality (broad)" — `v-check` standalone
- For specific domain: pick a single specialist from the menu

### Proceed?

(operator confirms; orchestrator dispatches the bundle)
```

The advice should be specific, signal-cited, and time-budgeted. Generic recommendations ("you should run audits!") fail the operator-experience bar.

---

## Specialist-recommendation logic (LAUNCHED state)

When project is launched, the operator likely wants a specific specialist audit. Pick based on:

1. **Audit gaps** — which specialist hasn't run in the last 30 days?
2. **Project signals** — which specialist's domain matches recent activity?

Decision tree:

```
launched_project:
  if HAS_GSC_DATA AND no recent v-audit-seo report (>30 days):
    recommend v-audit-seo
  elif recent commits touch resources/js/Pages/Marketing/ AND no recent v-audit-messaging:
    recommend v-audit-messaging
  elif HAS_LIVE_PRICING AND recent commits touch billing/Stripe AND no recent v-audit-sales-pricing:
    recommend v-audit-sales-pricing
  elif HAS_ADMIN_ROUTES AND no recent v-audit-admin:
    recommend v-audit-admin
  elif no recent v-check report (>30 days):
    recommend v-check
  else:
    recommend "specialist of operator's choice — last audit was [N days ago]"
```

The decision is heuristic, not authoritative. Always offer alternatives in the recommendation output.

---

## Confidence levels

The recommendation includes a confidence flag:

| Confidence | When |
|---|---|
| **High** | Signals strongly match exactly one state; recommendation is clear |
| **Medium** | Signals match 2+ states; picked the highest-priority state per the ordering above; mention the alternatives |
| **Low** | Signals are sparse / contradictory; recommendation is best-guess; emphasize the operator should confirm or override |

A LOW-confidence recommendation looks like:

```markdown
**Recommendation (LOW CONFIDENCE):** Pre-merge gate

Signals are sparse: 0 recent commits, 2 uncommitted files, no recent audits, ambiguous revenue signal in CLAUDE.md. This is a best-guess.

Consider explicitly picking from the main menu instead of accepting this recommendation.
```

---

## What the "Advise me" path does NOT do

- It does NOT auto-execute the recommended bundle. The operator confirms first.
- It does NOT fabricate signals. If detection commands fail, log the failure and recommend with reduced confidence.
- It does NOT re-run audits silently. If a fresh audit is recommended, it routes to the standard skill invocation.
- It does NOT replace operator judgment. The recommendation is a starting point; the operator can override.

---

## Cross-references

- Bundle definitions: `audit-family-map.md` § Bundle recipes
- Per-skill domains: `audit-family-map.md` § Skill cards
- Severity mapping (used post-bundle for consolidation): `~/.claude/skills/v-audit-consolidate/references/severity-mapping.md`
