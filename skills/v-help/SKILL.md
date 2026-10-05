---
name: v-help
description: "Use when explaining the v-* skill family, skill routing, or example /v workflows."
model: haiku
context: fork
allowed-tools: Read, Glob, Grep, AskUserQuestion
user-invocable: true
---
<!-- skill: v-help | version: 1.1.2 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: User-facing entry point.

This contract overrides older sections below on conflict.

No shared modules required. This is a read-only reference skill.

Rules:
- output to console only
- do not create files
- do not run commands
- artifact shorthand: PLAN_[timestamp]_${CLAUDE_SESSION_ID} (where [timestamp] = YYYY-MM-DD_HHMM, ${CLAUDE_SESSION_ID} = session ID)

```yaml
contract:
  tier: user-facing
  accepts: [optional topic filter]
  produces: []
  invokes: []
  invoked-by: [user]
  side-effects: none
  estimated_tokens: 3k-8k
  estimated_duration: <1 min
```

---

# /v-help — Skill Reference & Workflow Guide

## Skill Boundaries

**SME persona:** This skill is run by a **senior developer-tooling onboarding specialist** — specialty is meeting the operator where they are. New users get setup guidance + first-skill recommendations; experienced users get fast paths to the workflow they need; nobody gets a wall of marketing copy.

### Best fit

- Showing the current v-skill catalog, chaining paths, and artifact names
- Lightweight workflow orientation when the user wants to know which skill to run
- Quick console-only reference output without touching files or running commands

### Use instead

- Use `/v` when the user wants the work performed rather than explained
- Use `/v-plan` when the user wants a planning artifact, not a reference
- Use `/v-maintenance` when the question is really a concrete maintenance task in user-owned paths
- Use `/v-audit-orchestrator --advise` for "which audit should I run?" — it owns audit-routing; v-help only renders the catalog.

### Not for

- Executing workflows or modifying files
- Serving as a substitute for the underlying skill instructions during implementation
- Keeping a manually curated, drifting catalog that contradicts the current contracts

## Behavior

Print the reference below to the console. If the user appends a topic (`/v-help growth`, `/v-help artifacts`, `/v-help chains`), print only that section. Otherwise print everything.

---

## Output

### Skill Catalog (runtime-generated)

When the operator asks "what skills do I have" or invokes `/v-help` without a topic, generate the catalog at runtime — DO NOT rely on a hardcoded table. Hand-edited tables drift away from the on-disk skill set; this is documented as Gotcha #1 and the live cause of stale output before this skill was refactored.

**Generation steps (run in order):**

1. **Enumerate skills on disk (use the Glob tool — this skill has NO Bash and MUST NOT run shell commands):** Glob the pattern `~/.claude/skills/v-*/SKILL.md`, plus `~/.claude/skills/v/SKILL.md` for the orchestrator. Each returned path's parent-directory name is an installed skill (e.g. `…/v-build/SKILL.md` → `v-build`). Deduplicate and sort the derived names — this yields the complete installed v-* set plus `v` without invoking a shell.
2. **Read each skill's frontmatter** for the one-line summary. The first paragraph of the `description:` field (or the first sentence) is what to display.
3. **Read each skill's contract block** (`tier:` field) to group output by tier:
   - `orchestrator` (only `/v` ships at this tier)
   - `entry-point` and `user-facing` — Tier 1 (operator-invoked)
   - `orchestration-primitive` — Tier 2 (called by `/v`; usable directly)
   - `specialized` — Audit / Growth / Design / Content family
   - `comprehensive` — deep specialist audits (`v-bug-hunt` — both its `bugs` and `boundaries` lenses, the latter formerly `v-edge-hunt`, merged 2026-07-05 — `v-forensics`, `v-forensics-pack-runner`); render as their own group, not dropped or folded into `specialized`
4. **Read each skill's `produces:` line** for the artifact name; use it as the third column.
5. **Render the table** with one row per discovered skill, sorted alphabetically within each tier. Use this exact column structure:
   - Column 1: Skill — backtick-wrapped slash command (e.g., `` `/v-build` ``)
   - Column 2: Description — the first sentence of the frontmatter `description:` field, with trigger phrases stripped
   - Column 3: Produces — the `produces:` line from the contract block, abbreviated to the primary artifact name
   - Group rows under H4 headings: `#### Tier 1 — User-facing & Entry-points`, `#### Tier 2 — Orchestration primitives`, `#### Specialized — Audit / Growth / Design / Content`, `#### Comprehensive — Deep Specialist Audits`
   - Skip skills with `user-invocable: false` from the operator-visible catalog UNLESS the operator explicitly asks "show all skills including runner-only" — runner-only skills are an internal detail.
