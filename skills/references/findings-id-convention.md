# Findings ID Convention

_Last reviewed: 2026-08-02 (full resync, deferred from the same-day
single-source-of-truth sweep noted below — every registered skill was
re-audited against its own SKILL.md + references/ ground truth, not
carried forward from the prior pass's claims. Found and fixed 3 MORE
instances of the same drift class the prior pass caught: **v-audit-analytics**
also uses a 3-digit sequence (`TAXON-001`), not this file's 2-digit
default — undocumented until now, same class as v-audit-growth;
**v-audit-sales-pricing** likewise uses a 3-digit sequence (`ICP-001`),
also previously undocumented; **v-bug-hunt** has an entire SECOND lens
(`lens: boundaries`, absorbed from the retired `/v-edge-hunt`) with its own
9-dim `EHUNT-<DIM>-NN` scheme in `references/boundaries-lens.md` that was
never registered in this file at all — added as a new section.
`v-anti-template-gauntlet`'s table was re-verified against the skill body:
no contradiction, but no in-skill literal ID example either — annotated as
this file's own prescriptive convention rather than a confirmed citation.
`v-audit-messaging`, `v-audit-admin`, `v-audit-growth`, `v-audit-seo` were
re-checked and remain clean. See § Maintenance for the re-verification
method and its evidence-sweep command. Prior: 2026-08-02 earlier same-day
pass — single-source-of-truth sweep: v-audit-seo's row was wrong on two axes — showed 8 dims (skill has 9, including Dim 9 Alternative-Page Opportunities which had no ID home anywhere) and used the wrong ID grammar (`[DIM]-[NN]` dash format vs. the skill's actual `{PREFIX}{NNN}` no-separator scheme hard-coded in `dim-checklists.md` and declared in `v-audit-seo/SKILL.md`); corrected and registered as an explicit exception. Spot-check of 3 more registered skills found the SAME drift class twice more: v-audit-admin's table listed prefixes (`FUNC`/`CRAFT`/etc.) the skill has never emitted (real scheme is `ADM-{SUBCODE}-{NNN}`); v-audit-analytics was missing a 6th dim and had 2 wrong prefixes (`EVENT`→`TAXON`, `SCHEMA-EV`→`SCHEMA`); v-audit-growth's prefixes were correct but its sequence padding is 3-digit, not this file's 2-digit default. All corrected. Before that: 2026-07-06 theme-consistency sweep B)._

Registry of stable, run-to-run-diffable finding-identifier schemes for audit skills (v-audit-seo, v-audit-messaging, v-audit-sales-pricing, v-audit-growth, v-audit-analytics, v-audit-admin, v-anti-template-gauntlet, v-bug-hunt). Most of these use the canonical `[DIM]-[NN]` format below; **v-audit-seo is a registered exception with its own `{PREFIX}{NNN}` scheme** — see its section. (v-ui-audit was retired 2026-07-06 and absorbed into `/v-audit-code`'s deep UX/a11y mode — see the tombstoned dim table below; v-audit-code itself organizes findings by named lens, not numbered dim, per `v-audit-code/references/audit-lenses.md`, so it isn't listed as an active consumer of the `[DIM]-[NN]` table below, though it may still apply the general `[DIM]-[NN]` format per `deep-ux-audit.md` Cross-references.)

**When to load:** any audit skill that produces JSON findings. Read once at Step 0 (orientation); apply when assigning IDs to findings during Step 2 / Step 3 (synthesis).

**Why this exists:** without a consistent ID convention, the same finding gets different IDs on each audit run, breaking the operator's ability to diff "what's new" vs "what's still here" across audit cycles. IDs encode dimension + sequence so re-runs produce the same ID for the same finding.

---

## The format

```
[DIM]-[NN]
```

Where:
- `[DIM]` is the dimension prefix (3-8 letters, all-caps)
- `[NN]` is a 2-digit sequence number, zero-padded, scoped to the dimension

Examples:
- `HOME-01` — Homepage / Value Proposition dim, finding 1
- `PRICE-MSG-04` — Pricing Page Messaging dim (audit-messaging), finding 4
- `SEO-12` — SEO audit, finding 12
- `CRO-03` — Conversion Rate Optimization dim, finding 3
- `LAYOUT-08` — Layout & Density dim, finding 8

---

## Canonical dimension prefixes

### v-ui-audit (15 dims) — RETIRED 2026-07-06, tombstoned for back-compat

