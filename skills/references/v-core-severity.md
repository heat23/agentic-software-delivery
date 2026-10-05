# Severity Definitions & Scoring (shared, canonical)

_Last reviewed: 2026-07-05 (SKILL-CONTENT-REVIEW-2026-07-05 C4)._

Single source of truth for finding severity across the audit/review family. Every skill that
emits severity-tagged findings (v-audit-*, v-check, v-bug-hunt [both `bugs` and `boundaries`
lenses — v-edge-hunt merged in 2026-07-05], v-audit-code (absorbed v-refactor + v-ui-audit 2026-07-06),
v-anti-template-gauntlet, v-audit-consolidate, and any design/critic skill that emits P0-P3 such as
v-marketing-design) MUST use these definitions and, if it renders another
vocabulary, MUST use the mapping table below. This eliminates the four-incompatible-scales
problem where a consolidator or verdict swings on severities subagents invented ad hoc.

## Canonical scale (use these four levels)

| Level | Definition (what qualifies) | Verdict impact |
|-------|------------------------------|----------------|
| **P0** | Actively causes wrong/harmful output, data loss, security/payment/auth compromise, or blocks a core user flow. Ships-broken. | Any P0 ⇒ NOT READY / FAIL. Must be fixed before done. |
| **P1** | High-impact defect or gap that degrades a core flow, revenue, or trust but has a workaround; or a correctness bug off the hot path. | ≥1 P1 ⇒ NEEDS-WORK. Fix before ship unless explicitly deferred with a reason. |
| **P2** | Medium: quality/UX/maintainability issue, non-blocking. Improves the product; not a ship blocker. | Advisory. Batch-fixable. |
| **P3** | Low/polish/nit: cosmetic, style, or nice-to-have. | Advisory. Optional. |

## Cross-vocabulary mapping (render whatever the skill's audience expects, map to canon)

| Canonical | critical/high/medium/low | Craft vocab | Numeric band (if scoring) |
|-----------|--------------------------|-------------|---------------------------|
| P0 | critical | Critical-Craft | blocks READY regardless of score |
| P1 | high | High-Craft | −15 to −25 |
| P2 | medium | Medium-Craft | −5 to −12 |
| P3 | low | Low-Craft | −1 to −4 |

A skill MUST NOT invent a fifth level or use an unmapped word. When merging findings from
multiple skills (v-audit-consolidate), normalize every incoming severity to the canonical P0-P3 via
this table before dedup/ranking.

## Scoring discipline (port from v-audit-seo — the family standard)

When a skill produces a 0-100 score or a READY/NOT-READY verdict:

1. **Start at 100, deduct per finding by severity** using the numeric bands above (cap total
   deductions at 100). Do not invent a per-run scale.
2. **A single P0 forces the failing verdict** (NOT READY / FAIL / BLOCK) regardless of the
   numeric score — a 92/100 with one payment-loss P0 is NOT READY.
3. **Publish the schema in the dimension brief** so every parallel subagent returns
   `{id, severity (P0-P3), evidence (file:line), score_delta}` in the same shape — the
   consolidation/verdict step depends on identical schemas.
4. **Zero findings is a valid, high-scoring result.** Never manufacture a finding to fill a
   rubric slot (see [[v-core-solo-motion]] for the outbound-shaped-hole case).

## Severity is absolute, not relative to a baseline

The pre-existing-failure baseline ([[v-core-pre-existing]]) determines *whether a failure is
session-introduced* — it does **not** lower a finding's severity. A P0 (e.g. billing/webhook
double-charge) is P0 whether or not a prior audit already rated it MEDIUM. Downstream skills
(v-bug-hunt's `bugs` and `boundaries` lenses) MUST re-raise a mis-rated issue at its true canonical severity; an
earlier skill's lower rating never suppresses a later, correct higher rating.