6. **Append** the static sections below (workflows, artifacts, agents, shared modules, gotchas, removed skills) — those are stable across runs and do not need filesystem scanning.

If the catalog generation fails (filesystem unavailable, frontmatter malformed, or 0 skills returned), output a structured fallback in this exact form:

> Skill catalog generation failed: {one-line cause — "filesystem unavailable" / "0 skills found at expected path" / "frontmatter parse error in <skill>" / etc.}.
>
> Manual recovery:
> 1. Verify install: `ls -d ~/.claude/skills/v-*/` should return one directory per installed skill.
> 2. If the directory is empty: re-run `/v-setup-project` or check that ~/.claude/skills/ has the expected layout.
> 3. If frontmatter parsing failed: open the named skill's SKILL.md and confirm the YAML frontmatter has both `name:` and `description:` keys.
>
> Until repaired, refer to the static **Common Workflows** and **Auto-Chaining Paths** sections below — those work without filesystem scanning.

Do NOT fabricate a skill list when generation fails. The operator needs to see that something is wrong, not a confident-but-wrong table.

The static sections that follow (Common Workflows, Auto-Chaining Paths, Artifacts, Agents, Shared Modules, Gotchas, Removed Skills) ARE intentionally hardcoded — they document reasoning patterns, filename conventions, and historical deletions, none of which can be derived from the skill filesystem.

---

### Common Workflows

**Build a feature:**
```
/v add user notifications
```
Router detects scope, plans if needed, runs TDD → build → pre-flight → verify-done.

**Fix a bug:**
```
/v fix the 404 on /items/{item}/notifications
```
Investigates → fixes → tests → pre-flight → verify-done.

**Audit before launch / ship:**
```
/v-check
```
Runs the full 12-domain audit (Domain 12 covers config-validation / launch-readiness — the retired ship command was folded into it; see Removed Skills below) and produces a scored `AUDIT_REPORT_*.md`. Fix findings with `/v AUDIT_REPORT_*.md` (routes to the v-build primitive).

**Plan a big feature:**
```
/v-plan
```
Interactive planning with 6 routes (new product, understand codebase, specific feature, refactor, growth planning, user-owned maintenance). Output feeds into `/v-build`.

**Quick quality check:**
```
/v-pre-flight
```
Runs all gates, reports pass/fail.

**Maintain the local skill or hook system:**
```
/v-maintenance harden ~/.claude/hooks/session-env-check.sh and canonical skill tests only
```
Keeps the work in user-owned roots, edits canonical skills before mirror sync, runs targeted tests first, then finishes with hostile review and verification.

**Review a v-skill before changing it:**
```
/v-skill-reviewer v-tdd
```
Produces `SKILL_REVIEW_REPORT_<sid>.md` with ranked findings and exact patch recommendations. Implementation remains a separate `/v-maintenance` task.

**End a session cleanly:**
```
/v-handoff
```
Captures everything the next session needs.

**Scaffold a new service:**
```
/v scaffold PaymentReconciliationService
```
Routes to the v-scaffold primitive; creates service + test + optional job matching your project's patterns.

**TDD a new class:**
```
/v write failing tests for NotificationService
```
Routes to the v-tdd primitive; creates failing tests (RED), then you implement (GREEN).

**Full production audit:**
Run `/v-audit-orchestrator` — the canonical entry point. It routes to the right specialist audits (or a full bundle), runs each at its canonical depth (scored JSON + implementation prompts), and auto-invokes `/v-audit-consolidate` to merge results into one prioritized backlog (~10-35 min). The older `run-claude-ecosystem-review.sh` shell runner was archived 2026-07-05 — it is no longer present; use `/v-audit-orchestrator` instead. The legacy `v-audit-full` skill was removed 2026-04 — see Removed Skills below.

**Growth funnel review:**
```
/v-audit-growth
```
Assesses activation, retention, feedback, and CRO (4 dimensions). Automatically generates individual prompt files in `.v-prompt-packs/v-audit-growth-<MM-DD>/` — one per session, ready to copy-paste. For analytics, messaging, SEO, and pricing depth, use the dedicated specialist audit skills.

**Sales & pricing operations audit:**
```
/v-audit-sales-pricing
```
Audits ICP, lead scoring, outreach, CRM pipeline, sales content, pricing model, checkout, dunning, competitive pricing, and pricing strategy fitness (value metric, psychology, expansion revenue). Produces scored report + implementation prompts.

