# Audit-skill severity → canonical P-tier mapping

_Last reviewed: 2026-07-06 (theme-consistency sweep B: ID-prefix registry corrected to owners' registered schemes)._

> **Persona for this reference:** senior audit-tooling engineer
> responsible for cross-skill output compatibility. Loaded
> on-demand by v-audit-consolidate Step 3.

**Canonical scale authority:** the P0/P1/P2/P3 definitions and verdict rules are owned by
`~/.claude/skills/references/v-core-severity.md` ([[v-core-severity]]). This file is ONLY the per-skill
translation layer — it maps each source skill's *native* vocabulary onto that canonical scale. If the P-tier
definitions below ever appear to disagree with [[v-core-severity]], the shared reference wins.

The audit-skill family uses 4 different severity vocabularies
across its 10+ skills. This reference maps every native severity
to a canonical P-tier so cross-skill consolidation is
deterministic.

When a new audit skill adopts a fifth vocabulary, update this
file (and only this file). v-audit-consolidate reads the table
at runtime to normalize.

---

## Canonical P-tier definitions

| Tier | Meaning | Verdict impact |
|---|---|---|
| **P0** | Blocking issue. Code, surface, or data is broken or unsafe. Ship-blocker. | Triggers BLOCK or NEEDS-WORK |
| **P1** | High-impact issue. Silent conversion loss, accumulating tech debt, or trust erosion. Should fix before launch. | Triggers NEEDS-WORK |
| **P2** | Medium-impact issue. Polish, optimization, or non-critical hygiene. Nice to fix soon. | Does not affect verdict |
| **P3** | Low-impact issue. Cosmetic, edge-case, or future consideration. Deferrable indefinitely. | Does not affect verdict |
| **SKIP** | Skill explicitly skipped this dim/check (operator preference, n/a stage, etc.). | Excluded from consolidation |

---

## Per-skill severity mappings

| Skill | Native severity | Canonical P-tier | Notes |
|---|---|---|---|
| **v-prelaunch-readiness** | MUST-FIX | P0 | "Blocks driving traffic" → P0 |
| | SHOULD-FIX | P1 | "Causes silent conversion loss" → P1 |
| | NICE-TO-HAVE | P3 | "Polish" → P3 (skipping P2 — vocabulary has no medium tier) |
| **v-anti-template-gauntlet** | CRITICAL | P0 | "Instant fail / would damage brand" → P0 |
| | HIGH | P1 | "Strong tell, correctable in <30 min" → P1 |
| | MEDIUM | P2 | "Subtle drift" → P2 |
| | LOW | P3 | (gauntlet doesn't emit LOW currently, but reserved) |
| **v-ui-audit** (RETIRED 2026-07-06 — absorbed into `v-audit-code`; row kept only to parse pre-existing legacy reports) | Critical | P0 | v-ui-audit emitted 7 native tiers; mapped explicitly below |
| | Critical-Craft | P0 | Craft-tier critical findings still block |
| | High | P1 | Standard High severity |
| | Heavy | P1 | Heavy = legacy alias for High; same map |
| | Medium | P2 | Standard Medium severity |
| | Medium-Craft | P2 | Craft-tier medium |
| | Low | P3 | Standard Low severity |
| | Low-Craft | P3 | Craft-tier low |
| **v-audit-admin / -analytics / -growth / -messaging / -sales-pricing** | P0 | P0 | Already canonical |
| | P1 | P1 | Already canonical |
| | P2 | P2 | Already canonical |
| | P3 | P3 | Already canonical |
| **v-audit-seo** | CRITICAL | P0 | seo's native vocab is CRITICAL/HIGH/MEDIUM/LOW (NOT P-tier — score deltas −25/−15/−5/−2). Was wrongly bucketed "already canonical", so every CRITICAL SEO finding silently defaulted to P2 and could never BLOCK. |
| | HIGH | P1 | |
| | MEDIUM | P2 | |
| | LOW | P3 | |
| **v-bug-hunt** (`bugs` lens) | P0_CRITICAL / critical | P0 | Emits `### P0_CRITICAL`…`### P3_SUSPECTED` section headings AND an inline `severity: critical\|high\|medium\|low` field (shared FINDING_FORMAT_JSON). Map both forms. |
| | P1_IMPORTANT / high | P1 | |
| | P2_POLISH / medium | P2 | |
| | P3_SUSPECTED / low | P3 | |
| **v-bug-hunt** (`boundaries` lens — formerly v-edge-hunt, merged 2026-07-05; same `BUG_HUNT_REPORT_*` file, `lens: boundaries` metadata + `EHUNT-*` ID prefix) | critical | P0 | NO section-heading taxonomy — findings use the compact pipe header `#### <ID> \| file:line \| category \| severity \| confidence` (4th pipe token = severity), grouped by priority, plus a `by_priority: {P0..P3}` count in the YAML header. Parse the pipe token (or the JSON `severity` field when `--format=json`). Distinguish from the `bugs` lens by ID prefix (`EHUNT-` vs `BHUNT-`), not by skill name. |
| | high | P1 | |
| | medium | P2 | |
| | low | P3 | |
| **v-audit-code** | P0 | P0 | Already canonical (emits P0-P3 via [[v-core-severity]]); reports as `AUDIT_CODE_REPORT_*.md`. Standalone whole-repo pass — appears in consolidation only if the operator ran it alongside other audits. |
| | P1 | P1 | |
| | P2 | P2 | |
| | P3 | P3 | |
| **v-check** | P0_CRITICAL | P0 | Vocabulary uses underscore suffix; strip and map |
| | P1 | P1 | |
| | P2 | P2 | |
| **/v-ship** (retired 2026-04-29) | NO-GO blocker | P0 | Legacy reports only — /v-ship retired; its config-validation subset moved to v-check Domain 12. Kept so any pre-retirement /v-ship report still consolidates. |
| | First-72h watchlist (high) | P1 | |
| | First-72h watchlist (medium) | P2 | |
| | First-72h watchlist (low) | P3 | |
| **v-pre-flight** | fail | P0 | Failed quality gate (test/build/lint/types/security audit) |
| | pass | — | Gate passed cleanly; no finding to emit |
| | skipped | SKIP | Tooling not available (excluded from consolidation) |
| | not_evaluated | SKIP | Gate not run (excluded); a DEGRADED not_evaluated (e.g. missing phpstan.neon, browser binary absent) still surfaces as a prominent advisory per v-pre-flight, not a silent pass |
| **v-verify-done** | error | P1 | Convention check failure (lazy loading, DOMPurify, types) |
| | warning | P2 | Convention drift (non-blocking) |
| | info | P3 | Suggestion (non-blocking) |

---

## Verdict vocabulary mapping

Different skills emit different verdict words. Map all to canonical PASS / NEEDS-WORK / BLOCK:

| Skill | Native verdicts | Canonical |
|---|---|---|
| v-prelaunch-readiness | READY | PASS |
| | NEEDS-WORK | NEEDS-WORK |
| | NOT-READY | BLOCK |
| v-anti-template-gauntlet | PASS | PASS |
| | CONDITIONAL_PASS | NEEDS-WORK |
| | BLOCK | BLOCK |
| | BLOCK_OVERRIDDEN | NEEDS-WORK (operator overrode; flagged in consolidated report) |
| /v-ship (retired 2026-04-29) | GO | PASS |
| | NO-GO | BLOCK |
| (no third state) | (treated as PASS for partial-readiness) | — |
| v-ui-audit (RETIRED 2026-07-06 — legacy reports only) | (no top-level verdict; uses score 0-100) | PASS if score ≥80, NEEDS-WORK if 60-79, BLOCK if <60 — the current source, `v-audit-code`, is in the finding-count-driven row below |
| v-audit-analytics | `analytics_health`: HEALTHY \| DEGRADED \| UNRELIABLE | HEALTHY → PASS, DEGRADED → NEEDS-WORK, UNRELIABLE → BLOCK — UNRELIABLE fires on `any P0 OR overall_score < 4 OR instrumentation_score < 3`, so it can hit BLOCK with **zero P0 findings**; map by verdict name, don't re-derive from the P0 count alone. **Pre-launch caveat (v-audit-analytics ≥1.3.1, 2026-08-12):** a pre-launch / zero-data product is capped at DEGRADED and NEVER emits UNRELIABLE (absence-of-foundation is not a P0), so a greenfield analytics audit maps to NEEDS-WORK, never a false BLOCK — this reinforces "map by verdict NAME, never re-derive from the score/P0 triggers." |
| v-audit-growth | `growth_readiness`: READY \| READY WITH CAVEATS \| NOT READY | READY → PASS, READY WITH CAVEATS → NEEDS-WORK, NOT READY → BLOCK — NOT READY fires on `any P0 OR overall_score < 60`, score-alone with zero P0s included |
| v-audit-messaging | `messaging_health`: STRONG \| NEEDS WORK \| INCONSISTENT | STRONG → PASS, NEEDS WORK → NEEDS-WORK, INCONSISTENT → BLOCK — INCONSISTENT fires on `(integrity_score < 4) OR any P0 OR overall_score < 4`, score-alone with zero P0s included |
| v-audit-sales-pricing | `revenue_readiness`: READY \| READY WITH CAVEATS \| NOT READY | READY → PASS, READY WITH CAVEATS → NEEDS-WORK, NOT READY → BLOCK — NOT READY fires on `any P0 OR overall_score < 5 OR dunning_score < 3 (when dunning ran)`, score-alone with zero P0s included |
| v-check, v-audit-admin, v-audit-code, v-audit-seo | (no top-level verdict; uses finding counts / raw score) | PASS if 0 P0+P1, NEEDS-WORK if any P1, BLOCK if any P0 |

Non-Thorough partial states (`"N/A (quick depth …)"`, `"PARTIAL — <depth> depth"`, `AUDIT_INCOMPLETE`) are not one of the three tiers above — treat them as **SKIP** (excluded from BLOCK/NEEDS-WORK/PASS aggregation) rather than defaulting them to PASS, since an unscored partial run must never silently read as a clean verdict. **The partial signal is not always a verdict string (ND-0716):** `v-audit-growth` emits a real `growth_readiness` in every mode and marks non-Thorough runs via a separate top-level `"partial": true` boolean — when the source JSON carries `"partial": true` (or an equivalent top-level incomplete flag), map its verdict to SKIP exactly as if it were one of the partial strings above.

---

## Aggregation rule

The verdict-aggregation algorithm is **normative in ONE place**: `consolidation-rules.md` § Verdict aggregation
— which includes the `BLOCK_OVERRIDDEN` carve-out (operator-overrode → NEEDS-WORK, not BLOCK) that a former
duplicate here silently omitted. Do NOT restate the algorithm in this file: a second copy is exactly the
contract-drift that ships a divergent rule. See:
`~/.claude/skills/v-audit-consolidate/references/consolidation-rules.md` § Verdict aggregation.

The one-line intuition (the normative doc is authoritative if this ever disagrees): the consolidated verdict is
the worst-case reading across all source audits — one BLOCK dominates — except a source `BLOCK_OVERRIDDEN`, which
the operator already downgraded and which aggregates to NEEDS-WORK with a flag.

---

## Finding-ID prefix registry

The source-skill → ID-prefix mapping consolidation's dedup uses to recognize cross-skill duplicates
(consolidation-rules.md Gotcha #4 points here — this table IS the "ID prefix dictionary"; new audit skills add
a row). Two schemes exist:

| Skill | ID scheme | Examples |
|---|---|---|
| v-check | `FND-<n>` skill-scoped | FND-001 |
| v-bug-hunt (`bugs` lens) | `BHUNT-<dim>-<n>` skill-scoped | BHUNT-RACE-01 |
| v-bug-hunt (`boundaries` lens — formerly v-edge-hunt, merged 2026-07-05) | `EHUNT-<dim>-<n>` skill-scoped | EHUNT-MONEY-01 |
| v-audit-admin | `ADM-<n>` skill-scoped | ADM-003 |
| v-audit-code | `<FINDING-ID>` UPPERCASE-HYPHEN, single-subject | WEBHOOK-IDEMPOTENCY, N-PLUS-ONE-DASHBOARD |
| v-audit-seo | dimension-letter + 3 digits (no dash) | T001, C001, K001, S001, CS001, SD001, OG001, AP001 |
| v-audit-analytics | per-DIMENSION prefixes | TAXON-, INSTR-, … |
| v-audit-growth | per-DIMENSION prefixes | ACT-, RET-, … |
| v-audit-messaging | per-SURFACE prefixes | HOME-, PRICE-MSG-, FEAT-, ONBOARD-, EMAIL-, DIFF-, CONSIST- |
| v-audit-sales-pricing | per-DIMENSION prefixes | ICP-, LEAD-, REACH-, CRM-, ENABLE-, PRICE-, CHECKOUT-, DUNNING-, COMPETE-, STRAT- |
| v-prelaunch-readiness | per-SURFACE prefixes | HERO-, … |
| v-ui-audit (RETIRED 2026-07-06 — legacy reports only) / v-anti-template-gauntlet | no stable finding-ID scheme | dedup by content fingerprint only |

**Rule:** an ID prefix identifies the SOURCE, never the duplicate — two findings with different prefixes but the
same content fingerprint (file:line + issue) ARE duplicates and must merge (the prefix difference is exactly why
Gotcha #4 exists). Skills without a stable scheme dedup purely on the fingerprint.

---

## Unmapped severity handling

If an audit report contains a severity not listed above:

1. Log a warning: `unmapped severity: {value} from {skill}`
2. Default the finding to **P2** (medium impact; non-blocking)
3. Mark the consolidated finding with `severity_unmapped: true` for operator visibility
4. Return a soft-fail in the validation step — operator should update this file before re-running

This is preferable to silently dropping the finding.

---

## How to add a new audit skill

When a new audit skill is created:

1. Document its native severity vocabulary in this file
2. Map each level to canonical P0/P1/P2/P3
3. Add the skill name to the appropriate skills list in v-audit-consolidate's discovery patterns
4. Test consolidation by running a sample of the new skill + an existing audit on the same project — verify findings consolidate correctly

---

## Cross-references

- v-audit-output-conventions (shared output format): `~/.claude/skills/references/v-audit-output-conventions.md`
- v-audit-floors (per-dim minimum-findings calibration): `~/.claude/skills/references/v-audit-floors.md`
- Consolidation rules (fingerprinting, dedup): `~/.claude/skills/v-audit-consolidate/references/consolidation-rules.md`
