---
name: v-audit-orchestrator
description: "Use when routing a broad audit request across v-audit specialist skills."
allowed-tools: Read, Write, Bash, TaskCreate, TaskUpdate, AskUserQuestion, Skill
user-invocable: true
disable-model-invocation: true
context: fork
model: inherit  # inherit = run on the session/CLI model. Governs MANUAL /v-audit-orchestrator only; Skill-tool dispatch ignores it. Fan-out subprocesses are pinned separately at the dispatch site — via --model, or by the agent file's own frontmatter pin when dispatched with --agent (see v-core-model-routing.md).
---
<!-- skill: v-audit-orchestrator | version: 1.2.3 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: User-facing entry point. Meta-orchestrator that DISPATCHES to specialist audit skills — does not produce findings itself.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-review.md`, and `_v-audit.md`.

**Model — MANDATORY (parent-model inheritance).** Every subprocess this skill dispatches runs on the **operator's session model**, never a hardcoded tier — read `~/.claude/skills/references/v-audit-parent-model.md` and export its preamble ONCE before the first dispatch:

```bash
export V_MODEL_POLICY_OVERRIDE=1
V_AUDIT_MODEL="parent"     # every --model in this skill takes this value
```

Without that override every dispatch exits 2 on the sonnet-max gate. Never pass `--agent <name>` for a **haiku-pinned** agent — `--agent` ignores `--model` entirely and is the one path this preamble cannot correct (see that file's § The `--agent` bypass).


**Audit opener:** see `_v-audit.md` § Audit Skill Opener — perform PROJECT_ROOT resolution, V_DEPTH parsing, and TaskCreate/TaskUpdate initialization before Step 0 begins.

**Scope boundary (mandatory):** per `_v-audit.md` § In-App Actionability Boundary — every specialist this skill dispatches is bound by it (off-stack items never become findings, scores, or prompt packs). When composing dispatch prompts, do not add objectives that would push a specialist off-stack (e.g., "assess operational readiness / monitoring / backup strategy").

For the canonical audit-family decision matrix + bundle recipes, read `references/audit-family-map.md`.
For the "Advise me" path's signal-reading + recommendation logic, read `references/auto-routing-rules.md`.

```yaml
contract:
  tier: user-facing
  accepts: [project context, optional --bundle=, optional --specialist=, optional --advise, optional --no-consolidate (skip auto-consolidate even on multi-skill bundles)]
  produces: [routes to specialist skills; auto-invokes /v-audit-consolidate when N≥2 specialists ran]
  invokes: [/v-prelaunch-readiness, /v-anti-template-gauntlet, /v-audit-seo, /v-audit-messaging, /v-audit-sales-pricing, /v-audit-growth, /v-audit-analytics, /v-audit-admin, /v-check, /v-pre-flight, /v-verify-done, /v-audit-consolidate, /v-bug-hunt, /v-audit-code]
  conditional-invokes: []
  invoked-by: [/v, user]
  estimated_tokens: 5k-15k
  # orchestration-only — specialist skills are dispatched separately and use their own budgets
