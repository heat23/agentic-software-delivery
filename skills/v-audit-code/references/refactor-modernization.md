# Refactor & Modernization (absorbed from v-refactor)

_Last reviewed: 2026-07-06 (migrated from v-refactor on retirement)._

`v-refactor` has been retired. Its analysis substance — framework modernization, code
complexity, pattern consolidation, dependency hygiene, and safe cleanup — is already covered
by this skill's own lenses (`Code quality & maintainability`, `The modernization lens`, and
`Dependency & supply-chain hygiene` in `audit-lenses.md`). Do not re-derive a separate rubric
from this file for those domains.

Two capabilities from `v-refactor` were **not** duplicated anywhere else and are preserved
here as ADDITIVE appendices:

1. **DEBT_TREND** — a persistent, cross-run numeric register that gives real trend-over-time
   (this skill's lenses only produce prose "before → after" deltas within a single run).
2. **SaaS-architecture refactor shapes** — named refactor patterns for tenant-scoping,
   billing-service extraction, permission/RBAC consolidation, and analytics-instrumentation
   consolidation, for codebases with a multi-tenant/team/billing surface.

Use both only when they add value for the operator's goal (e.g. the operator wants trend
tracking across repeated audits, or the codebase has a team/tenant/billing surface). They are
optional, not mandatory steps of every polish/audit run.

---

## Appendix A: DEBT_TREND persistent register (optional)

When the operator wants trend-over-time across repeated polish/audit runs (not just a single
run's before→after prose), maintain a cumulative numeric register alongside the audit output.

### Register location
`{repo_path}/.claude/tech-debt-register.json`

### Register schema
```json
{
  "last_updated": "ISO date",
  "snapshots": [
    {
      "date": "ISO date",
      "source_report": "AUDIT_CODE_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md",
      "scores": {
        "modernization": 7,
        "complexity": 5,
        "consistency": 6,
        "dependencies": 8,
        "cleanliness": 4,
        "saas_architecture": null
      },
      "overall": 6.0,
      "finding_counts": {"critical": 1, "high": 3, "medium": 8, "low": 12},
      "total_effort_hours": 24
    }
  ]
}
```

### Scoring rubric (1–10 × domains)
Direction: **10 = no debt in this domain (healthiest), 1 = severe debt** (most findings /
highest severity). Higher is always better; an `↑` arrow means the score rose (improved).
Domains map onto this skill's existing lenses:

| Register domain | Corresponds to audit-lenses.md lens |
|---|---|
| `modernization` | The modernization lens |
| `complexity` | Code quality & maintainability (complexity sub-focus) |
| `consistency` | Code quality & maintainability (duplication/pattern sub-focus) |
| `dependencies` | Dependency & supply-chain hygiene |
| `cleanliness` | Code quality & maintainability (dead code/cleanup sub-focus) |
| `saas_architecture` | Architecture & data integrity (when Appendix B patterns apply) — `null` when no multi-tenant/team/billing surface exists in this codebase |

### Update logic
1. After writing the audit/polish output, check if `.claude/tech-debt-register.json` exists.
2. If yes: append a new snapshot with current scores. Keep the last 10 snapshots (drop oldest).
   `saas_architecture` is `null` in any snapshot where that surface doesn't apply — exclude
   `null` entries from trend deltas and the "improved" tally below.
3. If no: create the file with a single snapshot.
4. `overall` = mean of the domain scores that actually ran **this** snapshot (include
   `saas_architecture` only when it was scored). Round to one decimal.
5. Add a `## DEBT_TREND` section to the report output:

```markdown
## DEBT_TREND

**All scores use the same direction as the rubric above: higher = healthier/less debt. `↑` = improved, `↓` = regressed.**

| Metric | Previous | Current | Δ |
|--------|----------|---------|---|
| Overall | 5.2 | 6.0 | +0.8 ↑ |
| Modernization | 6 | 7 | +1 ↑ |
| Complexity | 5 | 5 | 0 → |
| ...

Trend: Improving (3 of 5 core domains improved since last run; SaaS Architecture excluded — not applicable to this codebase)
```

If no previous snapshot exists, show "First analysis — no trend data yet."

**Persistence:** `.claude/tech-debt-register.json` is intended to *survive across runs* — it is
the trend history, unlike an ephemeral single-run report. It should be committed (or otherwise
retained), never gitignored or deleted on re-run.

---

## Appendix B: SaaS-architecture refactor shapes (optional, conditional)

Applies when the codebase has team/organization models, role-based access, billing features,
or shared multi-user resources — detect via `team_id`/`tenant_id`/`organization_id` columns in
migrations, `Team`/`Organization` models, `Role`/`Permission` enums, Cashier/Stripe in
dependencies, or `Policy` classes with team-scoped checks. When this surface is absent, skip
this appendix entirely (do not force these patterns onto a single-tenant codebase).

These are named refactor SHAPES to reach for under the `Architecture & data integrity` and
`Code quality & maintainability` lenses — not a separate scoring dimension to bolt on:

- **Normalize tenant-scoping data access:** Scattered `where('team_id', ...)` calls repeated
  across controllers/queries → extract into a global scope or repository pattern so tenant
  isolation is enforced in one place, not re-implemented per call site.
- **Extract a billing service:** Cashier/Stripe calls spread across controllers → consolidate
  into a single `BillingService` so subscription/invoice logic has one source of truth.
- **Consolidate permission/RBAC checks:** Inline `auth()->user()->can(...)` checks scattered
  through controllers/views → extract into Policy classes and middleware so authorization
  logic is centralized and auditable.
- **Consolidate analytics instrumentation:** Ad-hoc event-tracking calls scattered through
  business logic → consolidate into domain events with listeners, so instrumentation doesn't
  leak into every code path that needs to emit a signal.
- **Normalize error handling on external calls:** Inconsistent try/catch patterns wrapping
  external API calls (payment gateways, third-party integrations) → extract into a service
  layer with standardized error handling and retry/backoff behavior.

When flagging one of these, use the same evidence-backed finding format the rest of this
skill uses (file:line, current vs. target state, effort estimate) — just tag it with a
`SAAS-` prefix and note the safety classification (`mechanical` / `behavior-preserving` /
`behavior-changing`) since permission and billing consolidations are frequently
behavior-changing and warrant the security-bearing review path (adversarial reviewer on the
diff) before shipping.
