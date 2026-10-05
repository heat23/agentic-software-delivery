# v-audit-* skill template — canonical section order

> **Purpose:** every v-audit-* skill should follow the same section
> order so agents (and operators reading SKILL.md files) see a
> consistent shape. This file documents the canonical order with
> rationale; new audit skills should adopt it directly, existing
> skills should converge over time.

The order below is the agreed shape. Sections marked `[required]`
must be present in every audit skill; `[optional]` sections are
skill-specific.

| # | Section | Required | Purpose |
|---|---|---|---|
| 1 | YAML frontmatter | required | name, description, `model: inherit` (do NOT hardcode a model alias — `inherit` defers to the operator's session/CLI model and governs manual `/skill-name` invocation only; fan-out subprocesses are set separately at the dispatch site via `--model`, see `references/v-core-model-routing.md`) |
| 1b | § Model block | required | Every audit skill dispatches ALL subprocesses at `--model parent` under `export V_MODEL_POLICY_OVERRIDE=1` — the operator's session model, never a hardcoded tier (standing operator instruction 2026-08-11). Copy the § Model block from any existing `v-audit-*/SKILL.md` and cite `~/.claude/skills/references/v-audit-parent-model.md`; do NOT restate its rules. Never `--agent` a **haiku-pinned** agent — `--agent` ignores `--model`. |
| 2 / 3 | `## Entry Point` and `## Why This Exists` | required | invocation pattern + rationale paragraph; either may come first depending on the skill (rationale-first if the skill needs context-setting, invocation-first if it's frequently re-invoked) |
| 4 | `## Skill Boundaries` | required | **Best fit** / **Not for** / **Use instead** — anti-trigger guidance |
| 5 | `## The N Audit Dimensions` | required | named, numbered list of dims with one-line summaries |
| 6 | `## Consolidation / Batch Mode` | required | orchestrator integration contract |
| 7 | `## Verification Gates` | required | pointer to `~/.claude/skills/references/v-audit-gates.md` |
| 8 | `## Output conventions` | required | pointer to `~/.claude/skills/references/v-audit-output-conventions.md` |
| 9 | `## Anti-AI-tells reference` | optional | where applicable (content-touching audits) |
| 10 | `## Anti-pattern catalog reference` | optional | Round 4 catalogs (where present) |
| 11 | `## Floors` | required | pointer to `~/.claude/skills/references/v-audit-floors.md` with **Section to load:** anchor |
| 12 | `## Mandatory Execution Workflow` | required | step-summary table, opens with `**Audit opener:** see _v-audit.md § Audit Skill Opener.` |
| 13 | `## How to Run` | required | step-by-step body |
| 14 | `### Step 0: Orientation` | required | data input, project context detection |
| 15 | `### Step 1: Launch dimension audits` | required | parallel/sequential dispatch — every dispatch carries `--model parent` (see row 1b) |
| 16 | `### Step 2: Consolidate Results` | required | scoring + report writing |
| 17 | `### Step 3: Generate Implementation Prompts` | required | MUST USE SUBAGENT pattern |
| 18 | `### Step 3.5: Validate JSON Before Write` | required | per `_v-audit.md` § Step 3.5 |
| 19 | `### Step 4: Validate Prompt Pack + Present` | required | per `_v-audit.md` § Step 4 |
| 20 | `## Cross-Cutting Checks` | optional | where applicable |
| 21 | `## Execution Error Handling` | required | per `_v-audit.md` § Error Handling |
| 22 | `## Important Notes` | required | tail-end caveats, scope notes, sensitivity |

---

## Why this order

**Top-of-file (sections 2–6):** every reader needs to know how to
invoke the skill, why it exists, what it covers, and what it
doesn't. Putting these first lets a casual reader decide in 30
seconds whether this is the right skill.

**Cross-skill plumbing (sections 7–11):** the contracts that bind
this skill to the audit family. Verification Gates, Output
conventions, Anti-pattern catalogs, Floors — each is a pointer
to a shared reference. They cluster here so a reader can scan
"what's borrowed from elsewhere" before reading what's unique.

**Skill-specific workflow (sections 12–19):** the step-by-step
body. By placing the workflow table (12) just before the
prose (13–19), readers get a map before the territory.

**Tail (sections 20–22):** cross-cutting checks, error handling,
and caveats. These are reference content that's loaded on demand
during a run, not always read in order.

---

## Common deviations + how to fix them

| Deviation | Skill(s) currently affected | Fix |
|---|---|---|
| Missing `## Why This Exists` | `v-audit-admin` | Add a 1-paragraph rationale section after Entry Point |
| `## The N Audit Dimensions` placed late | `v-audit-admin` (at L250 instead of near top) | Reorder so dims are introduced before the workflow table |
| `## Why This Exists` ordered before `## Entry Point` | `v-audit-growth`, `v-audit-seo` | Acceptable variation — skills with complex V_DEPTH parsing + question blocks benefit from rationale-first ordering. Document the rationale inline if not obvious. |
| `## Floors` placed before cross-skill plumbing | none currently | Floors should be section 11 per the canonical order |
| `## Important Notes` missing | `v-audit-sales-pricing` (has it; verify others) | Add a tail section for caveats |

---

## When deviations are acceptable

Some skills have legitimate reasons to deviate:

- **v-audit-admin's `## Invocation Modes`** is a genuinely
  skill-specific section that documents Quick vs Thorough vs
  Standalone vs Orchestrator distinctions. It's reasonable for
  this section to appear between Entry Point and Skill Boundaries
  for that skill.
- **v-audit-seo's `## Scoring Model (Full Mode Only)`** is mode-
  specific and can sit between Consolidation and Verification
  Gates without harm.

The canonical order is a strong default; deviations need
rationale (documented in this file or the skill body).

---

## How to validate a skill against this template

```bash
# Print the major-section order of any audit skill
grep -nE "^## " $HOME/.claude/skills/v-audit-{skill}/SKILL.md
```

Compare against the canonical order. Sections out of order should
either be moved or have an inline note explaining the deviation.

---

## Cross-references

- `_v-audit.md` § Audit Skill Opener — the opener boilerplate
  every workflow table sources
- `~/.claude/skills/references/v-audit-gates.md` — Verification Gates section content
- `~/.claude/skills/references/v-audit-output-conventions.md` — Output conventions section content
- `~/.claude/skills/references/v-audit-floors.md` — Floors section content
