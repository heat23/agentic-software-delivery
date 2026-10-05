---
name: v-audit-code
description: "Use when auditing a whole codebase for production-readiness, refactoring/modernization, or deep UX/accessibility — evidence-backed findings + remediation plan."
context: fork
model: inherit  # inherit = run on the session/CLI model. Governs MANUAL /v-audit-code only; Skill-tool dispatch ignores it. Fan-out subprocesses are pinned separately at the dispatch site — via --model, or by the agent file's own frontmatter pin when dispatched with --agent (see v-core-model-routing.md).
allowed-tools: Read, Write, Bash, Glob, Grep, TaskCreate, TaskUpdate, AskUserQuestion, WebSearch, WebFetch
user-invocable: true
disable-model-invocation: true
---
<!-- skill: v-audit-code | version: 1.5.0 | last-updated: 2026-08-12 (added CI/CD-config + deepened supply-chain lenses; duration/EC-1/DEBT_TREND/modes_loaded consistency fixes) -->

# 2026 Canonical Contract

Tier: Specialized audit.

**Model — MANDATORY (parent-model inheritance).** Every subprocess this skill dispatches runs on the **operator's session model**, never a hardcoded tier — read `~/.claude/skills/references/v-audit-parent-model.md` and export its preamble ONCE before the first dispatch:

```bash
export V_MODEL_POLICY_OVERRIDE=1
V_AUDIT_MODEL="parent"     # every --model in this skill takes this value
```