**Analytics quality audit:**
```
/v-audit-analytics
```
Audits event taxonomy, schema integrity, funnel definitions, KPI formulas, dashboards, and instrumentation coverage. Catches "silent lies" in your data.

**Messaging & positioning audit:**
```
/v-audit-messaging
```
Audits homepage, pricing page, onboarding, emails, feature pages, and competitive positioning for consistency, clarity, and differentiation strength.

**Grow organic traffic (the one-door wizard):**
```
/v-traffic
```
Zero-outreach traffic wizard. Paste your Search Console + GA4 data (or drop exports in `.seo/`) and it runs the whole pipeline for you — `/v-audit-seo` → `/v-content-ops` → a single ranked `TRAFFIC_PLAN` of do-this-week moves grounded in your own numbers. Reply `do 1,3` and it drafts them via `/v-content-create`. Re-run for the "what moved / next batch" cadence. Use this instead of remembering the individual skills below.

**Audit SEO and plan content:**
```
/v-audit-seo
```
Full SEO audit — keyword research, content gap analysis, SERP analysis, strategy planning. Produces a scored content plan with prioritized calendar.

**Write SEO content:**
```
/v-content-create write about [topic]
```
Writes an SEO-optimized article with visual content (infographics, interactive components, diagrams). Use `/v-audit-seo` first for strategy.

**Generate comparison page (X-vs-Y, alternatives-to, pricing pages):**
```
/v-content-create --type=comparison compare us to [competitor]
```
SEO-optimized comparison page with embedded playbook (3-framing variance, 5-axis publication-blocking grading, JSON-LD schema). Use after `/v-audit-seo` identifies a comparison opportunity. Requires a named competitor. (This was a standalone skill before the 2026-07-05 merge — see Removed Skills below.)

**Generate answer-engine / AI-citation content:**
```
/v-content-create --type=aeo which query should this target
```
AEO content optimized for citation in ChatGPT, Perplexity, Google AI Overviews (BLUF discipline, entity density, schema-first). (This was a standalone skill before the 2026-07-05 merge — see Removed Skills below.)

**Design email sequences:**
```
/v-content-create email sequences
```
Designs lifecycle email flows (welcome, onboarding, re-engagement, dunning) and generates templates for your framework.

**What should I work on next (across all my projects)?**
```
/v-next --root=~/dev
```
Read-only cross-project scan (stale audits, unresolved findings, stranded worktrees, CI health) producing one ranked next-action list. Recommends a skill per item; never runs anything itself.

**Is production healthy right now?**
```
/v-prod-triage
```
Read-only runtime health triage — error clustering, queue/failed-jobs backlog, scheduled-task drift, post-deploy smoke check. Add `restore-drill --confirm-restore-drill` to also verify the latest backup restores cleanly (against a throwaway scratch database only — never production).

**First time on a new project:**
```
/v-setup-project → stage-appropriate first audit → /v <prompt-pack file> (per session)
```
Bootstraps the project, then `/v-setup-project` Step 7 recommends the first audit by project stage: greenfield/pre-launch → `/v-prelaunch-readiness`, actively in-development → `/v-check` (fast code audit), already launched → `/v-audit-orchestrator` (routes to specialists + auto-consolidates). Copy-paste each generated prompt file from `.v-prompt-packs/` into parallel sessions.

---

### Auto-Chaining Paths

