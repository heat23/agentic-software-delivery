# Theme Owners — canon registry for cross-cutting themes (shared)

_Last reviewed: 2026-08-02 (added the AI/model-backed feature engineering row — AI-era coverage sweep)._

> **Persona for this reference:** skill author / reviewer deciding where a
> cross-cutting rule LIVES versus where it is merely USED.

Each cross-cutting theme has exactly ONE owning canon file. **New or edited
skills CITE the owner (`<file>.md § <Section>`), never restate its values** —
a restated threshold, palette, tier table, or policy line is drift waiting to
happen (the 2026-07-06 design/theme sweeps found dozens of such copies, each
slightly stale). If a skill needs a theme value, it links; if the value is
wrong, fix it in the owner file only.

| Theme | Owner (canon) | Notes |
|---|---|---|
| Design system (tokens, palette, typography, spacing, components, craft gate) | `~/.claude/skills/_v-design.md` | Full component spec beside it: `references/design-system-spec.md`. Per-product freedoms only via `.interface-design/system.md` overlay. |
| SEO / AEO | `~/.claude/skills/v-audit-seo/SKILL.md` + `references/seo-volatile-knowledge-2026.md` | The volatile-knowledge file owns anything dated (algorithm updates, schema deprecations, AI-search facts). |
| Security | `~/.claude/skills/_v-security.md` | Project-agnostic baseline; `~/.claude/CLAUDE.md § Security Defaults` holds the operator's global defaults. |
| Performance | `~/.claude/CLAUDE.md` (Quality Gates + Production Standards) + `~/.claude/skills/_v-exec.md` | N+1/eager-loading/bounded-query rules; wall-clock targets are aspirational, not CI-enforced. |
| Copy / content voice (AI-tell bans, contraction floors, casing) | `~/.claude/skills/references/anti-ai-tells-content.md` | Per-word thresholds live ONLY there — never restate a flat cap. |
| Severity / finding scales | `~/.claude/skills/references/v-core-severity.md` | P0–P3 canonical; per-skill native→P translation table in `v-audit-consolidate/references/severity-mapping.md`. AGENT_REVIEW's critical/high/medium/low is parser-frozen — map, don't rename. |
| UI states (loading / error / empty / optimistic / submission / stale) | `~/.claude/skills/v-build/references/saas-patterns.md` § UI state management checklist | The six canonical states; success feedback rides the optimistic-update toast row. |
| Growth motion (zero-outreach solo operator) | `~/.claude/skills/references/v-core-solo-motion.md` | Outbound/pitch/PR findings are banned by default; opt-in only via an explicit project `motion:` declaration. |
| AI/model-backed feature engineering (cost model, model selection criteria, eval harness, non-deterministic testing, degradation UX, observability for model calls) | `~/.claude/skills/references/ai-feature-engineering.md` | Job-level enforcement (budget caps before dispatch, timeouts, retry policy, streaming pattern) lives in `_v-jobs.md` § Model-Call Jobs — cite, don't restate. Code-review-time detection of missing cost/abuse controls lives in `v-audit-code/references/audit-lenses.md` § Cost & abuse: metered outbound calls. Explicitly out of scope: prompt-injection defense, authz, secrets — that's `_v-security.md`'s theme. |

## Rules

1. **Cite, never copy.** Reference the owner with a `file.md § Section` citation
   (the `citation-integrity` vitest guard verifies the section exists).
2. **One owner per theme.** If two files both claim a theme, pick the one above
   and demote the other to a citing consumer.
3. **New theme → add a row here first**, then cite it from the skill that
   needed it. A theme value with no registry row has no home and WILL fork.
4. **Volatile facts** (dated benchmarks, algorithm behavior, vendor pricing)
   belong in the theme's volatile-knowledge file (e.g.
   `seo-volatile-knowledge-2026.md`, `competitor-signals-2026.md`), never
   inline in a SKILL.md.