Without that override every dispatch exits 2 on the sonnet-max gate. Never pass `--agent <name>` for a **haiku-pinned** agent — `--agent` ignores `--model` entirely and is the one path this preamble cannot correct (see that file's § The `--agent` bypass).


This contract overrides older sections below on conflict.

```yaml
contract:
  tier: specialized
  accepts: [project state, optional PROJECT_ROOT= in invocation prompt, optional depth keyword (quick|standard|thorough)]
  produces:
    - AUDIT_CODE_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md
    - AUDIT_CODE_DASHBOARD_[timestamp]_${CLAUDE_SESSION_ID}.html
    - .v-prompt-packs/v-audit-code-<MM-DD>/ (00-README.md + flat w<N>-*.txt wave packs per v-runnable-pack-convention.md)
  invokes: []
  dispatches: per-domain specialist passes (sequential default; parallel via fork-safe claude -p subprocesses — v-dispatch-subagent.sh)
  invoked-by: [user, /v, /v-audit-orchestrator]
  estimated_tokens: 30k-100k
  estimated_duration: 5-60 min   # Quick ~10 / Standard ~20-30 / Thorough ~40-60 (matches the Depth question)
```

> Whole-repo pass. **Directly invokable** — manually (`/v-audit-code`), routed from `/v` for refactor / clean-up / modernization / production-readiness / deep-UX-and-accessibility requests (it absorbed `/v-refactor` and `/v-ui-audit` on their 2026-07-06 retirement — see `references/refactor-modernization.md` and `references/deep-ux-audit.md`), or as a single `[Specialist]` menu entry in `v-audit-orchestrator`. Because it is a self-contained whole-repo pass it is still NOT auto-included in the orchestrator's multi-specialist **pre-launch bundles** (which fan out several focused audits + consolidate) — being routed to directly for a whole-repo request is different from being silently bundled into a sweep.

## Skill Boundaries

**SME persona:** This audit is run by a **senior production-readiness auditor + modernization architect** — specialty is whole-repo risk triage (security, data integrity, reliability), 2026-stack modernization gaps, and turning findings into runnable, test-first fix packs.

### Best fit

- Whole-codebase production-readiness pass rating each area with evidence-backed findings
- Modernization review against current (2026) framework/stack conventions
- Producing an in-repo remediation plan (fix packs) an implementer or `/v` can execute directly

### Use instead

- Use `/code-review` or the review flow for single-PR/diff review — this skill is a whole-repo pass, not a diff reviewer
- Use `/v-check` for the operational launch gate (deploy/config/monitoring readiness)
- Use the `v-audit-*` specialists (admin/seo/messaging/...) for domain-scoped product audits

### Not for

- Single-PR/diff review or non-code audits (content, marketing, legal)
- Applying fixes — this skill never modifies source; hand off packs to `/v`

# Production-Readiness & Modernization Audit

**PROJECT_ROOT resolution (mandatory, before any file read/write):** this skill runs with `context: fork`, so `pwd` is a Claude-internal directory, NOT the repo. Follow `~/.claude/skills/_v-audit.md` § PROJECT_ROOT Resolution: use `PROJECT_ROOT=` from the invocation prompt if present, else `git rev-parse --show-toplevel`, else stop and ask the user (AskUserQuestion) for the project path — never fall back to `pwd`. Refuse `$HOME`, `~/.claude`, and any other meta/config directory even when explicitly passed — ask instead. Every path below is relative to `$PROJECT_ROOT`.

**Progress tracking:** initialize the task list (one `TaskCreate` per step) with the six workflow steps before starting; keep it current, especially across the per-domain passes of a Thorough run.

## Depth

If the invocation prompt declares a depth, use it and skip the question (`fast/quick/light` → Quick; `default/normal/standard/medium` → Standard; `full/thorough/deep/comprehensive` → Thorough; if contradictory keywords appear, the deepest named tier wins — record the interpretation in the report header). If `V_DEPTH >= 1` appears (orchestrator context), default to Thorough. A "headless/non-interactive run" is defined by the SAME machine-checkable condition the sibling audits use (ND-0716 — never inferred from vibes): `V_DEPTH >= 1`, OR the batch-mode context per `_v-audit.md` § Consolidation / Batch Mode Contract (all four flags: `V_CHAIN=ecosystem-review-runner`, `HEADLESS_BATCH=1`, `CONSOLIDATION_MODE=1`, `RETURN_JSON_ONLY=1` — most simply detected via `RETURN_JSON_ONLY=1`). Only under one of those signals: default to Standard (when no depth was given) and record that default in the report header — a documented deviation from the no-silent-defaults rule, justified because there is no operator to ask and blocking would hang the run. An interactive `V_DEPTH = 0` session with none of those signals MUST still ask the depth question — "the model suspects nobody is watching" is not a headless signal. Otherwise, ask (AskUserQuestion, canonical family shape):

```yaml
question: "How deep should this production-readiness audit go?"
header: "Audit Depth"
multiSelect: false
options:
  - label: "Quick — for iteration"
    description: "Security, data integrity, reliability + scenario-elevated lenses; static analysis only, no gate runs. ~10 min."
  - label: "Standard — recommended default"
    description: "All applicable lenses, single deep pass; fast gates (lint/typecheck/targeted tests/audits); report + fix packs. ~20-30 min."
  - label: "Thorough — pre-launch / pre-merge"
    description: "Every lens, full gate suite, per-domain specialist deep passes; report + dashboard + fix packs + validator. ~40-60 min."
```

Depth controls scope, never honesty: a Quick pass that spots a blocker reports it at full severity. Deliverables scale with depth — Quick produces the verdict + findings report only (no dashboard, no fix packs unless asked); Standard adds fix packs for material findings and the dashboard when the material warrants it; Thorough produces everything.

## Execution discipline (reliability + efficiency)

- **Read by risk, not exhaustively.** Start from manifests, entry points, auth/mutation/payment paths, and the seams between subsystems; use Glob/Grep to locate hot spots instead of streaming whole directories. Sample breadth-wise, read depth-wise where the scenario says the blast radius lives. On a large repo, coverage claims must match what you actually read — name the areas you sampled vs. skipped.
- **Run gates safely or not at all.** Only quality-read commands: test, lint, typecheck, build, dependency audit. NEVER run migrations, seeders, deploy/publish scripts, or anything that mutates data or external state. Apply a timeout to every gate command; at Quick depth skip gates (static reasoning, stated as such), at Standard run the fast ones, at Thorough run the full suite. Record each command, its exit code, and whether it was skipped — a gate you didn't run is a stated limitation, never an implied pass.
- **Per-domain passes: sequential is the default shape.** This skill runs `context: fork`, so the Agent tool NEVER works here (nested subagent dispatch fails silently — F16). Plan Thorough as sequential per-domain deep passes, or dispatch domains as independent `claude -p` subprocesses via `~/.claude/skills/v/references/v-dispatch-subagent.sh --mode capture` when parallelism is worth the setup; never present sequential work as a parallel panel. Whoever does the domain pass (you or a subagent), bound its scope (the lens + its file set), require file:line anchors, and re-verify any anchor you cite in the final report yourself.
- **Read each reference file once, at the step that needs it** (`audit-lenses.md` at step 2, `rating-framework.md` at step 3, `remediation-format.md` at step 5, `presentation-and-voice.md` at step 6). Don't re-read; don't front-load all four.

## Edge conditions

- **`CLAUDE_SESSION_ID` unset** (e.g., invoked outside a Claude Code session): substitute `$(date +%Y%m%d-%H%M%S)-$$` in every artifact name so runs still can't collide. `[timestamp]` in artifact names is always `YYYYMMDD-HHMMSS` local time.
- **Monorepo / multiple deployable apps:** if the invocation doesn't say which app, ask (AskUserQuestion) rather than guessing or averaging unrelated apps into one score. If clearly told, audit that app and say the others were out of scope.
- **Dirty worktree or detached HEAD:** proceed, but record `git rev-parse HEAD` and dirty-file count in the report header; all anchors are valid as of that state. Never `git stash`, `checkout`, or otherwise touch the user's git state.
- **Prior `AUDIT_CODE_REPORT_*` exists:** hold its category set and scale steady so deltas mean something; show before → after movement. Re-derive every score from current code — never carry a prior score forward as evidence.
- **Not a web app** (CLI, library, worker): adapt the lens set — swap the UX lens's surface bar for CLI/API ergonomics (flags, errors, exit codes, docs); drop lenses that genuinely don't apply and say so in the framework rationale.
- **Tiny or greenfield repo:** a full audit is disproportionate — do a proportionate pass, say the surface is small, and don't pad findings to fill the format.
- **`python3` unavailable:** ship the fix-pack validator as an equivalent `validate.sh` instead (see `remediation-format.md`).

You are auditing a software codebase and answering two questions at once:

1. **Is the application production-ready** for its actual real-world scenario?
2. **Is it modern and cutting-edge for its era** — or competently solving today's problem with yesterday's assumptions?

Both matter. Clean, well-tested code can still be architecturally dated. Say so if it is. The whole point is an honest, evidence-backed verdict a skeptical engineer would trust — not a checklist ritual and not a rubber stamp.

## Scope boundary — in-app ONLY (read this first)

This audit is about **the software in the repository**: its code, config, and tests. Stay inside that boundary in findings *and* recommendations. This section is this skill's stricter local form of the family-wide `_v-audit.md` § In-App Actionability Boundary — that section's rules (including the off-stack ledger below) apply here too.

- **Evaluate** the app's own code, data model, in-process logic, and test suite — what ships in the repo.
- **Do not introduce or recommend new third-party vendors or hosted services** (no new SaaS, monitoring/uptime services, mail relays, external secret managers, offsite storage, external CI/security services). Every recommendation must be implementable within the app and its existing stack.
- **Be conservative about new dependencies.** Prefer framework-native / standard-library patterns and patterns already in the codebase. A new library is an exception you justify, not a default.
- **Do not review or grade runbooks, ops docs, deployment pipelines, or infrastructure.** If in-app *code* references them, a code-level correctness note is fair; the docs/infra themselves are out of scope.
- Where a genuinely modern practice would require leaving this boundary, note it in one sentence as context — do **not** turn it into a recommendation or score the app down for it. If it's worth keeping, record it only in `$PROJECT_ROOT/.v/OFF_STACK_LEDGER.md` per `_v-audit.md` § In-App Actionability Boundary → Off-stack ledger (replace this skill's own section, latest-wins; never as a finding).

