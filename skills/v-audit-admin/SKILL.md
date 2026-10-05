---
name: v-audit-admin
description: "Use when auditing admin panels or back-office UI for usability, security, and destructive-action gaps."
context: fork
model: inherit  # inherit = run on the session/CLI model. Governs MANUAL /v-audit-admin only; Skill-tool dispatch ignores it. Fan-out subprocesses are pinned separately at the dispatch site — via --model, or by the agent file's own frontmatter pin when dispatched with --agent (see v-core-model-routing.md).
allowed-tools: Read, Glob, Grep, Bash, Write, TaskCreate, TaskUpdate, AskUserQuestion
user-invocable: true
disable-model-invocation: true
---
<!-- skill: v-audit-admin | version: 1.4.2 | last-updated: 2026-08-12 -->
<!-- 1.3.1 (2026-08-02): SME coverage-gap fix — added Gotchas #6 and #7 documenting the
     Domain 4 instance-less-authorize()/can() IDOR/BOLA detector and the rewritten
     Tenant Isolation enumerate-every-model check; the actual detection logic lives in
     references/admin-audit-checklists.md (same-day rewrite, see its own changelog). -->
<!-- line-count exception (~555 body lines vs 500 target): the 3-pass discovery
     protocol, feature-inventory matrix, and depth-tiered domain weighting are
     load-bearing inline workflow; long-form checklists and report templates are
     already extracted to references/admin-audit-checklists.md and
     references/report-templates.md. Documented-exception route, matching the
     sibling convention in v-audit-analytics/v-audit-seo/v-audit-messaging. -->


# 2026 Canonical Contract

Tier: Specialized audit.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-audit.md`, `_v-exec.md`, `_v-review.md`, and `_v-design.md` (for visual craft domain).

**Model — MANDATORY (parent-model inheritance).** Every subprocess this skill dispatches runs on the **operator's session model**, never a hardcoded tier — read `~/.claude/skills/references/v-audit-parent-model.md` and export its preamble ONCE before the first dispatch:

```bash
export V_MODEL_POLICY_OVERRIDE=1
V_AUDIT_MODEL="parent"     # every --model in this skill takes this value
```

Without that override every dispatch exits 2 on the sonnet-max gate. Never pass `--agent <name>` for a **haiku-pinned** agent — `--agent` ignores `--model` entirely and is the one path this preamble cannot correct (see that file's § The `--agent` bypass).


For error handling, read `~/.claude/skills/references/v-core-error-handling.md`.
For prompt pack generation, read `~/.claude/skills/references/v-core-prompt-pack.md`.
For report skeletons, read `references/report-templates.md`.
For the canonical P0-P3 severity scale + cross-vocabulary mapping (the Domain 2-4 subagents emit `critical|high|medium|low` — map to `P0|P1|P2|P3` before scoring), read `~/.claude/skills/references/v-core-severity.md`.

Rules:
- use the shared `FINDING_FORMAT`
- every heuristic finding includes `confidence`
- domain-prefixed finding IDs: `ADM-PM-`, `ADM-DES-`, `ADM-UX-`, `ADM-QA-`, `ADM-OPS-`, `ADM-AI-`
- these prefixes are specializations of `FINDING_FORMAT` per `_v-review.md` rule 5

Write `ADMIN_AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.json`. In standalone mode, also write the companion `.md` report.

```yaml
contract:
  tier: specialized
  accepts: [project state, ADMIN_AUDIT_DEPTH (scoped mode depth signal)]
  produces: [ADMIN_AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.json, companion .md report in standalone mode, .v-prompt-packs/v-audit-admin-<MM-DD>/ in standalone mode]
  invokes: []
  dispatches: up to 3 parallel claude -p subprocesses for Thorough depth (fork-compatible; Agent tool does not work from context: fork)
  invoked-by: [/v, user, /v-audit-orchestrator]
  estimated_tokens: 20k-80k
  estimated_duration: 3-20 min