```

## Skill Boundaries

**SME persona:** This orchestrator is run by a **senior consulting auditor** — someone who's run audits across hundreds of projects and can read project signals to recommend the right audit bundle, then dispatch the appropriate specialists in the right sequence. The orchestrator's job is **routing + sequencing**, not auditing.

**Canonical authority:** this skill is the ecosystem's authoritative launch/ship audit router — the single place that owns "which audit skill(s) for which intent" and the bundle recipes. Other skills that need to route an operator toward a launch/ship audit should point here (`references/audit-family-map.md`) rather than re-deriving their own routing table.

### Best fit

- Single entry point for "I want to audit but don't want to remember which specialist skill"
- Pre-launch sweeps that need 4-5 audits + auto-consolidation
- Pre-merge gates that pair pre-flight + verify-done in one invocation
- Operators new to the audit family who want guidance ("Advise me — pick based on project state")
- Any context where running multiple audits and consolidating is the goal

### Use instead

- **Direct specialist invocation** (`/v-audit-seo`, `/v-check`, etc.) — when you know exactly which specialist you need; this orchestrator just adds a routing step
- **`/v-audit-consolidate`** — when the audits are already run and you only want to consolidate. The orchestrator auto-invokes consolidate after multi-skill bundles; you don't need to invoke it separately.
- **Direct design-skill invocation** (`/v-pricing-design`, `/v-activation-funnel-design`, etc.) — design skills are NOT in this orchestrator's scope (different conceptual category: CREATE vs AUDIT)

### Not for

- Replacing specialist audit skills (this orchestrator dispatches; it does not produce findings)
- Cross-project orchestration (operates on ONE project at a time)
- Design skills (use direct invocation; this orchestrator is audit-focused)
- Implementation work (use `/v-build` to execute audit-generated prompt packs)

## Why This Exists

The v-* audit family has 13 skills + 1 consolidator (`/v-ui-audit` retired 2026-07-06, absorbed into `/v-audit-code`; `/v-edge-hunt` merged into `/v-bug-hunt` 2026-07-05 — see `references/audit-family-map.md`, which is canonical for this count). Operators face cognitive load:

1. **Remembering which skill exists** — 14 names is too many to keep in working memory
2. **Picking between similar-sounding skills** — `v-audit-messaging` vs `v-audit-sales-pricing` (both touch the pricing page)
3. **Knowing the right sequence** — audits → consolidate → build
4. **Re-running audits after fixes** — which to re-run when something changes?

This orchestrator collapses that cognitive load to: **memorize ONE skill name (`v-audit-orchestrator`), invoke it, pick from a focused multi-choice menu, the orchestrator handles dispatch and consolidation.**

The trade-off: an extra routing step for cases where the operator already knows which specialist they want. For those cases, direct invocation skips the orchestrator. For the common case (especially the pre-launch flow where 4-5 audits should run and consolidate), the orchestrator is the right entry point.

## Entry Point

**Auto-detect everything. ONE multiple-choice question for the operator.**

### Auto-detection sequence

1. **Project context** from `CLAUDE.md` (skill-name interpolation in option labels)
2. **Recent audit history** scan:
   ```bash
   find "$PROJECT_ROOT" -maxdepth 4 \
     \( -name '*_REPORT_*.md' -o -name '*_REPORT_*.json' \
        -o -name '*_AUDIT_*.md' -o -name '*_AUDIT_*.json' \
        -o -name 'PRELAUNCH_READINESS_REPORT_*.md' \
        -o -name 'GAUNTLET_REPORT_*.md' \
        -o -name 'PRE_FLIGHT_REPORT_*.md' \
        -o -name 'VERIFY_DONE_REPORT_*.md' \
        -o -name 'LAUNCH_CHECKLIST_*.md' \
        -o -name 'v-ui-audit-*.md' -o -name 'v-ui-audit-*.json' \) \
     ! -name 'CONSOLIDATED_AUDIT_REPORT_*' \
     ! -name 'QA_REPORT_*' ! -name 'IMPLEMENTATION_REPORT_*' ! -name 'SKILL_REVIEW_REPORT_*' \
     -mtime -14 2>/dev/null | wc -l | tr -d ' '
   ```
   > `v-audit-consolidate/SKILL.md` § Auto-detection owns the **authoritative** discovery glob (it adds the
   > named-audit + `LAUNCH_CHECKLIST_*` clauses). This is a lighter COUNT for the menu label — the `*_AUDIT_*` /
   > `*_REPORT_*` + `.json` catch-alls above must stay in sync with it so the "Consolidate prior audit reports"
   > option is never wrongly hidden when specialist audits (incl. JSON-only outputs) actually exist.
   >
   > **Legacy recognizer:** `/v-ui-audit` retired 2026-07-06, absorbed into `/v-audit-code` (see
   > `references/audit-family-map.md`). The `v-ui-audit-*.md`/`.json` clause above is kept only so
   > pre-existing legacy reports still count toward this total — `/v-audit-code`'s
   > `AUDIT_CODE_REPORT_*.md` already matches the `*_REPORT_*.md` catch-all, so no new clause is
   > needed for it.
   - Note count for the question's "Consolidate prior audit reports" option label
3. **Stage signals** (used by Advise-me path) per `references/auto-routing-rules.md` § Signal-reading pass

### The single question

The full catalog below is 16 intents across [Bundle]/[Specialist]/[Meta]. The tool hard-caps
a question at 4 explicit options (plus its own auto "Other") — present the 4 intents most
relevant to the detected project context (stage signals, recent audit history, invocation
wording) and let anything else be reached via "Other," not the full list at once.

```yaml
question: "What do you want to audit?"
header: "Audit Intent"
multiSelect: false
options:
  # aq-exempt: catalog — model presents the 4 most-relevant intents for the detected
  # context + the tool's auto "Other", not all 16 at once.
  # Visual grouping via [Bundle] / [Specialist] / [Meta] prefixes
  - label: "[Bundle] Pre-launch readiness sweep (Recommended for solo SaaS launches)"
    description: "Runs /v-prelaunch-readiness + /v-anti-template-gauntlet + auto-consolidate. ~25 min. Best for sending traffic to product for the first time."
  - label: "[Bundle] Pre-launch full sweep (everything that should pass before launch)"
    description: "Runs /v-prelaunch-readiness + /v-anti-template-gauntlet + /v-audit-seo + /v-audit-messaging + /v-check + auto-consolidate. ~45-60 min."
  - label: "[Bundle] Pre-merge gate (after implementing a feature)"
    description: "Runs /v-pre-flight + /v-verify-done in parallel (write to non-overlapping report files). Executable gates + convention checks. Use before commit/merge."

  - label: "[Specialist] Code quality (broad codebase audit) — /v-check"
    description: "12 domains: security, perf, tests, UX, tech debt, a11y, SEO triage, AI/LLM, feature completeness, agent dispatch, observability, config validation."
  - label: "[Specialist] SEO + content + AI-search readiness — /v-audit-seo"
    description: "9 dims: technical, on-page, content, keywords, SERP, strategy, schema/AI-readiness, off-site, alt-page opportunities."
  - label: "[Specialist] Messaging + positioning — /v-audit-messaging"
    description: "7 surfaces: homepage, pricing copy, features, onboarding, emails, differentiation, cross-surface consistency."
  - label: "[Specialist] Pricing + sales ops — /v-audit-sales-pricing"
    description: "10 dims across 3 tracks: sales pipeline (1-5), pricing & RevOps (6-9), pricing strategy (10)."
  - label: "[Specialist] Growth funnel — /v-audit-growth"
    description: "5 dims: activation, retention, feedback loops, CRO, cancellation/win-back."
  - label: "[Specialist] Analytics instrumentation — /v-audit-analytics"
    description: "6 dims: event taxonomy, schema integrity, funnels, KPIs, dashboards, coverage."
  - label: "[Specialist] Admin panel — /v-audit-admin"
    description: "6 dims: functional completeness, visual craft, usability, edge cases, audit trail, AI-built blind spots. Auto-exits if no admin panel detected."
  - label: "[Specialist] Anti-template / AI-tells gate — /v-anti-template-gauntlet"
    description: "Binary verdict (PASS / CONDITIONAL_PASS / BLOCK). Catches AI/template tells in copy + visual + brand. Pre-ship output-quality gate."
  - label: "[Specialist] Adversarial bug hunt (one subsystem) — /v-bug-hunt"
    description: "Full-stack adversarial pass on one flow/subsystem: race conditions, broken UX, critical-path defects. Read-only; ships a prompt pack, not fixes."
  - label: "[Specialist] Edge-case / boundary hunt (one subsystem) — /v-bug-hunt --lens=boundaries"
    description: "Boundary-condition sweep on one domain: empty/max-value, DST, currency, unicode, pagination, state-machine, concurrency, entitlement edges. Read-only. (Formerly /v-edge-hunt, merged into v-bug-hunt as a lens 2026-07-05.)"
  - label: "[Specialist] Production-readiness, modernization & deep UX/a11y — /v-audit-code"
    description: "Whole-repo pass: security/data-integrity/reliability risk triage + 2026-modernization gaps + comprehensive UX/a11y depth (absorbed /v-ui-audit 2026-07-06 — see references/deep-ux-audit.md). Standalone deep pass, not part of the bundle sequence."

  - label: "[Meta] Consolidate prior audit reports ({N} found in last 14 days)"
    description: "Runs /v-audit-consolidate. Merges N≥2 existing audit reports into one de-duplicated view. NOTE: when N≤1, this option is OMITTED from the menu entirely (don't render with disabled state — AskUserQuestion has no native disabled-option semantics)."
  - label: "[Meta] Advise me — pick based on project state"
    description: "Reads project signals and recommends the right bundle with rationale. Operator confirms before dispatch."