## Principles (the why — not a rigid recipe)

- **Verify, don't trust.** Open the actual files. Every material claim needs a concrete anchor (file + symbol/line). A commit message, a docblock, a test name, or a prior audit is a hypothesis, not evidence. This is what separates a real audit from a vibe.
- **Ground-up and adversarial.** Assume nothing is correct until you've seen it. Hunt the failure modes a happy-path reviewer misses: partial failures, concurrency, idempotency, rollback correctness, trust boundaries, error handling, and the seams between components.
- **Honest about maturity.** If an area is genuinely solid, say so plainly and move on — never inflate severity or manufacture findings to look thorough. Equally, never rubber-stamp: name what's wrong, weak, or dated regardless of how polished the surrounding code looks. Your credibility is the deliverable.
- **Distinguish "wrong" from "dated" from "deliberately deferred."** A consciously deferred capability, or one outside the in-app boundary, is not an app defect. A design that works today but won't age is a real finding — flag it as an in-app modernization item.
- **You choose the method.** A panel of specialist sub-perspectives (spawn subagents per domain if available), a single deep pass, or tool-assisted analysis — whatever gives genuine coverage. If you can run the project's real test/lint/audit gates, do; if you can't, say so and reason statically, and be explicit about the limitation.

## Workflow

Adapt the order to the situation; don't treat this as lockstep.