```

# /v-audit-admin — Multi-Persona Admin Panel Audit

**Conventions:** Follow `_v-core.md` for artifacts and paths, `_v-audit.md` for shared audit boilerplate (PROJECT_ROOT, V_DEPTH, TodoWrite, batch mode, prompt generation, JSON validation, error handling), `_v-exec.md` for execution rules, `_v-review.md` for findings, and `_v-design.md` for visual craft checks.

**Scope boundary (mandatory):** per `_v-audit.md` § In-App Actionability Boundary — off-stack items (runbooks/ops process, offsite backups, HA/failover/DR, external monitoring/alerting services, CI/CD or DNS/CDN infrastructure, new vendors/tools) never become findings, scores, or prompt packs. Deferred observations go only to `$PROJECT_ROOT/.v/OFF_STACK_LEDGER.md` per that section (standalone mode only). The ADM-OPS lens's failed-job monitoring / queue-health items mean **in-app admin surfaces** (dashboards, Horizon-style pages the repo ships) — never external monitoring services.

## Why This Exists

AI-built admin panels have a predictable failure mode: structurally complete CRUD but operationally hollow. No bulk operations, no audit trails, no error handling, off-spec one-off page shells that drift from the shared layout the design system mandates. This skill audits admin panels from a product/design/UX/QA/ops perspective using 6 specialized lenses.

## Skill Boundaries

**SME persona:** This audit is run by a **senior B2B internal-tools designer + RBAC architect** — specialty is admin surface UX, role/permission model design, audit logging, multi-tenancy boundaries, and the operational quality bar that distinguishes an admin panel built by a startup founder from one shipped by a mature B2B SaaS.

### Best fit

- Admin and back-office audits where the core question is CRUD completeness, operational tooling, admin UX, auditability, and AI-built blind spots
- Focused admin-panel reviews that need a feature inventory matrix plus prioritized findings
- Admin-focused reviews as part of the ecosystem review runner batch

### Use instead

- Use `/v-check` for a broad codebase audit that includes admin files but is not centered on admin operations
- Use `/v-build` if the admin audit already exists and the next step is implementation
- Use `/v-audit-code` (deep-UX mode — absorbed `/v-ui-audit` 2026-07-06) for the comprehensive product UX/a11y audit across the user-facing app; v-audit-admin is the admin-panel specialist subset
- Run ALL audit skills together via the ecosystem review runner for a full product/business readiness audit

### Not for

- Replacing a full security, performance, or launch audit
- General frontend polish outside admin surfaces
- Treating missing non-admin product features as admin-panel gaps

## Invocation Modes

### Standalone Mode (user invokes `/v-audit-admin` directly or `/v` classifies as admin audit)

- Full admin panel audit across all applicable domains
- Asks entry-point question for depth
- Writes ADMIN_AUDIT_REPORT with Feature Inventory Matrix and prioritized findings
- Recommends next steps

### Headless Batch Consolidation Mode (called by `ecosystem-review-runner`)

Triggered only when the invocation context includes all of:
- `V_CHAIN=ecosystem-review-runner`
- `HEADLESS_BATCH=1`
- `CONSOLIDATION_MODE=1`
- `RETURN_JSON_ONLY=1`

**Headless batch rules:**
1. **Skip the entry-point question** — use the explicit depth in the invocation prompt, or default to Thorough if omitted.
2. **Write only the JSON report** — do not write the companion Markdown report.
3. **Do not generate `.v-prompt-packs/v-audit-admin-<MM-DD>/`**.
4. **Return the same finding schema and composite `area_score`** used by standalone/scoped operation.
5. **Do not enable this mode for interactive runs** — outside the trusted headless runner chain, keep normal standalone behavior.

## Entry Point (Standalone Only)

**V_DEPTH parsing:** Per `_v-audit.md` § V_DEPTH Parsing and § Depth Question Contract. **When V_DEPTH >= 1 (orchestrator invoked):** Skip ALL entry-point questions. Default to Thorough depth unless the invocation already passed an explicit depth. When V_DEPTH == 0 and no explicit params, ask the canonical depth question:

```yaml
question: "How deep should this admin audit go?"
header: "Audit Depth"
multiSelect: false
options:
  - label: "Quick — for iteration"
    description: "Route + Model scan, domains 1+5+6 (PM + Ops + AI blind spots). ~3-5 min."
  - label: "Standard — recommended default"
    description: "Route + Model scan + fingerprint-only page scan, domains 1+2+5+6 (PM + Design + Ops + AI). ~8-10 min."
  - label: "Thorough — pre-launch / pre-merge"
    description: "All 3 discovery passes, all 6 domains, parallel subagents. ~15-20 min."