```

The {N} placeholder in the "Consolidate prior audit reports" label is interpolated with the actual count from auto-detection.

If the operator passes `--bundle=prelaunch|prelaunch-full|premerge` or `--specialist=seo|messaging|...` or `--advise` in the invocation, the question is skipped.

## Workflow

| Step | Action | Skip conditions |
|---|---|---|
| Step 0 | Audit opener (PROJECT_ROOT, V_DEPTH, TaskCreate/TaskUpdate) | — |
| Step 1 | Auto-detection (recent audit count, stage signals) | — |
| Step 2 | Render the single multi-choice question (with {N} interpolated) | If `--bundle=` or `--specialist=` or `--advise` passed in invocation |
| Step 3 | Branch based on operator selection | — |
| Step 4 | (If "Advise me") Apply auto-routing-rules logic; present recommendation; await confirmation | Skip if not advise path |
| Step 5 | Dispatch specialist(s) via Skill tool, sequenced per the bundle definition | — |
| Step 6 | (If multi-skill bundle ran) Auto-invoke `/v-audit-consolidate` after specialists complete | Skip if single specialist or `--no-consolidate` flag |
| Step 7 | Present unified summary (verdict + dispatch trace + next-step recommendation) | — |

### Step 0: Audit opener

Per `_v-audit.md` § Audit Skill Opener — perform PROJECT_ROOT resolution, V_DEPTH parsing, and TaskCreate/TaskUpdate initialization before Step 1.

### Step 1: Auto-detection

Run the auto-detection sequence documented in the **Entry Point** section above (project context from CLAUDE.md, recent audit history scan, stage signals). Cache the result for use in Step 2's `{N}` interpolation and Step 4's "Advise me" path.

### Step 2: Render the single multi-choice question

Per the YAML question schema in the **Entry Point** section. Substitute `{N}` with the actual count from Step 1's audit-history scan. Skip this step entirely when `--bundle=`, `--specialist=`, or `--advise` is present in the invocation prompt.

### Step 3: Branch logic

| Selection | Action |
|---|---|
| Pre-launch readiness sweep | Dispatch sequence: v-prelaunch-readiness → v-anti-template-gauntlet → v-audit-consolidate |
| Pre-launch full sweep | Dispatch: v-prelaunch-readiness → v-anti-template-gauntlet → v-audit-seo → v-audit-messaging → v-check → v-audit-consolidate |
| Pre-merge gate | Dispatch: v-pre-flight + v-verify-done (parallel-safe; can run in single message) |
| Code quality | Dispatch: v-check |
| SEO + content | Dispatch: v-audit-seo |
| Messaging + positioning | Dispatch: v-audit-messaging |
| Pricing + sales ops | Dispatch: v-audit-sales-pricing |
| Growth funnel | Dispatch: v-audit-growth |
| Analytics instrumentation | Dispatch: v-audit-analytics |
| Admin panel | Dispatch: v-audit-admin |
| Anti-template / AI-tells | Dispatch: v-anti-template-gauntlet |
| Adversarial bug hunt | Dispatch: v-bug-hunt |
| Edge-case / boundary hunt | Dispatch: v-bug-hunt --lens=boundaries |
| Production-readiness, modernization & deep UX/a11y | Dispatch: v-audit-code |
| Consolidate prior reports | Dispatch: v-audit-consolidate |
| Advise me | Apply auto-routing-rules logic (Step 4) |

### Step 4: "Advise me" path

Per `references/auto-routing-rules.md`:

1. Run signal-reading bash commands (parallel-safe; one Bash call)
2. Classify project state (GREENFIELD / PRE-LAUNCH / MID-IMPLEMENTATION / LAUNCHED / AUDIT-PENDING)
3. Apply state ordering (AUDIT-PENDING > MID-IMPLEMENTATION > LAUNCHED > GREENFIELD > PRE-LAUNCH) per `references/auto-routing-rules.md` § State classification. **LAUNCHED beats GREENFIELD and PRE-LAUNCH** — a launched product with content history must not mis-classify as pre-launch. Take the FIRST matching state.
4. Pick recommended bundle
5. Compute confidence level (high / medium / low)
6. Present recommendation in the format documented in `auto-routing-rules.md`
7. Await operator confirmation
8. On confirmation, branch to Step 3 with the confirmed bundle/specialist
9. On override, route operator back to the main question

### Step 5: Dispatch (two paths — runtime determines which)

The orchestrator supports two dispatch paths to handle the runtime variation in nested Skill-tool invocations. Many specialists in this family declare `disable-model-invocation: true`, which CAN block parent-skill Skill-tool invocations in some runtimes.

#### Path A: Skill-tool dispatch (preferred when supported)

For each specialist in the bundle:

```
Skill tool invocation:
  skill: "v-audit-seo" (or whatever specialist)
  args: "[V_DEPTH=1]"