1. **Orient.** Read the repo's own canon first — agent/convention files, architecture notes, decision records, dependency manifests, the test suite, and the real build/lint/typecheck/test commands. Establish the **actual operating scenario** (who runs this, at what scale, with what data sensitivity and blast radius); it defines the threat model and what "good" means. Prior audit artifacts may exist — skim for orientation, but do not trust or anchor to their scores; form your own view from the current code.

2. **Assess across lenses.** Read `references/audit-lenses.md` and apply the lenses that fit, weighted by the real scenario. For any UI-bearing surface, the visual bar is the canonical design system — `~/.claude/skills/_v-design.md` (tokens, typography/spacing scales, WCAG contrast + target-size definitions, Visual Craft Gate) with `.interface-design/system.md` as the only sanctioned per-product overlay; judge conformance against it, not against a per-project system of the repo's own invention. Add dimensions you think matter. Cite anchors as you go. **Two absorbed deep-modes, read on demand when the request calls for them (do NOT front-load either on a generic production-readiness pass):** for a **deep UX / accessibility / brand / SEO-UI** focus (or a request that came in as "UI audit / design review / accessibility / WCAG"), also read `references/deep-ux-audit.md` — the comprehensive UX+a11y mode absorbed from the retired `/v-ui-audit` (WCAG 2.2 AA compliance floor, structural anti-AI-tells, pixel-perfect thresholds, forms/brand/SEO-UI/visual-system/i18n) — and lean on the shared `~/.claude/skills/references/anti-ai-tells-content.md` for the copy tells. For a **refactor / clean-up / modernization** focus (or a request that came in as "refactor / simplify / modernize"), also read `references/refactor-modernization.md` — the SaaS-architecture refactor shapes + the optional `DEBT_TREND` trend-over-time register absorbed from the retired `/v-refactor`.

3. **Design a rating framework.** Read `references/rating-framework.md`. Pick categories and a scale that fit *this* system, define them, and score each with a one-line, evidence-grounded rationale. You own the framework; justify it and keep it comparable if the user re-runs over time.

4. **Write findings.** Each: a severity you can defend, concrete evidence (file + anchor / reproduction / recorded gate), the risk tied to the real scenario, and a concrete **in-app** fix. Separate genuine blockers from improvements from out-of-scope/deferred items. Fewer, sharper findings beat a padded list.