```
Build:    /v → worktree (medium/large) → /v-tdd → /v-build → /v-polish (UI) → /v-check (scoped, medium/large) → /v-pre-flight → agent review → /v-verify-done → merge-back
Launch:   /v → /v-pre-flight → /v-audit-orchestrator (routes specialists + auto-consolidates) → /v-check (launch-day procedure)
Review:   /v → /v-check → /v-audit-code (if structural issues; absorbed the retired v-refactor skill 2026-07-06 — see Removed Skills)
Planning: /v → /v-plan → /v-build (or growth skill)
Maintenance: /v → /v-maintenance → targeted tests → /v-pre-flight (changed-only when supported) → agent review → /v-verify-done
New Product: /v-plan (Route 1) → auto: /interface-design → auto: /v-setup-project → recommend: /v-audit-seo → paste .v-prompt-packs/v-plan-<MM-DD>/ into parallel sessions
Audit:    /v-check (quick) → /v-audit-orchestrator (comprehensive bundle) → copy-paste from .v-prompt-packs/ → /v (per session; routes to v-build)
Growth:   /v-audit-growth (incl. CRO) → copy-paste from .v-prompt-packs/v-audit-growth-<MM-DD>/ → /v (per session; routes to v-build)
Email:    /v-content-create email → /v (implement templates)
Revenue:  /v-audit-sales-pricing → /v (per implementation prompt session)
Analytics: /v-audit-analytics → /v (per implementation prompt session)
Messaging: /v-audit-messaging → /v (copy fixes) or /v-content-create (new content)
Feature Discovery: /v-discover-features → paste .v-prompt-packs/v-discover-features-<MM-DD>/ into /v-plan → /v (per feature)
Portfolio: /v-next (rank overdue items across projects) → the recommended skill for the #1 item
Prod health: /v-prod-triage → paste P0/P1 findings into a fresh /v session as fix tasks
Content:  /v-audit-seo → /v-content-ops (calendar + briefs) → /v-content-create (per brief)
Content (direct): /v-audit-seo → /v-content-create write (per article, skipping calendar)
Comparison: /v-audit-seo → /v-content-create --type=comparison → /v (per page)
Consolidation: /v-merge-all — merge all worktrees/branches after parallel sessions complete
```

---

### Artifacts

**Strategic** (immutable, timestamped — never silently overwritten):
`PLAN_[timestamp]_${CLAUDE_SESSION_ID}`, `AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}`, `REFACTOR_PLAN_[timestamp]_${CLAUDE_SESSION_ID}`, `BUILD_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}`, `LAUNCH_CHECKLIST_[timestamp]_${CLAUDE_SESSION_ID}`, `HANDOFF_${CLAUDE_SESSION_ID}` (literal — no timestamp), `GROWTH_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}`, `IMPLEMENTATION_PROMPTS_[timestamp]_${CLAUDE_SESSION_ID}`, `SALES_PRICING_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}`, `ANALYTICS_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}`, `MESSAGING_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}`, `SEO_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}`, `MERGE_ALL_REPORT_${CLAUDE_SESSION_ID}` (literal — no timestamp)

**Operational** (scoped to session):
`IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md`, `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md`, `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md`, `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md`, `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md`, `CI_FIX_SUMMARY_${CLAUDE_SESSION_ID}.md`, `CI_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md`

---

### Worktree Builds

For medium/large features (4+ files), `/v` automatically creates an isolated git worktree before invoking `/v-build`. This prevents parallel sessions from conflicting.

- **Auto-created** for medium (4-10 files) and large (10+ files) scope
- **Override**: `--worktree` forces worktree regardless of scope; `--no-worktree` disables it
- **Naming**: `.worktrees/build-{feature}-${CLAUDE_SESSION_ID}` (or the equivalent session-scoped native worktree path)
- **Merge-back**: Fast-forward preferred → rebase fallback → hard stop on conflicts
- **Failed builds**: Worktree left intact for next session to resume from

See `_v-exec.md` → Build Worktree Lifecycle for full protocol.

---

### Agents (`.claude/agents/`)

| Agent | What it does | Classification |
|-------|-------------|----------------|
| `codex-adversarial-reviewer` | Sends diff to OpenAI Codex CLI for independent hostile review, adjudicates each finding against the codebase | Mandatory dispatch if agent file found; Codex CLI unavailability handled gracefully |
| `security-reviewer` | Reviews diffs touching auth/payments/user data for injection, IDOR/BOLA, SSRF, secrets, data exposure | Mandatory on security-sensitive diffs |
| `logic-reviewer` | Reviews non-trivial PHP/JS/TS changes for logic errors, race conditions, N+1s, unbounded queries | Mandatory on non-trivial logic changes |
| `codebase-fit-reviewer` | Reviews new files/refactors for consistency with existing patterns and naming; catches reinvented utilities | Dispatched on new files / significant refactors |
| `framework-pitfall-reviewer` | Reviews queue/provider/webhook/cache-key/scheduler changes for framework-silent-override and env-keyed half-guard bugs | Dispatched only when the diff touches the gated surfaces (see project CLAUDE.md) |
| `v-pre-flight-runner` | Runs `/v-pre-flight` quality gates and writes `PRE_FLIGHT_REPORT_<sid>.md` | Read-only; used by `/v-pre-flight` |
| `v-verify-done-runner` | Runs `/v-verify-done` convention checks and writes `VERIFY_DONE_REPORT_<sid>.md` | Read-only; used by `/v-verify-done` |
| `v-qa-reviewer` | Independent acceptance/exploratory QA against the original request; writes `QA_REPORT_<sid>.md` | Read-only judge; used in `/v` Step 6.4.9 |
| `v-ux-critique-reviewer` | UX heuristic walkthrough of changed UI; writes `UX_CRITIQUE_<sid>.md` | Read-only, advisory; used in `/v` Step 3.5 |
| `v-workflow-verifier` | Drives changed user workflows (Playwright) and writes `WORKFLOW_VERIFICATION_<sid>.md` | Read-only, degrades loudly if no browser env; used in `/v` Step 3.5 |
| `v-orchestrator-auditor` | Read-only auditor of the `/v` system itself (skills, hooks, agents, validators) | Dispatched by `/v-self-audit` |