v-ui-audit was absorbed into `/v-audit-code`'s deep UX/a11y mode 2026-07-06.
This table is kept so `[DIM]-[NN]` IDs in pre-existing v-ui-audit reports
remain decodable for re-run diffing; it is not actively produced by any
current skill (v-audit-code's lens system in `audit-lenses.md` does not
map 1:1 onto these 15 numbered dims). Canonical dims match
`v-audit-floors.md § v-audit-code floors` and the hardened v-ui-audit SKILL
body (reconciled 2026-07-05 — the prior table used a retired dim scheme).

| Dim # | Name | Prefix |
|---|---|---|
| 1 | Visual hierarchy & layout | `LAYOUT` |
| 2 | Brand voice & in-product microcopy | `COPY` |
| 3 | Activation funnel | `ACTIVATE` |
| 4 | Empty states & first-run | `EMPTY` |
| 5 | Accessibility (WCAG 2.2 AA) | `A11Y` |
| 6 | Mobile responsiveness | `MOBILE` |
| 7 | Dark mode | `DARK` |
| 8 | Performance & web vitals | `PERF` |
| 9 | Print / PDF | `PRINT` |
| 10 | SEO (meta, OG, JSON-LD, hreflang) | `SEO-UI` |
| 11 | Visual system | `VISSYS` |
| 12 | Brand identity | `BRAND` |
| 13 | Documentation / help / trust | `TRUST` |
| 14 | i18n readiness | `I18N` |
| 15 | Security & data handling | `SEC-UI` |

### v-audit-seo (9 dims) — REGISTERED EXCEPTION: does NOT use `[DIM]-[NN]`

**v-audit-seo does not follow this file's `[DIM]-[NN]` format.** Its subagents
emit a dimension-letter-code + 3-digit sequence with NO separator
(`{PREFIX}{NNN}`, e.g. `T001`, `SD001` — not `TECH-01`), hard-coded in
`v-audit-seo/references/dim-checklists.md`'s Output JSON schemas and declared
canonical in `v-audit-seo/SKILL.md` § Output conventions → "Finding-ID
override". Never re-key these to `[DIM]-[NN]` at consolidation —
v-audit-consolidate preserves registered-scheme IDs as-is, same as it does for
v-audit-sales-pricing's owner-registered prefixes above.

| Dim # | Name | Prefix | Example |
|---|---|---|---|
| 1 | Technical SEO | `T` | `T001` |
| 2 | On-Page SEO | `O` | `O001` |
| 3 | Content Quality & Gaps | `C` | `C001` |
| 4 | Keyword Research & Intent | `K` | `K001` |
| 5 | SERP Analysis | `S` | `S001` |
| 6 | Content Strategy | `CS` | `CS001` |
| 7 | Structured Data & AI Readiness | `SD` | `SD001` |
| 8 | Off-Site Growth & Link Earning | `OG` | `OG001` |
| 9 | Alternative-Page Opportunities | `AP` | `AP001` |

### v-audit-messaging (7 dims)

| Dim # | Name | Prefix |
|---|---|---|
| 1 | Homepage & Value Prop | `HOME` |
| 2 | Pricing Page Messaging | `PRICE-MSG` |
| 3 | Feature & Product Pages | `FEAT` |
| 4 | Onboarding & In-App Copy | `ONBOARD` |
| 5 | Email & Notification Copy | `EMAIL` |
| 6 | Differentiation & Competitive | `DIFF` |
| 7 | Cross-Surface Consistency | `CONSIST` |

### v-audit-sales-pricing (10 dims)

