# Skill Authoring Contract

_Last reviewed: 2026-07-05_

Use this reference when adding or rewriting any `v-*` `SKILL.md` file.

## Goal

Keep every skill body readable, routable, and low-drift.

## Required Structure

Every user-facing, entry-point, orchestrator, and specialized skill must include:
- a short top-level explanation of what the skill does
- a `## Skill Boundaries` section
- `### Best fit`
- `### Use instead`
- `### Not for`

These sections should be concrete. Mention neighboring skills when misrouting is likely.

## Frontmatter Hygiene

- Frontmatter appears exactly once, at the top of the file.
- Do not repeat `model:`, `context:`, `allowed-tools:`, or similar frontmatter keys in the body.
- Do not leave malformed frontmatter remnants such as `model:` / `context:` / closing `---` blocks in the body.

## Body Hygiene

- Do not leave shell artifact lines in the body such as inline hook commands copied from debugging or generation runs.
- Keep workflow headings unique outside fenced code blocks.
- Prefer one authoritative template per output shape. If two routes share a large template, move it to a reference file.
- Large reusable prompt templates, output skeletons, or agent templates belong in `references/` when they would otherwise bloat the main SKILL body.
- Cross-cutting theme values (design tokens, SEO facts, security baseline, severity scales, copy thresholds, UI states, growth-motion policy) have ONE owning canon file each — see `references/v-theme-owners.md`. New/edited skills CITE the owner (`file.md § Section`), never restate its values; the `citation-integrity` vitest guard verifies cited sections exist.

## Boundary Writing Rules

`### Best fit` should describe the jobs the skill owns.

`### Use instead` should name the closest neighboring skills for adjacent jobs.

`### Not for` should block common misroutes:
- implementation vs planning
- full-codebase audit vs scoped audit
- generation vs audit
- user-owned maintenance vs product feature delivery

## Anti-Patterns

Avoid:
- repeating the same markdown template inline in multiple sections
- embedding volatile external facts directly in the workflow when they can drift
- relying on vague descriptions like "for anything related to X"
- leaving historical debugging fragments in the body

## Reference File Hygiene (last-reviewed stamps)

Reference files under `~/.claude/skills/references/` drift out of sync with the SKILLs that cite them — the dominant drift class is a hardened SKILL.md paired with a stale reference whose **worked examples** still teach forbidden vocabulary or fabricated APIs (agents imitate examples over prose).

To make drift visible and auditable:

- **Every reference file MUST carry a `_Last reviewed: <date>_` stamp** on its own line near the top (directly under the H1).
- The stamp asserts the file's content — especially its worked examples, code snippets, floors, and API references — was checked against the **owning SKILL's current version** on that date.
- **On any SKILL version bump, sweep every reference it loads** and reconcile: fix the **worked examples FIRST**, then prose, then bump the stamp. A stamp older than the SKILL it serves is a review-debt signal, not a guarantee.
- When you correct a reference for any reason, update its stamp to the correction date in the same change.

## Eval Requirement

Every `v-*` skill MUST ship with an `evals/evals.json` file containing at least one eval. This is enforced by `v-skill-linter.test.ts` § eval coverage enforcement.

### Eval Structure

```json
{
  "skill_name": "v-[name]",
  "evals": [
    {
      "id": 1,
      "prompt": "A realistic input prompt that exercises the skill's primary workflow",
      "expected_output": "Description of what the skill should produce: artifacts, decisions, tool invocations, and edge cases to handle correctly",
      "files": []
    }
  ]
}
```

### Guidelines

- At least 1 eval per skill, ideally 2-3 covering: happy path, edge case, and error/degraded path.
- `expected_output` is a behavioral description, not an exact text match — it describes what correct behavior looks like (artifacts produced, sub-skills invoked, edge cases handled).
- Critical-path skills (orchestrator, pre-flight, verify-done, ship, merge-all) should have 3+ evals each.
- The linter blocks new skills without `evals/evals.json`. Existing skills without evals are temporarily allowlisted with an expiration date — see the `evalExemptUntil` set in `v-skill-linter.test.ts`.
- When backfilling evals for existing skills, prioritize by blast radius: quality-gate skills first, then audit skills, then utilities.

### Token Budget Requirement

Every skill contract block MUST include `estimated_tokens` with a range estimate (e.g., `30k-100k`). This is enforced by `v-skill-linter.test.ts`. See `references/v-core-token-budgets.md` for per-workflow chain budgets.