Review agents (`codex-adversarial-reviewer`, `security-reviewer`, `logic-reviewer`, `codebase-fit-reviewer`, `framework-pitfall-reviewer`) are dispatched automatically by `/v-verify-done` and `/v-build` during the review phase, selected by changed file type. External-model agent findings start at `confidence: low` and must be independently verified before escalation.

---

### Shared Modules (internals)

| Module | Governs |
|--------|---------|
| `_v-core.md` | PLAN_SCHEMA, artifact specs |
| `_v-exec.md` | Trust boundary, confirmation matrix, capability detection, TypeScript auto-remediation protocol |
| `_v-growth.md` | Growth trigger categories, funnel stage reference, growth audit entry points |
| `_v-review.md` | FINDING_FORMAT (FND-001 + confidence), agent dispatch protocol |
| `_v-design.md` | Design token discovery, AI-generic pattern detection, Visual Craft Gate |
| `_v-artifact-formats.md` | Hook-binding artifact contracts (which artifacts block commits when missing). See the table at the top of that file for the operator-facing summary. |

For the full map of all 13 `_v-*.md` orchestrator files (responsibility, consumers, runtime contract), read `~/.claude/skills/references/v-orchestrator-map.md`.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Help output lists skills that don't exist (drift from real skill folder) | Static catalog tables drift over time | RESOLVED 2026-05 — Skill catalog now generated at runtime via filesystem scan (see Skill Catalog section). Static tables for skill names are forbidden in v-help; only workflow chains, artifact patterns, and tombstones may remain hardcoded. |
| 2 | "Which skill should I use for X?" recommendation doesn't account for project state | Recommendation logic uses keyword match only | For non-audit questions: read project's CLAUDE.md if present; recommendation considers stack + stage + recent skills used. For audit-family questions ("which audit should I run?") DO NOT recommend inline — defer to `/v-audit-orchestrator --advise` which owns the signal-reading and routing rules at `~/.claude/skills/v-audit-orchestrator/references/auto-routing-rules.md`. |
| 3 | Help output is 100+ lines when user asked "what are my skills" | Not differentiated by query type | "What skills do I have" = terse list; "How do I X" = workflow guidance with skill chain; "Tell me about v-X" = single skill detail |
| 4 | Skill chain example uses outdated workflow | Chain examples not maintained | If chain example references a renamed/removed skill, it breaks; sweep examples when family changes |
## Removed Skills

| Skill | Status | What replaces it |
|-------|--------|------------------|
| `/v-audit-full` | Removed 2026-04 | Use `/v-audit-orchestrator` (canonical — routes specialists + auto-consolidates). |
| `run-claude-ecosystem-review.sh` | Archived 2026-07-05 | Use `/v-audit-orchestrator` (canonical entry point; superseded the shell runner). |
| `/v-ship` | Removed 2026-04-29 | Ops checks removed; config-validation moved to `/v-check` Domain 12. Full retirement notes: `~/.claude/skills/references/archive/v-check-vs-v-ship-decision.md`. |
| `/v-comparison-page` | Merged 2026-07-05 | Use `/v-content-create --type=comparison` (same playbook, now a brief type of v-content-create). |
| `/v-aeo-content` | Merged 2026-07-05 | Use `/v-content-create --type=aeo` (same playbook, now a brief type of v-content-create). |
| `/v-refactor` | Retired 2026-07-06 | Absorbed into `/v-audit-code`'s code-quality + modernization lenses (`references/refactor-modernization.md` covers the DEBT_TREND register and SaaS-arch shapes). Run `/v-audit-code` or say "refactor X". |
| `/v-ui-audit` | Retired 2026-07-06 | Deep UX/a11y absorbed into `/v-audit-code` (`references/deep-ux-audit.md`). |

## Idempotency

**Idempotent.** Read-only — surfaces help content without mutations.