(Prefixes match the owner's registered scheme — `v-audit-sales-pricing/SKILL.md` § Finding-ID canon; hard-coded in its `references/dim-checklists.md` Output JSON schemas.)

**Re-verified 2026-08-02 (same drift class as v-audit-growth, previously
undocumented for this skill):** the skill's actual output uses a **3-digit
sequence** (`ICP-001`, `STRAT-001`) — not this file's file-default 2-digit
padding (`ICP-01`). Confirmed against every `Output findings as JSON. IDs:
{PREFIX}-001, {PREFIX}-002...` line in `references/dim-checklists.md` (all
10 dims) and the `"id": "ICP-001"` example in `v-audit-sales-pricing/SKILL.md`.
Treat 3-digit as this skill's registered override, same as v-audit-growth.

| Dim # | Name | Prefix |
|---|---|---|
| 1 | ICP definition | `ICP` |
| 2 | Lead scoring | `LEAD` |
| 3 | Outreach sequences | `REACH` |
| 4 | CRM hygiene | `CRM` |
| 5 | Sales enablement content | `ENABLE` |
| 6 | Pricing model fitness | `PRICE` |
| 7 | Checkout flow | `CHECKOUT` |
| 8 | Dunning / recovery | `DUNNING` |
| 9 | Competitive intel | `COMPETE` |
| 10 | Pricing strategy | `STRAT` |

### v-audit-growth (5 dims)

**Spot-checked 2026-08-02:** prefixes below are correct, but the skill's actual
output uses a 3-digit sequence (`ACT-001`) rather than this file's file-default
2-digit padding (`ACT-01`) — see `v-audit-growth/references/dimension-briefs.md:11`
and the `plg_ACT-001`-style examples in `v-audit-growth/SKILL.md`. Treat 3-digit
as this skill's registered override.

| Dim # | Name | Prefix |
|---|---|---|
| 1 | Activation | `ACT` |
| 2 | Retention | `RET` |
| 3 | Feedback loops | `FDBK` |
| 4 | CRO | `CRO` |
| 5 | Cancellation / Win-Back | `CHURN` |

### v-audit-analytics (6 dims)

**Spot-checked and corrected 2026-08-02 (same drift class as v-audit-seo/v-audit-admin):**
this table listed 5 dims with prefixes `EVENT`/`SCHEMA-EV` for dims 1-2 — the
skill actually has **6 dims**, dims 1-2 use `TAXON`/`SCHEMA` (never `EVENT` or
`SCHEMA-EV`), and dim 6 (Instrumentation Coverage, `COVER`) had no row at all.
Verified against `v-audit-analytics/SKILL.md`'s own dimension table and
`references/dim-checklists.md`'s per-dim `Output findings as JSON. IDs: ...`
lines. Cross-cutting findings get a `-CC-` infix on the owning dim's prefix
(e.g. `KPI-CC-001`) — not a separate dim.

**Re-verified 2026-08-02 — a second, previously undocumented drift found in
the same pass (same class as v-audit-growth/v-audit-sales-pricing):** every
`IDs: ...` line in `references/dim-checklists.md` (all 6 dims, e.g.
`TAXON-001, TAXON-002...`) and the `"id": "TAXON-001"` example in
`v-audit-analytics/SKILL.md` itself use a **3-digit sequence**, not this
file's file-default 2-digit padding. Treat 3-digit as this skill's
registered override, same as v-audit-growth and v-audit-sales-pricing.

| Dim # | Name | Prefix |
|---|---|---|
| 1 | Event Taxonomy & Naming | `TAXON` |
| 2 | Schema Integrity & Properties | `SCHEMA` |
| 3 | Funnel Definition Correctness | `FUNNEL` |
| 4 | KPI Formula Validation | `KPI` |
| 5 | Dashboard Assertions | `DASH` |
| 6 | Instrumentation Coverage | `COVER` |

### v-audit-admin (6 dims)

**Spot-checked and corrected 2026-08-02 (same drift class as v-audit-seo):** this
table previously listed `FUNC`/`CRAFT`/`UX`/`DESTRUCT`/`SEC-ADMIN`/`BLIND` — none
of which the skill has ever emitted. The real scheme shares an `ADM-` super-prefix
(`ADM-{SUBCODE}-{NNN}`, 3-digit sequence, e.g. `ADM-PM-001`), declared at
`v-audit-admin/SKILL.md:35` ("domain-prefixed finding IDs") and
`v-audit-admin/references/admin-audit-checklists.md` (per-dim `ID Prefix:` lines).

| Dim # | Name | Prefix | Example |
|---|---|---|---|
| 1 | Functional Completeness | `ADM-PM` | `ADM-PM-001` |
| 2 | Visual Craft & Consistency | `ADM-DES` | `ADM-DES-001` |
| 3 | Usability & Interaction | `ADM-UX` | `ADM-UX-001` |
| 4 | Edge Cases & Robustness | `ADM-QA` | `ADM-QA-001` |
| 5 | Audit Trail & Security | `ADM-OPS` | `ADM-OPS-001` |
| 6 | AI-Built Blind Spots | `ADM-AI` | `ADM-AI-001` |

### v-bug-hunt — `lens: bugs` (default lens, 8 dims)

Prefixes are two-part (`BHUNT-<DIM>`), like `PRICE-MSG`; the full ID is `BHUNT-<DIM>-NN` (e.g., `BHUNT-FLOW-01`).

| Dim # | Name | Prefix |
|---|---|---|
| 1 | Critical Flows | `BHUNT-FLOW` |
| 2 | Forms & Validation | `BHUNT-FORM` |
| 3 | API / Inertia Contract | `BHUNT-API` |
| 4 | Auth, Session & RBAC | `BHUNT-AUTH` |
| 5 | Async & State | `BHUNT-ASYNC` |
| 6 | Error Surfaces | `BHUNT-ERR` |
| 7 | Data Integrity | `BHUNT-DATA` |
| 8 | Production Surface | `BHUNT-PROD` |

Human-decision escalations in the bug-hunt report use `DEC-NN` (not findings — they carry no severity).

### v-bug-hunt — `lens: boundaries` (9 dims) — NEWLY REGISTERED 2026-08-02, was entirely absent from this file

**v-bug-hunt has a second lens** (`lens: boundaries`, merged 2026-07-05 from
the retired `/v-edge-hunt` skill — see the "Two lenses, one skill" callout
near the top of `v-bug-hunt/SKILL.md`, a bold pseudo-heading rather than a
markdown heading, so it is cited by name here rather than with a `§` section
anchor) with its own dimension set and prefix scheme, `EHUNT-<DIM>-NN`
(two-digit, e.g. `EHUNT-MONEY-01`), documented only in
`v-bug-hunt/references/boundaries-lens.md` and never cross-referenced from
this file until now. This is a real, coherent, in-skill-declared scheme —
registered as an exception, not merged into the `bugs`-lens table above
(the two lenses' dimension sets are disjoint and never share a prefix).

| Dim # | Name | Prefix |
|---|---|---|
| 1 | Empty / Null / Zero Inputs | `EHUNT-EMPTY` |
| 2 | Max / Limit / Overflow | `EHUNT-LIMIT` |
| 3 | Date / Time / Timezone / DST / Leap | `EHUNT-TIME` |
| 4 | Currency / Money / Cashier Proration | `EHUNT-MONEY` |
| 5 | Unicode / Emoji / RTL / Multibyte | `EHUNT-UNICODE` |
| 6 | Pagination / Sorting / Pluralization | `EHUNT-QUANTITY` |
| 7 | State Machine / Invalid Transitions | `EHUNT-STATE` |
| 8 | Concurrent / Race / Idempotency | `EHUNT-CONCURRENT` |
| 9 | Plan Limit / Entitlement Boundary | `EHUNT-ENTITLEMENT` |

Source: `v-bug-hunt/references/boundaries-lens.md` §§ "Dimension 1" through
"Dimension 9" (each dim's `` ` `` prefix appears in its own heading) and the
`"id": "EHUNT-MONEY-01"` JSON example at that file's § "JSON output
extensions (boundaries lens)".

### v-anti-template-gauntlet (cross-dim, severity-led — sequence is GLOBAL across all severities)

**Re-verified 2026-08-02:** `v-anti-template-gauntlet/SKILL.md` names its
severity tiers `CRITICAL`/`HIGH`/`MEDIUM`/`LOW` (matching
`v-core-severity.md`'s P0-P3 scale) but never hard-codes a literal ID
example anywhere in its own body or `references/gauntlet-checks.md` — the
report template just says `[For each: ID, file:line, severity, ...]`. **This
file is the sole source for the `BLOCK`/`HIGH`/`MED`/`LOW` prefix mapping**
below (nothing in-skill contradicts it, but nothing confirms the exact
prefix strings either — `BLOCK` in particular doesn't match the skill's own
`CRITICAL` severity word verbatim). Treat this table as prescriptive for
that skill, not as a citation of a hard-coded in-skill example; if
`v-anti-template-gauntlet` ever adds its own literal ID example, reconcile
against that, not this note.

| Severity | Prefix | Example |
|---|---|---|
| Critical (blocking template tells) | `BLOCK` | `BLOCK-01` |
| High | `HIGH` | `HIGH-02` |
| Medium | `MED` | `MED-03` |
| Low | `LOW` | `LOW-04` |

**Important deviation from other audit skills:** v-anti-template-gauntlet's sequence number `[NN]` is GLOBAL across all severities, NOT per-severity. So `BLOCK-01`, `HIGH-02`, `MED-03`, `LOW-04` are all consecutive findings (in severity order) within a single audit run. This convention enables severity-ordered ID assignment that re-run-diffs cleanly: a Medium finding promoted to High in a re-run keeps its sequence number but changes prefix (`MED-03` becomes `HIGH-03` if severity escalates).

For v-audit-consolidate: when merging anti-template-gauntlet output with other audit outputs, preserve the original ID; severity normalization to P0/P1/P2/P3 happens at the consolidator's severity-mapping layer, not by re-numbering.

---

## Sequence numbering

`[NN]` is zero-padded 2-digit, scoped to the dim within a single audit run:

- Within `HERO`: HERO-01, HERO-02, HERO-03, ...
- Within `PRICE-MSG`: PRICE-MSG-01, PRICE-MSG-02, ...
- Sequences DO NOT carry across audits — each audit run starts at NN=01 per dim
- If >99 findings in a single dim: continue HERO-100, HERO-101 (3-digit overflow allowed)

---

## Re-run diffing

The ID + finding-content fingerprint together enable re-run diffing:

| Audit run | Finding ID | Content fingerprint | Operator interpretation |
|---|---|---|---|
| Run 1 (2026-04-15) | HERO-03 | sha1(file:line:summary) = abc123 | Original finding |
| Run 2 (2026-04-29) | HERO-03 | sha1(...) = abc123 | Re-observed (operator hasn't fixed) |
| Run 2 | HERO-04 | (different fingerprint) | New finding from Run 2 |

Findings that re-appear with the same content fingerprint get tagged `re_observed: true`. Findings whose IDs persist but content fingerprints change get tagged `evolved: true` (operator partially-fixed but issue remains).

---

## When the operator fixes a finding

After the operator implements a fix (typically via v-build):

1. The finding does NOT appear in the next audit run (file:line is gone OR the issue is resolved)
2. The ID is NOT reused for a different finding in the same dim
3. After 3 consecutive runs without re-observation, the ID can be archived (released for reuse) — but practically, IDs grow monotonically

---

## Maintenance — this registry is derived, not invented

**Rule:** every row in this file must trace to a literal ID example that
already exists on disk in the owning skill's own `SKILL.md` or
`references/*.md` — never the reverse. If a skill's dispatch prompt or
JSON-schema instructions change their ID format, this file is wrong until
someone updates it; it does not become "wrong" the other way (a skill
should never be edited to match a stale claim here).

**How to re-verify any row:** open the skill's `references/dim-checklists.md`
(or equivalent per-dim reference) and find each dimension's `Output findings
as JSON. IDs: ...` line, plus any `"id": "..."` example in the skill's own
`SKILL.md`. Those two sources are ground truth for: dimension count, prefix
string, separator style (`-` vs none), and sequence padding (2-digit vs
3-digit). A table row that doesn't match either source is drift — fix the
table, don't touch the skill.

**Evidence sweep (tested 2026-08-02 against all 8 registered skills — run
from `~/.claude/skills`):**

```bash
for skill in v-audit-seo v-audit-messaging v-audit-sales-pricing \
             v-audit-growth v-audit-analytics v-audit-admin \
             v-anti-template-gauntlet v-bug-hunt; do
  echo "--- $skill ---"
  grep -rhoE '(IDs?:[^.\n]*[0-9]{2,3}[^.\n]*)|("id":\s*"[A-Z][A-Z0-9_-]*[0-9]{2,3}")' \
    "$skill"/SKILL.md "$skill"/references/*.md 2>/dev/null | sort -u
done
```

This is a surfacing tool, not an auto-differ — each skill's literal example
numbers vary (some start `-01`, some `-001`), so it can't diff itself
against the tables above unattended. What it reliably proves: (a) whether a
skill has ANY in-skill ID declaration at all (v-anti-template-gauntlet
correctly returns nothing — confirmed real absence, not a grep miss, by
also checking `references/gauntlet-checks.md` and the report-template
`[For each: ID, file:line, ...]` placeholder by hand), and (b) the exact
padding width per prefix (spotting the `-01` vs `-001` divergence is what
caught the v-audit-analytics and v-audit-sales-pricing drift in this pass).
Read the output, don't just check it's non-empty.

---

## Cross-references

- v-ui-audit `tier-classification.md` (retired 2026-07-06) — used these IDs for stable-finding determinism; the determinism CONCEPT carries forward in `v-audit-code/references/deep-ux-audit.md` § 9 "Tier-classification determinism concept"
- v-audit-consolidate — merges findings across audit skills using this ID convention; severity is normalized but IDs are preserved
- v-bug-hunt's second lens (`lens: boundaries`) and its `EHUNT-*` scheme: `v-bug-hunt/references/boundaries-lens.md`