```

**`[V_DEPTH=1]` is REQUIRED.** Per `_v-core.md` § V_DEPTH Parsing Protocol, specialists detect orchestrator invocation via `V_DEPTH ≥ 1` and use it to:
- Skip entry-point AskUserQuestion (operator already chose at the orchestrator's question)
- Skip critic/adversarial-review dispatch (orchestrator owns review at consolidation)
- Skip persona-engagement protocol (orchestrator owns post-output review)
- Default to Full / Thorough depth (the most comprehensive mode)

**Do NOT pass `HEADLESS_BATCH=1` or `CONSOLIDATION_MODE=1`** — those flags are reserved for the ecosystem-review runner chain (which sets all four batch flags including `V_CHAIN=ecosystem-review-runner` and `RETURN_JSON_ONLY=1`). Setting them partially would suppress the prompt-pack generation that the operator needs.

Specialists are dispatched **sequentially** by default to avoid resource contention. The Pre-merge gate is the exception — pre-flight + verify-done write to non-overlapping files (`PRE_FLIGHT_REPORT_*.md` vs `VERIFY_DONE_REPORT_*.md`) and can run in parallel.

For each dispatch:
- Log the dispatch via TaskUpdate (so the operator sees progress)
- Wait for the specialist's output (the specialist writes its own report + prompt pack)
- Move to the next specialist in the bundle

If a Skill-tool invocation fails with "skill blocked / disable-model-invocation" or similar runtime restriction, fall back to Path B for the remaining specialists — **"remaining" includes the specialist that just failed via Path A**: it has not produced a report yet, so it is redispatched as the first Path B call, not skipped. The bundle must still end with every specialist's report on disk; a specialist whose Path A attempt failed and was never retried would silently vanish from the Step 7 summary instead of appearing there as a Path-B dispatch.

#### Path B: Autonomous subprocess fallback (when Skill-tool dispatch is blocked)

When Path A is unavailable, the orchestrator does NOT hand the operator a manual paste-plan — that would require a human to babysit each step, violating the ecosystem's autonomous-operation rule. Instead it dispatches each remaining specialist itself as an independent, headless `claude -p` subprocess via the sanctioned dispatch helper (`~/.claude/skills/v/references/v-dispatch-subagent.sh`), the same fork-safe mechanism `run-v-packs` uses to fire-and-forget `/v` prompts (`~/.claude/skills/references/v-runnable-pack-convention.md`):

```bash
# One subprocess per specialist, run sequentially (no --agent: this dispatches a
# SKILL slash-command, not a ~/.claude/agents/ persona, so v-dispatch-subagent.sh's
# no-agent / --model path applies).
printf '%s\n' "/v-prelaunch-readiness [V_DEPTH=1]" > /tmp/dispatch-prompt.txt
~/.claude/skills/v/references/v-dispatch-subagent.sh \
  --model parent --mode self-write \
  --prompt-file /tmp/dispatch-prompt.txt \
  --artifact "$PROJECT_ROOT/PRELAUNCH_READINESS_REPORT_${TIMESTAMP}_${CLAUDE_SESSION_ID}.md"