```

---

## Verification Gates (REQUIRED — v-audit-gates v1)

**Moved to:** `~/.claude/skills/references/v-audit-gates.md`.

**Summary:** apply Gates 0, 1, 2, and 8 before declaring this audit complete:
- **Gate 1 — Citation format parseability** (every finding cites parseable `path:line`)
- **Gate 0 — Show your work** (per-dim exploration block; orchestrator spot-checks 2 random citations per subagent)
- **Gate 2 — Per-dim floor with mandatory re-task** (re-task before auto-justify; max 1 dim auto-justified per audit)
- **Gate 8 — File-existence verification** (verify output artifacts exist via Glob before methodology emission)

**Trigger to load:** every audit run loads the reference before running its first dim. Read the full gate definitions, escape-hatch rules, and forbidden methodology language list there — the 4-bullet summary above is a cheat sheet, not a substitute.

## Output conventions (v1.0 — v3.8.5 compatible)

**Moved to:** `~/.claude/skills/references/v-audit-output-conventions.md`.

**Summary:** every audit emits a version stamp (`Generated by {skill-name} v1.0`) in its methodology block, uses clickable Markdown file:line citations (`[path:line](path#Lline)` preferred, plain `path:line` fallback), and assigns stable finding IDs (`D{dim}-{C|F|P|A}-{nnn}`) for re-run diffability.

**Trigger to load:** every audit run loads the reference before emitting the report. Read it once at the start of Phase 1 / Step 0, not once per dim.

## Floors (per-dim minimum-findings calibration)

This skill's per-dim floors are defined in
`~/.claude/skills/references/v-audit-floors.md`. The floors
activate Gate 2 enforcement (see Verification Gates section above):
returns below floor trigger mandatory re-task before any
auto-justification.

**Section to load:** scan v-audit-floors.md for the section header `## v-audit-admin floors` — that's this skill's floor table. Gate 2 enforcement uses that exact header to locate the table at runtime.

The orchestrator detects project stage in Phase 1 and selects the
appropriate floor column (mature / growth / early) per the stage-selection
rule in `v-audit-floors.md` § Stage definitions — **mature signals dominate;
select `early` only on an unambiguous greenfield signal with no contradicting
mature signal.** Admin-specific rationale: a thin day-0 admin surface has
little to find, so a `mature` floor there just manufactures finding-pressure
Gate 2 must absorb — but that `early` shortcut must NEVER fire against a live,
revenue-bearing, deployed product.

To recalibrate floors, update `v-audit-floors.md` (not this skill
body). Floor changes should be backed by ≥3 audits showing a
consistent over- or under-shoot.

## Mandatory Execution Workflow (FOLLOW THIS ORDER)

**Every standalone invocation MUST complete ALL steps. Do NOT stop after writing the audit report.**

**Audit opener:** see `_v-audit.md` § Audit Skill Opener — perform PROJECT_ROOT resolution, V_DEPTH parsing, and TodoWrite initialization before Step 0 begins.

| Step | Action | Skip conditions |
|------|--------|----------------|
| **Step 0** | Entry point — determine depth (Quick/Standard/Thorough) | If depth passed in args, skip question |
| **Step 1** | Three-pass discovery engine (route scan, model scan, page scan) | Page scan: full in Thorough, fingerprint-only in Standard, skipped in Quick |
| **Step 2** | Run audit domains, score, write ADMIN_AUDIT_REPORT JSON + MD | — |
| **Step 3** | **Generate implementation prompts (MUST USE SUBAGENT)** — dispatch a fork-safe `claude -p` subprocess at the operator's model (via `v-dispatch-subagent.sh --model parent`; the Agent tool does NOT work from `context: fork`) to create `.v-prompt-packs/v-audit-admin-<MM-DD>/` with 00-README.md + flat `w<N>-*.txt` wave packs | — |
| **Step 3.5** | Validate JSON before write — per `_v-audit.md` § Step 3.5 | — |
| **Step 4** | **Validate prompt pack** — run structural validator from `~/.claude/skills/references/v-core-prompt-pack.md` | — |
| **Step 5** | Present summary with next steps pointing to `.v-prompt-packs/v-audit-admin-<MM-DD>/` | — |

**Steps 3-4 are NOT optional in standalone mode.** The prompt files are the primary deliverable — users run these in parallel sessions. The audit report without prompts is an incomplete output.

---

## Step 0: Entry point (depth — Quick / Standard / Thorough)

Per the **Entry Point** section above (Standalone Mode). Determines audit depth via single multi-choice question; skips the question when V_DEPTH >= 1 (defaults to Thorough) or when the operator's prompt declares a depth (`quick`, `standard`, `thorough`). Sets `DEPTH` for downstream Steps 1-2 and dictates how Pass 3 (page scan) runs: full in Thorough, fingerprint-only in Standard, skipped in Quick.

## Step 1: Three-Pass Discovery Engine

The discovery phase — runs all three passes (route, model, page) and assembles the **Feature Inventory Matrix** that subagents read at Step 2. See **Three-Pass Discovery Engine** below for full pass-by-pass detail.

## Step 2: Audit domains + scoring + write report

Run the 6 audit domains (per **6 Audit Domains** section below) in subagent topology determined by depth. Score per domain weights, write `ADMIN_AUDIT_REPORT_*.md` and `.json`. Subagent topology and score-rubric details follow.

## Three-Pass Discovery Engine

Before auditing, discover the admin panel's structure. Read `${CLAUDE_SKILL_DIR}/references/admin-audit-checklists.md` for all detection patterns and grep commands.

### Early Exit

If no admin routes are detected after Pass 1, stop immediately and report:

```markdown
# ADMIN_AUDIT_REPORT
generated: [ISO_DATE]
status: no_admin_panel
message: No admin panel detected. No admin-prefixed routes, no admin directory in pages/views, and no admin middleware found.
recommendation: If this project has an admin panel under a different prefix, re-run and specify it: /v-audit-admin (the skill will ask for the prefix, or pass it in the prompt e.g. "audit admin panel at /manage")
```

### Pass 1: Route Scan (Quick + Thorough)

Map admin routes to controllers to Inertia pages (or Blade views, or React routes).

**Steps:**
1. Detect admin route prefix (common: `admin`, `dashboard`, `manage`, `backoffice`, `internal`)
2. List all routes under that prefix
3. Classify each route as: `index` | `create` | `store` | `show` | `edit` | `update` | `destroy` | `custom`
4. Map routes to their controllers and page components

**Detection commands:** See `${CLAUDE_SKILL_DIR}/references/admin-audit-checklists.md` § Discovery Patterns.

### Pass 2: Model Scan (Quick + Thorough)

Inventory all Eloquent models (or equivalent ORM models) and cross-reference with Pass 1.

**Steps:**
1. List all models in `app/Models/` (or equivalent)
2. For each model, check if admin CRUD routes exist from Pass 1
3. Flag models with no admin representation (coverage gap) — but ONLY after applying the missing-CRUD **exemption class** in `admin-audit-checklists.md` § Domain 1 → Missing CRUD Checks (pivot/join, read-only lookup, system/framework, internal-log, and derived/cache models are exempt; only user-facing domain models warrant a CRUD-gap finding). This prevents the report flooding with noise on every pivot table.
4. Flag models using `SoftDeletes` without a restore route/UI in admin (detection of existing code — the global hard-deletes default is a build-time rule, not something this audit imposes)

### Pass 3: Page Scan (full in Thorough; fingerprint-only in Standard)

Walk admin page components and detect structural features.

**Steps:**
1. Read each admin page component identified in Pass 1
2. For each page, detect: tables, forms, search inputs, filter controls, bulk checkboxes, export buttons, pagination, empty states, loading states, error boundaries, confirmation dialogs (Thorough only)
3. Compute structural fingerprint per page (layout pattern hash) for shell-consistency detection in Domains 2 and 6 — layout consistency across admin pages is REQUIRED (spec §1); the fingerprint detects pages that BREAK the shared shell

**Standard mode (Pass 3-lite):** run steps 1 and 3 only — compute fingerprints, skip feature detection. Feature Inventory Matrix feature columns stay `?`; Domain 2's shell-conformance check gets real fingerprint data. In Quick mode, Pass 3 does not run at all — shell-break checks fall back to the Quick-mode limits in `admin-audit-checklists.md` § Domain 6.

---

## Feature Inventory Matrix

Always generated from discovery passes. This is the primary deliverable alongside findings.

Use the example matrix in `references/report-templates.md` when formatting the report.

- **Quick mode:** CRUD columns (`List`, `Create`, `Edit`, `Delete`) populated from routes. Other columns marked `?` (unknown — not scanned).
- **Standard mode:** CRUD columns from routes, other columns `?` (Pass 3-lite computes fingerprints only, not feature detection).
- **Thorough mode:** All columns populated from page scan. `Y` = detected, `N` = not found, `?` = could not determine.
- Resources with no admin representation are listed with all `N`.

---

## 6 Audit Domains

**Reference:** Read `${CLAUDE_SKILL_DIR}/references/admin-audit-checklists.md` for detailed checklists, grep commands, and evidence requirements for each domain.

| # | Domain | Persona | ID Prefix | Runs In | Key Focus |
|---|--------|---------|-----------|---------|-----------|
| 1 | Functional Completeness | Product Manager | ADM-PM | Quick + Thorough | Missing CRUD, bulk ops, export, admin-specific pages, relationship management, workflow dead ends |
| 2 | Visual Craft & Consistency | Designer | ADM-DES | Standard + Thorough | Shared-shell conformance, spacing (fixed scale), visual hierarchy, placeholder content, icon consistency (inline SVG), typography, canonical theme tokens. References `_v-design.md` |
| 3 | Usability & Interaction | UX Developer | ADM-UX | Thorough only | Loading states, error boundaries, confirmations, form dirty-state, search debouncing, filter persistence, keyboard nav, mobile responsiveness, pagination UX |
| 4 | Edge Cases & Robustness | QA Engineer | ADM-QA | Thorough only | Empty states, long text overflow, form validation (client+server), permission boundaries, file upload edge cases, error recovery, concurrent editing |
| 5 | Audit Trail & Security | Operations | ADM-OPS | Quick + Thorough | Action audit logging, before/after capture, activity log viewer, permission granularity, rate limiting, session management, 2FA enforcement, failed job monitoring, queue health, tenant isolation |
| 6 | AI-Built Blind Spots | Cross-cutting | ADM-AI | Quick + Thorough | Shared-shell breaks (pages off the mandated sidebar/header shell), happy-path only, binary permissions, no operational tooling, missing ⌘K command palette (spec §6.2), placeholder content, missing pages AI never builds, SoftDeletes without restore, no data integrity tools |

### Audit Order

Always audit in this order: PM (1) → OPS (5) → AI (6) → DES (2) → UX (3) → QA (4).

Quick mode runs domains 1, 5, 6 (3 domains). Standard mode runs domains 1, 2, 5, 6 (4 domains, adds Design persona). Thorough mode runs all 6 domains with parallel subagents and Pass 3 page scan.

---

## Depth Behavior

| Aspect | Quick | Standard | Thorough |
|--------|-------|----------|----------|
| Discovery | Pass 1 + 2 | Pass 1 + 2 + 3-lite (fingerprints only) | Pass 1 + 2 + 3 (full) |
| Matrix | CRUD columns, rest `?` | CRUD columns, rest `?` | All columns |
| Domains | 1, 5, 6 | 1, 2, 5, 6 | All 6 |
| Priorities | P0/P1 only | P0/P1/P2 | P0/P1/P2/P3 |
| Subagents | None (sequential) | None (sequential) | Dispatch Domains 2-4 in parallel |
| Duration | ~3-5 min | ~8-10 min | ~15-20 min |

Standard mode runs its 4 domains sequentially in the main context — Domain 2 uses the checklists in `admin-audit-checklists.md` § Domain 2 inline (no subagent), reading the Pass 3-lite fingerprints for shell conformance.

P3 only appears in Thorough because it is exclusively produced by the Domain 2-4 subagents' `low` severity, which maps to `P3` per `[[v-core-severity]]` (`~/.claude/skills/references/v-core-severity.md` § Cross-vocabulary mapping) and `admin-audit-checklists.md` § Subagent Prompts. Domains 1, 5, 6 (which run at every depth) never natively emit `P3` — their native ceiling is `P2` — so Quick and Standard's `by_priority.P3` is always `0`, not omitted from the schema.

### Thorough Mode: Subagent Dispatch (fork-safe)

**The Agent tool does NOT work here** — this skill runs `context: fork` (it IS a subagent, and subagents cannot dispatch subagents; an `Agent(...)` call fails silently and degrades to inline self-review). In Thorough mode, after completing domains 1, 5, 6 sequentially:
1. Write one fully-substituted briefing file per domain (2, 3, 4) from `${CLAUDE_SKILL_DIR}/references/admin-audit-checklists.md` § Subagent Prompts, embedding the discovery results (routes, models, pages, fingerprints)
2. Dispatch each as an independent subprocess: `~/.claude/skills/v/references/v-dispatch-subagent.sh --model parent --mode capture --prompt-file "$BRIEF" --artifact "$SCRATCH_DIR/adm-domain-<N>.md"` — run all 3 via `~/.claude/skills/v/references/v-supervise-children.sh` (one `--child` per domain, `--max-concurrency 3`) in a blocking Bash call
3. Apply 5-minute wall-clock timeout per subprocess per `~/.claude/skills/references/v-core-error-handling.md`; completion = artifact on disk, non-empty — never the subprocess's prose exit message
4. Merge findings from the 3 artifacts using deduplication protocol from `_v-review.md`

---

## Scoring

### Domain Weights

Weights are hand-tuned per depth (not mechanically renormalized). Each column sums to 100%.

| Domain | Thorough | Standard | Quick |
|--------|----------|----------|-------|
| PM (Functional Completeness) | 35% | 45% | 55% |
| OPS (Audit Trail & Security) | 20% | 30% | 35% |
| UX (Usability) | 15% | — | — |
| QA (Edge Cases) | 15% | — | — |
| DES (Visual Craft) | 10% | 15% | — |
| AI (Blind Spots) | 5% | 10% | 10% |

### Score Rubric

| Score | Meaning |
|-------|---------|
| 9-10 | No issues found or only minor cosmetic findings |
| 7-8.9 | Minor P2s, functionally complete |
| 5-6.9 | Mix of P1 findings, some operational gaps |
| 3-4.9 | Multiple P1s, significant functional or operational gaps |
| 0.1-2.9 | P0 findings present, critical admin functionality missing |
| 0 | No admin panel exists |

(Boundaries are disjoint and exhaustive over [0, 10] — each score falls in exactly one bucket, e.g. a 7.0 is "7-8.9" not also "5-6.9". `0` is the exact-zero sentinel for "no admin panel exists"; every score in `(0, 2.9]` — including 0.1-0.9, previously uncovered — falls in "0.1-2.9".)

### Score Calculation

Weighted average of domain scores. When a domain fails (Thorough subagent crash), exclude it from the denominator per `_v-core.md`. Report `AUDIT_INCOMPLETE` per the depth-specific thresholds in § Error Handling below (NOT a flat ">50% of domains fail" rule — the depth-specific table is normative; do not restate a second, looser threshold here).

---

## Output Format

File: `$PROJECT_ROOT/ADMIN_AUDIT_REPORT_YYYY-MM-DD_HHMM_${CLAUDE_SESSION_ID}.md` (absolute path — use resolved PROJECT_ROOT, NOT `pwd`)
<!-- Phase-2 DEFERRAL (2026-07-06): v-audit-admin is ecosystem-review-runner-coupled (its runner-mode JSON is a `primary_json_glob` input; that external runner has no .v/artifacts awareness), so this family stays at the repo root until the runner is updated — same as SESSION_LOG (Phase 3) and the specialist audit-family. -->
The JSON report is the primary deliverable. The Markdown report is a companion summary.

Use `references/report-templates.md` for:
- the JSON report structure
- the Markdown companion skeleton
- the example Feature Inventory Matrix

Include only sections with findings. Omit empty priority sections in the Markdown companion.

---

### Step 3: Generate Implementation Prompts (MUST USE SUBAGENT)

Per `_v-audit.md` § Step 3: Prompt Generation Contract, **overridden here per the unified pack standard** (`~/.claude/skills/references/v-runnable-pack-convention.md` — individual skill contracts override `_v-audit.md` on conflict per its own header): output is the `.txt` wave form, not `_v-audit.md`'s legacy `NN-*.md` example (fork-safe `claude -p` subprocess via `v-dispatch-subagent.sh` — NOT the Agent tool, which fails silently from `context: fork`). Set `PROMPT_DIR=".v-prompt-packs/v-audit-admin-$(date +%m-%d)"`. Include sections 3a, 3b, 3c (below) verbatim in the briefing file.

Pre-dispatch shell setup (run before dispatching the subprocess):

**`/v` first-line requirement:** every pack file (flat `.txt`, excluding `00-README.md`) MUST start on line 1 with the literal `/v ` prefix (the orchestrator routing prefix). Files that do not start with `/v ` — or that are not `.txt` — are rejected by the post-generation validator (`~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate the emitted tree — or `~/.claude/scripts/validate-audit-prompt-packs.sh`) and the pack will fail. The dispatched subagent must produce paste-ready files: operator copy-pastes the entire file content into a fresh `/v` session with zero edits required.


```bash
PROMPT_DIR=".v-prompt-packs/v-audit-admin-$(date +%m-%d)"

# Idempotent re-run: archive any prior pack, then create the active dir.
# Per `_v-audit.md` § Step 3: Prompt Generation Contract — see the Pre-dispatch shell block.
# Without this, fewer-or-renamed packs on re-run leave stale w<N>-*.txt orphaned;
# the post-generation validator counts them and reports a false-positive PASS.
if [ -d "$PROJECT_ROOT/$PROMPT_DIR" ] && [ -n "$(ls -A "$PROJECT_ROOT/$PROMPT_DIR" 2>/dev/null)" ]; then
  PACK_TS=$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)
  mv "$PROJECT_ROOT/$PROMPT_DIR" "$PROJECT_ROOT/$PROMPT_DIR.bak-$PACK_TS"
fi
mkdir -p "$PROJECT_ROOT/$PROMPT_DIR"
```

### Step 3.5: Validate JSON Before Write

Per `_v-audit.md` § Step 3.5: JSON Validation.

---

### Step 4: Validate Prompt Pack

Run the self-validate block from `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate the emitted tree (or `~/.claude/scripts/validate-audit-prompt-packs.sh "$PROJECT_ROOT/$PROMPT_DIR"`), then `run-v-packs "$PROJECT_ROOT/$PROMPT_DIR" --dry-run` to confirm the wave plan resolves as assigned. On failure, re-dispatch the subprocess once with the failure messages as context (per `_v-audit.md` § Step 4: Post-Generation Validation retry rule). On second failure, mark `prompt_pack: validation_failed` in the JSON report.

### Step 5: Present Summary

Present a concise summary:
- **Depth** and domains audited
- **Score:** X.X/10 with domain breakdown
- **Finding counts:** P0/P1/P2/P3 (P3 only at Thorough depth)
- **Prompt files:** "Implementation prompts are in `.v-prompt-packs/v-audit-admin-<MM-DD>/`. Run each in a parallel `/v` session."
- **Next steps:** Point to `.v-prompt-packs/v-audit-admin-$(date +%m-%d)/00-README.md` for the wave map. If you've run other `/v-audit-*` skills on this project recently, run `/v-audit-consolidate` first to merge overlapping findings into one prioritized backlog (audits → consolidate → build).

#### 3a. Build the File Dependency Graph

1. **Extract file targets** — for every finding, list every file it touches (both files to modify and test files to create).
2. **Build a conflict graph** — two findings conflict if they share any file target.
3. **Cluster connected components** — findings that share files (directly or transitively) must go in the same session.
4. **Handle dependencies** — if finding A depends on finding B, they must be in the same session (or A's session must be marked as "run after B's session").

#### 3b. Assign Sessions

Group the clusters into sessions:

1. **Size each session at 15-40 estimated hours.** Smaller sessions finish faster; larger ones have more context.
2. **Theme each session** — give it a descriptive name based on the dominant domain (e.g., "Admin Functional Completeness", "Audit Trail & Security Hardening", "Admin UX & Edge Cases").
3. **Order findings within each session** by priority (P0 first), then by dependency order, then by effort (smallest first for early momentum).
4. **Sort sessions** by priority of their highest-priority finding (sessions with P0 findings come first).
5. **Separate domains:** Group by audit domain where possible (PM findings together, OPS findings together) unless they share file targets.

Aim for 3-6 packs total. **Wave mapping:** each cluster/session from 3a/3b becomes one pack file. A cluster with no dependency edge on another cluster takes NO wave prefix (wave 0 — the common case: most admin findings across different domains touch disjoint files). Only assign `w1-`, `w2-` prefixes where 3a's dependency-handling step found a genuine dependency — per `~/.claude/skills/references/v-runnable-pack-convention.md` § Wave assignment.

#### 3c. Write Wave Packs

Create a directory `.v-prompt-packs/v-audit-admin-<MM-DD>/` in the project workspace. Write one flat `.txt` file per pack (NOT `.md`, NOT `NN-` numbered):

```
.v-prompt-packs/v-audit-admin-<MM-DD>/
  00-README.md                         ← Overview, wave map, dependency notes (the ONLY .md file)
  functional-completeness.txt          ← wave 0: self-contained /v prompt (copy-paste ready)
  audit-trail-security.txt             ← wave 0
  w1-admin-ux-polish.txt               ← wave 1 (only if it depends on an earlier pack landing first)
  ...
  w<N>-pre-flight.txt                  ← closing wave: read-only gate run (§ 3d)
  w<N>-review.txt                      ← closing wave: read-only adversarial/second-opinion review (§ 3d)
  w<N+1>-hardening.txt                 ← closing wave: sequential triage + fix + re-gate (§ 3d)
  99-verify.txt                        ← final gate-runner, always last
```

**00-README.md** must include:
- Project name, audit date, depth, total findings, estimated total hours
- A wave map table: `| Wave | File | Theme | Domain | Findings | Est. Hours | Can Parallel? |` — the table's last rows are always the closing waves (pre-flight + review in parallel, then hardening, then `99-verify`)
- Dependencies between packs (most should have none — wave 0)
- Post-merge quality gate commands from CLAUDE.md
- Every filename named in the table must exist on disk and vice-versa (no phantom/orphan packs)

#### 3d. Closing waves (per `v-runnable-pack-convention.md` § Closing waves)

After the last implementation wave assigned in 3a/3b, always append the standard closing waves as the
highest wave prefixes: a parallel READ-ONLY verification wave — `w<N>-pre-flight.txt` (runs the project's
full quality gates) + `w<N>-review.txt` (dispatches the adversarial/second-opinion reviewer agents — whatever
lives in the project's `.claude/agents/` matching the changed file types, always including an adversarial
reviewer: codex-adversarial-reviewer, fallback `superpowers:requesting-code-review`) — then a single
sequential `w<N+1>-hardening.txt` (triages the review findings, fixes CRITICAL/HIGH, re-runs gates until
green, runs `/v-verify-done`), then `99-verify.txt` last (final gate-runner). The two verification packs use
`## Goal` / `## Checks` / `## Acceptance` (not the implementation schema) and OMIT the "leave staged; do not
commit" line — they are read-only, they never fix.

**Security-bearing pack clause (per `v-runnable-pack-convention.md` § Security-bearing packs) — matters most
here.** Domain 5 (Audit Trail & Security) findings routinely produce fixes touching auth/authz decisions
(role/permission checks, tenant-isolation boundaries), 2FA enforcement, session management, and credential
handling — exactly the security-bearing classes the convention calls out. When an implementation pack's
`## Files` touches request signing/HMAC/webhook or signature verification, credential/secret handling,
host/URL construction from variables, auth/authz decisions, or payment flows, that pack's body MUST
additionally inline: "This pack touches security-bearing code — dispatch an adversarial reviewer
(codex-adversarial-reviewer, fallback superpowers:requesting-code-review) on your own diff before finishing;
fix CRITICAL/HIGH in-session." This is in addition to, not a replacement for, the closing review wave above.

**Each pack file (`<theme>.txt`, `w1-<theme>.txt`, etc.)** contains ONLY the prompt — the entire file is what gets pasted into a new session. Line 1 is the `/v` invocation; the body below MUST carry these sections, in order, per `~/.claude/skills/references/v-runnable-pack-convention.md` § Pack body schema: `## Goal` · `## Context` · **`## Files`** (literal H2, every file to touch — REQUIRED, v-build's scope guard keys on it) · `## Changes` · `## Acceptance criteria` (checkbox) · `## Tests` · `## Constraints` (cite CLAUDE.md + stack + guardrails) · `## Dependencies` (`Wave N. Requires: ...`).

```markdown
/v Fix the following admin panel audit findings for [Project Name].

## Goal
Fix [N] admin audit findings in the [theme] area — [1-3 sentence outcome + why].

## Context
Read the project's CLAUDE.md first for architecture context, conventions, and quality gate commands.
Tech stack: [brief tech stack from orientation].
Admin prefix: [detected admin route prefix].

### Finding 1: [ID] [Title] (P0, Xh est.)
**Problem:** [description with evidence, file:line]

### Finding 2: [ID] [Title] (P1, Xh est.)
...

## Files
- path/to/file.ts:42 — [what changes]
- path/to/other.test.ts — [new test file]
(every file any finding below touches)

## Changes

Work through these in order. For each one: write the test first (TDD for backend, test-after for UI), implement the fix, run the verification command, then move to the next.

### Fix 1: [ID] [Title] (P0, Xh est.)
**Problem:** [description with evidence]
**Files:** [exact paths with line numbers where applicable]
**Implementation:** [specific code changes to make]

### Fix 2: [ID] [Title] (P1, Xh est.)
...

## Acceptance criteria
- [ ] [Finding 1 fixed and verified via its verification command]
- [ ] [Finding 2 fixed and verified via its verification command]
- [ ] Full verification suite passes

## Tests
- [test file path, test name, setup, assertions — enough detail to write the test without referencing anything else — one per finding]

## Constraints
- Read the project's CLAUDE.md first
- Tech stack: [from orientation]
- [any guardrail the findings imply]

## Dependencies
Wave [N]. Requires: [prior pack name(s), or "none"].

Run the full verification suite:
\`\`\`bash
[project-specific quality gate commands from CLAUDE.md]
\`\`\`

Leave all changes staged; do NOT commit — the operator/orchestrator owns commits.
```

**Prompt writing rules:**
- Start with `/v` so the orchestrator routes automatically
- Include project context (name, stack, admin prefix, instruction to read CLAUDE.md) inline in `## Context`
- Each fix includes exact file paths, line numbers, implementation details, and test specs
- Completely self-contained — no references to other pack files or the audit report
- End with the project's full verification suite

---

## Error Handling

Per `_v-audit.md` § Error Handling for Parallel Subagents. Specific thresholds for `AUDIT_INCOMPLETE`: 4 of 6 domain failures in Thorough, 3 of 4 in Standard, all 3 of 3 in Quick.

---

## Quality Rules

1. **Evidence required** — every finding needs file:line or grep output
2. **No false positives** — verify before reporting
3. **Actionable fixes** — include specific code, not just descriptions
4. **Prioritized correctly** — missing audit trail = P0, pages breaking the shared shell = P1, cosmetic spacing drift = P2
5. **Acknowledge good** — list what's done right in VERIFIED_GOOD
6. **Check before recommending** — don't recommend what's already configured
7. **Cross-reference with `_v-design.md`** — visual craft findings follow design governance

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Audit flags admin panel "needs improvement" without specific feature gaps | Three-pass discovery skipped Pass 3 (page scan) | Pass 3 is mandatory in Thorough mode; without it, findings are speculative |
| 2 | Subagent topology defaults to all 6 dims for Quick mode (60+ min budget) | Depth-mode wiring not honored | Quick = 3 dims (~3-5 min); Standard = 4 dims (~8-10 min); Thorough = all 6 dims with Pass 3 (~15-20 min) |
| 3 | Audit findings re-flag issues that were "deferred per operator preference" | Operator preferences not loaded | Operator preferences must be read at Step 0 and inform dim allocation |
| 4 | Privilege-escalation finding generic ("admin can do too much") | Specific role scope not extracted | Pass 1 (route scan) must enumerate every authenticated route + check policy/middleware; findings cite specific routes |
| 5 | Re-running on same project produces different ADMIN_AUDIT_REPORT | Discovery non-deterministic | Pass output should be sorted; same input + same skill version = same report (modulo time-based fields) |
| 6 | Textbook IDOR (`$this->authorize('update', Model::class)`) passes the admin audit cleanly | Authorization check was presence-only (`grep -c "authorize\|Gate::\|can("`) — any call at all counted as a pass | `admin-audit-checklists.md`'s Domain 4 authorization check now captures the call's 2nd argument; an instance-less class-reference on an ability that needs one (`view`/`update`/`delete`/`restore`/`forceDelete`) is a P0 finding, never a pass |
| 7 | Cross-tenant data leak never surfaces as a finding despite the persona's multi-tenancy-architect claim | Tenant Isolation check was two unscored greps for the string `team_id`, no per-model enumeration, no severity table | `admin-audit-checklists.md`'s Tenant Isolation section now enumerates every tenant-owned model (not a sample), greps for scope-bypassing raw-query paths, and scores an unscoped tenant model P0 |

## Idempotency

**Idempotent.** Re-running on the same project produces a fresh SID-qualified audit report. Findings can be diffed across runs to track regression vs improvement. No filesystem mutations outside of the audit artifact directory.