5. **Produce actionable remediation.** Turn the material findings into work an implementer (human or coding agent) can pick up directly. Read `references/remediation-format.md` for the self-contained, single-subject, test-first "fix pack" brief that forms each pack's body — that brief maps onto the schema below; adapt its guidance to the required headings, don't skip them. Emit the packs in the ecosystem's unified runnable form so `/v` and `run-v-packs` can consume them (single source of truth: `~/.claude/skills/references/v-runnable-pack-convention.md` § Canonical form + § Pack body schema; folder rule owned by `~/.claude/skills/references/v-core-prompt-pack.md`): directory `$PROJECT_ROOT/.v-prompt-packs/v-audit-code-<MM-DD>/` (archive any same-day prior pack dir before writing — the family's one-audit-per-name concurrency rule applies), a `00-README.md` wave-map table (wave/dependency order — the ONLY `.md` file), and one flat **`.txt`** pack per finding (or per tightly-coupled cluster of findings) — NOT `NN-<FINDING-ID>.md`. Wave-naming: no prefix = wave 0 (disjoint findings — the common case for a single audit's independent findings), `w1-`/`w2-` only where one fix genuinely depends on another landing first. **Closing waves are mandatory whenever Step 5 emits any implementation pack** (per `v-runnable-pack-convention.md` § Closing waves) — after the last implementation wave, append a parallel READ-ONLY verification wave (`w<N>-pre-flight.txt` running the project's full gates + `w<N>-review.txt` dispatching the adversarial/second-opinion reviewer agents — whatever lives in `.claude/agents/` matching the changed file types, always including an adversarial reviewer: codex-adversarial-reviewer, fallback `superpowers:requesting-code-review`), then a single sequential `w<N+1>-hardening.txt` (triages the review findings, fixes CRITICAL/HIGH, re-runs gates until green, runs `/v-verify-done`), then `99-verify.txt` last (final gate-runner). The two verification packs use `## Goal` / `## Checks` / `## Acceptance` and omit the "leave staged; do not commit" line. **Security-bearing pack clause (per `v-runnable-pack-convention.md` § Security-bearing packs):** when a pack's `## Files` touches request signing/HMAC/webhook or signature verification, credential/secret handling, host/URL construction from variables, auth/authz decisions, or payment flows — plausible here since the security lens is one of this audit's core dimensions — that pack's body MUST additionally inline: "This pack touches security-bearing code — dispatch an adversarial reviewer (codex-adversarial-reviewer, fallback superpowers:requesting-code-review) on your own diff before finishing; fix CRITICAL/HIGH in-session," in addition to (not instead of) the closing review wave. Line 1 of every pack starts with `/v `, paste-ready (no unsubstituted placeholders), self-contained, ≥50 lines, no commit/push instructions, and the body carries the mandatory schema in order: `## Goal` · `## Context` (the finding inlined with file:line evidence — no reference to the audit report/dashboard) · **`## Files`** (literal H2, every file to touch — REQUIRED, v-build's scope guard keys on it) · `## Changes` · `## Acceptance criteria` (checkbox) · `## Tests` · `## Constraints` (cite CLAUDE.md + stack + any guardrail) · `## Dependencies` (`Wave N. Requires: ...`) · ends "leave all changes staged; do NOT commit". Generate packs via a fork-safe `claude -p` subprocess at the operator's model (`v-dispatch-subagent.sh --model parent --mode self-write`) per the contract; if the dispatch helper or `claude` CLI is unavailable, generate inline — a documented deviation, safe here because this skill's single-pass audit keeps the material lean. Then self-validate the emitted tree (`~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate the emitted tree — or `~/.claude/scripts/validate-audit-prompt-packs.sh "$PROJECT_ROOT/.v-prompt-packs/v-audit-code-<MM-DD>"`) plus `run-v-packs "$PROJECT_ROOT/.v-prompt-packs/v-audit-code-<MM-DD>" --dry-run` plus the content checks from `remediation-format.md`, and fix until PASS. This skill **never modifies source** — it produces the plan and artifacts. If the user asks to apply a fix pack in this session, hand off to `/v` (e.g., `/v apply fix packs 1 and 2 from <pack folder>`): `/v` owns the TDD/build routing, the quality gates, and the Stop-hook artifact contract (`PRE_FLIGHT_REPORT_${SID}` / `AGENT_REVIEW_${SID}`) that an audit session cannot satisfy mid-flight. Do not edit inline even if pressed — explain the hand-off instead.

6. **Deliver with craft.** Read `references/presentation-and-voice.md`. Use `assets/dashboard-template.html` as the base for a responsive scorecard + filterable-findings view rather than rebuilding one each time. One severity vocabulary everywhere: findings, fix-pack IDs, and the dashboard's `sev` field all use P0–P3 per `~/.claude/skills/references/v-core-severity.md` ([[v-core-severity]]) — its definitions and "one P0 ⇒ failing verdict" rule govern this skill's severities (the template's `sev` values are the lowercase form, `"p0"`–`"p3"`, per its inline example). Lead with the verdict; no walls of text; humanized voice.

## Output

Canonical artifact paths (all under `$PROJECT_ROOT`, all session-bound so concurrent or repeat runs never collide):

- Report: `AUDIT_CODE_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md`
- Dashboard: `AUDIT_CODE_DASHBOARD_[timestamp]_${CLAUDE_SESSION_ID}.html`
- Fix packs: `.v-prompt-packs/v-audit-code-<MM-DD>/` (family convention — dated, not SID-suffixed, so `run-v-packs` discovers it; same-day re-runs archive the prior dir first)

The report opens with a machine-checkable header before the verdict: audited commit (`git rev-parse HEAD`), dirty-file count, date, depth tier, scope (app/paths audited vs. excluded), the absorbed deep-modes actually loaded (`modes_loaded: deep-ux` / `modes_loaded: refactor` / `modes_loaded: deep-ux,refactor` when both ran / `modes_loaded: none` — comma-joined, no spaces; v-check's overlap-skip rule keys on this stamp via substring grep, so it must reflect what actually ran), and the gates run with exit codes (or `skipped: <reason>`). Everything a future run needs to compute honest deltas.

Deliver, in whatever form best fits the material:

- **A clear verdict** — ready / not / yes-with-conditions. Don't hedge into meaninglessness.
- **A rating scorecard** — your framework, each category scored with a one-line evidence-based rationale.
- **Prioritized findings** — severity, evidence anchor, scenario-tied risk, in-app fix.
- **A modernization section** — where the app is dated within its own walls, what a cutting-edge in-app version looks like, and whether the change is worth it here (including where "leave it" is the right call).
- **Remediation artifacts** — the fix packs + validator, ready to hand off.
- **Honesty about diminishing returns** — if it's genuinely in good shape, say so instead of inventing work.

Match the deliverable's polish to the audience: a consumer/multi-user surface warrants more visual engagement; an internal tool with a few operators should optimize for productivity, clarity, and low cognitive load — well-designed and fast, not flashy.

## Idempotency

**Idempotent.** Re-running on the same project produces a fresh SID-qualified report and dashboard, and a fresh dated pack dir (same-day priors archived, never clobbered); scores stay comparable across runs per `references/rating-framework.md`. Strictly read-only on source: no filesystem mutations outside the three named artifact paths above plus the optional `$PROJECT_ROOT/.v/OFF_STACK_LEDGER.md` (per `_v-audit.md` § In-App Actionability Boundary → Off-stack ledger), ever. (The session harness may create a `.v/` telemetry dir in the project — hook-owned, not this skill's write.) Fix-pack application is always handed off to `/v` (Workflow step 5).

## Guardrails

- No fabrication: never invent a metric, CVE, benchmark, file, or line number. If you assert a figure or external fact, it must be real and checkable — use WebSearch/WebFetch to verify any external claim (CVE ID, advisory, benchmark, EOL date, dependency vulnerability) before citing it; if you can't verify, say so.
- No rubber-stamping and no fear-mongering: severity must survive a skeptical engineer.
- Stay in-app: no new vendors/services, no runbook/infra review, no recommendations that leave the codebase.
- Respect deliberate trade-offs, but don't let "it's intentional" excuse a genuine in-app safety hole — argue the case either way.