```

For each specialist in the bundle:
- Build its `/v-<specialist> [V_DEPTH=1]` prompt and expected artifact path exactly as Path A would
- Dispatch via the helper (`--mode self-write` — specialists write their own report + prompt pack)
- Log the dispatch and its exit code via TaskUpdate
- On exit 0, verify the artifact landed and move to the next specialist
- On non-zero exit (helper exit codes 2-7), record the failure in the run's summary and continue to the next specialist rather than stalling the whole bundle — the final Step 7 summary calls out any specialist that failed to produce its artifact

This is slower than Path A (a fresh process per specialist) but requires zero operator interaction — the orchestrator completes the bundle end-to-end either way.

The orchestrator detects which path applies during the FIRST dispatch attempt:
- If Path A succeeds → continue with Path A for remaining specialists
- If Path A fails → switch to Path B for ALL remaining steps and continue autonomously (never fall back to a manual paste-plan)

### Step 6: Auto-consolidate

When the bundle ran ≥2 specialists, after the last specialist completes:

**Path A (if Skill-tool dispatch worked):**
```
Skill tool invocation:
  skill: "v-audit-consolidate"
  args: ""  (consolidator auto-detects the recent reports just produced)
```

**Path B:** dispatch `/v-audit-consolidate [V_DEPTH=1]` as the final `v-dispatch-subagent.sh` subprocess, same as any other Path B specialist dispatch.

Skip auto-consolidate when:
- Only 1 specialist ran (nothing to consolidate)
- Operator passed `--no-consolidate` flag (rare; for when they want each specialist's output independently)
- **Pre-merge gate bundle** — pre-flight and verify-done are two intentionally-separate gate types (deterministic checks vs. convention judgment), not a general 2-report bundle; see `references/audit-family-map.md` § Pre-merge gate. Step 3's dispatch table deliberately has no `→ v-audit-consolidate` arrow for this row. Present both reports side by side instead of consolidating them.

### Step 7: Unified summary

After all dispatches complete (and consolidation if applicable):

```markdown
# v-audit-orchestrator dispatch summary
generated: [ISO timestamp]
bundle: [bundle name or specialist name]

## Specialists dispatched

| # | Skill | Verdict (canonical) | Findings (P0/P1/P2/P3) | Report path | Prompt pack |
|---|---|---|---|---|---|
| 1 | v-prelaunch-readiness | {verdict} | {p0/p1/p2/p3} | PRELAUNCH_READINESS_REPORT_*.md | .v-prompt-packs/v-prelaunch-readiness-<MM-DD>/ |
| 2 | v-anti-template-gauntlet | {verdict} | {p0/p1/p2/p3} | GAUNTLET_REPORT_*.md | .v-prompt-packs/v-anti-template-gauntlet-<MM-DD>/ |
| ... | ... | ... | ... | ... | ... |

## Consolidation (auto-triggered)

Verdict: **BLOCK** (worst-case across bundle)
Consolidated findings: 14 unique (4 duplicate clusters merged)
Report: CONSOLIDATED_AUDIT_REPORT_*.md
Prompt pack: .v-prompt-packs/v-audit-consolidate-<MM-DD>/

## Recommended next step

Paste `.v-prompt-packs/v-audit-consolidate-<MM-DD>/w1-{theme}.txt` into a fresh `/v` session to start fixing the highest-priority findings (substitute today's actual run date; v-audit-consolidate emits the runnable wave form, not `NN-*.md` — see `~/.claude/skills/references/v-runnable-pack-convention.md`).

## Re-run guidance

After implementing fixes from the consolidated prompt pack:
- Re-run `/v-audit-orchestrator` with the same bundle to confirm verdict flipped
- Or re-run individual specialists if you only changed one domain

**Stale-report warning:** when re-running >7 days after a prior consolidation, the new consolidator may include findings from the prior run (the 14-day discovery window catches both fresh and recent specialist reports). To get a clean re-run picture, pass `--window=1` to the auto-consolidate step OR delete the prior specialist reports before re-running.
```

## Cross-references

- Audit family decision matrix: `references/audit-family-map.md`
- "Advise me" path logic: `references/auto-routing-rules.md`
- Consolidator (auto-invoked): `~/.claude/skills/v-audit-consolidate/SKILL.md`
- Severity normalization (used by consolidator): `~/.claude/skills/v-audit-consolidate/references/severity-mapping.md`
- Skill template + section conventions: `~/.claude/skills/v-audit-orchestrator/references/v-audit-skill-template.md`
- Audit family verification gates: `~/.claude/skills/references/v-audit-gates.md`

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Orchestrator dispatches multiple specialist audits but operator only wanted one | Single-multiple-choice question's bundle option not understood | Question's bundle options [Bundle X / Specialist Y / Meta Z] must be unambiguous; if user clarifies "just one audit", route to specialist not bundle |
| 2 | Path A (Skill tool) fails silently because target skill has `disable-model-invocation: true` | Runtime restriction not detected | Per Step 5: attempt Path A on the FIRST dispatch; if it fails with a blocked / disable-model-invocation error, fall back to Path B (execution plan) for all remaining specialists. `disable-model-invocation: true` blocks model AUTO-invocation, not necessarily explicit Skill-tool calls — so do NOT pre-emptively default to Path B; detect on the first attempt and commit to whichever path that attempt proves. |
| 3 | Bundle dispatch consumed 200K+ tokens because main context streamed full specialist outputs | Specialists not internally forking — main context received raw findings | Use **Skill tool** for sequential specialist dispatch (Step 5 Path A) **when supported by the runtime — see Gotcha 2 above for the `disable-model-invocation: true` constraint that may force Path B**. Specialists fork their own subagents internally; the main context only sees their final summaries, not raw dimension outputs. Never invoke specialists' workflow steps inline in the orchestrator's own context. |
| 4 | Auto-consolidate ran but produced empty findings list | Per-skill outputs didn't write expected paths | Auto-consolidate relies on `v-audit-consolidate`'s own early-exit (writes a `NOT-RUN` verdict report on <2 reports found) — this skill does not duplicate that check itself |
| 5 | State classification picked PRE-LAUNCH for project with live recurring revenue | Order-of-operations bug | AUDIT-PENDING > MID-IMPLEMENTATION > LAUNCHED > GREENFIELD > PRE-LAUNCH; revenue ≥ launched threshold even if "pre-launch" mentioned in copy |
## Idempotency

Re-running on the same project produces fresh dispatches. The orchestrator does NOT reuse prior reports unless explicitly invoking the "Consolidate prior audit reports" option. Each specialist invocation produces a fresh report + prompt pack.

## What this skill does NOT do

- **Does not produce findings** — it dispatches specialists; specialists produce findings
- **Does not implement fixes** — operator pastes consolidated prompt pack into `/v` for implementation
- **Does not replace `/v` (the master orchestrator)** — `/v` routes to TDD/build/check/etc.; this orchestrator is audit-specific
- **Does not handle design skills** — design (pricing, activation, beta, illustrations) uses direct invocation; this skill is audit-focused
